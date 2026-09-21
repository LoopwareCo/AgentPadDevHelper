#if !canImport(UIKit) && canImport(AppKit)
import XCTest
import AppKit
@testable import AgentPadDevHelper

/// The app's own report of whether the user is LOOKING at it.
///
/// AgentPad's comment bar over a device feed names whatever this says is in front, and nothing
/// else can answer the question — a simulator's process list says what is running, never what is
/// on screen. So the two things that matter are that a change is actually announced, and that it
/// is announced ONCE: the server re-derives every watching viewer's state from it.
final class ForegroundReporterTests: XCTestCase {

    /// A fresh reporter, not the shared one — tests must not fight over a process-wide singleton.
    private func reporter() -> ForegroundReporter {
        let r = ForegroundReporter()
        r.start()
        // `start()` installs its observers on the main queue; let that land before posting.
        let settled = expectation(description: "observers installed")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        return r
    }

    func testActivationIsReportedOnceAndRepeatsAreNot() {
        let r = reporter()
        var changes: [Bool] = []
        r.onChange = { changes.append($0) }

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(changes, [true])
        XCTAssertTrue(r.isForeground)

        // A second activation is not news. Announcing it would re-derive every viewer's comment
        // bar for a state it is already showing.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(changes, [true])

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(changes, [true, false])
        XCTAssertFalse(r.isForeground, "going away has to be readable from the hello too")
    }

    /// `isForeground` is read on a socket queue while it is written from main, so it may not be a
    /// plain stored property read across threads.
    func testStateIsReadableOffTheMainThread() {
        let r = reporter()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let read = expectation(description: "read off-main")
        DispatchQueue.global().async {
            XCTAssertTrue(r.isForeground)
            read.fulfill()
        }
        wait(for: [read], timeout: 2)
    }
}
#endif
