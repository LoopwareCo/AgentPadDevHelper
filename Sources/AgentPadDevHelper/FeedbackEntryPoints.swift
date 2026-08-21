import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// How captured feedback leaves the device — decides the entry points' wording and (from
/// AgentPadDevHelper's public API) whether anything dials out at all.
enum FeedbackCaptureMode {
    /// `start()`'s DEBUG dial-out is running: feedback syncs to every reachable AgentPad.
    case debugDialOut
    /// `enableUIFeedback(.localOnly)`: nothing dials out; the user shares the file themselves.
    case localOnly
    /// `enableUIFeedback(.appKey(_))`: feedback syncs over the LAN to the one server holding
    /// the key.
    case appKey
}

/// The developer-facing ways INTO the feedback feature, installed once per process:
///   - Mac: an "AgentPad" grouping at the end of the host app's Help menu — "Leave UI Review
///     Feedback…" and "View & Send (N) UI Feedbacks…" (the pending list window).
///   - iOS: SHAKE the device → a chooser alert (leave feedback / view pending / cancel). One
///     gesture for both actions; the alert is the menu.
///
/// Everything here is additive to the host app and self-contained: the menu items validate
/// through their own target (never the host's menu delegate), the iOS gesture is read off the
/// accelerometer and so never touches the host's own touch handling, and a host app with no
/// Help menu simply gets no Mac menu entry (documented in the README).
final class FeedbackEntryPoints: NSObject {
    static let shared = FeedbackEntryPoints()
    private override init() { super.init() }

    private(set) var mode: FeedbackCaptureMode = .localOnly
    private var installed = false

    /// Idempotent; a later call can only UPGRADE the mode: `start()`'s dial-out beats
    /// everything (that transport reaches every AgentPad), a key beats `.localOnly`.
    func install(mode: FeedbackCaptureMode) {
        if installed {
            if mode == .debugDialOut || (mode == .appKey && self.mode == .localOnly) { self.mode = mode }
            return
        }
        installed = true
        self.mode = mode
        DispatchQueue.main.async { [self] in
            #if canImport(UIKit)
            installGestures()
            #else
            installMenu()
            #endif
        }
    }

    /// The pending list's one-line footer: where these items go from here.
    func pendingStatusLine(count: Int) -> String {
        switch mode {
        case .debugDialOut:
            return "Syncs to AgentPad automatically whenever it can be reached."
        case .localOnly:
            return "Stored on this device until you send it to the developer."
        case .appKey:
            return "Waiting to sync to your AgentPad over the local network."
        }
    }

    // MARK: - macOS: the Help-menu grouping + the list window

    #if !canImport(UIKit) && canImport(AppKit)

    private var leaveItem: NSMenuItem?
    private var viewItem: NSMenuItem?
    private var listWindow: NSWindow?
    private var launchObserver: NSObjectProtocol?

