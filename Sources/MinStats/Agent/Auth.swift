import CryptoKit
import Foundation
import MinStatsProtocol
import Observation

/// Request authentication for the agent.
///
/// Requests are signed with HMAC-SHA256 rather than carrying a bearer
/// token: the shared secret authorizes *restarting the Mac*, so it must
/// never cross a plaintext LAN connection. The signature covers the method,
/// path, timestamp, nonce, and a hash of the body — so a kill payload can't
/// be swapped for a different one under a captured signature.
///
/// Every paired phone holds its OWN secret (minted per pairing, looked up by
/// the client id it sends in X-MinStats-Key), so one phone can be revoked
/// without kicking the others.
@MainActor
final class Auth {
    enum Failure: Error {
        case missingHeaders
        case unknownKey
        case staleTimestamp
        case replayed
        case badSignature
    }

    /// Requests older/newer than this are refused (clock skew + replay window).
    private static let maxSkew: TimeInterval = 60
    /// Nonces are remembered for longer than the skew window, so a request
    /// can't be replayed while it's still within its valid time.
    private static let nonceTTL: TimeInterval = 120

    private let deviceID: String
    private let store: ClientStore
    private var seenNonces: [String: Date] = [:]

    init(deviceID: String, store: ClientStore) {
        self.deviceID = deviceID
        self.store = store
    }

    /// The pairing payload handed to the phone (QR / copyable string), for
    /// one client slot. `id` stays the Mac's identity — what the phone lists —
    /// while `client` + `secret` are the phone's own credentials.
    ///
    /// Carries the display name as well as the host: without it the phone can
    /// only label the Mac by hostname ("192.168.1.4"), which is useless in a
    /// list of several Macs.
    func pairingURL(for client: ClientStore.Client, host: String, port: UInt16, name: String, altHosts: [String] = []) -> String {
        var components = URLComponents()
        components.scheme = "minstats"
        components.host = "pair"
        var items: [URLQueryItem] = [
            .init(name: "id", value: deviceID),
            .init(name: "name", value: name),
            .init(name: "host", value: host),
            .init(name: "port", value: String(port)),
            .init(name: "client", value: client.id),
            .init(name: "secret", value: client.secret.base64EncodedString()),
        ]
        // Extra reachable addresses (Tailscale / LAN IP), so pairing captures
        // the remote routes. Absent → the phone works on-LAN only until re-paired.
        if !altHosts.isEmpty { items.append(.init(name: "alt", value: altHosts.joined(separator: ","))) }
        components.queryItems = items
        return components.string ?? ""
    }

    /// Verifies a signed request. Throws rather than returning a Bool so a
    /// caller can't accidentally ignore the result.
    func verify(method: String, path: String, headers: [String: String], body: Data) throws {
        guard let key = headers["x-minstats-key"],
              let timestamp = headers["x-minstats-timestamp"],
              let nonce = headers["x-minstats-nonce"],
              let signature = headers["x-minstats-signature"],
              let provided = Data(base64Encoded: signature)
        else { throw Failure.missingHeaders }

        guard let client = store.client(for: key) else { throw Failure.unknownKey }

        guard let sent = Double(timestamp),
              abs(Date().timeIntervalSince1970 - sent) <= Self.maxSkew
        else { throw Failure.staleTimestamp }

        // Constant-time comparison. The signed message comes from the shared
        // `WireSignature` — the same function the iOS client signs with, so the
        // two can't drift.
        guard HMAC<SHA256>.isValidAuthenticationCode(
            provided,
            authenticating: WireSignature.requestMessage(
                method: method, path: path, timestamp: timestamp, nonce: nonce, body: body
            ),
            using: SymmetricKey(data: client.secret)
        ) else { throw Failure.badSignature }

        // Only burn the nonce once the signature is known good, so an
        // attacker can't invalidate a legitimate nonce with a forged request.
        try claim(nonce: nonce)

        // The phone is real now: its first verified request claims the slot,
        // and the pairing window moves on to offering a fresh one.
        store.markClaimed(client.id)
        if let name = headers["x-minstats-client-name"] {
            store.noteName(name, for: client.id)
        }
    }

    /// Signs a response body so the phone can verify it came from the paired
    /// Mac and not an impostor on the same network (requests prove the phone
    /// to the Mac; this is the other direction). Signed with the *requesting
    /// client's* secret and bound to its nonce. The signed message comes from
    /// the shared `WireSignature`, so it can't drift from the phone's check.
    func responseSignature(clientID: String, nonce: String, body: Data) -> String? {
        guard let client = store.client(for: clientID) else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(
            for: WireSignature.responseMessage(nonce: nonce, body: body),
            using: SymmetricKey(data: client.secret)
        )
        return Data(mac).base64EncodedString()
    }

    /// Records a nonce, rejecting reuse. Also prunes expired entries so the
    /// set can't grow without bound on a long-running agent.
    private func claim(nonce: String) throws {
        let now = Date()
        seenNonces = seenNonces.filter { now.timeIntervalSince($0.value) < Self.nonceTTL }
        guard seenNonces[nonce] == nil else { throw Failure.replayed }
        seenNonces[nonce] = now
    }
}

// MARK: - Client credentials

