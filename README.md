# tappitytap

A little Mac app that plays satisfying sounds when you tap on your laptop chassis. Like a fidget toy you didn't have to buy.

It reads the Apple Silicon SPU accelerometer at 1 kHz via an undocumented IOKit HID interface, detects taps with a rising-edge onset detector, and plays variable-pitch pentatonic clicks. Designed for finger drumming.

## Hardware requirements

**M2-class or newer Apple Silicon MacBook.** The SPU accelerometer is exposed as a HID device (Apple vendor `0x5ac`, product `0x8104`, transport `SPU`, usage page `0xFF00`, usage `3`). M1 base MacBooks do not have it. `prototypes/probe/probe.swift` verifies presence.

## Quick start

The project is split into a root helper daemon and a user-context menu-bar app.

```bash
swift build

# Terminal 1: start the helper (needs sudo)
sudo .build/debug/tappitytap-helper

# Terminal 2: launch the menu-bar app
.build/debug/tappitytap
```

Look for the drum icon in your menu bar. Click it to see sliders for sensitivity, debounce, and volume, plus an on/off toggle. Tap the chassis to drum.

For a release build (lower latency, smaller binaries):

```bash
swift build -c release
sudo .build/release/tappitytap-helper
.build/release/tappitytap
```

## Why two binaries

- **Helper** needs root to write IORegistry properties on the `AppleSPUHIDDriver` (waking the SPU sensor) and to open the HID device.
- **App** needs to run in the user's audio session to play sound through the default output device.

The two talk over a Unix domain socket at `/tmp/tappitytap.sock`. The helper is the server, the app is the client. JSON-line protocol: the helper sends `tap` events, the app sends `setParams` whenever you move a slider. Newer client connections displace older ones, so you can restart the app without restarting the helper.

## Architecture

### Detection pipeline (helper)

1. **Wake the SPU driver.** On boot the `AppleSPUHIDDriver` IOKit service is in a non-reporting state. Set three CF properties via `IORegistryEntrySetCFProperty` on each matching driver instance:
   - `SensorPropertyReportingState = 1`
   - `SensorPropertyPowerState = 1`
   - `ReportInterval = 1000` (microseconds)
2. **Open the HID device** via `IOHIDManagerCopyDevices`, matching on usage page `0xFF00`, usage `3`, vendor `0x5ac`, product `0x8104`, transport `SPU`.
3. **Stream 22-byte input reports** on a high-priority dispatch queue via `IOHIDDeviceSetDispatchQueue` + `IOHIDDeviceActivate`.
4. **Decode** little-endian int32 X/Y/Z at byte offsets 6, 10, 14; divide by 65536 to get g. Use `loadUnaligned` because the offsets aren't 4-byte aligned.
5. **Per-sample at 1 kHz**: subtract a slow EMA gravity baseline, take the AC magnitude, smooth it with a 1 ms EMA into a short-term average (STA).
6. **Rising-edge onset detection**: maintain a 20 ms ring buffer of recent STA values. Fire when current STA rises by more than the delta threshold above the recent valley AND current STA exceeds the min-peak threshold.
7. **State machine**: idle → peakCapture (8 ms — measure true impact peak for velocity-mapped audio) → blackout (tunable, default 50 ms) → idle. The blackout suppresses chassis ring-out doubles.

### Audio (app)

`AVAudioEngine` with a pool of 8 `AVAudioPlayerNode` instances cycled per-tap. Click sounds are generated programmatically at startup as 30 ms damped-sine pings on a pentatonic scale, keeping audio energy small enough to minimize speaker-to-accelerometer feedback.

### Settings (app)

User settings live in `UserDefaults` and are pushed to the helper via `setParams` whenever they change:

- **Sensitivity** (slider 0..1) — maps to delta + min-peak thresholds between 0.080 g (least sensitive) and 0.005 g (most sensitive)
- **Debounce** (slider 0..1) — maps to blackout window between 10 ms and 200 ms
- **Volume** (slider 0..1) — `AVAudioEngine` mainMixerNode output volume
- **Enabled** (toggle) — gates detection in the helper

### Why undocumented?

CoreMotion / `CMMotionManager` is iOS/watchOS only. The old SMC accelerometer keys are gone post-2016. The Apple Silicon SPU HID interface is the only path that works on modern MacBooks, but it's not exposed in any public framework — discovered by reverse-engineering (see references). This means: no App Store distribution, and the API could break on any macOS update.

## References

- [olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer) — Python reverse-engineering reference
- [taigrr/apple-silicon-accelerometer](https://github.com/taigrr/apple-silicon-accelerometer) — Go port
- [taigrr/spank](https://github.com/taigrr/spank) — end-to-end Go tap-detection app
- [SlapMac](https://slapmac.com) — the commercial app that demonstrated this is possible

## Layout

```
tappitytap/
├── Package.swift
├── Sources/
│   ├── TappityTapShared/         shared JSON-line wire protocol
│   ├── TappityTapHelper/         root daemon: HID + detector + socket server
│   └── TappityTapApp/            user app: menu-bar + audio + socket client
└── prototypes/                    standalone scripts from earlier phases
    ├── probe/                     HID device enumeration
    ├── reader/                    raw X/Y/Z stream
    ├── detector/                  detector-only, no audio
    └── v1/                        first end-to-end single-process version
```

## Troubleshooting

- **App shows "no helper".** The helper isn't running, or `/tmp/tappitytap.sock` is missing. Start the helper with `sudo .build/debug/tappitytap-helper` and the app will auto-reconnect within ~1 s.
- **Helper exits with "IOHIDManagerOpen failed".** You didn't run it with `sudo`.
- **Spurious double-fires per tap.** Move the **Debounce** slider higher.
- **Detector ignores light taps.** Move the **Sensitivity** slider higher.
- **Typing fires the detector.** Move **Sensitivity** lower (further left). Future work: a typing gate via NSEvent global keystroke monitor.
- **App launches but no menu-bar icon.** macOS sometimes hides menu-bar items when there are too many. Quit other menu-bar apps or use Bartender/Ice to manage them.

## Status

- [x] Phase 0: Probe device presence
- [x] Phase 1: Bare accelerometer reader
- [x] Phase 2: Tap detector
- [x] Phase 3: Sound playback (single-process prototype)
- [x] Phase 4a: Split into root helper daemon + SwiftUI menu-bar app (current)
- [ ] Phase 4b: SMAppService.daemon install so the helper launches automatically without manual `sudo`
- [ ] Phase 5: Real sound packs (clicks/pops + soft drum kit, switchable from UI)
