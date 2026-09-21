#if !canImport(UIKit) && canImport(AppKit)
import XCTest
import AppKit
@testable import AgentPadDevHelper

/// `ui_pick_tree` — the app half of commenting on one control of a running app from a viewer.
///
/// The viewer hit-tests this list locally over the device feed, so the numbers here ARE the
/// feature: they leave AppKit's bottom-left, whole-desktop coordinates and have to arrive as
/// fractions of the display, measured DOWNWARD from its top. Getting the flip wrong doesn't crash
/// anything — it just makes the crosshair name the element mirrored about the middle of the
/// screen, which looks entirely plausible until you click.
final class PickTreeGeometryTests: XCTestCase {

    /// Put a window at a known place on the primary display and read one of its views back out.
    private func placedWindow(height: CGFloat = 200) throws -> (NSWindow, NSView, CGRect) {
        let screen = try XCTUnwrap(NSScreen.screens.first).frame
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: height),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Greeter"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: height))
        w.contentView = content
        // Top-left of the display, so "measured from the top" and "measured from the bottom" can't
        // coincide: the window's top edge sits at the screen's top edge.
        w.setFrameTopLeftPoint(NSPoint(x: screen.minX, y: screen.maxY))
        return (w, content, screen)
    }

    func testFramesAreFractionsOfTheDisplayMeasuredFromItsTop() throws {
        let (window, content, screen) = try placedWindow()
        let frame = try XCTUnwrap(UIDriver().normalizedScreenFrame(of: content))

        XCTAssertEqual(frame.minX, 0, accuracy: 0.001, "the window is flush with the left edge")
        // The content view sits just under the titlebar, so a small way down from the top — NOT
        // almost at the bottom, which is what an unflipped y would report.
        XCTAssertLessThan(frame.minY, 0.2, "content near the TOP reads near 0, not near 1")
        XCTAssertEqual(frame.width, 300 / screen.width, accuracy: 0.001)
        XCTAssertEqual(frame.height, 200 / screen.height, accuracy: 0.001)
        window.orderOut(nil)
    }

    /// The same view moved DOWN the screen must report a LARGER y. This is the assertion a sign
    /// error cannot survive, and it doesn't depend on knowing the titlebar's height.
    func testMovingAWindowDownIncreasesY() throws {
        let (window, content, screen) = try placedWindow()
        let top = try XCTUnwrap(UIDriver().normalizedScreenFrame(of: content)).minY
        window.setFrameTopLeftPoint(NSPoint(x: screen.minX, y: screen.maxY - 400))
        let lower = try XCTUnwrap(UIDriver().normalizedScreenFrame(of: content)).minY
        XCTAssertGreaterThan(lower, top, "moving down the screen must move y toward 1")
        XCTAssertEqual(lower - top, 400 / screen.height, accuracy: 0.002)
        window.orderOut(nil)
    }

    /// A subview inside the content view has to come out inside the content view's rectangle —
    /// the nesting the viewer's "smallest element wins" rule depends on.
    func testASubviewIsContainedByItsParent() throws {
        let (window, content, _) = try placedWindow()
        let button = NSButton(title: "Save", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 20, width: 80, height: 24)
        content.addSubview(button)
        let driver = UIDriver()
        let parent = try XCTUnwrap(driver.normalizedScreenFrame(of: content))
        let child = try XCTUnwrap(driver.normalizedScreenFrame(of: button))
        XCTAssertTrue(parent.contains(child), "\(child) escaped \(parent)")
        XCTAssertLessThan(child.width * child.height, parent.width * parent.height)
        window.orderOut(nil)
    }

    /// Anything without a rectangle is left out rather than shipped at the origin, where it would
    /// silently win every hit test in the top-left corner.
    func testThingsWithNoRectangleAreLeftOut() {
        let driver = UIDriver()
        XCTAssertNil(driver.normalizedScreenFrame(of: NSView()), "a view in no window has no place")
        XCTAssertNil(driver.normalizedScreenFrame(of: NSMenuItem()), "a menu item is not pointable")
        XCTAssertNil(UIDriver.fraction(.zero, in: CGRect(x: 0, y: 0, width: 100, height: 100)),
                     "a degenerate rect is not pointable")
        XCTAssertNil(UIDriver.fraction(CGRect(x: 500, y: 500, width: 10, height: 10),
                                       in: CGRect(x: 0, y: 0, width: 100, height: 100)),
                     "a rect entirely off the display is not pointable")
    }

    /// The walk's own output: a window with a button in it produces the app's name and a list the
    /// viewer can decode, with the button in it.
    func testTheWalkProducesDecodableJSONNamingTheApp() throws {
        let (window, content, _) = try placedWindow()
        let button = NSButton(title: "Save", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 20, width: 80, height: 24)
        content.addSubview(button)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let json = UIDriver().pickTreeJSON()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNotNil(object["appName"] as? String)
        let elements = try XCTUnwrap(object["elements"] as? [[String: Any]])
        XCTAssertTrue(elements.contains { ($0["label"] as? String) == "Save" },
                      "the button the user would point at is missing from the tree")
        for element in elements {
            for key in ["x", "y", "w", "h"] {
                let v = try XCTUnwrap(element[key] as? Double, "\(key) missing")
                XCTAssertTrue(v.isFinite, "\(key) is not a number")
            }
        }
    }
}
#endif
