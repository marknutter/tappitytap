import Foundation
import SwiftUI
import AppKit
import TappityTapShared

// LaunchDaemon install state, derived from /Library/LaunchDaemons.
enum DaemonInstallState {
    case notInstalled        // no plist on disk
    case installed           // plist on disk (presumed loaded — launchctl bootstrap is idempotent at boot)
    case unavailable         // not running from a .app bundle
}

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
    @AppStorage("soundPack") var soundPackId: String = SoundPackKind.pentatonic.rawValue {
        didSet {
            if let kind = SoundPackKind(rawValue: soundPackId) {
                player.setPack(kind)
            }
        }
    }

    // ---- Live status ----
    @Published var helperConnected = false
    @Published var lastTapIntensity: Double = 0
    @Published var totalTaps: Int = 0
    @Published var daemonState: DaemonInstallState = .unavailable

    private let client = IPCClient(path: SocketPath.default)
    private let player: TapPlayer
    private var daemonStatusTimer: Timer?

    private let daemonLabel = "com.marknutter.tappitytap.helper"
    private var systemPlistPath: String { "/Library/LaunchDaemons/\(daemonLabel).plist" }

    init() {
        let initialKind = SoundPackKind(rawValue: UserDefaults.standard.string(forKey: "soundPack") ?? "") ?? .pentatonic
        self.player = try! TapPlayer(initialPack: initialKind)
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

    // ---- Daemon management (via launchctl, single sudo prompt at install) ----

    private var bundledHelperPath: String? {
        // Only present when running from a real .app bundle. Bundle.main.bundlePath
        // for a plain SPM binary points at the binary's parent dir, where there's
        // no helper alongside — that's how we detect "dev binary, not installable".
        let candidate = Bundle.main.bundlePath + "/Contents/MacOS/tappitytap-helper"
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    func refreshDaemonStatus() {
        let newState: DaemonInstallState
        if bundledHelperPath == nil {
            newState = .unavailable
        } else if FileManager.default.fileExists(atPath: systemPlistPath) {
            newState = .installed
        } else {
            newState = .notInstalled
        }
        DispatchQueue.main.async { self.daemonState = newState }
    }

    func installDaemon() {
        guard let helperPath = bundledHelperPath else { return }
        // Generate the plist at /tmp with an absolute Program path so launchd
        // can find the helper from the system context (no BundleProgram support
        // outside SMAppService).
        let plist: [String: Any] = [
            "Label": daemonLabel,
            "Program": helperPath,
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": "/tmp/tappitytap.helper.out.log",
            "StandardErrorPath": "/tmp/tappitytap.helper.err.log",
        ]
        let tmpPath = "/tmp/\(daemonLabel).plist"
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? data.write(to: URL(fileURLWithPath: tmpPath))

        let script = """
        do shell script "cp '\(tmpPath)' '\(systemPlistPath)' && chown root:wheel '\(systemPlistPath)' && chmod 644 '\(systemPlistPath)' && launchctl bootstrap system '\(systemPlistPath)' 2>/dev/null; launchctl enable 'system/\(daemonLabel)' 2>/dev/null; launchctl kickstart -k 'system/\(daemonLabel)' 2>/dev/null" with administrator privileges with prompt "tappitytap needs to install its background helper, which reads the accelerometer (requires root)."
        """
        runOSAScript(script)
        refreshDaemonStatus()
    }

    func uninstallDaemon() {
        let script = """
        do shell script "launchctl bootout 'system/\(daemonLabel)' 2>/dev/null; rm -f '\(systemPlistPath)'" with administrator privileges with prompt "tappitytap is removing its background helper."
        """
        runOSAScript(script)
        refreshDaemonStatus()
    }

    private func runOSAScript(_ source: String) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", source]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("osascript failed: \(error)")
        }
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
