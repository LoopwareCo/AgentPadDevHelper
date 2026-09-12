import XCTest
@testable import AgentPadDevHelper

final class GuestEndpointTests: XCTestCase {
    func testExplicitHostIsAdditiveAndDoesNotDuplicateAnAutomaticEndpoint() {
        let endpoint = DevKitClient.Endpoint(kind: .tcp(host: "127.0.0.1", port: DevKit.devTCPPort))
        let apps = DevKitClient.candidateEndpoints(lanHost: "127.0.0.1:\(DevKit.devTCPPort)")
        XCTAssertEqual(apps.filter { $0 == endpoint }.count, 1)
        let extra = DevKitClient.Endpoint(kind: .tcp(host: "127.0.0.1", port: 9911))
        let explicit = DevKitClient.candidateEndpoints(lanHost: "127.0.0.1:9911")
        XCTAssertTrue(explicit.contains(extra))
        XCTAssertTrue(explicit.contains(endpoint))
    }

    func testGuestAlwaysRetriesHostTunnelWithoutLaunchEnvironment() {
        XCTAssertEqual(DevKitClient.guestEndpoints(inVM: true), [
            DevKitClient.Endpoint(kind: .tcp(host: "127.0.0.1", port: DevKit.guestTCPPort))
        ])
        XCTAssertTrue(DevKitClient.guestEndpoints(inVM: false).isEmpty)
        XCTAssertNotEqual(DevKit.guestTCPPort, DevKit.devTCPPort)
        XCTAssertNotEqual(DevKit.guestTCPPort, DevKit.releaseTCPPort)
    }
}
