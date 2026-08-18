import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Feedback wire payload

/// One hop in a chosen element's ancestor path, as sent in the `feedback` ingress frame.
///
/// PUBLIC and field-for-field identical to `AgentPadProtocol.UIElementNode` — this package is
/// deliberately dependency-free, so the shape is duplicated and a ServerKit parity test
/// (`UIFeedbackPayloadParityTests`) encodes one of these and decodes it with the protocol type
/// to keep the two from drifting.
public struct FeedbackElementNode: Codable {
    public var role: String
    public var className: String
    public var label: String?
    public var value: String?
    public var identifier: String?
    public var x: Double?
    public var y: Double?
    public var w: Double?
    public var h: Double?

    public init(role: String, className: String, label: String? = nil, value: String? = nil,
                identifier: String? = nil, x: Double? = nil, y: Double? = nil,
                w: Double? = nil, h: Double? = nil) {
        self.role = role; self.className = className; self.label = label; self.value = value
        self.identifier = identifier; self.x = x; self.y = y; self.w = w; self.h = h
    }
}

/// The element one piece of feedback is about: ancestor chain, root → leaf.
/// Mirror of `AgentPadProtocol.UIElementDescriptor`.
public struct FeedbackElementDescriptor: Codable {
    public var windowTitle: String?
    public var path: [FeedbackElementNode]

    public init(windowTitle: String? = nil, path: [FeedbackElementNode]) {
        self.windowTitle = windowTitle; self.path = path
    }
}

/// The whole `feedback` frame payload. Mirror of what `Server.recordUIFeedback` decodes;
/// app identity is NOT here — the server denormalizes it from this connection's hello.
public struct FeedbackPayload: Codable {
    public var message: String
    public var element: FeedbackElementDescriptor?
    /// A 1x PNG of the reviewed window at submit time, base64. Optional — capture can fail
    /// or be skipped when the encoded frame would blow the ingress line budget.
    public var screenshotPNG: String?

    public init(message: String, element: FeedbackElementDescriptor? = nil, screenshotPNG: String? = nil) {
        self.message = message; self.element = element; self.screenshotPNG = screenshotPNG
    }
}

// MARK: - Building descriptors from live views

/// Turns live views into `FeedbackElementDescriptor`s for Review UI Mode: the ancestor walk
/// (superview chain up to the window root, reversed), the point → view hit-test the selection
/// overlay drives, and the "what the user is looking at" default target.
///
/// Main-thread only, like everything else that touches the view hierarchy.
enum ElementPath {

    /// Ancestor chains deeper than this are trimmed from the MIDDLE — the root end says which
    /// window/screen the element lives on, the leaf end says exactly what it is; the wrapper
    /// soup in between (layout guides, hosting views, private containers) is the part an agent
    /// can re-derive. 6 + 18 covers every hierarchy we've walked in practice.
    private static let maxNodes = 24

    #if canImport(UIKit)
    typealias PlatformView = UIView
    #else
    typealias PlatformView = NSView
    #endif

    /// The full descriptor for one chosen view: its window's title plus every ancestor from the
    /// window's root view down to the view itself.
    static func descriptor(for view: PlatformView) -> FeedbackElementDescriptor {
        var chain: [PlatformView] = []
        var cursor: PlatformView? = view
        while let v = cursor {
            chain.append(v)
            cursor = v.superview
        }
        var nodes = chain.reversed().map(node(for:))
        if nodes.count > maxNodes {
            let keepLeaf = maxNodes - 6
            nodes = Array(nodes.prefix(6)) + Array(nodes.suffix(keepLeaf))
        }
        return FeedbackElementDescriptor(windowTitle: windowTitle(of: view), path: nodes)
    }

    /// One view → one wire node. Reuses `UIDriver`'s role/label/value vocabulary so the same
    /// element reads the same in a feedback card and a `ui_snapshot`.
    static func node(for v: PlatformView) -> FeedbackElementNode {
        let frame = frameInWindow(of: v)
        #if canImport(UIKit)
        let identifier = v.accessibilityIdentifier?.isEmpty == false ? v.accessibilityIdentifier : nil
        #else
        let identifier = v.identifier?.rawValue
        #endif
        return FeedbackElementNode(
            role: UIDriver.role(v), className: String(describing: type(of: v)),
            label: truncated(UIDriver.label(v)), value: truncated(UIDriver.value(v)),
            identifier: identifier,
            x: frame.map { Double($0.origin.x) }, y: frame.map { Double($0.origin.y) },
            w: frame.map { Double($0.width) }, h: frame.map { Double($0.height) })
    }

    /// The view's frame in its WINDOW's coordinates — what the wire nodes carry, and what the
    /// selection overlay draws. nil when the view is detached or its frame is non-finite (the
    /// same mid-layout NaN case `apSafeInt` guards; `Double(CGFloat.nan)` doesn't trap, but a
    /// NaN rect on the wire helps nobody).
    static func frameInWindow(of v: PlatformView) -> CGRect? {
        guard v.window != nil else { return nil }
        let rect = v.convert(v.bounds, to: nil)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        return rect
    }

