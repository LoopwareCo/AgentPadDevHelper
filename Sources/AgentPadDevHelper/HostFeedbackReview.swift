import Foundation

/// **The host's way into the feedback the SDK is holding.**
///
/// The SDK ships its own review window (`PendingFeedbackListViewController`) and that is the
/// whole story for an app whose only feedback is the UI reviews captured here. An app that
/// collects OTHER kinds — of its own, from its own stores, which this package has no business
/// knowing about — can instead draw its own window over everything and take the entry point with
/// `setFeedbackReviewHandler`.
///
/// The boundary is deliberate and one-way: this file is read/act-on-the-outbox plus one hook,
/// plus `extraSections` on the share file, which the SDK writes verbatim and never interprets.
/// No host type, store or vocabulary crosses into the package.
public extension AgentPadDevHelper {

    /// One piece of feedback still sitting in this device's outbox.
    struct PendingFeedback {
        public let id: String
        public let capturedAt: Date
        /// What the user typed.
        public let message: String
        /// Ready to hand to `FeedbackCardView` — the SAME adapter the SDK's own list uses, so a
        /// host-drawn card and an SDK-drawn one can't drift.
        public let card: FeedbackCardModel

        /// Public so a host can build one for a preview / offscreen render without capturing
        /// real feedback first.
        public init(id: String, capturedAt: Date, message: String, card: FeedbackCardModel) {
            self.id = id; self.capturedAt = capturedAt; self.message = message; self.card = card
        }
    }

    /// Posted whenever the outbox changes shape (captured, synced away, deleted). Observe with
    /// `object: nil` — the poster is the SDK's own store.
    static var pendingFeedbackDidChange: Notification.Name { FeedbackOutbox.didChangeNotification }

    /// Every pending item, oldest first (list UIs reverse it). Screenshots are NOT attached —
    /// they stay in their sidecar files until something exports or uploads the item.
    static func pendingFeedback() -> [PendingFeedback] {
        FeedbackOutbox.shared.all().map {
            PendingFeedback(id: $0.id, capturedAt: $0.capturedAt,
                            message: $0.payload.message, card: $0.cardModel())
        }
    }

    static func pendingFeedbackCount() -> Int { FeedbackOutbox.shared.count() }

    static func deletePendingFeedback(ids: [String]) {
        FeedbackOutbox.shared.delete(ids: ids)
    }

    /// The one-line "where these go from here" the SDK's own list shows in its footer — worded
    /// for the transport this app actually has (local-only / app key / dial-out).
    static func pendingFeedbackStatusLine() -> String {
        FeedbackEntryPoints.shared.pendingStatusLine(count: FeedbackOutbox.shared.count())
    }

    /// Write a `.agentpadfeedback` share file and return its URL (hand it to a share panel).
    ///
    /// - Parameters:
    ///   - ids: which pending items to include; nil means all of them. Screenshots are
    ///     re-attached inline as it writes, so the file stands on its own.
    ///   - extraSections: top-level JSON the host adds to the same package — its own kinds of
    ///     feedback, which the receiving AgentPad reads alongside ours. Must be
    ///     JSON-serializable; a key that collides with the SDK's own is ignored.
    ///   - fileLabel: what to call the file, when "UI Feedback" undersells what's inside.
    static func writeFeedbackArchive(ids: [String]? = nil, extraSections: [String: Any] = [:],
                                     fileLabel: String = "UI Feedback") throws -> URL {
        let all = FeedbackOutbox.shared.all()
        let chosen = ids.map { wanted in all.filter { wanted.contains($0.id) } } ?? all
        return try FeedbackArchive.write(items: chosen, extraSections: extraSections,
                                         fileLabel: fileLabel)
    }

    #if DEBUG
    /// Record a piece of feedback as if the user had captured it in Review UI Mode — for demos
    /// and for reviewing a host's own feedback UI without tapping through a capture first.
    /// DEBUG-only; there is no way to forge feedback in a shipped build.
    @discardableResult
    static func debugRecordFeedback(message: String, elementLabel: String? = nil,
                                    role: String = "button",
                                    className: String = "NSButton") -> String {
        let element = elementLabel.map {
            FeedbackElementDescriptor(path: [FeedbackElementNode(role: role, className: className,
                                                                label: $0)])
        }
        return FeedbackOutbox.shared.record(FeedbackPayload(message: message, element: element)).id
    }
    #endif

    /// A host taking the "View & Send…" entry point over with a window of its own.
    struct FeedbackReviewHandler {
        /// The Help-menu title, given the total count (pending items + `extraCount`).
        public var title: (Int) -> String
        /// Feedback the HOST holds, beyond this device's outbox — counted into the menu title.
        public var extraCount: () -> Int
        /// Raise the host's window.
        public var open: () -> Void

        public init(title: @escaping (Int) -> String,
                    extraCount: @escaping () -> Int = { 0 },
                    open: @escaping () -> Void) {
            self.title = title; self.extraCount = extraCount; self.open = open
        }
    }

    /// Route the Help-menu item (macOS) / the chooser's "view" action (iOS) to `handler` instead
    /// of the SDK's own list. Pass nil to hand it back.
    static func setFeedbackReviewHandler(_ handler: FeedbackReviewHandler?) {
        FeedbackEntryPoints.shared.hostReview = handler
    }
}
