import XCTest
@testable import AgentPadDevHelper

/// The gate that decides whether the UI-control channel is allowed to open. Getting this wrong in
/// the permissive direction ships a remote-control channel to end users, so every distribution
/// channel gets a test — and so does the ordinary local build, because a false positive here would
/// silently disable the SDK for every developer using it.
final class BuildTrustTests: XCTestCase {

    // MARK: policy

    func testAPlainLocalBuildIsDevelopment() {
        // Unsigned / ad-hoc: no receipt, no profile, no Developer ID.
        XCTAssertEqual(BuildTrust.verdict(for: .init()), .development)
    }

    func testABuildSignedWithADevelopmentProfileIsDevelopment() {
        XCTAssertEqual(BuildTrust.verdict(for: .init(profileAllowsDebugging: true)), .development)
    }

    func testTestFlightIsRefused() {
        let verdict = BuildTrust.verdict(for: .init(testFlightReceipt: true))
        XCTAssertFalse(verdict.isDevelopment)
        guard case .shipped(let reason) = verdict else { return XCTFail("expected .shipped") }
        XCTAssertTrue(reason.contains("TestFlight"), "the reason should name the channel; got: \(reason)")
    }

    func testAppStoreIsRefused() {
        let verdict = BuildTrust.verdict(for: .init(appStoreReceipt: true))
        guard case .shipped(let reason) = verdict else { return XCTFail("expected .shipped") }
        XCTAssertTrue(reason.contains("App Store"), "got: \(reason)")
    }

    func testDeveloperIDSignedIsRefused() {
        let verdict = BuildTrust.verdict(for: .init(developerIDSigned: true))
        guard case .shipped(let reason) = verdict else { return XCTFail("expected .shipped") }
        XCTAssertTrue(reason.contains("Developer ID"), "got: \(reason)")
    }

    func testADistributionProfileIsRefused() {
        let verdict = BuildTrust.verdict(for: .init(profileAllowsDebugging: false))
        guard case .shipped(let reason) = verdict else { return XCTFail("expected .shipped") }
        XCTAssertTrue(reason.contains("distribution"), "got: \(reason)")
    }

    /// A Debug-configured archive pushed to TestFlight is the exact case the compile-time
    /// `#if DEBUG` can't catch — evidence of distribution has to win over the development profile
    /// such a build is otherwise signed with.
    func testDistributionEvidenceBeatsADevelopmentProfile() {
        let verdict = BuildTrust.verdict(for: .init(testFlightReceipt: true, profileAllowsDebugging: true))
        XCTAssertFalse(verdict.isDevelopment)
    }

    // MARK: provisioning-profile parsing

    func testReadsGetTaskAllowFromADevelopmentProfile() {
        let profile = wrap("<key>get-task-allow</key>\n\t\t<true/>")
        XCTAssertEqual(BuildTrust.profileGrantsGetTaskAllow(profile), true)
    }

    func testReadsGetTaskAllowFromADistributionProfile() {
        let profile = wrap("<key>get-task-allow</key>\n\t\t<false/>")
        XCTAssertEqual(BuildTrust.profileGrantsGetTaskAllow(profile), false)
    }

    /// The value is whichever boolean comes FIRST after the key — a later `<true/>` belonging to
    /// some other entitlement must not flip a distribution profile into a development one.
    func testTakesTheBooleanNearestTheKey() {
        let profile = wrap("<key>get-task-allow</key>\n\t\t<false/>\n\t\t<key>aps-environment</key>\n\t\t<true/>")
        XCTAssertEqual(BuildTrust.profileGrantsGetTaskAllow(profile), false)
    }

    func testAProfileWithoutTheKeyIsUnknownRatherThanADecision() {
        XCTAssertNil(BuildTrust.profileGrantsGetTaskAllow(wrap("<key>aps-environment</key><string>production</string>")))
        XCTAssertNil(BuildTrust.profileGrantsGetTaskAllow(Data([0x00, 0x01, 0x02])))
    }

    /// A real profile is a CMS envelope with binary either side of the plist; the scan has to cope
    /// with bytes that aren't valid UTF-8.
    private func wrap(_ plistFragment: String) -> Data {
        var data = Data([0x30, 0x82, 0x0A, 0xFF, 0x06, 0x09, 0x80, 0xFE])   // DER-ish preamble
        data.append(Data(("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>"
                          + plistFragment + "</dict></plist>").utf8))
        data.append(Data([0xFF, 0xD9, 0x00]))
        return data
    }
}
