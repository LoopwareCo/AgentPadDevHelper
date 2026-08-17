import XCTest
@testable import AgentPadDevHelper

#if os(macOS)
/// The dial-out ladder must never hand `NWConnection` a unix path it would TRAP on: sun_path
/// is 104 bytes on Darwin, and Network.framework's failure mode for exceeding it is a crash in
/// the HOST app (found live: a sandboxed app whose container path put the socket at 109 bytes).
final class DevKitClientEndpointTests: XCTestCase {

    func testUnixPathLimit() {
        XCTAssertTrue(DevKitClient.unixPathFits("/tmp/devkit-dev.sock"))
        XCTAssertTrue(DevKitClient.unixPathFits(String(repeating: "a", count: 103)))
        XCTAssertFalse(DevKitClient.unixPathFits(String(repeating: "a", count: 104)))
        // Bytes, not characters — a multi-byte path can exceed the limit at fewer characters.
        XCTAssertFalse(DevKitClient.unixPathFits(String(repeating: "é", count: 60)))
    }

    func testLadderNeverYieldsAnOverlongUnixPath() {
        for endpoint in DevKitClient.candidateEndpoints() {
            if case .unixSocket(let path) = endpoint.kind {
                XCTAssertLessThan(path.utf8.count, 104, "over-long unix path would trap: \(path)")
            }
        }
    }

    func testLadderAlwaysIncludesLoopbackTCP() {
        // The rung every environment (sandboxed, deep home, Simulator) can actually use.
        let tcpPorts = DevKitClient.candidateEndpoints().compactMap { endpoint -> UInt16? in
            if case .tcp(let host, let port) = endpoint.kind, host == "127.0.0.1" { return port }
            return nil
        }
        XCTAssertTrue(tcpPorts.contains(DevKit.devTCPPort))
        XCTAssertTrue(tcpPorts.contains(DevKit.releaseTCPPort))
    }
}
#endif
