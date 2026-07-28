import XCTest
@testable import MinStatsProtocol

/// Pins the exact wire-signature format. If any of these change, the agent and
/// the iOS app stop agreeing and every signed request 401s — a total, silent
/// outage. These assertions make that a red build instead of a support fire.
///
/// The expected hashes are the canonical SHA-256 test vectors:
///   - empty string → e3b0c442…852b855
///   - "abc"        → ba7816bf…20015ad
/// so they also verify `bodyHash` itself, independent of any local recompute.
final class WireSignatureTests: XCTestCase {
    private let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private let abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testBodyHashKnownVectors() {
        XCTAssertEqual(WireSignature.bodyHash(Data()), emptyHash)
        XCTAssertEqual(WireSignature.bodyHash(Data("abc".utf8)), abcHash)
    }

    func testRequestMessageFormat() {
        let message = WireSignature.requestMessage(
            method: "POST", path: "/control/kill",
            timestamp: "1700000000", nonce: "n0nce", body: Data("abc".utf8)
        )
        XCTAssertEqual(
            String(data: message, encoding: .utf8),
            "POST\n/control/kill\n1700000000\nn0nce\n\(abcHash)"
        )
    }

    func testRequestMessageEmptyBody() {
        let message = WireSignature.requestMessage(
            method: "GET", path: "/stats",
            timestamp: "1700000000", nonce: "n0nce", body: Data()
        )
        XCTAssertEqual(
            String(data: message, encoding: .utf8),
            "GET\n/stats\n1700000000\nn0nce\n\(emptyHash)"
        )
    }

    func testResponseMessageFormat() {
        let message = WireSignature.responseMessage(nonce: "n0nce", body: Data("abc".utf8))
        XCTAssertEqual(
            String(data: message, encoding: .utf8),
            "RESPONSE\nn0nce\n\(abcHash)"
        )
    }

    /// The `RESPONSE` prefix is what domain-separates a response signature from
    /// a request signature — losing it would let one be replayed as the other.
    func testResponseAndRequestMessagesDiffer() {
        let request = WireSignature.requestMessage(
            method: "GET", path: "/stats", timestamp: "1", nonce: "n", body: Data()
        )
        let response = WireSignature.responseMessage(nonce: "n", body: Data())
        XCTAssertNotEqual(request, response)
    }
}
