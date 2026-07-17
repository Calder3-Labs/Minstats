import SwiftUI

/// Config for temperature alerts: a threshold and the channels to notify. Opened
/// from the right-click menu, mirroring the pairing window.
struct AlertsView: View {
    @Bindable var monitor: AlertMonitor
    let useFahrenheit: Bool
    let machineName: String

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

            Section("Alert above") {
                HStack {
                    Slider(value: $monitor.thresholdC, in: 60...105, step: 1)
                    Text(thresholdLabel)
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
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
                    monitor.sendTest(machineName: machineName)
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
        .frame(width: 380, height: 520)
    }

    private var thresholdLabel: String {
        let value = useFahrenheit ? monitor.thresholdC * 9 / 5 + 32 : monitor.thresholdC
        return "\(Int(value.rounded()))°\(useFahrenheit ? "F" : "C")"
    }

    private var anyChannelReady: Bool {
        (monitor.imessageEnabled && !monitor.imessageRecipient.isEmpty)
            || (monitor.discordEnabled && !monitor.discordWebhook.isEmpty)
    }
}
