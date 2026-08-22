import XCTest
@testable import AgentPadDevHelper

/// The `.agentpadfeedback` share file, in particular the seam a HOST app ships its own kinds of
/// feedback through — `extraSections`, written verbatim beside the SDK's own items so one package
/// can carry everything an app collected, and read back by whoever put them there.
final class FeedbackArchiveTests: XCTestCase {

    private func item(_ id: String, message: String) -> OutboxItem {
        OutboxItem(id: id, capturedAt: Date(timeIntervalSince1970: 1_000_000),
                   payload: FeedbackPayload(message: message))
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
    }

    func testExtraSectionsRideAtTheTopLevel() throws {
        let url = try FeedbackArchive.write(
            items: [item("a", message: "make it blue")],
            extraSections: ["hostFeedback": [["id": "case-1", "kind": "policy"]]])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let object = try read(url)
        XCTAssertEqual((object["items"] as? [[String: Any]])?.count, 1)
        let cases = try XCTUnwrap(object["hostFeedback"] as? [[String: Any]])
        XCTAssertEqual(cases.first?["id"] as? String, "case-1")
        // The document still says what it is, so an older reader can still read the UI half.
        XCTAssertEqual(object["formatVersion"] as? Int, FeedbackArchive.currentFormatVersion)
        XCTAssertNotNil(object["app"])
    }

    /// A host section can't overwrite the SDK's own keys — an app that names one `items` must not
    /// be able to replace the UI feedback in its own package.
    func testExtraSectionsCannotClobberTheArchivesOwnKeys() throws {
        let url = try FeedbackArchive.write(items: [item("a", message: "make it blue")],
                                            extraSections: ["items": [], "formatVersion": 99])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let object = try read(url)
        XCTAssertEqual((object["items"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(object["formatVersion"] as? Int, FeedbackArchive.currentFormatVersion)
    }

    /// With both halves inside, "UI Feedback" undersells the file — the caller names it.
    func testFileLabelNamesTheSharedFile() throws {
        let plain = try FeedbackArchive.write(items: [item("a", message: "hi")])
        defer { try? FileManager.default.removeItem(at: plain.deletingLastPathComponent()) }
        XCTAssertTrue(plain.lastPathComponent.hasSuffix("UI Feedback.agentpadfeedback"),
                      plain.lastPathComponent)

        let labelled = try FeedbackArchive.write(items: [item("a", message: "hi")],
                                                 fileLabel: "Feedback")
        defer { try? FileManager.default.removeItem(at: labelled.deletingLastPathComponent()) }
        XCTAssertTrue(labelled.lastPathComponent.hasSuffix(" Feedback.agentpadfeedback"),
                      labelled.lastPathComponent)
        XCTAssertFalse(labelled.lastPathComponent.contains("UI Feedback"))
    }

    /// A host sending only ITS kind writes no UI items at all; the package still has to be a
    /// valid document, because the reader accepts either half alone.
    func testArchiveWithNoUIItemsStillCarriesTheHostSection() throws {
        let url = try FeedbackArchive.write(items: [],
                                            extraSections: ["hostFeedback": [["id": "case-1"]]],
                                            fileLabel: "Feedback")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let object = try read(url)
        XCTAssertEqual((object["items"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((object["hostFeedback"] as? [[String: Any]])?.count, 1)
    }
}
