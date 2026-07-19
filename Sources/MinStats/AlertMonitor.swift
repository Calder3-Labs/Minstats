import Foundation
import MinStatsProtocol

/// Watches the headline die temperature and fires a notification when it runs
/// hot — to a **Discord webhook** the owner controls. Deliberately no push
/// service: the Mac emits outbound to a channel you own, so there's no relay to
/// run, no credential to hold, nothing stored off your machine. Works behind
/// home NAT and without phone pairing, since it's the Mac reaching out.
///
/// Discord is the single channel by design. iMessage was tried and dropped: it
/// failed silently in too many ways outside the app's control (Automation TCC
/// denied, no iMessage account, no delivery confirmation) while the UI reported
/// success — false confidence a safety alert can't have. A plain HTTPS POST has
/// one well-defined failure mode and returns a real status code, so a bad setup
/// is caught honestly at test time.
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

    /// The Discord webhook URL. A valid one being present is what "a channel is
    /// configured" means — no separate enable toggle, since it's the sole
    /// channel and the master `enabled` already gates everything.
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
    /// `useFahrenheit` matches the menu bar's unit so the message reads in the
    /// same units the owner sees everywhere else, not raw Celsius.
    func evaluate(headlineC: Double?, machineName: String, useFahrenheit: Bool) {
        guard enabled, let temp = headlineC else { return }
        if temp >= thresholdC {
            guard armed else { return }
            if let last = lastFired, Date().timeIntervalSince(last) < cooldown { return }
            armed = false
            lastFired = Date()
            notify(
                title: "\(machineName) is running hot",
                body: "Die temperature \(Self.tempString(temp, fahrenheit: useFahrenheit)) (threshold \(Self.tempString(thresholdC, fahrenheit: useFahrenheit)))."
            )
        } else if temp < thresholdC - rearmMarginC {
            armed = true
        }
    }

    /// Formats a raw-Celsius value in the requested unit, e.g. "162°F".
    static func tempString(_ celsius: Double, fahrenheit: Bool) -> String {
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))°\(fahrenheit ? "F" : "C")"
    }

    /// Delivers a real alert. Fire-and-forget so a slow or failed POST never
    /// blocks sampling (failures are logged); no-op if no valid webhook is set.
    /// `evaluate` already gated on `enabled`.
    func notify(title: String, body: String) {
        guard let url = DiscordNotifier.validated(discordWebhook) else { return }
        DiscordNotifier.sendInBackground(webhook: url, message: "\(title) — \(body)")
    }

    /// Sends a real test message and reports the ACTUAL outcome — no optimistic
    /// "Sent." Throws a descriptive `DiscordNotifier.SendError` the settings
    /// window shows verbatim, so a bad webhook is caught at setup, not during a
    /// real thermal event.
    func sendTest(machineName: String) async throws {
        guard let url = DiscordNotifier.validated(discordWebhook) else {
            throw DiscordNotifier.SendError.notConfigured
        }
        try await DiscordNotifier.send(
            webhook: url,
            message: "MinStats test — alerts from \(machineName) are working."
        )
    }

    // MARK: - Remote config (phone)

    /// True when there's a valid webhook to send to — so the phone can warn
    /// that alerts are on but would fire into the void.
    var channelsConfigured: Bool {
        DiscordNotifier.validated(discordWebhook) != nil
    }

    /// The wire view of the alert config — the temperature options only, never
    /// the webhook URL (that stays Mac-side).
    func configDTO() -> AlertConfigDTO {
        AlertConfigDTO(enabled: enabled, thresholdC: thresholdC, channelsConfigured: channelsConfigured)
    }

    /// Applies a remote update from the phone. Only the temperature options are
    /// settable; the read-only `channelsConfigured` is ignored, and the channel
    /// details are never on the wire to begin with. The threshold is clamped to
    /// a sane range so a buggy or hostile client can't neuter alerting with an
    /// absurd value (a garbage/NaN threshold is dropped, keeping the current one).
    @discardableResult
    func apply(_ dto: AlertConfigDTO) -> AlertConfigDTO {
        enabled = dto.enabled
        if dto.thresholdC.isFinite {
            thresholdC = min(max(dto.thresholdC, 30), 120)
        }
        return configDTO()
    }
}

/// Posts to a Discord webhook — a plain HTTPS POST, no credential to store
/// beyond the URL. One well-defined failure mode (a bad or deleted webhook),
/// reported honestly with a real HTTP status — which is exactly why it's the
/// single alert channel.
enum DiscordNotifier {
    enum SendError: LocalizedError {
        case notConfigured
        case unreachable(String)
        case rejected(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Add a Discord webhook URL first."
            case let .unreachable(detail):
                return "Couldn't reach Discord — \(detail)"
            case let .rejected(code) where code == 401 || code == 404:
                return "Discord rejected the webhook (HTTP \(code)) — check the URL is correct and hasn't been deleted."
            case let .rejected(code):
                return "Discord rejected the message (HTTP \(code))."
            }
        }
    }

    /// A webhook we're willing to POST to: **HTTPS only**. An alert reveals the
    /// machine name and — implicitly — that you're away, so it must never cross
    /// the network in cleartext. Returns nil for empty, plain-http, or
    /// scheme-less input, which is also what disables the Send Test button.
    static func validated(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Awaitable send that reports the real outcome — used by "Send Test", so
    /// the button can tell the truth instead of guessing.
    static func send(webhook: URL, message: String) async throws {
        var request = URLRequest(url: webhook)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["content": message])
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SendError.unreachable((error as NSError).localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw SendError.rejected(code) }
    }

    /// Fire-and-forget for real alerts — never blocks sampling; logs failures.
    static func sendInBackground(webhook: URL, message: String) {
        Task {
            do {
                try await send(webhook: webhook, message: message)
            } catch {
                NSLog("MinStats Discord alert failed: \(error.localizedDescription)")
            }
        }
    }
}
