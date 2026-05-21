import Foundation
import SwiftUI
import AppKit
import TappityTapShared

// State + glue: holds settings, owns the IPC client, owns the audio engine,
// pushes setParams to the helper when the user changes a slider.

@MainActor
final class Coordinator: ObservableObject {
    // ---- Persisted user settings (via UserDefaults) ----
    @AppStorage("enabled") var enabled: Bool = true {
        didSet { pushParams() }
    }
    @AppStorage("sensitivity") var sensitivity: Double = 0.5 {
        didSet { pushParams() }
    }
    @AppStorage("debounce") var debounce: Double = 0.5 {
        didSet { pushParams() }
    }
    @AppStorage("volume") var volume: Double = 0.8 {
        didSet { player.masterVolume = Float(volume) }
    }

    // ---- Live status ----
    @Published var helperConnected = false
    @Published var lastTapIntensity: Double = 0
    @Published var totalTaps: Int = 0

    private let client = IPCClient(path: SocketPath.default)
    private let player: TapPlayer

    init() {
        self.player = try! TapPlayer()
        self.player.masterVolume = Float(volume)
        client.onConnect = { [weak self] in
            DispatchQueue.main.async {
                self?.helperConnected = true
                self?.pushParams()
            }
        }
        client.onDisconnect = { [weak self] in
            DispatchQueue.main.async { self?.helperConnected = false }
        }
        client.onMessage = { [weak self] msg in
            guard let self = self else { return }
            if msg.type == "tap", let i = msg.intensity {
                DispatchQueue.main.async {
                    self.lastTapIntensity = i
                    self.totalTaps += 1
                }
                self.player.playTap(intensity: i)
            }
        }
        client.start()
    }

    // ---- Param mapping ----
    // Sensitivity slider 0..1 -> deltaG and minPeakG between (0.080, 0.005).
    // High slider = lower threshold = more sensitive.
    private var sensitivityToFloors: (delta: Double, minPeak: Double) {
        let high = 0.080
        let low  = 0.005
        let v = high - (high - low) * sensitivity
        return (v, v)
    }

    // Debounce slider 0..1 -> blackoutMs between (10ms, 200ms).
    // Higher slider = longer blackout = fewer doubles at the cost of max rate.
    private var debounceToBlackoutMs: Int {
        return Int(10.0 + (200.0 - 10.0) * debounce)
    }

    func pushParams() {
        let floors = sensitivityToFloors
        let msg = ClientMessage.setParams(
            deltaG: floors.delta,
            minPeakG: floors.minPeak,
            blackoutMs: debounceToBlackoutMs,
            enabled: enabled
        )
        client.send(msg)
    }
}
