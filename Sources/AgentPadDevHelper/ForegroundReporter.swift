import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Whether this app is the one the user is LOOKING at, pushed to AgentPad as it changes.
///
/// Only the app can answer this. A simulator's process list names what is RUNNING — hundreds of
/// daemons, every installed app the system has warmed — and nothing public says which of them is
/// on screen. So the app that has the SDK says so itself, and AgentPad's comment bar follows it:
/// go Home in the simulator and the bar stops claiming to be about your app.
///
/// Read from a lock rather than from `UIApplication.shared.applicationState`, because the hello
/// frame is written on a socket queue and UIKit/AppKit must only be touched on the main thread.
final class ForegroundReporter {
    static let shared = ForegroundReporter()

    /// What to tell every connected AgentPad when this changes.
    var onChange: ((Bool) -> Void)?

    private let lock = NSLock()
    private var active = false
    private var observing = false

    /// The value to put in a hello — the current state, whatever queue is asking.
    var isForeground: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// Start watching. Safe to call more than once; the observers are installed once.
    func start() {
        lock.lock()
        guard !observing else { lock.unlock(); return }
        observing = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.observe() }
    }

    private func observe() {
        let center = NotificationCenter.default
#if canImport(UIKit)
        // `.active` covers the case this is installed INTO an app that is already frontmost —
        // no notification is coming for a state it is already in.
        set(UIApplication.shared.applicationState == .active)
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                           queue: .main) { [weak self] _ in self?.set(true) }
        // Resign, not "did enter background": going Home, the app switcher and a system alert over
        // the app all resign active, and in every one of them the user has stopped looking at it.
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                           queue: .main) { [weak self] _ in self?.set(false) }
#elseif canImport(AppKit)
        set(NSApp?.isActive == true)
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                           queue: .main) { [weak self] _ in self?.set(true) }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                           queue: .main) { [weak self] _ in self?.set(false) }
#endif
    }

    private func set(_ value: Bool) {
        lock.lock()
        guard value != active else { lock.unlock(); return }
        active = value
        lock.unlock()
        onChange?(value)
    }
}
