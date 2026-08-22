import XCTest
@testable import AgentPadDevHelper

#if os(macOS)
import AppKit

/// The element Review Mode attaches when the user has chosen nothing. It used to be the reviewed
/// window's CONTENT VIEW — which on most windows is an anonymous container, so the compose token
/// read "NSView" and the feedback item shipped "NSView" as its whole path. The default is the
/// WINDOW now, named by its title.
final class DefaultAttachmentTests: XCTestCase {

    private func window(_ title: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                         styleMask: [.titled], backing: .buffered, defer: true)
        w.title = title
        return w
    }

    func testTheWindowNodeIsNamedByItsTitle() {
        let node = ElementPath.windowNode(for: window("Local LLM"))
        XCTAssertEqual(node.role, "window")
        XCTAssertEqual(node.label, "Local LLM")
        XCTAssertEqual(ElementPath.displayName(for: node), "Local LLM — window")
    }

    /// A titleless window (a panel, an inspector) must still not fall through to the class name.
    func testAnUntitledWindowFallsBackToTheAppNameNotTheClass() {
        let node = ElementPath.windowNode(for: window(""))
        XCTAssertNil(ElementPath.title(of: window("")))
        XCTAssertEqual(node.label, UIDriver.appName)
        XCTAssertEqual(ElementPath.displayName(for: node), "\(UIDriver.appName) — window")
    }

    /// The window is the coordinate space the descriptor's frames are in, so it sits at the
    /// origin and spans the whole frame (content + titlebar).
    func testTheNodeCarriesTheWindowsOwnBounds() {
        let node = ElementPath.windowNode(for: window("Local LLM"))
        XCTAssertEqual(node.x, 0)
        XCTAssertEqual(node.y, 0)
        XCTAssertEqual(node.w, 400)
        XCTAssertGreaterThanOrEqual(node.h ?? 0, 300)
    }
}
#endif
