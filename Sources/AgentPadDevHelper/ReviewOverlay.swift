import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The "Choose UI" selection overlay, one file both platforms.
///
/// Mac: one transparent borderless child window per app window; mouse-moves hit-test the HOST
/// window's own view tree (`ElementPath.hitTest`) and a floating rect + name tag follows the
/// element under the cursor; a click commits it. iOS: one full-screen overlay window; press-and-
/// hold shows the rect over the touched element, dragging updates it, releasing commits.
///
/// The overlay only exists while choosing — created by `ReviewModeController.beginChoosing()`,
/// torn down on commit/cancel — so at rest Review Mode adds no windows over the app.

// MARK: - the highlight drawing (shared shape, per-platform view)

#if !canImport(UIKit) && canImport(AppKit)

/// Draws the selection rect + role/name tag. Lives in each overlay window; coordinates are
/// window-base (== this content view's own, since the overlay exactly covers its host window).
private final class ReviewHighlightView: NSView {
    var rect: NSRect?
    var name: String?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect else { return }
        let accent = NSColor.controlAccentColor
        accent.withAlphaComponent(0.15).setFill()
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        path.fill()
        accent.setStroke()
        path.lineWidth = 2
        path.stroke()

        guard let name, !name.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: name, attributes: attrs)
        var size = text.size()
        size.width = min(size.width, bounds.width - 24)
        let pad: CGFloat = 5
        // Tag above the rect when there's room, else just inside its top edge.
        var origin = NSPoint(x: rect.minX, y: rect.maxY + 4)
        if origin.y + size.height + pad * 2 > bounds.maxY { origin.y = rect.maxY - size.height - pad * 2 - 4 }
        origin.x = max(4, min(origin.x, bounds.maxX - size.width - pad * 2 - 4))
        let tag = NSRect(x: origin.x, y: origin.y, width: size.width + pad * 2, height: size.height + pad * 2)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: tag, xRadius: 5, yRadius: 5).fill()
        text.draw(at: NSPoint(x: tag.minX + pad, y: tag.minY + pad))
    }
}

/// One overlay window pinned over one host window, forwarding hover/click to the controller.
private final class ReviewOverlayWindow: NSWindow {
    weak var host: NSWindow?
    var onHover: ((NSWindow, NSPoint) -> Void)?
    var onPick: ((NSWindow, NSPoint) -> Void)?
    let highlight = ReviewHighlightView()

    init(host: NSWindow) {
        self.host = host
        super.init(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        level = host.level
        contentView = highlight
        highlight.addTrackingArea(NSTrackingArea(rect: .zero,
                                                 options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                                 owner: self, userInfo: nil))
    }

    // Borderless windows refuse key by default; we don't need key either — tracking areas
    // deliver mouseMoved regardless (`.activeAlways`).
    override var canBecomeKey: Bool { false }

    override func mouseMoved(with event: NSEvent) {
        guard let host else { return }
        onHover?(host, event.locationInWindow)   // same coords as host: frames are identical
    }
    override func mouseDown(with event: NSEvent) {
        guard let host else { return }
        onPick?(host, event.locationInWindow)
    }
}

/// Owns the choosing session on the Mac: one `ReviewOverlayWindow` per target window, plus an
/// Esc monitor. `onPick(view)` / `onCancel()` fire exactly once.
final class ReviewOverlay {
    var onPickView: ((NSView) -> Void)?
    var onCancel: (() -> Void)?

    private var overlays: [ReviewOverlayWindow] = []
    private var keyMonitor: Any?
    private var finished = false

    /// Windows the overlay panels are counted among — `ElementPath.targetWindows` filters these.
    private(set) static var liveOverlayWindows: [NSWindow] = []

    func begin() {
        for host in ElementPath.targetWindows() {
            let overlay = ReviewOverlayWindow(host: host)
            overlay.onHover = { [weak self] host, point in self?.hover(host: host, point: point) }
            overlay.onPick = { [weak self] host, point in self?.pick(host: host, point: point) }
            host.addChildWindow(overlay, ordered: .above)
            overlays.append(overlay)
        }
        Self.liveOverlayWindows = overlays
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            self?.finish { $0.onCancel?() }
            return nil
        }
    }

    func end() {
        finished = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for overlay in overlays {
            overlay.host?.removeChildWindow(overlay)
            overlay.orderOut(nil)
        }
        overlays.removeAll()
        Self.liveOverlayWindows = []
    }

