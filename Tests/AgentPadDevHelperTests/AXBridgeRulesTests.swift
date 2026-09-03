import XCTest
@testable import AgentPadDevHelper

/// The platform-neutral core of `AXBridge`: how UIAccessibility traits map onto the driver's role
/// vocabulary, which traits make an element pressable, where AX-only elements may be grafted into
/// the view walk, and how toggle values are normalised. These run on macOS too — the UIKit half
/// translates real `UIAccessibilityTraits` into `AXBridge.TraitFlags` before calling in here.
final class AXBridgeRulesTests: XCTestCase {

    // MARK: trait → role

    func testPlainTraitsMapToDriverRoles() {
        XCTAssertEqual(AXBridge.genericRole(traits: .button), "button")
        XCTAssertEqual(AXBridge.genericRole(traits: .link), "link")
        XCTAssertEqual(AXBridge.genericRole(traits: .image), "image")
        XCTAssertEqual(AXBridge.genericRole(traits: .staticText), "text")
        XCTAssertEqual(AXBridge.genericRole(traits: .header), "text")
        XCTAssertEqual(AXBridge.genericRole(traits: .searchField), "textField")
        XCTAssertEqual(AXBridge.genericRole(traits: .adjustable), "slider")
        XCTAssertEqual(AXBridge.genericRole(traits: .keyboardKey), "button")
        XCTAssertEqual(AXBridge.genericRole(traits: .tabBar), "tabBar")
    }

    /// A SwiftUI Toggle carries BOTH `button` and `toggleButton`; it must read as a switch, the
    /// role a UISwitch has in the view walk, so `find role:"switch"` finds either.
    func testToggleButtonWinsOverButton() {
        XCTAssertEqual(AXBridge.genericRole(traits: [.button, .toggleButton]), "switch")
    }

    /// A slider is adjustable and may also be marked as a button by its host; adjustable wins so
    /// the increment/decrement actions are offered.
    func testAdjustableWinsOverButton() {
        XCTAssertEqual(AXBridge.genericRole(traits: [.button, .adjustable]), "slider")
    }

    /// Modifier traits alone say nothing about WHAT the element is.
    func testModifierTraitsAloneGiveNoRole() {
        XCTAssertNil(AXBridge.genericRole(traits: []))
        XCTAssertNil(AXBridge.genericRole(traits: .selected))
        XCTAssertNil(AXBridge.genericRole(traits: .notEnabled))
        XCTAssertNil(AXBridge.genericRole(traits: [.selected, .notEnabled]))
    }

    /// Modifiers don't change the role either — a disabled, selected button is still a button.
    func testModifiersDoNotChangeRole() {
        XCTAssertEqual(AXBridge.genericRole(traits: [.button, .selected, .notEnabled]), "button")
        XCTAssertEqual(AXBridge.genericRole(traits: [.staticText, .selected]), "text")
    }

    // MARK: pressability

    func testPressableTraits() {
        XCTAssertTrue(AXBridge.isPressable(traits: .button))
        XCTAssertTrue(AXBridge.isPressable(traits: .link))
        XCTAssertTrue(AXBridge.isPressable(traits: .keyboardKey))
        XCTAssertTrue(AXBridge.isPressable(traits: [.button, .toggleButton]))
        XCTAssertFalse(AXBridge.isPressable(traits: .staticText))
        XCTAssertFalse(AXBridge.isPressable(traits: .adjustable))
        XCTAssertFalse(AXBridge.isPressable(traits: .image))
        XCTAssertFalse(AXBridge.isPressable(traits: []))
    }

    // MARK: graft rule (no duplicates of real controls)

    /// Only containers are graft points: a real control, or a view that is itself one AX element,
    /// is already fully represented by its own node.
    func testGraftPointRule() {
        XCTAssertTrue(AXBridge.isGraftPoint(isControl: false, isAccessibilityElement: false), "hosting view / plain container")
        XCTAssertFalse(AXBridge.isGraftPoint(isControl: true, isAccessibilityElement: false), "UIControl")
        XCTAssertFalse(AXBridge.isGraftPoint(isControl: false, isAccessibilityElement: true), "a leaf AX element (UILabel, custom element view)")
        XCTAssertFalse(AXBridge.isGraftPoint(isControl: true, isAccessibilityElement: true), "UIButton")
    }

    // MARK: toggle values

    /// UIKit's AX bundle and SwiftUI report toggles as "1"/"0" (or localised On/Off); the view
    /// walk renders a UISwitch as "on"/"off", and the two must read the same.
    func testToggleValueNormalisation() {
        XCTAssertEqual(AXBridge.toggleValue("1"), "on")
        XCTAssertEqual(AXBridge.toggleValue("0"), "off")
        XCTAssertEqual(AXBridge.toggleValue("On"), "on")
        XCTAssertEqual(AXBridge.toggleValue("OFF"), "off")
        XCTAssertEqual(AXBridge.toggleValue("true"), "on")
        XCTAssertEqual(AXBridge.toggleValue("false"), "off")
        XCTAssertEqual(AXBridge.toggleValue("mixed"), "mixed", "unknown values pass through untouched")
    }

    // MARK: rendering an AX-only node

    /// An AX-only node renders in the same compact line format as a view node, so a SwiftUI
    /// switch and a UISwitch are indistinguishable to the agent reading a snapshot.
    func testAXNodeLineMatchesViewNodeFormat() {
        let node = UINode(ref: 7, role: "switch", label: "Probe toggle", value: "on",
                          identifier: "probe.toggle", x: 201, y: 437, enabled: true, actions: ["activate"])
        XCTAssertEqual(node.line(), "[7] switch \"Probe toggle\" =\"on\" #probe.toggle @201,437")
    }
}
