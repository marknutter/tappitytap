import SwiftUI

struct MenuContent: View {
    @EnvironmentObject var coordinator: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("tappitytap").font(.headline)
                Spacer()
                Circle()
                    .fill(coordinator.helperConnected ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(coordinator.helperConnected ? "connected" : "no helper")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DaemonSection()

            Toggle("Enabled", isOn: $coordinator.enabled)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 4) {
                Text("Sound pack").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $coordinator.soundPackId) {
                    ForEach(SoundPackKind.allCases) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sensitivity")
                    Spacer()
                    Text(coordinator.sensitivity, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(.secondary)
                        .font(.caption.monospacedDigit())
                }
                Slider(value: $coordinator.sensitivity)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Debounce")
                    Spacer()
                    Text(coordinator.debounce, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(.secondary)
                        .font(.caption.monospacedDigit())
                }
                Slider(value: $coordinator.debounce)
                Text("Higher = fewer doubles, lower max tap rate")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Volume")
                    Spacer()
                    Text(coordinator.volume, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(.secondary)
                        .font(.caption.monospacedDigit())
                }
                Slider(value: $coordinator.volume)
            }

            Divider()

            HStack {
                Text("Taps").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(coordinator.totalTaps)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("last:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.3f", coordinator.lastTapIntensity))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button("Quit tappitytap") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 280)
    }
}

struct DaemonSection: View {
    @EnvironmentObject var coordinator: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Helper daemon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            actionRow
        }
    }

    private var statusLabel: String {
        switch coordinator.daemonState {
        case .notInstalled: return "not installed"
        case .installed:    return "installed"
        case .unavailable:  return "not in bundle"
        }
    }

    private var statusColor: Color {
        switch coordinator.daemonState {
        case .installed:    return .green
        case .notInstalled: return .secondary
        case .unavailable:  return .red
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch coordinator.daemonState {
        case .notInstalled:
            Button("Install Helper…") { coordinator.installDaemon() }
            Text("Prompts for your password once. After that the helper auto-starts at boot, no terminal needed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .installed:
            Button("Uninstall Helper…") { coordinator.uninstallDaemon() }
        case .unavailable:
            Text("Build the .app via scripts/build-app.sh and launch it from /Applications.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
