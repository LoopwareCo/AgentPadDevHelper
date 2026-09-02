import XCTest
import Foundation
@testable import AgentPadDevHelper

/// The INJECTED build of this SDK (`Sources/AgentPadDevHelperInject` in the AgentPad repo) stands
/// down when the host app already embeds the package, and it detects that by looking up ONE of
/// this module's Objective-C-visible classes by its mangled runtime name. This pins that name to
/// the real module: rename or de-objc the class and the guard silently stops working, so this
/// test fails instead.
final class InjectGuardProbeTests: XCTestCase {
    /// Must match `DevHelperInjectGuard.embeddedProbeClassName` in InjectEntry.swift.
    private let probeClassName = "_TtC17AgentPadDevHelper23ReviewBarViewController"

    func testEmbeddedProbeClassIsRegisteredUnderThePinnedName() {
        XCTAssertNotNil(NSClassFromString(probeClassName),
                        "the injected build probes this exact name to detect an embedded copy")
        XCTAssertTrue(NSClassFromString(probeClassName) == ReviewBarViewController.self)
    }
}