    private func hover(host: NSWindow, point: NSPoint) {
        guard !finished, let view = ElementPath.hitTest(at: point, in: host),
              let overlay = overlays.first(where: { $0.host === host }) else { return }
        // Clear every other window's highlight so exactly one rect is visible app-wide.
        for other in overlays where other !== overlay && other.highlight.rect != nil {
            other.highlight.rect = nil
            other.highlight.needsDisplay = true
        }
        overlay.highlight.rect = ElementPath.frameInWindow(of: view)
        overlay.highlight.name = ElementPath.displayName(for: ElementPath.node(for: view))
        overlay.highlight.needsDisplay = true
    }

    private func pick(host: NSWindow, point: NSPoint) {
        guard let view = ElementPath.hitTest(at: point, in: host) else { return }
        finish { $0.onPickView?(view) }
    }

    private func finish(_ deliver: (ReviewOverlay) -> Void) {
        guard !finished else { return }
        end()
        deliver(self)
    }
}

#endif

// MARK: - iOS

#if canImport(UIKit)

/// Full-screen choosing overlay: press-and-hold shows the rect over the element under the
/// finger (hit-testing the app's own windows, never ours), drag refines, release commits.
private final class ReviewOverlayViewController: UIViewController {
    var onPickView: ((UIView) -> Void)?
    var onCancel: (() -> Void)?

    private let highlight = UIView()
    private let tag = UILabel()
    private let hint = UILabel()
    private var current: UIView?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)

        hint.text = "Press and hold an element, release to choose — tap here to cancel"
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = .white
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        hint.layer.cornerRadius = 12
        hint.layer.masksToBounds = true
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.isUserInteractionEnabled = true
        hint.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(cancelTapped)))
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            hint.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
            hint.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])

        highlight.layer.borderWidth = 2
        highlight.layer.borderColor = view.tintColor.cgColor
        highlight.layer.cornerRadius = 4
        highlight.backgroundColor = view.tintColor.withAlphaComponent(0.15)
        highlight.isHidden = true
        highlight.isUserInteractionEnabled = false
        view.addSubview(highlight)

        tag.font = .systemFont(ofSize: 11, weight: .semibold)
        tag.textColor = .white
        tag.backgroundColor = view.tintColor
        tag.layer.cornerRadius = 5
        tag.layer.masksToBounds = true
        tag.isHidden = true
        view.addSubview(tag)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.12
        view.addGestureRecognizer(press)
    }

    @objc private func cancelTapped() { onCancel?() }

    @objc private func pressed(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            update(at: g.location(in: view))
        case .ended:
            if let current { onPickView?(current) } else { onCancel?() }
        case .cancelled, .failed:
            onCancel?()
        default:
            break
        }
    }

    private func update(at pointInOverlay: CGPoint) {
        guard let overlayWindow = view.window else { return }
        // Highest app window whose hit-test answers wins (targetWindows is level-sorted low→high).
        for target in ElementPath.targetWindows().reversed() {
            let point = overlayWindow.convert(pointInOverlay, to: target)
            guard let hit = ElementPath.hitTest(at: point, in: target) else { continue }
            current = hit
            let frame = ElementPath.frameInWindow(of: hit).map { target.convert($0, to: overlayWindow) }
                ?? .zero
            highlight.frame = view.convert(frame, from: nil)
            highlight.isHidden = false
            tag.text = "  " + ElementPath.displayName(for: ElementPath.node(for: hit)) + "  "
            tag.sizeToFit()
            var origin = CGPoint(x: highlight.frame.minX, y: highlight.frame.minY - tag.bounds.height - 4)
            if origin.y < view.safeAreaInsets.top { origin.y = highlight.frame.minY + 4 }
            origin.x = max(4, min(origin.x, view.bounds.maxX - tag.bounds.width - 4))
            tag.frame = CGRect(origin: origin, size: tag.bounds.size)
            tag.isHidden = false
            return
        }
    }
}

/// Owns the iOS choosing session: one overlay `UIWindow` above everything, torn down on
/// commit/cancel.
final class ReviewOverlay {
    var onPickView: ((UIView) -> Void)?
    var onCancel: (() -> Void)?

    private var window: UIWindow?
    private var finished = false

    private(set) static var liveOverlayWindows: [UIWindow] = []

    func begin() {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return }
        let vc = ReviewOverlayViewController()
        vc.onPickView = { [weak self] view in self?.finish { $0.onPickView?(view) } }
        vc.onCancel = { [weak self] in self?.finish { $0.onCancel?() } }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 10
        w.rootViewController = vc
        w.isHidden = false
        window = w
        Self.liveOverlayWindows = [w]
    }

    func end() {
        finished = true
        window?.isHidden = true
        window = nil
        Self.liveOverlayWindows = []
    }

    private func finish(_ deliver: (ReviewOverlay) -> Void) {
        guard !finished else { return }
        end()
        deliver(self)
    }
}

#endif
