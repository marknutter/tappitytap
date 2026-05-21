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

            Toggle("Enabled", isOn: $coordinator.enabled)
                .toggleStyle(.switch)

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
