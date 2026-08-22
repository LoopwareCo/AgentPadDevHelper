import Foundation

/// The share-file format: one `.agentpadfeedback` JSON document carrying MANY feedback items
/// plus the identity of the app they came from — what a beta tester's share panel sends to the
/// developer, and what AgentPad's double-click import reads. Dates are ISO-8601 (the outbox's
/// own shape); items keep their app-minted ids so importing the same file twice can't duplicate.
enum FeedbackArchive {
    static let fileExtension = "agentpadfeedback"
    static let currentFormatVersion = 1

    struct AppInfo: Codable {
        var name: String
        var bundleID: String?
        var platform: String
        var version: String?
    }

    struct Archive: Codable {
        var formatVersion: Int
        var app: AppInfo
        var items: [OutboxItem]
    }

    /// Write `items` to a fresh temp file, named for the app so the received file explains
    /// itself ("HelloWorld UI Feedback.agentpadfeedback"). The caller hands the URL to the
    /// share panel; the temp directory is per-share, so successive shares never collide.
    ///
    /// `extraSections` are merged in at the TOP LEVEL of the document, which is how a host app
    /// ships feedback this SDK knows nothing about in the same package: keys and values are
    /// written verbatim and never read back here — whoever put them in is whoever takes them out.
    /// Values must be JSON-serializable; a key that collides with one of ours is ignored rather
    /// than allowed to overwrite it. `fileLabel` names the file when "UI Feedback" would
    /// undersell what's inside.
    static func write(items: [OutboxItem], extraSections: [String: Any] = [:],
                      fileLabel: String = "UI Feedback") throws -> URL {
        let archive = Archive(
            formatVersion: currentFormatVersion,
            app: AppInfo(name: AppIdentity.displayName,
                         bundleID: AppIdentity.bundleID.isEmpty ? nil : AppIdentity.bundleID,
                         platform: AppIdentity.platform,
                         version: AppIdentity.version.isEmpty ? nil : AppIdentity.version),
            // Screenshots live in sidecar files; the shared file the developer opens has to
            // carry them inline, so re-attach as we write.
            items: items.map(FeedbackOutbox.shared.fullItem))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentPadDevHelper-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Keep the filename filesystem-safe without mangling normal app names.
        let safeName = AppIdentity.displayName.map { "/:\\".contains($0) ? "-" : $0 }
        let url = dir.appendingPathComponent("\(String(safeName)) \(fileLabel).\(fileExtension)")
        var data = try JSONEncoder.outbox.encode(archive)
        if !extraSections.isEmpty,
           var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in extraSections where object[key] == nil { object[key] = value }
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    static func read(from url: URL) throws -> Archive {
        try JSONDecoder.outbox.decode(Archive.self, from: Data(contentsOf: url))
    }
}
