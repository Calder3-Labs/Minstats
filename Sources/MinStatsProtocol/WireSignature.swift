import CryptoKit
import Foundation

/// The canonical bytes the agent and the iOS client sign — defined **once**,
/// here, and called by both sides so they can never drift.
///
/// This used to be two hand-maintained copies (`Auth.signingString` on the Mac,
/// an inline string in `StatsClient` on the phone). They had to stay
/// byte-identical or every request 401s — a silent, total outage that only a
/// human reading both files could catch. Making it one shared function turns
/// "keep two copies identical" into "there is one copy," and `WireSignatureTests`
/// pins the exact format so a change is caught at build time, not by a customer.
///
/// The HMAC *key* still differs by side (the agent verifies with the client's
/// secret; the client signs with its own) — only the signed *message* is shared.
public enum WireSignature {
    /// Lowercase hex SHA-256 of the body. The body is signed as a hash so large
    /// payloads don't have to be re-run through the MAC.
    public static func bodyHash(_ body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }

    /// The message a request signature covers:
    /// `METHOD\nPATH\nTIMESTAMP\nNONCE\nsha256hex(body)`. Binding the method and
    /// path stops a captured `GET /stats` signature being replayed as
    /// `POST /control/kill`; the nonce + timestamp bound replay.
    public static func requestMessage(
        method: String, path: String, timestamp: String, nonce: String, body: Data
    ) -> Data {
        Data("\(method)\n\(path)\n\(timestamp)\n\(nonce)\n\(bodyHash(body))".utf8)
    }

    /// The message a response signature covers: `RESPONSE\nNONCE\nsha256hex(body)`.
    /// The `RESPONSE` prefix domain-separates it from a request signature (so one
    /// can't be mistaken for the other), and binding the request's nonce means a
    /// captured response can't be replayed as the answer to a different request.
    public static func responseMessage(nonce: String, body: Data) -> Data {
        Data("RESPONSE\n\(nonce)\n\(bodyHash(body))".utf8)
    }
}
