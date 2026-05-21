import Foundation
import IOKit
import IOKit.hid
import Dispatch

// Phase 1 (v3): bare accelerometer reader with the driver-wake step.
//
// On Apple Silicon the AppleSPUHIDDriver starts in a non-reporting power
// state. Opening the HID device alone is not enough — you must first set
// three CF properties on the driver IORegistry entry:
//   SensorPropertyReportingState = 1
//   SensorPropertyPowerState     = 1
//   ReportInterval               = 1000   (microseconds -> ~1 kHz native)
//
// Then open the HID device, register an input report callback, and stream
// 22-byte reports. X/Y/Z are little-endian int32 at offsets 6/10/14 (÷65536 = g).
//
// Run with: sudo swift reader.swift

let APPLE_SPU_USAGE_PAGE: UInt32 = 0xFF00
let ACCEL_USAGE: UInt32 = 3
let APPLE_VENDOR_ID: UInt32 = 0x5AC
let SPU_ACCEL_PRODUCT_ID: UInt32 = 0x8104
let SCALE: Double = 65536.0

var sampleCount: UInt64 = 0
let PRINT_EVERY: UInt64 = 50            // ~1 kHz native -> print ~20 Hz
var restMagnitude: Double = 1.0
var maxDeviationThisWindow: Double = 0.0
var firstReportSeen = false

func parseReport(_ ptr: UnsafePointer<UInt8>, length: Int) -> (Double, Double, Double)? {
    guard length >= 18 else { return nil }
    let raw = UnsafeRawPointer(ptr)
    // loadUnaligned is required because offsets 6/10/14 aren't 4-byte aligned.
    let xRaw = raw.loadUnaligned(fromByteOffset: 6,  as: Int32.self).littleEndian
    let yRaw = raw.loadUnaligned(fromByteOffset: 10, as: Int32.self).littleEndian
    let zRaw = raw.loadUnaligned(fromByteOffset: 14, as: Int32.self).littleEndian
    return (Double(xRaw) / SCALE, Double(yRaw) / SCALE, Double(zRaw) / SCALE)
}

func hexDump(_ ptr: UnsafePointer<UInt8>, length: Int) -> String {
    var s = ""
    for i in 0..<length { s += String(format: "%02x ", ptr[i]) }
    return s
}

let inputCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
    guard result == kIOReturnSuccess else { return }

    if !firstReportSeen {
        firstReportSeen = true
        print("first report (\(reportLength) bytes): \(hexDump(report, length: reportLength))")
    }

    guard let xyz = parseReport(report, length: reportLength) else { return }
    let (x, y, z) = xyz
    let mag = sqrt(x*x + y*y + z*z)
    let deviation = abs(mag - restMagnitude)
    restMagnitude = restMagnitude * 0.9995 + mag * 0.0005
    if deviation > maxDeviationThisWindow { maxDeviationThisWindow = deviation }

    sampleCount += 1
    if sampleCount % PRINT_EVERY == 0 {
        let bar = String(repeating: "#", count: min(60, Int(maxDeviationThisWindow * 200)))
        let line = String(format: "x=%+.4f y=%+.4f z=%+.4f  peak|dev|=%.4f  %@",
                          x, y, z, maxDeviationThisWindow, bar)
        print(line)
        maxDeviationThisWindow = 0
    }
}

// ---- Step 1: wake every AppleSPUHIDDriver in the IORegistry ----

func wakeSPUDrivers() {
    let matchDict = IOServiceMatching("AppleSPUHIDDriver")
    var iter: io_iterator_t = 0
    let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iter)
    guard kr == KERN_SUCCESS else {
        print("IOServiceGetMatchingServices failed: 0x\(String(kr, radix: 16))")
        return
    }
    defer { IOObjectRelease(iter) }

    func cfInt(_ v: Int32) -> CFNumber {
        var x = v
        return CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &x)
    }

    var count = 0
    while case let svc = IOIteratorNext(iter), svc != 0 {
        defer { IOObjectRelease(svc) }
        count += 1
        let pairs: [(String, CFNumber)] = [
            ("SensorPropertyReportingState", cfInt(1)),
            ("SensorPropertyPowerState",     cfInt(1)),
            ("ReportInterval",               cfInt(1000)),
        ]
        for (key, value) in pairs {
            let rc = IORegistryEntrySetCFProperty(svc, key as CFString, value)
            if rc != KERN_SUCCESS {
                print("  set \(key) on driver #\(count) -> 0x\(String(rc, radix: 16))")
            }
        }
    }
    print("Woke \(count) AppleSPUHIDDriver service(s).")
}

wakeSPUDrivers()

// ---- Step 2: locate and open the HID device ----

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matching: [String: Any] = [
    kIOHIDPrimaryUsagePageKey: APPLE_SPU_USAGE_PAGE,
    kIOHIDPrimaryUsageKey: ACCEL_USAGE,
    kIOHIDVendorIDKey: APPLE_VENDOR_ID,
    kIOHIDProductIDKey: SPU_ACCEL_PRODUCT_ID,
    kIOHIDTransportKey: "SPU",
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

let openRes = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard openRes == kIOReturnSuccess else {
    print("IOHIDManagerOpen failed: 0x\(String(openRes, radix: 16)) — run with sudo")
    exit(1)
}

guard
    let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
    let device = devices.first
else {
    print("SPU accelerometer not found.")
    exit(2)
}

let openDev = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
guard openDev == kIOReturnSuccess else {
    print("IOHIDDeviceOpen failed: 0x\(String(openDev, radix: 16))")
    exit(3)
}

let reportSize = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
print("Device opened. Max input report size: \(reportSize) bytes.")

let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
let queue = DispatchQueue(label: "tappitytap.hid", qos: .userInteractive)
IOHIDDeviceSetDispatchQueue(device, queue)
IOHIDDeviceRegisterInputReportCallback(device, buffer, reportSize, inputCallback, nil)
IOHIDDeviceActivate(device)

let heartbeat = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
heartbeat.schedule(deadline: .now() + 2.0, repeating: 2.0)
heartbeat.setEventHandler {
    if !firstReportSeen {
        FileHandle.standardError.write("(no reports yet — \(sampleCount) samples seen)\n".data(using: .utf8)!)
    }
}
heartbeat.resume()

print("Tap the lid or chassis. Ctrl-C to quit.\n")
dispatchMain()
