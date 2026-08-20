import Foundation

/// One captured piece of Review-UI feedback, as it lives in the on-device outbox and rides the
/// `feedback` ingress frame's envelope. The APP mints the id and stamps the capture time — so a
/// re-send after a lost connection is idempotent on the server (same id → same stored item, just
/// re-acked), and the item is dated by when the user wrote it, not when it finally reached a
/// server.
struct OutboxItem: Codable {
    var id: String
    var capturedAt: Date
    var payload: FeedbackPayload
}

/// The one ISO-8601 formatter every transport stamps `capturedAt` with (thread-safe per Apple).
enum WireDate {
    static let iso8601 = ISO8601DateFormatter()
}

/// The on-device store for captured feedback: every submit is written here FIRST, then uploaded,
/// and a file is deleted only when a server acknowledges receipt (`feedbackAck`) or the user
/// deletes it — so feedback survives "AgentPad isn't running", a dropped connection, and the app
/// itself crashing mid-send.
///
/// One JSON file per item (the `UIFeedbackStore` layout, for the same reasons: a corrupt file
/// costs one item) under the host app's own container:
/// `Application Support/AgentPadDevHelper/Outbox/<bundle id>/` — resolved per-app because a
/// NON-sandboxed Mac app's Application Support is the shared `~/Library` one, and two apps
/// embedding this SDK must not drain each other's feedback.
///
/// **Screenshots live in a sidecar `<id>.png`, not in the JSON.** This runs inside someone
/// else's app, and a window PNG is up to 4 MB (5.3 MB once base64'd): keeping them in the item
/// records would hold ~1 GB resident at the 200-item cap, for state that is only needed at the
/// moment of upload. The JSON stays small enough to cache every item cheaply; the bytes are
/// read (and base64'd) on demand by `fullItem(_:)`, and stored raw, which also saves the 33%
/// base64 overhead on disk.
final class FeedbackOutbox {
    static let shared = FeedbackOutbox()

    /// Unsynced feedback is precious but not unbounded: past this many items the OLDEST are
    /// evicted on the next add — a device that can never reach its server must not grow a
    /// screenshot graveyard (items can carry a ~4 MB PNG each).
    static let maxItems = 200

    /// Posted (object = the outbox) whenever it changes shape (add / delete / eviction), off-lock
    /// on no particular queue — UI listeners hop to main. Drives the pending counts in the entry
    /// points, the list, and the Help-menu item titles.
    static let didChangeNotification = Notification.Name("AgentPadDevHelper.FeedbackOutbox.didChange")

    private let lock = NSLock()
    private let directoryURL: URL
    private var items: [String: OutboxItem] = [:]
    private var loaded = false

    /// The default root resolves inside the HOST app's container; tests construct their own
    /// with a scratch directory.
    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let app = AppIdentity.bundleID.isEmpty ? ProcessInfo.processInfo.processName : AppIdentity.bundleID
            self.directoryURL = support
                .appendingPathComponent("AgentPadDevHelper", isDirectory: true)
                .appendingPathComponent("Outbox", isDirectory: true)
                .appendingPathComponent(app, isDirectory: true)
        }
    }

    // MARK: - reads

    /// Every pending item, oldest first — the upload/drain order, so a long-parked backlog
    /// arrives in the order it was written. List UIs reverse it.
    ///
    /// Items come back WITHOUT their screenshot (see the type note): enough to render a card
    /// or order a drain. Ask `fullItem(_:)` for the version that goes on the wire.
    func all() -> [OutboxItem] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return items.values.sorted { $0.capturedAt < $1.capturedAt }
    }

    /// `item` with its sidecar screenshot re-attached (base64), for upload or export. Reads one
    /// file; returns the item unchanged when it has no sidecar (or already carries a shot).
    func fullItem(_ item: OutboxItem) -> OutboxItem {
        guard item.payload.screenshotPNG == nil,
              let data = try? Data(contentsOf: screenshotURL(id: item.id)) else { return item }
        var full = item
        full.payload.screenshotPNG = data.base64EncodedString()
        return full
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return items.count
    }

    // MARK: - mutations (each flushes immediately)

    /// Mint + persist a new item for a just-submitted payload. This is the ONE entry point for
    /// captured feedback, called before any upload is attempted.
    func record(_ payload: FeedbackPayload) -> OutboxItem {
        // The screenshot goes to its own file; the record kept in memory (and in the JSON)
        // holds everything else.
        var lean = payload
        let screenshot = payload.screenshotPNG.flatMap { Data(base64Encoded: $0) }
        lean.screenshotPNG = nil
        let item = OutboxItem(id: UUID().uuidString, capturedAt: Date(), payload: lean)
        lock.lock()
        loadIfNeeded()
        items[item.id] = item
        write(item)
        if let screenshot { try? screenshot.write(to: screenshotURL(id: item.id), options: .atomic) }
        evictOverflowLocked()
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return item
    }

    func delete(ids: [String]) {
        lock.lock()
        loadIfNeeded()
        var removed = false
        for id in ids {
            guard items.removeValue(forKey: id) != nil else { continue }
            try? FileManager.default.removeItem(at: fileURL(id: id))
            try? FileManager.default.removeItem(at: screenshotURL(id: id))
            removed = true
        }
        lock.unlock()
        if removed { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
    }

    // MARK: - disk (call with `lock` held)

    private func evictOverflowLocked() {
        guard items.count > Self.maxItems else { return }
        let oldestFirst = items.values.sorted { $0.capturedAt < $1.capturedAt }
        for item in oldestFirst.prefix(items.count - Self.maxItems) {
            items.removeValue(forKey: item.id)
            try? FileManager.default.removeItem(at: fileURL(id: item.id))
            try? FileManager.default.removeItem(at: screenshotURL(id: item.id))
        }
    }

    private func fileURL(id: String) -> URL { itemURL(id: id, extension: "json") }
    private func screenshotURL(id: String) -> URL { itemURL(id: id, extension: "png") }

    private func itemURL(id: String, extension ext: String) -> URL {
        // Ids are our own UUIDs, but a filename must never traverse — same guard as the
        // server-side store, since the directory is shared with whatever a future build writes.
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return directoryURL.appendingPathComponent(String(safe) + "." + ext)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let files = (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil))
            ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let item = try? JSONDecoder.outbox.decode(OutboxItem.self, from: data) else { continue }
            items[item.id] = item
        }
    }

    private func write(_ item: OutboxItem) {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.outbox.encode(item) else { return }
        try? data.write(to: fileURL(id: item.id), options: .atomic)
    }
}

extension JSONDecoder {
    /// ISO-8601 dates — the on-disk AND on-wire date shape (`capturedAt` travels as a string in
    /// the `feedback` envelope), stable across app/SDK versions sharing the directory.
    static let outbox: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let outbox: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
