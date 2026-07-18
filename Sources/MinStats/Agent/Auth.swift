import CryptoKit
import Foundation

/// Request authentication for the agent.
///
/// Requests are signed with HMAC-SHA256 rather than carrying a bearer
/// token: the shared secret authorizes *restarting the Mac*, so it must
/// never cross a plaintext LAN connection. The signature covers the method,
/// path, timestamp, nonce, and a hash of the body — so a kill payload can't
/// be swapped for a different one under a captured signature.
///
/// The secret lives in the Keychain (not UserDefaults, where the app's
/// other prefs live) precisely because of what it authorizes.
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
    private let secret: SymmetricKey
    private var seenNonces: [String: Date] = [:]
    private let lock = NSLock()

    init(deviceID: String, secret: SymmetricKey) {
        self.deviceID = deviceID
        self.secret = secret
    }

    /// The pairing payload handed to the phone (QR / copyable string).
    ///
    /// Carries the display name as well as the host: without it the phone can
    /// only label the Mac by hostname ("192.168.1.4"), which is useless in a
    /// list of several Macs.
    func pairingURL(host: String, port: UInt16, name: String, altHosts: [String] = []) -> String {
        let raw = secret.withUnsafeBytes { Data($0) }.base64EncodedString()
        var components = URLComponents()
        components.scheme = "minstats"
        components.host = "pair"
        var items: [URLQueryItem] = [
            .init(name: "id", value: deviceID),
            .init(name: "name", value: name),
            .init(name: "host", value: host),
            .init(name: "port", value: String(port)),
            .init(name: "secret", value: raw),
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

        guard key == deviceID else { throw Failure.unknownKey }

        guard let sent = Double(timestamp),
              abs(Date().timeIntervalSince1970 - sent) <= Self.maxSkew
        else { throw Failure.staleTimestamp }

        let signed = Data(Self.signingString(
            method: method, path: path, timestamp: timestamp, nonce: nonce, body: body
        ).utf8)
        // Constant-time comparison.
        guard HMAC<SHA256>.isValidAuthenticationCode(provided, authenticating: signed, using: secret)
        else { throw Failure.badSignature }

        // Only burn the nonce once the signature is known good, so an
        // attacker can't invalidate a legitimate nonce with a forged request.
        try claim(nonce: nonce)
    }

    /// Signs a response body so the phone can verify it came from the paired
    /// Mac and not an impostor on the same network (requests prove the phone
    /// to the Mac; this is the other direction). Bound to the request's nonce,
    /// which is unique per request, so a captured response can never be
    /// replayed for a different one. Must stay byte-identical to the
    /// verification in `ios/MinStats/StatsClient.swift`.
    func responseSignature(nonce: String, body: Data) -> String {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("RESPONSE\n\(nonce)\n\(bodyHash)".utf8),
            using: secret
        )
        return Data(mac).base64EncodedString()
    }

    /// The exact bytes both sides sign. Body is included as a hash so large
    /// payloads don't have to be re-sent through the MAC.
    static func signingString(method: String, path: String, timestamp: String, nonce: String, body: Data) -> String {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return "\(method)\n\(path)\n\(timestamp)\n\(nonce)\n\(bodyHash)"
    }

    /// Records a nonce, rejecting reuse. Also prunes expired entries so the
    /// set can't grow without bound on a long-running agent.
    private func claim(nonce: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        seenNonces = seenNonces.filter { now.timeIntervalSince($0.value) < Self.nonceTTL }
        guard seenNonces[nonce] == nil else { throw Failure.replayed }
        seenNonces[nonce] = now
    }
}

// MARK: - Persistence

/// Stable identity + secret for this Mac. The id is public (it's in the
/// Bonjour TXT record); the secret is owner-readable only.
///
/// The secret lives in a 0600 file rather than the Keychain, deliberately.
/// The Keychain ACL is bound to code identity, and this app is ad-hoc signed
/// — so every rebuild changes its identity and `SecItemCopyMatching` *blocks
/// forever* waiting on an approval dialog a headless agent can never show
/// (a hang, not an error). Beyond the practicality: this secret authorizes
/// quitting apps and requesting a restart, which is strictly less than any
/// process already running as this user can do — so file permissions are the
/// honest boundary here, not a downgrade. Revisit once Developer ID signing
/// lands and code identity is stable.
enum AgentIdentity {
    private static let idKey = "agentDeviceID"

    private static var secretURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MinStats", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return base.appendingPathComponent("agent-secret")
    }

    static func deviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: idKey) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: idKey)
        return fresh
    }

    /// Loads the paired secret, or nil if this Mac has never been paired.
    static func loadSecret() -> SymmetricKey? {
        guard let data = try? Data(contentsOf: secretURL), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// Generates and stores a fresh secret, replacing any existing one
    /// (which invalidates already-paired phones — that's the rotate path).
    @discardableResult
    static func rotateSecret() -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let url = secretURL
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return key
    }

    /// The secret, creating one on first use.
    static func secret() -> SymmetricKey {
        loadSecret() ?? rotateSecret()
    }
}
