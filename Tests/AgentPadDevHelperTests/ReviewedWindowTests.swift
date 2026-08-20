import XCTest
@testable import AgentPadDevHelper

#if os(macOS)
import AppKit

/// Which window Review Mode screenshots and describes. The compose bar takes key focus the
/// moment the mode turns on, so by submit time NONE of the app's own windows is key — the
/// original code then fell back to `NSApp.windows.first`, i.e. the window the app created
/// FIRST, and every feedback item from a multi-window app shipped a shot of its welcome
/// window instead of the one the user was working in.
final class ReviewedWindowTests: XCTestCase {

    private func window(_ title: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                         styleMask: [.titled], backing: .buffered, defer: true)
        w.title = title
        return w
    }

    /// Creation order (what `NSApp.windows` gives) must not decide the answer.
    func testFrontmostWindowWinsOverTheOldestOne() {
        let welcome = window("Welcome"), bench = window("Bench")
        let chosen = ElementPath.chooseReviewedWindow(from: [welcome, bench], lastKey: nil,
                                                      main: nil, ordered: [bench, welcome])
        XCTAssertEqual(chosen?.title, "Bench")
    }

    /// The window the user was last typing in beats both main and z-order — with the bar up,
    /// that's the most faithful record of "the window I'm giving feedback about".
    func testTheLastAppWindowToHoldKeyWins() {
        let welcome = window("Welcome"), bench = window("Bench")
        let chosen = ElementPath.chooseReviewedWindow(from: [welcome, bench], lastKey: bench,
                                                      main: welcome, ordered: [welcome, bench])
        XCTAssertEqual(chosen?.title, "Bench")
    }

    /// A remembered window that has since closed (so it's no longer a target) must not win.
    func testAStaleRememberedWindowIsIgnored() {
        let welcome = window("Welcome"), bench = window("Bench"), closed = window("Closed")
        let chosen = ElementPath.chooseReviewedWindow(from: [welcome, bench], lastKey: closed,
                                                      main: nil, ordered: [bench, welcome])
        XCTAssertEqual(chosen?.title, "Bench")
    }

    func testMainWindowIsPreferredOverZOrder() {
        let welcome = window("Welcome"), bench = window("Bench")
        let chosen = ElementPath.chooseReviewedWindow(from: [welcome, bench], lastKey: nil,
                                                      main: bench, ordered: [welcome, bench])
        XCTAssertEqual(chosen?.title, "Bench")
    }

    func testNoCandidatesYieldsNil() {
        XCTAssertNil(ElementPath.chooseReviewedWindow(from: [], lastKey: window("Welcome"),
                                                      main: nil, ordered: []))
    }
}
#endif
