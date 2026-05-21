# tappitytap

A little Mac app that plays satisfying sounds when you tap on your laptop chassis. Like a fidget toy you didn't have to buy.

It reads the Apple Silicon SPU accelerometer at 1 kHz via an undocumented IOKit HID interface, detects taps with a rising-edge onset detector, and plays variable-pitch pentatonic clicks. Designed for finger drumming up to ~40 Hz.

## Hardware requirements

- **M2-class or newer Apple Silicon MacBook.** The SPU accelerometer is exposed as a HID device (Apple vendor `0x5ac`, product `0x8104`, transport `SPU`, usage page `0xFF00`, usage `3`). M1 base MacBooks do not have it. The probe script (`probe/probe.swift`) verifies presence.

## Quick start (current state — single Swift script)

The project is still at the prototype stage: a single Swift script you run with `sudo`. The menu-bar app and helper-daemon split are future work.

```bash
sudo swift v1/tappitytap.swift
```

You'll be prompted for your password (required to write the IORegistry properties that wake the SPU driver — see Architecture). Tap the chassis to hear pentatonic clicks. Ctrl-C to quit.

## Architecture

### Detection pipeline

1. **Wake the SPU driver.** On boot the `AppleSPUHIDDriver` IOKit service is in a non-reporting state. Set three CF properties via `IORegistryEntrySetCFProperty` on each matching driver instance:
   - `SensorPropertyReportingState = 1`
   - `SensorPropertyPowerState = 1`
   - `ReportInterval = 1000` (microseconds)
2. **Open the HID device** via `IOHIDManagerCopyDevices`, matching on usage page `0xFF00`, usage `3`, vendor `0x5ac`, product `0x8104`, transport `SPU`.
3. **Stream 22-byte input reports** on a high-priority dispatch queue via `IOHIDDeviceSetDispatchQueue` + `IOHIDDeviceActivate`.
4. **Decode** little-endian int32 X/Y/Z at byte offsets 6, 10, 14; divide by 65536 to get g. Use `loadUnaligned` because the offsets aren't 4-byte aligned.
5. **Per-sample at 1 kHz**: subtract a slow EMA gravity baseline, take the AC magnitude, smooth it with a 1 ms EMA into a short-term average (STA).
6. **Rising-edge onset detection**: maintain a 20 ms ring buffer of recent STA values. Fire when current STA rises by more than `DELTA_TRIGGER_G` above the recent valley AND current STA exceeds `MIN_PEAK_G`. This detects new impacts even while the chassis is still ringing from prior hits — crucial for fast drumming.
7. **25 ms refractory** between fires (caps at ~40 Hz = 1/32 notes at 300 BPM).

### Audio

`AVAudioEngine` with a pool of 8 `AVAudioPlayerNode` instances cycled per-tap. Click sounds are generated programmatically at startup as 30 ms damped-sine pings on a pentatonic scale, keeping audio energy small enough to minimize speaker-to-accelerometer feedback.

### Why undocumented?

CoreMotion / `CMMotionManager` is iOS/watchOS only. The old SMC accelerometer keys are gone post-2016. The Apple Silicon SPU HID interface is the only path that works on modern MacBooks, but it's not exposed in any public framework — discovered by reverse-engineering (see references). This means: no App Store distribution, and the API could break on any macOS update.

## References

- [olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer) — Python reverse-engineering reference
- [taigrr/apple-silicon-accelerometer](https://github.com/taigrr/apple-silicon-accelerometer) — Go port
- [taigrr/spank](https://github.com/taigrr/spank) — end-to-end Go tap-detection app
- [SlapMac](https://slapmac.com) — the commercial app that demonstrated this is possible

## Tuning

If detection isn't right for your taps:

| Constant | Default | Meaning |
| --- | --- | --- |
| `DELTA_TRIGGER_G` | 0.04 | Rise (g) above recent valley needed to fire |
| `MIN_PEAK_G` | 0.04 | Absolute STA must exceed this |
| `REFRACTORY_S` | 0.025 | Minimum gap between fires (s) |
| `STA_TAU_S` | 0.001 | Smoothing time constant for the impact-edge signal |
| `HISTORY_MS` | 20 | Ring-buffer length for valley tracking |

## Troubleshooting

- **No reports stream from the device.** The SPU driver wake step likely failed — confirm you're running with `sudo`. The script prints `Woke N AppleSPUHIDDriver service(s)` on success.
- **Audio doesn't play under sudo.** Root processes sometimes can't reach the user audio session. The current workaround is "audio works on this Mac under sudo"; the proper fix is the helper-daemon + user-context app split (Phase 4).
- **Spurious double-fires per tap.** Increase `DELTA_TRIGGER_G` or `REFRACTORY_S`. Chassis ringout that happens to produce sharp secondary edges is the cause.
- **Typing fires the detector.** Raise `MIN_PEAK_G` to ~0.10 to suppress most keystrokes. Future work: gate via NSEvent global keystroke monitor.

## Status

- [x] Phase 0: Probe device presence
- [x] Phase 1: Bare accelerometer reader
- [x] Phase 2: Tap detector
- [x] Phase 3: Sound playback
- [ ] Phase 4: Menu-bar app + root helper daemon (SMAppService)
- [ ] Phase 5: Real sound packs (clicks/pops + soft drum kit)
