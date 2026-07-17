import Foundation

/// Watches the headline die temperature and fires a notification when it runs
/// hot — to a channel the *owner* already has (iMessage to yourself, a Discord
/// webhook). Deliberately no push service: the Mac emits outbound to a channel
/// you own, so there's no relay to run, no credential to hold, nothing stored
/// off your machine. Works behind home NAT and without phone pairing, since
/// it's the Mac reaching out.
///
/// Independent of the agent: alerts run whenever MinStats does, gated only by
/// their own `enabled`, so someone who never turns on phone pairing can still
/// use them.
@MainActor
@Observable
final class AlertMonitor {
    var enabled: Bool = UserDefaults.standard.bool(forKey: "alertsEnabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "alertsEnabled") }
    }

    /// Stored in Celsius (the raw unit); the UI converts for display.
    var thresholdC: Double = {
        let stored = UserDefaults.standard.double(forKey: "alertThresholdC")
        return stored > 0 ? stored : 90
    }() {
        didSet { UserDefaults.standard.set(thresholdC, forKey: "alertThresholdC") }
    }

    var imessageEnabled: Bool = UserDefaults.standard.bool(forKey: "alertIMessageEnabled") {
        didSet { UserDefaults.standard.set(imessageEnabled, forKey: "alertIMessageEnabled") }
    }
    var imessageRecipient: String = UserDefaults.standard.string(forKey: "alertIMessageRecipient") ?? "" {
        didSet { UserDefaults.standard.set(imessageRecipient, forKey: "alertIMessageRecipient") }
    }

    var discordEnabled: Bool = UserDefaults.standard.bool(forKey: "alertDiscordEnabled") {
        didSet { UserDefaults.standard.set(discordEnabled, forKey: "alertDiscordEnabled") }
    }
    var discordWebhook: String = UserDefaults.standard.string(forKey: "alertDiscordWebhook") ?? "" {
        didSet { UserDefaults.standard.set(discordWebhook, forKey: "alertDiscordWebhook") }
    }

    // Anti-spam so a Mac hovering at the line doesn't machine-gun you:
    // fire once on the way up, then stay quiet until it cools past a margin
    // (hysteresis) AND a cooldown has elapsed.
    @ObservationIgnored private var armed = true
    @ObservationIgnored private var lastFired: Date?
    @ObservationIgnored private let cooldown: TimeInterval = 15 * 60
    @ObservationIgnored private let rearmMarginC = 5.0

    /// Called once per sample with the current headline temperature.
    func evaluate(headlineC: Double?, machineName: String) {
        guard enabled, let temp = headlineC else { return }
        if temp >= thresholdC {
            guard armed else { return }
            if let last = lastFired, Date().timeIntervalSince(last) < cooldown { return }
            armed = false
            lastFired = Date()
            notify(
                title: "\(machineName) is running hot",
                body: String(format: "Die temperature %.0f°C (threshold %.0f°C).", temp, thresholdC)
            )
        } else if temp < thresholdC - rearmMarginC {
            armed = true
        }
    }

    /// Fires a message to every enabled channel. Used by both a real alert and
    /// the "Send Test" button, so testing exercises the exact delivery path.
    func notify(title: String, body: String) {
        let message = "\(title) — \(body)"
        if imessageEnabled, !imessageRecipient.isEmpty {
            IMessageNotifier.send(to: imessageRecipient, message: message)
        }
        if discordEnabled, let url = URL(string: discordWebhook), !discordWebhook.isEmpty {
            DiscordNotifier.send(webhook: url, message: message)
        }
    }

    func sendTest(machineName: String) {
        notify(title: "MinStats test", body: "Alerts from \(machineName) are working.")
    }
}

/// Posts to a Discord webhook — a plain outbound POST, no auth to store beyond
/// the URL. Fire-and-forget; a failed alert logs but never blocks sampling.
enum DiscordNotifier {
    static func send(webhook: URL, message: String) {
        var request = URLRequest(url: webhook)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["content": message])
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                NSLog("MinStats Discord alert failed: \(error.localizedDescription)")
            } else if let code = (response as? HTTPURLResponse)?.statusCode, !(200...299).contains(code) {
                NSLog("MinStats Discord alert rejected: HTTP \(code)")
            }
        }.resume()
    }
}

/// Sends an iMessage via Messages.app to a recipient (your own number / Apple
/// ID). Uses the Mac's existing Messages session, so there's no credential —
/// but it needs Automation permission to control Messages (macOS prompts on
/// first send; the "Send Test" button is the natural trigger).
enum IMessageNotifier {
    static func send(to recipient: String, message: String) {
        // AppleScript string literals can't span newlines and treat " and \ as
        // special — sanitise both the recipient and the (single-line) message.
        let safeRecipient = escape(recipient)
        let safeMessage = escape(message.replacingOccurrences(of: "\n", with: " "))
        let script = """
            tell application "Messages"
                set svc to 1st account whose service type = iMessage
                send "\(safeMessage)" to participant "\(safeRecipient)" of svc
            end tell
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
        } catch {
            NSLog("MinStats iMessage alert failed to launch osascript: \(error.localizedDescription)")
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
