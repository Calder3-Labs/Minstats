import XCTest
@testable import MinStatsProtocol

/// The version handshake decides whether the app and a given Mac can talk, and
/// which side to tell the user to update. These lock the direction so a future
/// protocol bump can't invert the message ("update your Mac" vs "update the app").
final class ProtocolCompatibilityTests: XCTestCase {
    func testSameVersionIsOK() {
        XCTAssertEqual(
            MinStatsProtocolVersion.compatibility(agentProtocol: MinStatsProtocolVersion.current),
            .ok
        )
    }

    func testNewerAgentAsksToUpdateTheApp() {
        XCTAssertEqual(
            MinStatsProtocolVersion.compatibility(agentProtocol: MinStatsProtocolVersion.current + 1),
            .agentNewer
        )
    }

    func testOlderAgentAsksToUpdateTheMac() {
        XCTAssertEqual(
            MinStatsProtocolVersion.compatibility(agentProtocol: MinStatsProtocolVersion.current - 1),
            .agentOlder
        )
    }
}
