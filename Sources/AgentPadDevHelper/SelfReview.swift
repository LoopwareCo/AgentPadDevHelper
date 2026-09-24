import Foundation

/// Review UI Mode driven by the host app ITSELF, with no AgentPad on the other end of a socket.
///
/// The ordinary path is a round trip: AgentPad relays a `review_mode` tool call over the DevKit
/// ingress (`DevKitClient` → `DevToolHandler`), the bar goes up in the reviewed app, and each note
/// travels back over the same connection. That whole path is `#if DEBUG` (see
/// `AgentPadDevHelper.start()`) and needs a *second* process to be the reviewer — neither of which
/// fits the one app that is its own reviewer: **AgentPad reviewing AgentPad**. It already hosts the
/// Comment Inbox, so there is nothing to dial.
///
/// So this is the same `ReviewModeController` — same floating bar, same Choose UI overlay, same
/// element path and window screenshot — wired straight to a closure instead of a connection. It is
/// NOT DEBUG-only, because the build it exists for is a signed release build (AgentPad's dogfood
/// audience). It opens no socket and accepts no remote command, so it carries none of the risk
/// `start()`'s two safety layers exist to contain: the only thing that can turn it on is the host
/// app's own code.
///
/// Main thread only, like everything else that touches the view hierarchy.
public enum SelfReview {

    /// Is the bar up right now — for any reason, including a DevKit review this didn't start?
    public static var isActive: Bool { ReviewModeController.shared.isActive }

    /// True only while the review up right now is OURS. `isActive` alone can't answer that, and
    /// three things need to know: `stop()` (so a self-review's off-switch can't end someone
    /// else's review), the host's menu (so it doesn't offer to stop a review it can't stop), and
    /// `DevKitClient` (so an incoming `review_mode` is REFUSED rather than silently swallowed by
    /// `ReviewModeController`'s already-active guard).
    public private(set) static var owned = false

    /// `ReviewModeController` is a process-wide singleton with ONE pair of handler slots, and
    /// `DevKitClient.start()` fills them once at launch and never again. Overwriting them for the
    /// length of a self-review would therefore destroy the DevKit path permanently: the bar would
    /// still go up for a remote reviewer afterwards, but `onSubmit` would be nil and every note
    /// they wrote would vanish without a log. So put back exactly what was there.
    private static var displacedSubmit: ((FeedbackPayload) -> Void)?
    private static var displacedModeChanged: ((Bool) -> Void)?

    /// Turn Review UI Mode on in THIS process.
    ///
    /// - Parameters:
    ///   - onSubmit: called for each note the user sends, with the message, the element they
    ///     attached it to, and a PNG of the reviewed window. Not called once the mode is off.
    ///   - onModeChanged: the mode as it actually ended up. Worth watching: this can report
    ///     `false` straight back when the process has no window that can host the bar, and the
    ///     user's own **Done** button in the bar turns the mode off without going through here.
    /// - Returns: false if the review did not start — either one was already up (this one, or a
    ///   live DevKit review another AgentPad owns; taking that over would send its notes to the
    ///   wrong inbox, so whoever turned the mode on keeps it until it goes off), or this process
    ///   has no window that can host the bar.
    @discardableResult
    public static func start(onSubmit: @escaping (FeedbackPayload) -> Void,
                             onModeChanged: ((Bool) -> Void)? = nil) -> Bool {
        let controller = ReviewModeController.shared
        guard !controller.isActive else { return false }
        displacedSubmit = controller.onSubmit
        displacedModeChanged = controller.onModeChanged
        controller.onSubmit = onSubmit
        controller.onModeChanged = { mode in
            if !mode { restoreHandlers() }
            onModeChanged?(mode)
        }
        owned = true
        controller.setActive(true)
        // A windowless process can't host the bar: `setActive` reports false straight back, which
        // has already run `restoreHandlers()` above. Say so rather than claiming a live review.
        return owned
    }

    /// Turn OUR review off. A no-op when no review is up, or when the one up belongs to a DevKit
    /// reviewer.
    public static func stop() {
        guard owned else { return }
        ReviewModeController.shared.setActive(false)
    }

    /// Once the mode is off, drop our closures (so a stale `self` isn't held past the review) and
    /// put back whatever `DevKitClient` had wired, so the next DevKit review works.
    private static func restoreHandlers() {
        owned = false
        ReviewModeController.shared.onSubmit = displacedSubmit
        ReviewModeController.shared.onModeChanged = displacedModeChanged
        displacedSubmit = nil
        displacedModeChanged = nil
    }
}
