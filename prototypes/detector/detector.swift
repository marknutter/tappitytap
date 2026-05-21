import Foundation
import IOKit
import IOKit.hid
import Dispatch

// Phase 2: tap detector.
//
// Pipeline (runs per-sample at ~1 kHz):
//   1. Read X/Y/Z (g).
//   2. Estimate gravity baseline with a slow EMA (tau ~ 1 s).
//      The AC component is (sample - baseline). Magnitude is its norm.
//   3. STA  = EMA of AC magnitude over ~5 ms  (short-term, sensitive to spikes).
//      LTA  = EMA of AC magnitude over ~500 ms (long-term, the background).
//   4. Trigger when STA/LTA > RATIO and STA > FLOOR and refractory has elapsed.
//   5. Emit TAP with intensity = peak STA in the trigger window.
//
// FLOOR exists so the detector doesn't fire on quiet noise just because LTA
// happens to be tiny (STA/LTA can blow up when both are near zero).
//
// Run with: sudo swift detector.swift

// ---------- Device constants ----------
let APPLE_SPU_USAGE_PAGE: UInt32 = 0xFF00
let ACCEL_USAGE: UInt32 = 3
let APPLE_VENDOR_ID: UInt32 = 0x5AC
let SPU_ACCEL_PRODUCT_ID: UInt32 = 0x8104
let SCALE: Double = 65536.0

// ---------- Detector tuning ----------
let SAMPLE_HZ: Double = 1000.0
let GRAVITY_TAU_S: Double = 1.0
let STA_TAU_S: Double = 0.005
let LTA_TAU_S: Double = 0.500
let TRIGGER_RATIO: Double = 4.0
let FLOOR_G: Double = 0.03          // ~3× the quiet-baseline peak we measured
let REFRACTORY_S: Double = 0.08     // 80 ms — long enough to skip ring-out

func emaAlpha(tauSeconds: Double) -> Double {
    // alpha such that the EMA has a time constant of tau at SAMPLE_HZ.
    return 1.0 - exp(-1.0 / (tauSeconds * SAMPLE_HZ))
}
let GRAVITY_A = emaAlpha(tauSeconds: GRAVITY_TAU_S)
let STA_A     = emaAlpha(tauSeconds: STA_TAU_S)
let LTA_A     = emaAlpha(tauSeconds: LTA_TAU_S)
let REFRACTORY_SAMPLES = Int(REFRACTORY_S * SAMPLE_HZ)

// ---------- Detector state ----------
var gx: Double = 0, gy: Double = 0, gz: Double = -1   // gravity baseline
var sta: Double = 0
var lta: Double = 0
var samplesSeen: UInt64 = 0
var refractoryRemaining = 0
var peakStaInWindow: Double = 0
var peakAxAbs: Double = 0, peakAyAbs: Double = 0, peakAzAbs: Double = 0
var ltaAtTrigger: Double = 0
var ratioAtTrigger: Double = 0
var samplesSinceTrigger: Int = 0
var triggerEventIndex: Int = 0
var primed = false
let PRIME_SAMPLES = 200

let startedAt = Date()
func t() -> String {
    return String(format: "%7.3fs", Date().timeIntervalSince(startedAt))
}

// ---------- HID parsing ----------
func parseReport(_ ptr: UnsafePointer<UInt8>, length: Int) -> (Double, Double, Double)? {
    guard length >= 18 else { return nil }
    let raw = UnsafeRawPointer(ptr)
    let xRaw = raw.loadUnaligned(fromByteOffset: 6,  as: Int32.self).littleEndian
    let yRaw = raw.loadUnaligned(fromByteOffset: 10, as: Int32.self).littleEndian
    let zRaw = raw.loadUnaligned(fromByteOffset: 14, as: Int32.self).littleEndian
    return (Double(xRaw) / SCALE, Double(yRaw) / SCALE, Double(zRaw) / SCALE)
}

