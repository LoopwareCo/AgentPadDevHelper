import XCTest
@testable import AgentPadDevHelper

/// The on-device feedback outbox: durable-on-record, delete-on-ack, capped. All against a
/// scratch directory — the shared instance (which resolves inside the host app's container)
/// is never touched.
final class FeedbackOutboxTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-outbox-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    func testRecordPersistsAcrossInstances() {
        let first = FeedbackOutbox(directoryURL: dir)
        let element = FeedbackElementDescriptor(path: [FeedbackElementNode(role: "button", className: "NSButton",
                                                                           label: "Save")])
        let recorded = first.record(FeedbackPayload(message: "make it blue", element: element))

        let second = FeedbackOutbox(directoryURL: dir)
        let loaded = second.all()
        XCTAssertEqual(loaded.map(\.id), [recorded.id])
        XCTAssertEqual(loaded[0].payload.message, "make it blue")
        XCTAssertEqual(loaded[0].payload.element?.path.first?.label, "Save")
        // capturedAt round-trips through ISO-8601 (sub-second precision is deliberately shed).
        XCTAssertEqual(loaded[0].capturedAt.timeIntervalSince1970,
                       recorded.capturedAt.timeIntervalSince1970, accuracy: 1)
    }

    func testAllIsOldestFirstAndDeleteFlushes() {
        let outbox = FeedbackOutbox(directoryURL: dir)
        // Distinct capturedAt values without sleeping: write files directly is overkill —
        // record() stamps "now", so nudge via ordering-tolerant assertion instead.
        let a = outbox.record(FeedbackPayload(message: "first"))
        let b = outbox.record(FeedbackPayload(message: "second"))
        XCTAssertEqual(Set(outbox.all().map(\.id)), [a.id, b.id])

        outbox.delete(ids: [a.id])
        XCTAssertEqual(outbox.all().map(\.id), [b.id])
        XCTAssertEqual(FeedbackOutbox(directoryURL: dir).all().map(\.id), [b.id])
    }

    func testDeleteUnknownIdIsANoOpAndDoesNotNotify() {
        let outbox = FeedbackOutbox(directoryURL: dir)
        _ = outbox.record(FeedbackPayload(message: "keep"))
        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: FeedbackOutbox.didChangeNotification, object: outbox, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        outbox.delete(ids: ["nope"])
        XCTAssertEqual(outbox.count(), 1)
        XCTAssertEqual(changes, 0)
    }

    func testOverflowEvictsOldestFirst() throws {
        // Seed maxItems files with an OLD capturedAt straight to disk (record() stamps "now",
        // and 200 real records with distinct timestamps would need sleeps), then record one
        // more live: the count must hold at the cap and the evicted one must be the oldest.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder.outbox
        for i in 0..<FeedbackOutbox.maxItems {
            let item = OutboxItem(id: "seed-\(i)",
                                  capturedAt: Date(timeIntervalSince1970: TimeInterval(1000 + i)),
                                  payload: FeedbackPayload(message: "seed \(i)"))
            try encoder.encode(item).write(to: dir.appendingPathComponent("seed-\(i).json"))
        }
        let outbox = FeedbackOutbox(directoryURL: dir)
        let live = outbox.record(FeedbackPayload(message: "newest"))

        let ids = Set(outbox.all().map(\.id))
        XCTAssertEqual(ids.count, FeedbackOutbox.maxItems)
        XCTAssertTrue(ids.contains(live.id))
        XCTAssertFalse(ids.contains("seed-0"), "the oldest item should have been evicted")
        // And the eviction removed the file, not just the memory entry.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("seed-0.json").path))
    }

    /// Screenshots are held in a sidecar `<id>.png`, NOT in the cached item records — the
    /// records stay small enough to keep in memory inside someone else's app, and the bytes
    /// are re-attached only for the frame (or archive) that carries them.
    func testScreenshotLivesInASidecarAndIsReattachedOnDemand() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
        let outbox = FeedbackOutbox(directoryURL: dir)
        let item = outbox.record(FeedbackPayload(message: "too cramped",
                                                 screenshotPNG: png.base64EncodedString()))

        // Nothing cached (or re-loaded) carries the base64 blob…
        XCTAssertNil(item.payload.screenshotPNG)
        XCTAssertNil(outbox.all().first?.payload.screenshotPNG)
        let reloaded = FeedbackOutbox(directoryURL: dir)
        let lean = try XCTUnwrap(reloaded.all().first)
        XCTAssertNil(lean.payload.screenshotPNG)
        XCTAssertEqual(lean.payload.message, "too cramped")

        // …but the bytes are on disk RAW (no base64 tax) and come back on request.
        let sidecar = dir.appendingPathComponent("\(item.id).png")
        XCTAssertEqual(try Data(contentsOf: sidecar), png)
        XCTAssertEqual(reloaded.fullItem(lean).payload.screenshotPNG, png.base64EncodedString())

        // Deleting an item takes its screenshot with it.
        reloaded.delete(ids: [item.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(item.id).json").path))
    }

    func testCorruptFileCostsOnlyThatItem() throws {
        let outbox = FeedbackOutbox(directoryURL: dir)
        _ = outbox.record(FeedbackPayload(message: "survives"))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("garbage.json"))
        XCTAssertEqual(FeedbackOutbox(directoryURL: dir).all().map(\.payload.message), ["survives"])
    }

    /// The `.agentpadfeedback` share file's field names are a wire contract with AgentPad's
    /// import sheet (which decodes with its own lenient structs, like every cross-build shape) —
    /// pin them here on the writing side.
    func testArchiveFieldNamesAreTheImportContract() throws {
        let url = try FeedbackArchive.write(items: [
            OutboxItem(id: "item-1", capturedAt: Date(timeIntervalSince1970: 1_000_000),
                       payload: FeedbackPayload(message: "too cramped",
                                                element: FeedbackElementDescriptor(path: [
                                                    FeedbackElementNode(role: "button", className: "NSButton"),
                                                ]))),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.pathExtension, FeedbackArchive.fileExtension)

        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(obj["formatVersion"] as? Int, 1)
        let app = try XCTUnwrap(obj["app"] as? [String: Any])
        XCTAssertNotNil(app["name"] as? String)
        XCTAssertNotNil(app["platform"] as? String)
        let items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["id"] as? String, "item-1")
        XCTAssertNotNil(items.first?["capturedAt"] as? String, "ISO-8601 string on disk")
        let payload = try XCTUnwrap(items.first?["payload"] as? [String: Any])
        XCTAssertEqual(payload["message"] as? String, "too cramped")
        XCTAssertNotNil(payload["element"])
    }
}
