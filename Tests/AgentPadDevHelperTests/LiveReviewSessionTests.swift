import XCTest
@testable import AgentPadDevHelper

final class LiveReviewSessionTests: XCTestCase {
    private final class Owner {}

    func testOnlyInitiatingConnectionReceivesNotesAndCanStopReview() {
        let review = LiveReviewSession<Owner>()
        let first = Owner(), second = Owner()
        var notes: [String] = [], modes: [Bool] = []
        XCTAssertTrue(review.setActive(true, owner: first, send: { notes.append($0.message) },
                                       report: { _ in }, activate: { modes.append($0) }))
        XCTAssertFalse(review.setActive(true, owner: second, send: { _ in XCTFail() },
                                        report: { _ in XCTFail() }, activate: { _ in XCTFail() }))
        XCTAssertFalse(review.setActive(false, owner: second, send: { _ in },
                                        report: { _ in }, activate: { _ in XCTFail() }))
        review.submit(FeedbackPayload(message: "Make it blue"))
        review.disconnect(second)
        XCTAssertEqual(notes, ["Make it blue"])
        XCTAssertEqual(modes, [true])
        review.disconnect(first)
        review.submit(FeedbackPayload(message: "Offline"))
        XCTAssertEqual(notes, ["Make it blue"])
        XCTAssertEqual(modes, [true, false])
    }

    func testDoneReleasesOwnershipAndReconnectDoesNotReplayNotes() {
        let review = LiveReviewSession<Owner>()
        let first = Owner(), second = Owner()
        var reported: [Bool] = [], received: [String] = []
        review.setActive(true, owner: first, send: { _ in }, report: { reported.append($0) }, activate: { _ in })
        review.modeChanged(false)
        review.submit(FeedbackPayload(message: "Ended"))
        XCTAssertEqual(reported, [false])
        XCTAssertTrue(review.setActive(true, owner: second, send: { received.append($0.message) },
                                       report: { _ in }, activate: { _ in }))
        XCTAssertTrue(received.isEmpty)
        review.submit(FeedbackPayload(message: "New review"))
        XCTAssertEqual(received, ["New review"])
    }
}