// ---------- Per-sample tap detection ----------
@inline(__always)
func processSample(x: Double, y: Double, z: Double) {
    // Update gravity baseline.
    gx += GRAVITY_A * (x - gx)
    gy += GRAVITY_A * (y - gy)
    gz += GRAVITY_A * (z - gz)

    // AC component magnitude.
    let ax = x - gx, ay = y - gy, az = z - gz
    let mag = sqrt(ax*ax + ay*ay + az*az)

    // STA / LTA EMAs.
    sta += STA_A * (mag - sta)
    lta += LTA_A * (mag - lta)

    samplesSeen += 1
    if samplesSeen < PRIME_SAMPLES {
        return                          // let baselines settle
    }
    if !primed {
        primed = true
        print("[\(t())] detector primed. listening for taps. quiet floor=\(String(format: "%.4f", lta))")
    }

    if refractoryRemaining > 0 {
        refractoryRemaining -= 1
        samplesSinceTrigger += 1
        if sta > peakStaInWindow { peakStaInWindow = sta }
        let ax = x - gx, ay = y - gy, az = z - gz
        if abs(ax) > peakAxAbs { peakAxAbs = abs(ax) }
        if abs(ay) > peakAyAbs { peakAyAbs = abs(ay) }
        if abs(az) > peakAzAbs { peakAzAbs = abs(az) }
        if refractoryRemaining == 0 {
            triggerEventIndex += 1
            let intensity = peakStaInWindow
            // Identify dominant axis and per-axis fractions.
            let total = max(peakAxAbs + peakAyAbs + peakAzAbs, 1e-6)
            let fx = peakAxAbs / total, fy = peakAyAbs / total, fz = peakAzAbs / total
            let dom: String
            if fx >= fy && fx >= fz { dom = "X" }
            else if fy >= fx && fy >= fz { dom = "Y" }
            else { dom = "Z" }
            // Rise time = samples from trigger to peak.
            // (We start counting at the trigger sample, peak is during refractory.)
            let line = String(format:
                "[\(t())] EVT #%-3d  i=%.3f  ratio=%.1f  bgLta=%.4f  axis=%@(x%.2f y%.2f z%.2f)",
                triggerEventIndex, intensity, ratioAtTrigger, ltaAtTrigger, dom, fx, fy, fz)
            print(line)
            peakStaInWindow = 0
            peakAxAbs = 0; peakAyAbs = 0; peakAzAbs = 0
        }
        return
    }

    let ratio = lta > 1e-6 ? sta / lta : 0
    if ratio > TRIGGER_RATIO && sta > FLOOR_G {
        refractoryRemaining = REFRACTORY_SAMPLES
        peakStaInWindow = sta
        ratioAtTrigger = ratio
        ltaAtTrigger = lta
        samplesSinceTrigger = 0
        let ax = x - gx, ay = y - gy, az = z - gz
        peakAxAbs = abs(ax); peakAyAbs = abs(ay); peakAzAbs = abs(az)
    }
}

let inputCallback: IOHIDReportCallback = { _, result, _, _, _, report, reportLength in
    guard result == kIOReturnSuccess else { return }
    guard let xyz = parseReport(report, length: reportLength) else { return }
    processSample(x: xyz.0, y: xyz.1, z: xyz.2)
}

// ---------- Driver wake ----------
func wakeSPUDrivers() {
    let matchDict = IOServiceMatching("AppleSPUHIDDriver")
    var iter: io_iterator_t = 0
    let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iter)
    guard kr == KERN_SUCCESS else { return }
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

wakeSPUDrivers()

// ---------- Open the HID device ----------
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
let queue = DispatchQueue(label: "tappitytap.hid", qos: .userInteractive)
IOHIDDeviceSetDispatchQueue(device, queue)
IOHIDDeviceRegisterInputReportCallback(device, buffer, reportSize, inputCallback, nil)
IOHIDDeviceActivate(device)

print("Tap the chassis. Quiet for a second so the baseline can settle. Ctrl-C to quit.")
dispatchMain()
