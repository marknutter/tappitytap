import Foundation
import SwiftUI
import AppKit
import ServiceManagement
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
    @Published var daemonStatus: SMAppService.Status = .notFound

    private let client = IPCClient(path: SocketPath.default)
    private let player: TapPlayer
    private let daemonService = SMAppService.daemon(
        plistName: "com.marknutter.tappitytap.helper.plist")
    private var daemonStatusTimer: Timer?

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

        refreshDaemonStatus()
        daemonStatusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshDaemonStatus()
        }
    }

    // ---- Daemon management ----

    func refreshDaemonStatus() {
        let s = daemonService.status
        DispatchQueue.main.async { self.daemonStatus = s }
    }

    func installDaemon() {
        do {
            try daemonService.register()
        } catch {
            NSLog("daemon register failed: \(error)")
        }
        refreshDaemonStatus()
    }

    func uninstallDaemon() {
        do {
            try daemonService.unregister()
        } catch {
            NSLog("daemon unregister failed: \(error)")
        }
        refreshDaemonStatus()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // ---- Param mapping ----
    // Log-linear so the slider middle hits the empirically tuned v1 values
    // (delta = 0.025 g, blackoutMs ≈ 50). Geometric mean of the endpoints
    // lands on the proven tuning.
    //
    // Sensitivity: slider 0..1 -> deltaG/minPeakG between 0.080 g (low, slider 0)
    // and 0.010 g (high, slider 1). At slider 0.5 -> sqrt(0.080 * 0.010) ≈ 0.028 g.
    private var sensitivityToFloors: (delta: Double, minPeak: Double) {
        let logLow  = log(0.010)
        let logHigh = log(0.080)
        let v = exp(logHigh - (logHigh - logLow) * sensitivity)
        return (v, v)
    }

    // Debounce: slider 0..1 -> blackoutMs between 10 ms (slider 0, fastest)
    // and 200 ms (slider 1, fewest doubles). Slider 0.5 -> sqrt(10 * 200) ≈ 45 ms.
    private var debounceToBlackoutMs: Int {
        let logLow  = log(10.0)
        let logHigh = log(200.0)
        return Int(exp(logLow + (logHigh - logLow) * debounce))
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
