#if !canImport(UIKit) && canImport(AppKit)
import XCTest
import AppKit
@testable import AgentPadDevHelper

/// The AppKit walk roots each window at its FRAME VIEW (`contentView.superview`), so the titlebar
/// and toolbar are walked too. That view's own AX layer carries no name — `accessibilityLabel()`
/// is nil on an `NSThemeFrame` — so every window used to read as an anonymous class name, and the
/// only way to tell one from another was the first label inside it. That's how a driver run came to
/// call the environment pop-out "Paused" (its status chip) and the Settings window "Server:" (the
/// pane's server chooser). A window root now reports as the window: role `window`, label = title.
final class WindowRootNodeTests: XCTestCase {

    private func window(titled title: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = title
        w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        return w
    }

    func testWindowRootIsNamedByItsTitle() throws {
        let w = window(titled: "macOS 27")
        let frame = try XCTUnwrap(w.contentView?.superview)
        let node = UIDriver().makeNode(for: frame, ref: 1)
        XCTAssertEqual(node.role, "window")
        XCTAssertEqual(node.label, "macOS 27")
        XCTAssertTrue(node.actions.isEmpty, "a window is walked into, not pressed")
    }

    /// A title the window HIDES (the environment pop-out draws its own, in a titlebar accessory)
    /// is still the window's name — that case is precisely the one that went wrong.
    func testHiddenWindowTitleStillNamesTheRoot() throws {
        let w = window(titled: "macOS 27")
        w.titleVisibility = .hidden
        let frame = try XCTUnwrap(w.contentView?.superview)
        XCTAssertEqual(UIDriver().makeNode(for: frame, ref: 1).label, "macOS 27")
    }

    /// Only the ROOT is the window: a label inside it reads as its own text, so nothing about the
    /// rest of the walk changed.
    func testViewsInsideTheWindowAreUnaffected() throws {
        let w = window(titled: "macOS 27")
        let chip = NSTextField(labelWithString: "Paused")
        w.contentView?.addSubview(chip)
        let node = UIDriver().makeNode(for: chip, ref: 2)
        XCTAssertEqual(node.role, "text")
        XCTAssertEqual(node.label, "Paused")
    }

    /// An untitled window (a popover's, a panel's) gets no invented name — better an anonymous
    /// `window` than a made-up one.
    func testUntitledWindowHasNoLabel() throws {
        let w = window(titled: "")
        let frame = try XCTUnwrap(w.contentView?.superview)
        let node = UIDriver().makeNode(for: frame, ref: 1)
        XCTAssertEqual(node.role, "window")
        XCTAssertNil(node.label)
    }
}
#endif