/// The per-phone pairing credentials this Mac has issued.
///
/// One JSON file (0600) holds every client. The pairing QR always offers an
/// *unclaimed* slot; a phone's first verified request claims it (and a fresh
/// slot is minted), so pairing two phones back-to-back Just Works and any
/// one phone can be revoked without touching the others.
///
/// The file lives on disk rather than in the Keychain, deliberately. The
/// Keychain ACL is bound to code identity, and this app is ad-hoc signed —
/// so every rebuild changes its identity and `SecItemCopyMatching` *blocks
/// forever* waiting on an approval dialog a headless agent can never show
/// (a hang, not an error). Beyond the practicality: these secrets authorize
/// quitting apps and requesting a restart, which is strictly less than any
/// process already running as this user can do — so file permissions are the
/// honest boundary here, not a downgrade. Revisit once Developer ID signing
/// lands and code identity is stable.
@MainActor
@Observable
final class ClientStore {
    struct Client: Codable, Identifiable, Hashable {
        let id: String
        let secret: Data
        let createdAt: Double
        var claimedAt: Double?
        /// What the phone calls itself (X-MinStats-Client-Name) — recorded
        /// only from requests whose signature verified. Display-only.
        var name: String?

        static func fresh() -> Client {
            Client(
                id: UUID().uuidString,
                secret: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
                createdAt: Date().timeIntervalSince1970,
                claimedAt: nil,
                name: nil
            )
        }
    }

    private(set) var clients: [Client] = []
    private let deviceID: String

    init(deviceID: String) {
        self.deviceID = deviceID
        load()
        migrateLegacy()
        ensureUnclaimed()
        save()
    }

    /// The client the pairing QR currently offers. Every mutation re-ensures
    /// one exists, so the fallback is unreachable in practice.
    var unclaimed: Client {
        clients.first { $0.claimedAt == nil } ?? Client.fresh()
    }

    /// Phones that have actually paired — what the revocation list shows.
    var claimed: [Client] {
        clients.filter { $0.claimedAt != nil }
    }

    func client(for id: String) -> Client? {
        clients.first { $0.id == id }
    }

    func markClaimed(_ id: String) {
        guard let index = clients.firstIndex(where: { $0.id == id }),
              clients[index].claimedAt == nil
        else { return }
        clients[index].claimedAt = Date().timeIntervalSince1970
        ensureUnclaimed()
        save()
    }

    /// Records what a phone calls itself. Trusted only as far as it's
    /// reached from `Auth.verify` AFTER the signature validated; sanitized
    /// because it's still remote input headed for the UI.
    func noteName(_ raw: String, for id: String) {
        let decoded = raw.removingPercentEncoding ?? raw
        let name = String(decoded
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(40))
        guard !name.isEmpty,
              let index = clients.firstIndex(where: { $0.id == id }),
              clients[index].name != name
        else { return }
        clients[index].name = name
        save()
    }

    /// Kicks one phone: its next request is a 401, and no other phone notices.
    func revoke(_ id: String) {
        clients.removeAll { $0.id == id }
        // A revoked legacy client must take its secret file with it, or
        // migration would resurrect it on the next launch.
        if id == deviceID {
            try? FileManager.default.removeItem(at: AgentIdentity.legacySecretURL)
        }
        ensureUnclaimed()
        save()
    }

    /// The "shared the QR with the wrong person" escape hatch: every paired
    /// phone stops working.
    func revokeAll() {
        clients = []
        try? FileManager.default.removeItem(at: AgentIdentity.legacySecretURL)
        ensureUnclaimed()
        save()
    }

    private func ensureUnclaimed() {
        guard !clients.contains(where: { $0.claimedAt == nil }) else { return }
        clients.append(.fresh())
    }

    /// An install that paired before per-phone secrets holds one shared
    /// secret in `agent-secret`, and its phones sign with the Mac's device id
    /// as their key — so it becomes a claimed client under that id and they
    /// keep working untouched. Runs per device id (the app and the `--serve`
    /// CLI have different UserDefaults domains, hence different ids, but
    /// share this file), so each domain heals its own id on first run.
    private func migrateLegacy() {
        guard let legacy = AgentIdentity.legacySecret(), client(for: deviceID) == nil else { return }
        clients.append(Client(
            id: deviceID, secret: legacy,
            createdAt: Date().timeIntervalSince1970,
            claimedAt: Date().timeIntervalSince1970
        ))
    }

    nonisolated private static var fileURL: URL {
        AgentIdentity.supportDirectory.appendingPathComponent("agent-clients")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([Client].self, from: data)
        else { return }
        clients = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(clients) else { return }
        // createFile applies the permissions at creation, so the secrets are
        // 0600 from the first byte.
        FileManager.default.createFile(
            atPath: Self.fileURL.path, contents: data,
            attributes: [.posixPermissions: 0o600]
        )
    }
}

// MARK: - Device identity

/// Stable identity for this Mac. The id is public (it's in the Bonjour TXT
/// record); per-phone credentials live in `ClientStore`.
enum AgentIdentity {
    private static let idKey = "agentDeviceID"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MinStats", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return base
    }

    /// Where the pre-1.5 single shared secret lived; read only for migration
    /// into `ClientStore`, deleted when its legacy client is revoked.
    static var legacySecretURL: URL {
        supportDirectory.appendingPathComponent("agent-secret")
    }

    static func deviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: idKey) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: idKey)
        return fresh
    }

    static func legacySecret() -> Data? {
        guard let data = try? Data(contentsOf: legacySecretURL), data.count == 32 else { return nil }
        return data
    }
}
