import Foundation
import IOKit
import IOKit.hid

// Probe: enumerate HID devices and report anything matching the Apple Silicon
// SPU accelerometer (PrimaryUsagePage 0xFF00). On M2-class+ MacBooks one of
// the matches should be PrimaryUsage 3 (accel) and another PrimaryUsage 9 (gyro).
//
// Run with: sudo swift probe.swift

let APPLE_SPU_USAGE_PAGE: UInt32 = 0xFF00

func cfNumber(_ value: UInt32) -> CFNumber {
    var v = value
    return CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v)
}

func stringProp(_ device: IOHIDDevice, _ key: CFString) -> String {
    guard let v = IOHIDDeviceGetProperty(device, key) else { return "?" }
    return String(describing: v)
}

func intProp(_ device: IOHIDDevice, _ key: CFString) -> Int {
    guard let v = IOHIDDeviceGetProperty(device, key) as? Int else { return -1 }
    return v
}

print("=== tappitytap probe: scanning for Apple SPU motion HID devices ===\n")

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

let matching: [String: Any] = [
    kIOHIDPrimaryUsagePageKey: APPLE_SPU_USAGE_PAGE,
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
if openResult != kIOReturnSuccess {
    print("IOHIDManagerOpen failed: 0x\(String(openResult, radix: 16))")
    print("(if 0xe00002c2 this is unauthorized — run with sudo)")
    exit(1)
}

guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
    print("No devices matched usage page 0xFF00.")
    print("This machine may not expose the SPU accelerometer.")
    exit(2)
}

if devices.isEmpty {
    print("No devices matched usage page 0xFF00.")
    print("This machine may not expose the SPU accelerometer, or you need to run with sudo.")
    exit(2)
}

print("Found \(devices.count) matching device(s):\n")
for (i, device) in devices.enumerated() {
    let product = stringProp(device, kIOHIDProductKey as CFString)
    let manufacturer = stringProp(device, kIOHIDManufacturerKey as CFString)
    let usage = intProp(device, kIOHIDPrimaryUsageKey as CFString)
    let usagePage = intProp(device, kIOHIDPrimaryUsagePageKey as CFString)
    let transport = stringProp(device, kIOHIDTransportKey as CFString)
    let vendorID = intProp(device, kIOHIDVendorIDKey as CFString)
    let productID = intProp(device, kIOHIDProductIDKey as CFString)

    let usageLabel: String
    switch usage {
    case 3: usageLabel = "(accelerometer)"
    case 9: usageLabel = "(gyroscope)"
    default: usageLabel = ""
    }

    print("[\(i)] \(product)")
    print("    manufacturer: \(manufacturer)")
    print("    transport:    \(transport)")
    print("    usage page:   0x\(String(usagePage, radix: 16))")
    print("    primary usage: \(usage) \(usageLabel)")
    print("    vendorID/productID: 0x\(String(vendorID, radix: 16)) / 0x\(String(productID, radix: 16))")
    print()
}

let hasAccel = devices.contains { intProp($0, kIOHIDPrimaryUsageKey as CFString) == 3 }
if hasAccel {
    print("OK: accelerometer (usage 3) is present. Phase 1 is feasible.")
    exit(0)
} else {
    print("WARN: usage-page 0xFF00 devices found but none with usage 3 (accelerometer).")
    print("      Dump above so we can identify the right device.")
    exit(3)
}
