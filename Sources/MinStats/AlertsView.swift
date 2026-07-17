import SwiftUI

/// Config for temperature alerts: a threshold and the channels to notify. Opened
/// from the right-click menu, mirroring the pairing window.
struct AlertsView: View {
    @Bindable var monitor: AlertMonitor
    /// For the live current temperature and the °C/°F preference.
    let model: StatsModel

    @State private var testNote: String?

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

            Section("iMessage") {
                Toggle("Send an iMessage", isOn: $monitor.imessageEnabled)
                TextField("Your number or Apple ID", text: $monitor.imessageRecipient)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!monitor.imessageEnabled)
            }

            Section("Discord") {
                Toggle("Post to a Discord webhook", isOn: $monitor.discordEnabled)
                TextField("Webhook URL", text: $monitor.discordWebhook)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!monitor.discordEnabled)
            }

            Section {
                Button("Send Test Notification") {
                    monitor.sendTest(machineName: SystemInfo.computerName)
                    testNote = "Sent to the enabled channels — check your phone."
                }
                .disabled(!anyChannelReady)
                if let testNote {
                    Text(testNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("The first iMessage asks macOS for permission to control Messages — approve it, then it sends silently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 540)
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

    private var anyChannelReady: Bool {
        (monitor.imessageEnabled && !monitor.imessageRecipient.isEmpty)
            || (monitor.discordEnabled && !monitor.discordWebhook.isEmpty)
    }
}
