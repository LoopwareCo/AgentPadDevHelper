import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Review UI Mode inside the host app: the state machine (idle → active ⇄ choosing) and the
/// windows it owns — the Mac's floating bar panel above the Dock, iOS's status-bar strip, and
/// the choosing overlay on both.
///
/// Entered two ways, exited two ways, all converging here:
///   - AgentPad relays the `review_mode` tool call over the ingress (`DevToolHandler`), and
///   - the user hits Done in the bar → `setActive(false)`.
/// Every state change reports through `onModeChanged` (→ the `reviewMode` ingress frame), so
/// the server's picture is correct whichever side drove the change — the server treats a
/// repeat as a no-op, so confirming a server-initiated change is harmless.
///
/// Main-thread only (it owns windows); `DevToolHandler` already hops there.
final class ReviewModeController {
    static let shared = ReviewModeController()
    private init() {}

    /// Live feedback, sent only to the connection that opened this review.
    var onSubmit: ((FeedbackPayload) -> Void)?
    /// Mode changes (both directions). Wired by `DevKitClient` to the `reviewMode` frame.
    var onModeChanged: ((Bool) -> Void)?

    private(set) var isActive = false
    private var overlay: ReviewOverlay?

    /// The chosen element's descriptor, captured AT CHOOSE TIME — a view can be deallocated
    /// between choosing and sending (a dismissed sheet, a reused cell), and a descriptor
    /// snapshot outlives it where a weak view reference would silently go nil.
    private var attachedElement: FeedbackElementDescriptor?
    /// True while the token is the automatic "what you're looking at" default (refreshed on
    /// every send), false once the user explicitly chose an element (kept until removed).
    private var attachedIsDefault = true
    /// The last of the app's OWN windows to hold key. Review Mode's bar/compose window takes
    /// key as soon as the mode turns on, so `keyWindow` stops naming the window under review
    /// from that moment; this is what `ElementPath.reviewedWindow()` falls back to.
    private weak var lastKeyWindow: ElementPath.PlatformWindow?
    static var lastKeyAppWindow: ElementPath.PlatformWindow? { shared.lastKeyWindow }
    private var keyObserver: NSObjectProtocol?

