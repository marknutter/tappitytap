import Foundation
import IOKit
import IOKit.hid
import Dispatch
import Darwin
import TappityTapShared

// When stdout/stderr are redirected to a file (which is what launchd does
// via StandardOutPath / StandardErrorPath), Swift's print() goes through a
// fully buffered FILE*, so nothing reaches the log until ~4 KB accumulates
// or the process exits. That made the daemon's logs look empty during
// debugging. Disable buffering so each print() flushes immediately.
setbuf(stdout, nil)
setbuf(stderr, nil)

// =====================================================================
// MARK: - Constants
// =====================================================================

let APPLE_SPU_USAGE_PAGE: UInt32 = 0xFF00
let ACCEL_USAGE: UInt32 = 3
let APPLE_VENDOR_ID: UInt32 = 0x5AC
let SPU_ACCEL_PRODUCT_ID: UInt32 = 0x8104
let SCALE: Double = 65536.0

let SAMPLE_HZ: Double = 1000.0
let GRAVITY_TAU_S: Double = 1.0
let STA_TAU_S: Double = 0.001
let PEAK_WINDOW_S: Double = 0.008
let HISTORY_MS = 20             // short window for rising-edge valley
let REST_HISTORY_MS = 200       // long window for "chassis at rest" gate
let REST_FLOOR_G = 0.020        // STA must dip below this within REST_HISTORY_MS
                                // for the chassis to count as "recently at rest".
                                // Suppresses triggers during pickup / walking / etc.
let PRIME_SAMPLES = 200

// =====================================================================
// MARK: - Mutable tuning (atomic via serial queue)
// =====================================================================

final class Tuning {
    private let q = DispatchQueue(label: "tappitytap.tuning")
    private var _deltaG: Double = 0.025
    private var _minPeakG: Double = 0.025
    private var _blackoutSamples: Int = 50    // 50 ms at 1 kHz
    private var _enabled: Bool = true

    var deltaG: Double { q.sync { _deltaG } }
    var minPeakG: Double { q.sync { _minPeakG } }
    var blackoutSamples: Int { q.sync { _blackoutSamples } }
    var enabled: Bool { q.sync { _enabled } }

    func update(deltaG: Double?, minPeakG: Double?, blackoutMs: Int?, enabled: Bool?) {
        q.sync {
            if let v = deltaG { _deltaG = v }
            if let v = minPeakG { _minPeakG = v }
            if let v = blackoutMs { _blackoutSamples = max(1, v) }
            if let v = enabled { _enabled = v }
        }
    }
}

let tuning = Tuning()

// =====================================================================
// MARK: - IPC server (Unix socket, JSON-line)
// =====================================================================

final class IPCServer {
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private let clientLock = NSLock()
    private let path: String

    init(path: String) {
        self.path = path
    }

