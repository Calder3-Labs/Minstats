import Foundation
import MinStatsProtocol

/// Watches the headline die temperature and fires a notification when it runs
/// hot — to a **webhook-based service the owner controls** (Discord, Slack, or
/// ntfy). Deliberately no push service of our own: the Mac emits outbound to a
/// channel you own, so there's no relay to run, no credential to hold, nothing
/// stored off your machine. Works behind home NAT and without phone pairing,
/// since it's the Mac reaching out.
///
/// Every channel is a plain HTTPS POST with one well-defined failure mode and a
/// real status code, so a bad setup is caught honestly at test time. (iMessage
/// was tried and dropped: it failed silently in too many ways outside the app's
/// control while the UI reported success — false confidence a safety alert
/// can't have.)
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

    /// Which service alerts go to. A valid endpoint for the *selected* provider
    /// being present is what "a channel is configured" means — there's no extra
    /// enable toggle, since the master `enabled` already gates everything.
    var provider: AlertProvider =
        AlertProvider(rawValue: UserDefaults.standard.string(forKey: "alertProvider") ?? "") ?? .discord {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "alertProvider") }
    }

    // One stored endpoint per provider, so switching providers doesn't lose the
    // others' values. `alertDiscordWebhook` predates the multi-provider change,
    // so an existing Discord user keeps working with no migration.
    var discordWebhook: String = UserDefaults.standard.string(forKey: "alertDiscordWebhook") ?? "" {
        didSet { UserDefaults.standard.set(discordWebhook, forKey: "alertDiscordWebhook") }
    }
    var slackWebhook: String = UserDefaults.standard.string(forKey: "alertSlackWebhook") ?? "" {
        didSet { UserDefaults.standard.set(slackWebhook, forKey: "alertSlackWebhook") }
    }
    var ntfyTopic: String = UserDefaults.standard.string(forKey: "alertNtfyTopic") ?? "" {
        didSet { UserDefaults.standard.set(ntfyTopic, forKey: "alertNtfyTopic") }
    }

    /// The raw endpoint string for the selected provider — the single field the
    /// settings UI binds to. Reads/writes the right per-provider store.
    var endpoint: String {
        get {
            switch provider {
            case .discord: discordWebhook
            case .slack: slackWebhook
            case .ntfy: ntfyTopic
            }
        }
        set {
            switch provider {
            case .discord: discordWebhook = newValue
            case .slack: slackWebhook = newValue
            case .ntfy: ntfyTopic = newValue
            }
        }
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
    /// blocks sampling (failures are logged); no-op if no valid endpoint is set.
    /// `evaluate` already gated on `enabled`.
    func notify(title: String, body: String) {
        AlertSender.sendInBackground(provider: provider, endpoint: endpoint, message: "\(title) — \(body)")
    }

    /// Sends a real test message and reports the ACTUAL outcome — no optimistic
    /// "Sent." Throws a descriptive `AlertSender.SendError` the settings window
    /// shows verbatim, so a bad endpoint is caught at setup, not during a real
    /// thermal event.
    func sendTest(machineName: String) async throws {
        try await AlertSender.send(
            provider: provider, endpoint: endpoint,
            message: "MinStats test — alerts from \(machineName) are working."
        )
    }

    // MARK: - Remote config (phone)

    /// True when the selected provider has a valid endpoint to send to — so the
    /// phone can warn that alerts are on but would fire into the void.
    var channelsConfigured: Bool {
        provider.resolve(endpoint) != nil
    }

    /// The wire view of the alert config — the temperature options only, never
    /// the endpoint (that stays Mac-side).
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

// MARK: - Providers

/// A webhook-based alert destination. Each knows how to turn a user-entered
/// endpoint into a URL and how to shape the POST body — the payload key is
/// service-specific (Discord `content`, Slack `text`, ntfy raw text), which is
/// exactly why a single "generic webhook URL" field would silently no-op.
enum AlertProvider: String, CaseIterable, Identifiable {
    case discord, slack, ntfy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .discord: "Discord"
        case .slack: "Slack"
        case .ntfy: "ntfy"
        }
    }

    /// Placeholder for the endpoint field.
    var fieldPrompt: String {
        switch self {
        case .discord: "https://discord.com/api/webhooks/…"
        case .slack: "https://hooks.slack.com/services/…"
        case .ntfy: "a topic name, or https://ntfy.sh/your-topic"
        }
    }

    /// One-line setup hint under the field.
    var hint: String {
        switch self {
        case .discord: "In Discord: Server Settings → Integrations → Webhooks → New Webhook → Copy Webhook URL."
        case .slack: "In Slack: add an Incoming Webhooks app and copy its webhook URL."
        case .ntfy: "Install the ntfy app and subscribe to a topic to get a push. Public ntfy.sh topics are readable by anyone who guesses the name — use a random one or self-host."
        }
    }

    /// What to say when the field is non-empty but invalid.
    var invalidHint: String {
        switch self {
        case .discord, .slack: "Enter a full https:// webhook URL."
        case .ntfy: "Enter a topic name or a https://ntfy.sh/… URL."
        }
    }

    /// Resolves a user-entered endpoint into the URL to POST to, or nil if it
    /// isn't valid for this provider. HTTPS-only (an alert reveals the machine
    /// name and that you're away — never in cleartext); ntfy also accepts a bare
    /// topic, expanded to `https://ntfy.sh/<topic>`.
    func resolve(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch self {
        case .discord, .slack:
            return httpsURL(trimmed)
        case .ntfy:
            if let url = httpsURL(trimmed) { return url }
            // Bare topic: a single path-safe token, expanded to the public server.
            let ok = trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            return ok ? URL(string: "https://ntfy.sh/\(trimmed)") : nil
        }
    }

    private func httpsURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Builds the POST for this provider's payload shape.
    func request(url: URL, message: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        switch self {
        case .discord:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["content": message])
        case .slack:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": message])
        case .ntfy:
            request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(message.utf8)
        }
        return request
    }
}

/// Sends an alert to the selected provider — one well-defined failure mode,
/// reported honestly with the real HTTP status.
enum AlertSender {
    enum SendError: LocalizedError {
        case notConfigured
        case unreachable(String)
        case rejected(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Add a valid endpoint first."
            case let .unreachable(detail):
                return "Couldn't reach the alert service — \(detail)"
            case let .rejected(code) where code == 401 || code == 403 || code == 404:
                return "The service rejected it (HTTP \(code)) — check the URL/topic is correct and still exists."
            case let .rejected(code):
                return "The service rejected the message (HTTP \(code))."
            }
        }
    }

    /// Awaitable send that reports the real outcome — used by "Send Test", so
    /// the button can tell the truth instead of guessing.
    static func send(provider: AlertProvider, endpoint: String, message: String) async throws {
        guard let url = provider.resolve(endpoint) else { throw SendError.notConfigured }
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: provider.request(url: url, message: message))
        } catch {
            throw SendError.unreachable((error as NSError).localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw SendError.rejected(code) }
    }

    /// Fire-and-forget for real alerts — never blocks sampling; logs failures.
    static func sendInBackground(provider: AlertProvider, endpoint: String, message: String) {
        Task {
            do {
                try await send(provider: provider, endpoint: endpoint, message: message)
            } catch {
                NSLog("MinStats alert failed: \(error.localizedDescription)")
            }
        }
    }
}
