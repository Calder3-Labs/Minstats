import SwiftUI

/// Config for temperature alerts: a threshold and the service to notify
/// (Discord / Slack / ntfy). Opened from the right-click menu, mirroring the
/// pairing window.
struct AlertsView: View {
    @Bindable var monitor: AlertMonitor
    /// For the live current temperature and the °C/°F preference.
    let model: StatsModel

    @State private var testNote: String?
    @State private var sending = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable temperature alerts", isOn: $monitor.enabled)
            } footer: {
                Text("MinStats notifies you when this Mac runs hot. Alerts are sent from the Mac to a channel you own — no account, nothing stored off your machine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Slider(value: thresholdBinding, in: thresholdRange, step: thresholdStep)
                    Text(thresholdLabel)
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            } header: {
                Text("Alert above")
            } footer: {
                if let current = model.headlineTemp {
                    Text("Currently \(display(current)). Set the threshold below this to fire a test alert.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Service", selection: $monitor.provider) {
                    ForEach(AlertProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                TextField(monitor.provider.fieldPrompt, text: $monitor.endpoint)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Send alerts to")
            } footer: {
                // Flag a non-empty-but-invalid endpoint; otherwise show setup help.
                if !monitor.endpoint.isEmpty, monitor.provider.resolve(monitor.endpoint) == nil {
                    Text(monitor.provider.invalidHint)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text(monitor.provider.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await sendTest() }
                } label: {
                    Text(sending ? "Sending…" : "Send Test Notification")
                }
                .disabled(!webhookReady || sending)
                if let testNote {
                    Text(testNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Posts a test message to your alert service and reports whether it actually worked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Tall enough that the Send Test button AND its result line sit above
        // the fold — the honest test feedback is the point, so it mustn't hide
        // below a scroll.
        .frame(width: 380, height: 580)
    }

    private func sendTest() async {
        sending = true
        testNote = nil
        do {
            try await monitor.sendTest(machineName: SystemInfo.computerName)
            testNote = "Sent — check your Discord channel."
        } catch {
            testNote = error.localizedDescription
        }
        sending = false
    }

    // The slider runs in the *displayed* unit so both the range and the steps
    // land on round numbers — stepping 1°C would show ragged ~2°F jumps. The
    // stored value stays Celsius (the raw unit); this converts at the edges.
    private var thresholdRange: ClosedRange<Double> {
        model.useFahrenheit ? 95...220 : 35...105
    }

    private var thresholdStep: Double {
        model.useFahrenheit ? 5 : 1
    }

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { model.useFahrenheit ? monitor.thresholdC * 9 / 5 + 32 : monitor.thresholdC },
            set: { monitor.thresholdC = model.useFahrenheit ? ($0 - 32) * 5 / 9 : $0 }
        )
    }

    private var thresholdLabel: String { display(monitor.thresholdC) }

    private func display(_ celsius: Double) -> String {
        AlertMonitor.tempString(celsius, fahrenheit: model.useFahrenheit)
    }

    private var webhookReady: Bool {
        monitor.provider.resolve(monitor.endpoint) != nil
    }
}
