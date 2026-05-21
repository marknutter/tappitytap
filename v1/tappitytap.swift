import Foundation
import IOKit
import IOKit.hid
import Dispatch
import AVFoundation

// Phase 3 (v2): tap detection with audio-feedback resistance.
//
// Two problems v1 had:
//   1) Played sound vibrates the chassis -> accelerometer reads it as new
//      taps -> cascading false triggers per single physical tap.
//   2) Fast drumming feels unresponsive because the detector is busy
//      chewing through phantom retriggers.
//
// Fixes:
//   * Schmitt trigger: after a tap, require STA to drop below a low re-arm
//     threshold before the next tap can fire. Audio ring-out can't sustain
//     a flat-line of triggers anymore.
//   * STA tau = 1 ms so we ride the impact edge, not the decay envelope.
//   * Click sounds are generated as ~5 ms damped-sine pings with random
//     pitch. Tiny audio footprint = tiny feedback footprint, and we get
//     drum-toy variety for free.

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
let STA_TAU_S: Double = 0.001       // 1 ms — rides the impact edge
// --- These four are what a settings UI will eventually expose. ---
let HISTORY_MS = 20                  // sliding window for "recent valley"
let DELTA_TRIGGER_G: Double = 0.025  // rise-from-valley needed to fire
let MIN_PEAK_G: Double = 0.025       // peak must exceed this absolutely
let PEAK_WINDOW_S: Double = 0.008    // 8 ms — capture the impact peak, then fire
let POST_FIRE_BLACKOUT_S: Double = 0.050  // 50 ms — let the chassis ring out
// Total min gap between fires = PEAK_WINDOW_S + POST_FIRE_BLACKOUT_S = 58 ms (~17 Hz)
let PRIME_SAMPLES = 200

let SOFT_INTENSITY: Double = 0.05
let HARD_INTENSITY: Double = 0.30

// Click generator parameters.
let AUDIO_SR: Double = 44_100.0
let CLICK_DURATION_S: Double = 0.030  // 30 ms total
let CLICK_DECAY_TAU_S: Double = 0.006 // exponential decay constant

// =====================================================================
// MARK: - Click bank (programmatic damped-sine pings)
// =====================================================================

func makeClickBuffer(frequency: Double, format: AVAudioFormat) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount(CLICK_DURATION_S * AUDIO_SR)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    let channels = Int(format.channelCount)
    let twoPiF = 2.0 * .pi * frequency
    for n in 0..<Int(frames) {
        let t = Double(n) / AUDIO_SR
        let env = exp(-t / CLICK_DECAY_TAU_S)
        let sample = Float(sin(twoPiF * t) * env)
        for c in 0..<channels {
            buf.floatChannelData![c][n] = sample
        }
    }
    return buf
}

final class TapPlayer {
    private let engine = AVAudioEngine()
    private var buffers: [AVAudioPCMBuffer] = []
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0

    init() throws {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        // Pentatonic-ish set so even random sequences sound musical.
        let frequencies: [Double] = [440, 523.25, 587.33, 659.25, 783.99, 880]
        for f in frequencies {
            buffers.append(makeClickBuffer(frequency: f, format: format))
        }
        for _ in 0..<8 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        try engine.start()
        for p in players { p.play() }
    }

    func playTap(intensity: Double) {
        let buf = buffers.randomElement()!
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        let t = (intensity - SOFT_INTENSITY) / (HARD_INTENSITY - SOFT_INTENSITY)
        let volume = Float(max(0.2, min(1.0, 0.2 + 0.8 * t)))
        player.volume = volume
        player.scheduleBuffer(buf, at: nil, options: [.interrupts], completionHandler: nil)
    }
}

// =====================================================================
// MARK: - Tap detector (per-sample, Schmitt-triggered)
// =====================================================================

var gx: Double = 0, gy: Double = 0, gz: Double = -1
var sta: Double = 0
var samplesSeen: UInt64 = 0
var primed = false

// State machine: idle -> peakCapture (after trigger) -> blackout -> idle
enum DetectorState { case idle, peakCapture, blackout }
var state: DetectorState = .idle
var stateRemaining = 0
var peakStaInWindow: Double = 0

// Ring buffer of recent STA samples for valley tracking.
var history = [Double](repeating: 0, count: HISTORY_MS)
var historyHead = 0

func emaAlpha(tauSeconds: Double) -> Double {
    return 1.0 - exp(-1.0 / (tauSeconds * SAMPLE_HZ))
}
let GRAVITY_A = emaAlpha(tauSeconds: GRAVITY_TAU_S)
let STA_A     = emaAlpha(tauSeconds: STA_TAU_S)
let PEAK_WINDOW_SAMPLES   = Int(PEAK_WINDOW_S   * SAMPLE_HZ)
let BLACKOUT_SAMPLES      = Int(POST_FIRE_BLACKOUT_S * SAMPLE_HZ)

var tapPlayer: TapPlayer!
var tapCount = 0

@inline(__always)
func processSample(x: Double, y: Double, z: Double) {
    gx += GRAVITY_A * (x - gx)
    gy += GRAVITY_A * (y - gy)
    gz += GRAVITY_A * (z - gz)
    let ax = x - gx, ay = y - gy, az = z - gz
    let mag = sqrt(ax*ax + ay*ay + az*az)
    sta += STA_A * (mag - sta)

    // Update ring buffer of recent STA samples.
    history[historyHead] = sta
    historyHead = (historyHead + 1) % HISTORY_MS

    samplesSeen += 1
    if samplesSeen < PRIME_SAMPLES { return }
    if !primed {
        primed = true
        print("listening. delta=\(DELTA_TRIGGER_G)g minPeak=\(MIN_PEAK_G)g peakWin=\(PEAK_WINDOW_S)s blackout=\(POST_FIRE_BLACKOUT_S)s")
    }

    switch state {
    case .peakCapture:
        if sta > peakStaInWindow { peakStaInWindow = sta }
        stateRemaining -= 1
        if stateRemaining == 0 {
            tapCount += 1
            let intensity = peakStaInWindow
            print(String(format: "tap #%-3d  i=%.3f", tapCount, intensity))
            tapPlayer.playTap(intensity: intensity)
            peakStaInWindow = 0
            state = .blackout
            stateRemaining = BLACKOUT_SAMPLES
        }
        return

    case .blackout:
        // Hard mute on detection so chassis ring-out can't produce phantom taps.
        stateRemaining -= 1
        if stateRemaining == 0 { state = .idle }
        return

    case .idle:
        break
    }

    // Rising-edge detector: fire on rise from recent valley, regardless of
    // absolute level. Lets rapid drumming through even when chassis is still
    // ringing from prior hits.
    var minRecent = sta
    for s in history where s < minRecent { minRecent = s }
    let rise = sta - minRecent
    if rise > DELTA_TRIGGER_G && sta > MIN_PEAK_G {
        state = .peakCapture
        stateRemaining = PEAK_WINDOW_SAMPLES
        peakStaInWindow = sta
    }
}

// =====================================================================
// MARK: - HID
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
    print("Woke \(count) AppleSPUHIDDriver service(s).")
}

// =====================================================================
// MARK: - Main
// =====================================================================

do {
    tapPlayer = try TapPlayer()
} catch {
    print("audio init failed: \(error)")
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

print("Audio ready. Tap the chassis (Ctrl-C to quit).")
dispatchMain()