    private func installMenu() {
        // The host app owns its menu; wait for it to finish building one. (Calling the API
        // from applicationDidFinishLaunching lands in the `else` branch immediately.)
        if NSApp == nil || NSApp.mainMenu == nil {
            launchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification, object: nil,
                queue: .main) { [weak self] _ in
                if let observer = self?.launchObserver { NotificationCenter.default.removeObserver(observer) }
                self?.appendMenuItems()
            }
        } else {
            appendMenuItems()
        }
    }

    private func appendMenuItems() {
        guard leaveItem == nil, let help = helpMenu() else { return }

        // Its own "AgentPad" grouping at the END of Help: a separator, a small-caps section
        // label (a disabled item — works on every macOS this package supports), then the items.
        help.addItem(.separator())
        let header = NSMenuItem(title: "AgentPad", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: "AGENTPAD",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor])
        help.addItem(header)

        let leave = NSMenuItem(title: "Leave UI Review Feedback…",
                               action: #selector(leaveFeedbackTapped), keyEquivalent: "")
        leave.target = self
        help.addItem(leave)
        leaveItem = leave

        let view = NSMenuItem(title: "View & Send UI Feedbacks…",
                              action: #selector(viewPendingTapped), keyEquivalent: "")
        view.target = self
        help.addItem(view)
        viewItem = view
    }

    /// `NSApp.helpMenu` when the host set it (Xcode's app templates do); otherwise the last
    /// top-level submenu named "Help" — the convention every English AppKit app follows. A menu
    /// found neither way means no Mac entry point, by design.
    private func helpMenu() -> NSMenu? {
        if let help = NSApp.helpMenu { return help }
        return NSApp.mainMenu?.items.last(where: { $0.submenu?.title == "Help" })?.submenu
    }

    @objc private func leaveFeedbackTapped() {
        ReviewModeController.shared.setActive(true)
    }

    @objc private func viewPendingTapped() {
        if let listWindow {
            listWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: PendingFeedbackListViewController())
        window.title = "UI Feedback — \(AppIdentity.displayName)"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(listWindowClosed(_:)),
                                               name: NSWindow.willCloseNotification, object: window)
        listWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func listWindowClosed(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === listWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        listWindow = nil
    }

    #endif

    // MARK: - iOS: shake the device → chooser alert

    #if canImport(UIKit)

    private var alertWindow: UIWindow?
    private var listWindow: UIWindow?
    /// One of this type's own windows (the chooser, the pending list)? `ElementPath` excludes
    /// these from walks/hit-tests the same way it excludes review chrome.
    static func isFeedbackWindow(_ window: UIWindow) -> Bool {
        let s = shared
        return window === s.alertWindow || window === s.listWindow
    }

    /// SHAKE, not the status bar. Two shipped attempts at the status-bar band both did nothing
    /// on a real iPhone — first a recognizer on the app's key window, then a transparent window
    /// of our own ABOVE `.statusBar`. Neither is reachable: that band is arbitrated by the
    /// system (and on an iPhone with a Dynamic Island its middle third is system UI outright),
    /// so no window level wins it back. The accelerometer has no such owner.
    private func installGestures() {
        ShakeDetector.shared.onShake = { [weak self] in self?.shakeDetected() }
        ShakeDetector.shared.start()
    }

    private func shakeDetected() {
        // Not on top of our own chrome, and not mid-review — the strip's own Done ends that.
        guard alertWindow == nil, listWindow == nil,
              !ReviewModeController.shared.isActive else { return }
        presentChooser()
    }

    /// The chooser, as raised by a shake or by `AgentPadDevHelper.showUIFeedbackChooser()`.
    func showChooser() {
        guard installed, alertWindow == nil else { return }
        presentChooser()
    }

    private func presentChooser() {
        guard let scene = foregroundScene() else { return }
        let count = FeedbackOutbox.shared.count()
        let alert = UIAlertController(title: "AgentPad UI Feedback", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Leave UI Review Feedback", style: .default) { [weak self] _ in
            self?.dismissChooser()
            ReviewModeController.shared.setActive(true)
        })
        let view = UIAlertAction(title: count > 0 ? "View Pending Feedback (\(count))"
                                                  : "View Pending Feedback", style: .default) { [weak self] _ in
            self?.dismissChooser()
            self?.presentList()
        }
        view.isEnabled = count > 0
        alert.addAction(view)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.dismissChooser()
        })

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 4
        window.rootViewController = UIViewController()
        window.isHidden = false
        alertWindow = window
        window.rootViewController?.present(alert, animated: true)
    }

    private func dismissChooser() {
        alertWindow?.isHidden = true
        alertWindow = nil
    }

    func presentList() {
        guard listWindow == nil, let scene = foregroundScene() else { return }
        let list = PendingFeedbackListViewController(style: .plain)
        list.onDismiss = { [weak self] in
            self?.listWindow?.isHidden = true
            self?.listWindow = nil
        }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 3
        window.rootViewController = UINavigationController(rootViewController: list)
        window.isHidden = false
        listWindow = window
    }

    private func foregroundScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    #endif
}

#if !canImport(UIKit) && canImport(AppKit)

extension FeedbackEntryPoints: NSMenuItemValidation {
    /// Titles/enabled state resolve HERE, each time the menu opens — no delegate takeover of
    /// the host's Help menu, no stale counts.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === leaveItem {
            return !ReviewModeController.shared.isActive
        }
        if menuItem === viewItem {
            let count = FeedbackOutbox.shared.count()
            menuItem.title = title(forPendingCount: count)
            return count > 0
        }
        return true
    }

    /// "View & Send (N) UI Feedbacks…" — worded as pending-sync when an app key is carrying
    /// them to a specific server; plain when there's nothing to show.
    func title(forPendingCount count: Int) -> String {
        guard count > 0 else { return "View & Send UI Feedbacks…" }
        if mode == .appKey { return "View \(count) Pending UI Feedback\(count == 1 ? "" : "s")…" }
        return "View & Send (\(count)) UI Feedbacks…"
    }
}

#endif