    // MARK: - mode

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            // Before the bar exists — while the app's own key window is still key.
            startTrackingKeyWindow()
            attachedIsDefault = true
            refreshDefaultElement()
            showBar()
            guard barIsHosted else {
                // A windowless process (the widgets-only sample, a CLI tool) can't host the
                // bar. Report NOT active so the server reverts its optimistic flip instead of
                // wedging "reviewing" on an app with no way to compose.
                isActive = false
                onModeChanged?(false)
                return
            }
        } else {
            overlay?.end()
            overlay = nil
            hideBar()
            attachedElement = nil
            stopTrackingKeyWindow()
        }
        onModeChanged?(active)
    }

    /// Is `window` one of Review Mode's own (the bar, the choosing overlay, iOS's strip)?
    /// `ElementPath` filters these out of every walk/hit-test so the feature can't choose or
    /// describe its own chrome.
    #if canImport(UIKit)
    static func isReviewWindow(_ window: UIWindow) -> Bool {
        let c = shared
        return window === c.stripWindow || window === c.composeWindow
            || ReviewOverlay.liveOverlayWindows.contains { $0 === window }
    }
    #else
    static func isReviewWindow(_ window: NSWindow) -> Bool {
        return window === shared.barPanel
            || ReviewOverlay.liveOverlayWindows.contains { $0 === window }
    }
    #endif

    // MARK: - reviewed window

    /// Watch which of the app's own windows holds key, starting from whichever does right now.
    /// The notification is the only way to keep up: once the bar is up, key ping-pongs between
    /// it and the window the user clicks back into, and only the latter is the reviewed one.
    private func startTrackingKeyWindow() {
        lastKeyWindow = ElementPath.targetWindows().first(where: { $0.isKeyWindow }) ?? lastKeyWindow
        guard keyObserver == nil else { return }
        #if canImport(UIKit)
        let name = UIWindow.didBecomeKeyNotification
        #else
        let name = NSWindow.didBecomeKeyNotification
        #endif
        keyObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
            guard let window = note.object as? ElementPath.PlatformWindow,
                  !ReviewModeController.isReviewWindow(window) else { return }
            ReviewModeController.shared.lastKeyWindow = window
        }
    }

    private func stopTrackingKeyWindow() {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        lastKeyWindow = nil
    }

    // MARK: - element token

    private func refreshDefaultElement() {
        guard attachedIsDefault else { return }
        attachedElement = ElementPath.defaultDescriptor()
        pushElementToBar()
    }

    private func pushElementToBar() {
        let name = attachedElement.flatMap { $0.path.last.map(ElementPath.displayName(for:)) }
        barViewController?.setTarget(name: name, symbolName: "viewfinder")
    }

    // MARK: - choosing

    private func beginChoosing() {
        guard overlay == nil else { return }
        barViewController?.setChoosing(true)
        let o = ReviewOverlay()
        o.onPickElement = { [weak self] chosen in
            guard let self else { return }
            self.overlay = nil
            self.attachedElement = ElementPath.descriptor(for: chosen)
            self.attachedIsDefault = false
            self.barViewController?.setChoosing(false)
            self.pushElementToBar()
            self.focusComposer()
        }
        o.onCancel = { [weak self] in
            guard let self else { return }
            self.overlay = nil
            self.barViewController?.setChoosing(false)
            self.focusComposer()
        }
        overlay = o
        o.begin()
    }

    private func cancelChoosing() {
        overlay?.end()
        overlay = nil
        barViewController?.setChoosing(false)
    }

    // MARK: - sending

    private func send(_ message: String) {
        // The default token tracks "what you're looking at", so re-resolve it at the moment of
        // send; an explicit choice is exactly what the user picked, frozen at choose time.
        if attachedIsDefault {
            attachedElement = ElementPath.defaultDescriptor()
        }
        guard isActive else { return }
        // No screenshot: feedback travels as text + the element descriptor only.
        onSubmit?(FeedbackPayload(message: message, element: attachedElement))
        // Back to the default scope for the next thought.
        attachedIsDefault = true
        refreshDefaultElement()
    }

    private func removeElement() {
        // ✕ on the token: this feedback is about the app in general.
        attachedElement = nil
        attachedIsDefault = false
        pushElementToBar()
    }

    private func wireBar(_ bar: ReviewBarViewController) {
        bar.onSend = { [weak self] message in self?.send(message) }
        bar.onChooseUI = { [weak self] in self?.beginChoosing() }
        bar.onCancelChoose = { [weak self] in self?.cancelChoosing() }
        bar.onDone = { [weak self] in self?.setActive(false) }
        bar.onRemoveTarget = { [weak self] in self?.removeElement() }
    }

    // MARK: - hosting: macOS floating bar panel

    #if !canImport(UIKit) && canImport(AppKit)

    private var barPanel: NSPanel?
    private var barViewController: ReviewBarViewController?
    /// Whether the bar is meant to be on screen right now (`NSApp.isActive`). Kept apart from
    /// `panel.isVisible`, which lags behind a fade-out still in flight.
    private var barShown = false
    /// False until the bar has been revealed once — the first reveal is what places it and
    /// takes the composer's focus, whether that happens immediately or when the app comes
    /// forward later.
    private var barRevealedOnce = false
    private var activationObservers: [NSObjectProtocol] = []

    /// The bar exists (the process can host it) — NOT that it's on screen; it spends the whole
    /// time the app is in the background created but ordered out.
    private var barIsHosted: Bool { barPanel != nil }

    private func showBar() {
        guard barPanel == nil, NSApp != nil else { return }
        let bar = ReviewBarViewController(appName: UIDriver.appName)
        wireBar(bar)
        // A STANDARD titled window (controls hidden), not a borderless one: the system then
        // owns the shape, so the shadow hugs the rounded corners instead of boxing them (a
        // borderless panel's shadow was computed off the rectangular frame). Non-activating:
        // typing in the bar must not yank the reviewed app's windows around.
        let panel = ReviewBarPanel(contentRect: .zero,
                                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for which in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(which)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true       // grab any empty glass and drag
        panel.level = .statusBar                       // above every app window, below screensaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // We hide/show it ourselves rather than letting AppKit do it: the bar also has to stay
        // away when the mode is turned ON from AgentPad, which is the frontmost app at that
        // moment — a window AppKit never hid is a window it won't restore.
        panel.hidesOnDeactivate = false
        panel.contentViewController = bar
        panel.layoutIfNeeded()
        panel.alphaValue = 0
        barPanel = panel
        barViewController = bar
        barShown = false
        barRevealedOnce = false
        pushElementToBar()
        startTrackingAppActivation()
        // Reveals with a fade if the app is frontmost right now; otherwise it waits, ordered out,
        // for the app to come forward.
        syncBarVisibility(animated: true)
    }

    private func hideBar() {
        stopTrackingAppActivation()
        guard let panel = barPanel else { return }
        barPanel = nil
        barViewController = nil
        barShown = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: - following the app to the front

    /// The bar is chrome for ONE app — the one being reviewed — so it belongs on screen only
    /// while that app is frontmost. Floating at `.statusBar` level over whatever the user
    /// switched to (AgentPad included) is just clutter, and it can't say anything useful about
    /// a window the user isn't looking at. Review Mode itself stays on throughout: the bar
    /// comes straight back, in place, when the app returns.
    private func startTrackingAppActivation() {
        guard activationObservers.isEmpty else { return }
        let center = NotificationCenter.default
        activationObservers = [NSApplication.didBecomeActiveNotification,
                               NSApplication.didResignActiveNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                ReviewModeController.shared.syncBarVisibility(animated: true)
            }
        }
    }

    private func stopTrackingAppActivation() {
        for observer in activationObservers { NotificationCenter.default.removeObserver(observer) }
        activationObservers = []
    }

    private func syncBarVisibility(animated: Bool) {
        guard let panel = barPanel else { return }
        let shouldShow = NSApp?.isActive ?? false
        guard shouldShow != barShown else { return }
        barShown = shouldShow
        if shouldShow {
            let firstReveal = !barRevealedOnce
            if firstReveal {
                barRevealedOnce = true
                placeBar(panel)
            }
            panel.orderFrontRegardless()
            fadeBar(panel, to: 1, duration: animated ? 0.18 : 0)
            // Only the first reveal takes focus. On every later one the app came forward
            // because the user clicked one of ITS windows (or ⌘-tabbed to it) — pulling key
            // over to the composer would fight the click they just made.
            if firstReveal { focusComposer() }
        } else {
            // Choosing is a hit-test layer over the app's own windows with no visible way out
            // once the bar is gone; drop back to composing so the returning bar is coherent.
            cancelChoosing()
            fadeBar(panel, to: 0, duration: animated ? 0.15 : 0) { [weak self] in
                // A fast switch away and back can re-show the bar mid-fade — leave it alone then.
                guard let self, !self.barShown, self.barPanel === panel else { return }
                panel.orderOut(nil)
            }
        }
    }

    /// Bottom-center of the screen the reviewed window is on, just above the Dock. Done at the
    /// first reveal, not at creation: the mode is usually switched on from AgentPad, and the
    /// screen worth centering on is the one the user has the app open on. Never repeated —
    /// the bar is draggable, and where the user put it is where it belongs.
    private func placeBar(_ panel: NSPanel) {
        guard let screen = ElementPath.reviewedWindow()?.screen ?? NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame          // already excludes Dock + menu bar
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 16))
    }

    private func fadeBar(_ panel: NSPanel, to alpha: CGFloat, duration: TimeInterval,
                         completion: (() -> Void)? = nil) {
        guard duration > 0 else {
            panel.alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            panel.animator().alphaValue = alpha
        }, completionHandler: completion)
    }

    private func focusComposer() {
        guard let panel = barPanel, barShown else { return }
        panel.makeKey()
        barViewController?.focusField()
    }

    /// Borderless panels refuse key status by default; the compose field needs it to type.
    private final class ReviewBarPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    // MARK: - hosting: iOS status-bar strip + compose card

    #else

    private var stripWindow: UIWindow?
    private var composeWindow: UIWindow?
    private var barViewController: ReviewBarViewController?

    private var barIsHosted: Bool { stripWindow != nil }

    /// The AgentPad icon's background gradient (sampled from the shipped 1024pt icon):
    /// #53A3FF at the top → #9B4FFF at the bottom.
    static let brandGradient: [CGColor] = [
        UIColor(red: 0x53 / 255.0, green: 0xA3 / 255.0, blue: 0xFF / 255.0, alpha: 1).cgColor,
        UIColor(red: 0x9B / 255.0, green: 0x4F / 255.0, blue: 0xFF / 255.0, alpha: 1).cgColor,
    ]

    private func showBar() {
        guard stripWindow == nil else { return }
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return }

        // The band the status bar occupies is NOT the app's to take touches in — the system
        // arbitrates it, and on a Dynamic Island phone owns its middle outright. So the strip
        // spans that band (for the gradient) PLUS a 44pt row underneath it, and every control
        // lives in that row. A strip sized to the status bar alone draws perfectly and can't
        // be pressed on a real device.
        let band = scene.statusBarManager?.statusBarFrame.height ?? 0
        let strip = UIWindow(windowScene: scene)
        strip.windowLevel = .statusBar + 1
        strip.frame = CGRect(x: 0, y: 0, width: scene.screen.bounds.width,
                             height: band + ReviewStripViewController.controlRowHeight)
        let vc = ReviewStripViewController()
        vc.onCompose = { [weak self] in self?.presentComposer() }
        vc.onDone = { [weak self] in self?.setActive(false) }
        strip.rootViewController = vc
        strip.isHidden = false
        stripWindow = strip
    }

    private func hideBar() {
        dismissComposer()
        stripWindow?.isHidden = true
        stripWindow = nil
    }

    private func presentComposer() {
        guard composeWindow == nil, let scene = stripWindow?.windowScene else { return }
        let bar = ReviewBarViewController(appName: UIDriver.appName)
        wireBar(bar)
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 5
        w.rootViewController = bar
        w.isHidden = false
        composeWindow = w
        barViewController = bar
        pushElementToBar()
        bar.focusField()
    }

    private func dismissComposer() {
        composeWindow?.isHidden = true
        composeWindow = nil
        barViewController = nil
    }

    private func focusComposer() {
        barViewController?.focusField()
    }

    /// The status-bar takeover strip — the ONE review-mode chrome, whoever activated the mode
    /// (AgentPad's `review_mode` call or the app's own shake entry): brand gradient covering the
    /// status bar and a row below it, "+ UI Review" in the LEFT corner, "Done" in the RIGHT.
    private final class ReviewStripViewController: UIViewController {
        /// The pressable part, below the system-owned status-bar band.
        static let controlRowHeight: CGFloat = 44

        var onCompose: (() -> Void)?
        var onDone: (() -> Void)?
        private let gradient = CAGradientLayer()

        override func viewDidLoad() {
            super.viewDidLoad()
            gradient.colors = ReviewModeController.brandGradient
            view.layer.insertSublayer(gradient, at: 0)

            let review = UIButton(type: .system)
            review.setTitle("+ UI Review", for: .normal)
            review.setTitleColor(.white, for: .normal)
            review.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            review.addTarget(self, action: #selector(composeTapped), for: .touchUpInside)

            let done = UIButton(type: .system)
            done.setTitle("Done", for: .normal)
            done.setTitleColor(.white, for: .normal)
            done.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            done.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

            let row = UIStackView(arrangedSubviews: [review, UIView(), done])
            row.axis = .horizontal
            row.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                // Centred in the control row the strip adds BELOW the status bar: clear of the
                // cutout to read, and clear of the system's band to be pressable at all.
                row.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
                row.heightAnchor.constraint(equalToConstant: 24),
            ])
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            gradient.frame = view.bounds
        }

        @objc private func composeTapped() { onCompose?() }
        @objc private func doneTapped() { onDone?() }
    }

    #endif
}