    func start() throws {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "socket", code: Int(errno)) }
        listenFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strlcpy(UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self), src, sunPathCapacity)
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        guard bindResult == 0 else { throw NSError(domain: "bind", code: Int(errno)) }

        // chmod 666 so any user on this machine can connect (helper runs as root).
        chmod(path, 0o666)

        guard listen(fd, 1) == 0 else { throw NSError(domain: "listen", code: Int(errno)) }

        DispatchQueue.global(qos: .utility).async { [weak self] in self?.acceptLoop() }

        print("ipc server listening at \(path)")
    }

    private func acceptLoop() {
        while true {
            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 {
                if errno == EINTR { continue }
                print("accept error: \(errno)")
                break
            }
            print("client connected fd=\(cfd)")
            // Replace any existing client.
            clientLock.lock()
            if clientFD >= 0 { close(clientFD) }
            clientFD = cfd
            clientLock.unlock()
            // Send hello and start reading commands on a background queue.
            sendMessage(ServerMessage.hello(sampleHz: Int(SAMPLE_HZ)))
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.readLoop(fd: cfd) }
        }
    }

    private func readLoop(fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                return read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 {
                print("client disconnected fd=\(fd)")
                clientLock.lock()
                if clientFD == fd { clientFD = -1 }
                clientLock.unlock()
                close(fd)
                return
            }
            buffer.append(chunk, count: n)
            // Process any complete lines.
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.isEmpty else { continue }
                do {
                    let msg = try decodeLine(line, as: ClientMessage.self)
                    handle(msg)
                } catch {
                    print("decode error: \(error)")
                }
            }
        }
    }

    private func handle(_ msg: ClientMessage) {
        if msg.type == "setParams" {
            tuning.update(deltaG: msg.deltaG, minPeakG: msg.minPeakG, blackoutMs: msg.blackoutMs, enabled: msg.enabled)
            let summary = "delta=\(tuning.deltaG) minPeak=\(tuning.minPeakG) blackoutMs=\(tuning.blackoutSamples) enabled=\(tuning.enabled)"
            print("setParams -> \(summary)")
        }
    }

    func sendMessage<T: Encodable>(_ msg: T) {
        let data = encodeLine(msg)
        clientLock.lock()
        let fd = clientFD
        clientLock.unlock()
        guard fd >= 0 else { return }
        _ = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
            return write(fd, ptr.baseAddress, ptr.count)
        }
    }
}

let ipc = IPCServer(path: SocketPath.default)

// =====================================================================
// MARK: - Detector (per-sample, rising-edge + peak-capture + blackout)
// =====================================================================

var gx: Double = 0, gy: Double = 0, gz: Double = -1
var sta: Double = 0
var samplesSeen: UInt64 = 0
var primed = false

enum DetectorState { case idle, peakCapture, blackout }
var state: DetectorState = .idle
var stateRemaining = 0
var peakStaInWindow: Double = 0

var history = [Double](repeating: 0, count: HISTORY_MS)
var historyHead = 0
var restHistory = [Double](repeating: 0, count: REST_HISTORY_MS)
var restHead = 0

func emaAlpha(tauSeconds: Double) -> Double {
    return 1.0 - exp(-1.0 / (tauSeconds * SAMPLE_HZ))
}
let GRAVITY_A = emaAlpha(tauSeconds: GRAVITY_TAU_S)
let STA_A     = emaAlpha(tauSeconds: STA_TAU_S)
let PEAK_WINDOW_SAMPLES = Int(PEAK_WINDOW_S * SAMPLE_HZ)

let startedAt = Date()

@inline(__always)
func processSample(x: Double, y: Double, z: Double) {
    gx += GRAVITY_A * (x - gx)
    gy += GRAVITY_A * (y - gy)
    gz += GRAVITY_A * (z - gz)
    let ax = x - gx, ay = y - gy, az = z - gz
    let mag = sqrt(ax*ax + ay*ay + az*az)
    sta += STA_A * (mag - sta)

    history[historyHead] = sta
    historyHead = (historyHead + 1) % HISTORY_MS
    restHistory[restHead] = sta
    restHead = (restHead + 1) % REST_HISTORY_MS

    samplesSeen += 1
    if samplesSeen < PRIME_SAMPLES { return }
    if !primed { primed = true }

    if !tuning.enabled { return }

    switch state {
    case .peakCapture:
        if sta > peakStaInWindow { peakStaInWindow = sta }
        stateRemaining -= 1
        if stateRemaining == 0 {
            let intensity = peakStaInWindow
            let ts = Date().timeIntervalSince(startedAt)
            ipc.sendMessage(ServerMessage.tap(intensity: intensity, timestamp: ts))
            peakStaInWindow = 0
            state = .blackout
            stateRemaining = tuning.blackoutSamples
        }
        return

    case .blackout:
        stateRemaining -= 1
        if stateRemaining == 0 { state = .idle }
        return

    case .idle:
        break
    }

    var minRecent = sta
    for s in history where s < minRecent { minRecent = s }
    let rise = sta - minRecent

    // Rest gate: only allow a trigger if the chassis was at rest at some
    // point in the last REST_HISTORY_MS. Sustained motion (lifting, walking,
    // setting the laptop down) keeps STA above the rest floor for the whole
    // window, so triggers stay suppressed throughout. Drumming with a hand-off
    // chassis keeps inter-tap STA near zero, so triggers fire normally.
    var restMin = sta
    for s in restHistory where s < restMin { restMin = s }
    let chassisRecentlyAtRest = restMin < REST_FLOOR_G

    if rise > tuning.deltaG && sta > tuning.minPeakG && chassisRecentlyAtRest {
        state = .peakCapture
        stateRemaining = PEAK_WINDOW_SAMPLES
        peakStaInWindow = sta
    }
}

