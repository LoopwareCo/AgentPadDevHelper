#if !canImport(UIKit) && canImport(AppKit)
import XCTest
import AppKit
@testable import AgentPadDevHelper

/// A checkbox has to read as a CHECKBOX, with its ticked state as the node's value — otherwise a
/// driver can't tell whether a destructive toggle (the run-target card's "Run in a copy", which
/// decides whether the user's base image is cloned or written to) is on before it presses Start.
///
/// It didn't. On macOS 27 a cell-backed control answers `AXUnknown` at the VIEW level —
/// `NSButton.accessibilityRole()` is unknown and `accessibilityValue()` nil, while its
/// `NSButtonCell` says `AXCheckBox` — so every checkbox in every app the driver walked reported
/// `role: button, value: (none)`. `UIDriver.axRole` asks the cell when the view has nothing to say.
final class CheckboxNodeTests: XCTestCase {

    /// The exact AppKit fact this fix stands on, asserted so an OS change that fixes it upstream
    /// shows up here rather than as a silently redundant fallback.
    func testViewLevelRoleIsUnknownWhileTheCellKnows() {
        let box = NSButton(checkboxWithTitle: "Run in a copy", target: nil, action: nil)
        XCTAssertEqual(box.cell?.accessibilityRole(), .checkBox)
        XCTAssertEqual(UIDriver.axRole(box), .checkBox)
    }

    func testCheckboxNodeReportsRoleAndTickedState() {
        let box = NSButton(checkboxWithTitle: "Run in a copy", target: nil, action: nil)
        box.state = .on
        var node = UIDriver().makeNode(for: box, ref: 1)
        XCTAssertEqual(node.role, "checkbox")
        XCTAssertEqual(node.value, "on")
        XCTAssertEqual(node.label, "Run in a copy")
        XCTAssertTrue(node.actions.contains("activate"))

        box.state = .off
        node = UIDriver().makeNode(for: box, ref: 1)
        XCTAssertEqual(node.value, "off", "the node's value must track the control, not a snapshot")
    }

    func testRadioButtonReportsItsOwnRoleAndState() {
        let radio = NSButton(radioButtonWithTitle: "Warm", target: nil, action: nil)
        radio.state = .on
        let node = UIDriver().makeNode(for: radio, ref: 1)
        XCTAssertEqual(node.role, "radio")
        XCTAssertEqual(node.value, "on")
    }

    /// A momentary push button has no state worth reporting — it must NOT pick up an on/off value
    /// from the cell fallback.
    func testPushButtonStaysValueless() {
        let node = UIDriver().makeNode(for: NSButton(title: "Start VM", target: nil, action: nil), ref: 1)
        XCTAssertEqual(node.role, "button")
        XCTAssertNil(node.value)
    }

    /// A view whose identifier is set is findable by it (`ui_find identifier:`) — the other half of
    /// making a toggle drivable.
    func testIdentifierRidesOnTheNode() {
        let box = NSButton(checkboxWithTitle: "Run in a copy", target: nil, action: nil)
        box.identifier = NSUserInterfaceItemIdentifier("runtarget.inCopy")
        XCTAssertEqual(UIDriver().makeNode(for: box, ref: 1).identifier, "runtarget.inCopy")
    }
}
#endif