    /// A short display name for a node ("Save — button", "ProfileHeaderView"), shared by the
    /// attached-element token and the selection overlay's tag.
    static func displayName(for node: FeedbackElementNode) -> String {
        if let label = node.label, !label.isEmpty { return "\(label) — \(node.role)" }
        if let id = node.identifier, !id.isEmpty { return "#\(id) — \(node.role)" }
        return node.className.isEmpty ? node.role : node.className
    }

    private static func truncated(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s.count > 200 ? String(s.prefix(200)) : s
    }

    /// The reviewed window as a 1x PNG, base64 — visual context that rides each feedback
    /// item. 1x on purpose: a Retina capture quadruples the bytes for context nobody zooms,
    /// and the ingress frames are newline-JSON with a line budget. Returns nil when there's
    /// no window, the render fails, or the result is still too big to put on the wire.
    static func captureWindowPNGBase64() -> String? {
        guard let png = captureWindowPNG() else { return nil }
        // ~4 MB of PNG is ~5.3 MB of base64 — stay comfortably under the ingress's 16 MB
        // line cap even with several fields around it.
        guard png.count <= 4_000_000 else { return nil }
        return png.base64EncodedString()
    }

    // MARK: platform specifics

    #if canImport(UIKit)

    private static func captureWindowPNG() -> Data? {
        guard let window = targetWindows().first(where: { $0.isKeyWindow }) ?? targetWindows().first else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return image.pngData()
    }


    /// The deepest visible view under `point` (in `window` coordinates) that's worth giving
    /// feedback on. Plain `UIView.hitTest` — the same answer a touch would get — minus views
    /// that can't take a hit (userInteractionEnabled false falls back to the nearest ancestor
    /// that can, which is what the user means anyway).
    static func hitTest(at point: CGPoint, in window: UIWindow) -> UIView? {
        window.hitTest(point, with: nil) ?? window.rootViewController?.view
    }

    /// Every window Review Mode may choose from — the app's own visible windows, never ours.
    static func targetWindows() -> [UIWindow] {
        var windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        windows += UIApplication.shared.windows
        var seen = Set<ObjectIdentifier>()
        return windows.filter {
            !$0.isHidden && $0.alpha > 0.01 && !ReviewModeController.isReviewWindow($0)
                && seen.insert(ObjectIdentifier($0)).inserted
        }
    }

    /// What the user is looking at when they open the composer without choosing: the key
    /// window's TOP view controller's view (not the root — a pushed/presented screen is the
    /// thing on screen).
    static func defaultTarget() -> UIView? {
        guard let window = targetWindows().first(where: { $0.isKeyWindow }) ?? targetWindows().first,
              var vc = window.rootViewController else { return nil }
        while true {
            if let presented = vc.presentedViewController { vc = presented; continue }
            if let nav = vc as? UINavigationController, let top = nav.topViewController { vc = top; continue }
            if let tab = vc as? UITabBarController, let sel = tab.selectedViewController { vc = sel; continue }
            break
        }
        return vc.viewIfLoaded ?? window
    }

    static func windowTitle(of v: UIView) -> String? {
        guard let window = v.window else { return nil }
        var vc = window.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        if let nav = vc as? UINavigationController { vc = nav.topViewController }
        return vc?.navigationItem.title ?? vc?.title
    }

    #else

    private static func captureWindowPNG() -> Data? {
        let windows = targetWindows()
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first,
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Downscale the (usually Retina) capture to 1x — draw it into a point-sized bitmap.
        let size = view.bounds.size
        guard size.width >= 1, size.height >= 1,
              let scaled = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: scaled) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return scaled.representation(using: .png, properties: [:])
    }

    /// The deepest view under `point` (window base coordinates) in `window`'s hierarchy.
    /// Hit-testing the frame view (`contentView.superview`) covers the titlebar/toolbar too,
    /// same as `UIDriver.rootElements()`.
    static func hitTest(at point: NSPoint, in window: NSWindow) -> NSView? {
        guard let frameView = window.contentView?.superview ?? window.contentView else { return nil }
        // `hitTest(_:)` takes the point in the receiver's superview's coordinates; the frame
        // view has no superview and fills the window, so window base coordinates are its own.
        return frameView.hitTest(point) ?? frameView
    }

    /// The app's own ordinary windows — never Review Mode's bar/overlay panels, and nothing
    /// invisible or bar-adjacent (tooltips etc. have no content view worth walking).
    static func targetWindows() -> [NSWindow] {
        (NSApp?.windows ?? []).filter {
            $0.isVisible && !ReviewModeController.isReviewWindow($0) && $0.contentView != nil
        }
    }

    /// What the user is looking at: the key (else main, else frontmost) window's content
    /// view-controller's view, falling back to the content view.
    static func defaultTarget() -> NSView? {
        let windows = targetWindows()
        guard let window = windows.first(where: { $0.isKeyWindow })
            ?? NSApp?.mainWindow.flatMap({ windows.contains($0) ? $0 : nil })
            ?? windows.first else { return nil }
        return window.contentViewController?.view ?? window.contentView
    }

    static func windowTitle(of v: NSView) -> String? {
        guard let title = v.window?.title, !title.isEmpty else { return nil }
        return title
    }

    #endif
}
