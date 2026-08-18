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

    /// Submitted feedback, ready for the wire. Wired by `DevKitClient` to the `feedback` frame.
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

    // MARK: - mode

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            attachedIsDefault = true
            refreshDefaultElement()
            showBar()
            guard barIsVisible else {
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

    // MARK: - element token

    private func refreshDefaultElement() {
        guard attachedIsDefault else { return }
        attachedElement = ElementPath.defaultTarget().map(ElementPath.descriptor(for:))
        pushElementToBar()
    }

    private func pushElementToBar() {
        let name = attachedElement.flatMap { $0.path.last.map(ElementPath.displayName(for:)) }
        barViewController?.setElementName(name)
    }

    // MARK: - choosing

    private func beginChoosing() {
        guard overlay == nil else { return }
        barViewController?.setChoosing(true)
        let o = ReviewOverlay()
        o.onPickView = { [weak self] view in
            guard let self else { return }
            self.overlay = nil
            self.attachedElement = ElementPath.descriptor(for: view)
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
            attachedElement = ElementPath.defaultTarget().map(ElementPath.descriptor(for:))
        }
        // The reviewed window, as the user sees it right now (the bar/overlay are their own
        // windows, so they're not in the shot).
        let screenshot = ElementPath.captureWindowPNGBase64()
        onSubmit?(FeedbackPayload(message: message, element: attachedElement, screenshotPNG: screenshot))
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
        bar.onRemoveElement = { [weak self] in self?.removeElement() }
    }

    // MARK: - hosting: macOS floating bar panel

    #if !canImport(UIKit) && canImport(AppKit)

    private var barPanel: NSPanel?
    private var barViewController: ReviewBarViewController?

    private var barIsVisible: Bool { barPanel != nil }

    private func showBar() {
        guard barPanel == nil, NSApp != nil else { return }
        let bar = ReviewBarViewController(appName: UIDriver.appName)
        wireBar(bar)
        // Borderless + non-activating: typing in the bar must not yank the reviewed app's
        // windows around, and hovering it must not activate anything.
        let panel = ReviewBarPanel(contentRect: .zero,
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar                       // above every app window, below screensaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.contentViewController = bar
        panel.layoutIfNeeded()

        // Bottom-center of the screen the app's key window is on, just above the Dock.
        let screen = NSApp?.keyWindow?.screen ?? NSScreen.main
        if let screen {
            let size = panel.frame.size
            let visible = screen.visibleFrame       // already excludes Dock + menu bar
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                         y: visible.minY + 16))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        barPanel = panel
        barViewController = bar
        pushElementToBar()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        focusComposer()
    }

    private func hideBar() {
        guard let panel = barPanel else { return }
        barPanel = nil
        barViewController = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func focusComposer() {
        guard let panel = barPanel else { return }
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

    private var barIsVisible: Bool { stripWindow != nil }

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

        let height = max(scene.statusBarManager?.statusBarFrame.height ?? 0, 44)
        let strip = UIWindow(windowScene: scene)
        strip.windowLevel = .statusBar + 1
        strip.frame = CGRect(x: 0, y: 0, width: scene.screen.bounds.width, height: height)
        let vc = ReviewStripViewController()
        vc.onCompose = { [weak self] in self?.presentComposer() }
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

    /// The status-bar takeover strip: brand gradient, the AgentPad face on the left,
    /// "+ Compose" on the right.
    private final class ReviewStripViewController: UIViewController {
        var onCompose: (() -> Void)?
        private let gradient = CAGradientLayer()

        override func viewDidLoad() {
            super.viewDidLoad()
            gradient.colors = ReviewModeController.brandGradient
            view.layer.insertSublayer(gradient, at: 0)

            let face = UILabel()
            face.text = ">_<"
            face.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)
            face.textColor = .white

            let compose = UIButton(type: .system)
            compose.setTitle("+ Compose", for: .normal)
            compose.setTitleColor(.white, for: .normal)
            compose.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            compose.addTarget(self, action: #selector(composeTapped), for: .touchUpInside)

            let row = UIStackView(arrangedSubviews: [face, UIView(), compose])
            row.axis = .horizontal
            row.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                // Pin to the strip's bottom so notch/Dynamic-Island screens read it below the cutout.
                row.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
                row.heightAnchor.constraint(equalToConstant: 24),
            ])
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            gradient.frame = view.bounds
        }

        @objc private func composeTapped() { onCompose?() }
    }

    #endif
}