// =====================================================================
// MARK: - HID setup
// =====================================================================

func parseReport(_ ptr: UnsafePointer<UInt8>, length: Int) -> (Double, Double, Double)? {
    guard length >= 18 else { return nil }
    let raw = UnsafeRawPointer(ptr)
    let xRaw = raw.loadUnaligned(fromByteOffset: 6,  as: Int32.self).littleEndian
    let yRaw = raw.loadUnaligned(fromByteOffset: 10, as: Int32.self).littleEndian
    let zRaw = raw.loadUnaligned(fromByteOffset: 14, as: Int32.self).littleEndian
    return (Double(xRaw) / SCALE, Double(yRaw) / SCALE, Double(zRaw) / SCALE)
}

let inputCallback: IOHIDReportCallback = { _, result, _, _, _, report, reportLength in
    guard result == kIOReturnSuccess else { return }
    guard let xyz = parseReport(report, length: reportLength) else { return }
    processSample(x: xyz.0, y: xyz.1, z: xyz.2)
}

func wakeSPUDrivers() {
    let matchDict = IOServiceMatching("AppleSPUHIDDriver")
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iter) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(iter) }
    func cfInt(_ v: Int32) -> CFNumber {
        var x = v
        return CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &x)
    }
    var count = 0
    while case let svc = IOIteratorNext(iter), svc != 0 {
        defer { IOObjectRelease(svc) }
        count += 1
        IORegistryEntrySetCFProperty(svc, "SensorPropertyReportingState" as CFString, cfInt(1))
        IORegistryEntrySetCFProperty(svc, "SensorPropertyPowerState"     as CFString, cfInt(1))
        IORegistryEntrySetCFProperty(svc, "ReportInterval"               as CFString, cfInt(1000))
    }
    print("woke \(count) AppleSPUHIDDriver service(s)")
}

// =====================================================================
// MARK: - Main
// =====================================================================

do {
    try ipc.start()
} catch {
    print("ipc start failed: \(error)")
    exit(1)
}

wakeSPUDrivers()

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matching: [String: Any] = [
    kIOHIDPrimaryUsagePageKey: APPLE_SPU_USAGE_PAGE,
    kIOHIDPrimaryUsageKey: ACCEL_USAGE,
    kIOHIDVendorIDKey: APPLE_VENDOR_ID,
    kIOHIDProductIDKey: SPU_ACCEL_PRODUCT_ID,
    kIOHIDTransportKey: "SPU",
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    print("IOHIDManagerOpen failed — run with sudo"); exit(1)
}
guard
    let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
    let device = devices.first
else { print("SPU accelerometer not found."); exit(2) }
guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    print("IOHIDDeviceOpen failed."); exit(3)
}

let reportSize = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
let hidQueue = DispatchQueue(label: "tappitytap.hid", qos: .userInteractive)
IOHIDDeviceSetDispatchQueue(device, hidQueue)
IOHIDDeviceRegisterInputReportCallback(device, buffer, reportSize, inputCallback, nil)
IOHIDDeviceActivate(device)

print("helper ready. tap the chassis.")
dispatchMain()
