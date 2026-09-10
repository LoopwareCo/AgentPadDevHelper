import Foundation

/// One live review owner. All calls run on the main thread, beside the review UI.
/// Disconnecting clears the owner before hiding the UI; nothing is saved or replayed.
final class LiveReviewSession<Owner: AnyObject> {
    private weak var owner: Owner?
    private var send: ((FeedbackPayload) -> Void)?
    private var report: ((Bool) -> Void)?
    private var activate: ((Bool) -> Void)?

    @discardableResult
    func setActive(_ enabled: Bool, owner candidate: Owner,
                   send: @escaping (FeedbackPayload) -> Void,
                   report: @escaping (Bool) -> Void,
                   activate: @escaping (Bool) -> Void) -> Bool {
        guard owner == nil || owner === candidate else { return false }
        if enabled {
            if owner != nil { self.activate?(false) }
            owner = candidate
            self.send = send; self.report = report; self.activate = activate
            activate(true)
        } else {
            activate(false)
            clear()
        }
        return true
    }

    func submit(_ payload: FeedbackPayload) {
        guard owner != nil else { return }
        send?(payload)
    }

    func modeChanged(_ active: Bool) {
        guard owner != nil else { return }
        report?(active)
        if !active { clear() }
    }

    func disconnect(_ candidate: Owner) {
        guard owner === candidate else { return }
        let stop = activate
        clear()
        stop?(false)
    }

    private func clear() {
        owner = nil; send = nil; report = nil; activate = nil
    }
}
