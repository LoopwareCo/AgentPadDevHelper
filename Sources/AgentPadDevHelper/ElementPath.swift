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
    typealias PlatformWindow = UIWindow
    #else
    typealias PlatformView = NSView
    typealias PlatformWindow = NSWindow
    #endif

    /// What Choose UI can land on: a real platform view, or (macOS) an AX-only element inside a
    /// SwiftUI hosting view — SwiftUI draws into one `NSHostingView`, so the view walk bottoms
    /// out there and the `AXBridge` node tree is the only route to the elements the user sees.
    enum ChosenElement {
        case view(PlatformView)
        #if !canImport(UIKit) && canImport(AppKit)
        case axElement(AnyObject, host: NSView)
        #endif
    }

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

    // MARK: chosen-element wrappers (view or SwiftUI AX element)

    static func descriptor(for chosen: ChosenElement) -> FeedbackElementDescriptor {
        switch chosen {
        case .view(let view):
            return descriptor(for: view)
        #if !canImport(UIKit) && canImport(AppKit)
        case .axElement(let element, let host):
            // The view chain down to (and including) the hosting view, then the AX chain from
            // the hosting view down to the chosen SwiftUI element.
            var base = descriptor(for: host)
            base.path.append(contentsOf: axChain(from: element, to: host)
                .map { axNode(for: $0, in: host.window) })
            if base.path.count > maxNodes {
                base.path = Array(base.path.prefix(6)) + Array(base.path.suffix(maxNodes - 6))
            }
            return base
        #endif
        }
    }

    /// The chosen thing's leaf node — what the token and the overlay tag show.
    static func leafNode(for chosen: ChosenElement) -> FeedbackElementNode {
        switch chosen {
        case .view(let view):
            return node(for: view)
        #if !canImport(UIKit) && canImport(AppKit)
        case .axElement(let element, let host):
            return axNode(for: element, in: host.window)
        #endif
        }
    }

    /// The chosen thing's frame in ITS window's coordinates (the overlay's highlight rect).
    static func frameInWindow(of chosen: ChosenElement) -> CGRect? {
        switch chosen {
        case .view(let view):
            return frameInWindow(of: view)
        #if !canImport(UIKit) && canImport(AppKit)
        case .axElement(let element, let host):
            return axFrameInWindow(of: element, in: host.window)
        #endif
        }
    }

    /// The window a chosen element lives in. An explicit choice pins the screenshot to ITS
    /// window, so clicking elsewhere between choosing and sending can't swap the shot.
    static func window(of chosen: ChosenElement) -> PlatformWindow? {
        switch chosen {
        case .view(let view):
            return view.window
        #if !canImport(UIKit) && canImport(AppKit)
        case .axElement(_, let host):
            return host.window
        #endif
        }
    }

    private static func truncated(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s.count > 200 ? String(s.prefix(200)) : s
    }

    /// The reviewed window as a 1x PNG, base64 — visual context that rides each feedback
    /// item. 1x on purpose: a Retina capture quadruples the bytes for context nobody zooms,
    /// and the ingress frames are newline-JSON with a line budget. Returns nil when there's
    /// no window, the render fails, or the result is still too big to put on the wire.
    static func captureWindowPNGBase64(of pinned: PlatformWindow? = nil) -> String? {
        guard let png = captureWindowPNG(of: pinned) else { return nil }
        // ~4 MB of PNG is ~5.3 MB of base64 — stay comfortably under the ingress's 16 MB
        // line cap even with several fields around it.
        guard png.count <= 4_000_000 else { return nil }
        return png.base64EncodedString()
    }

    // MARK: platform specifics

    #if canImport(UIKit)

    private static func captureWindowPNG(of pinned: PlatformWindow?) -> Data? {
        guard let window = pinned.flatMap({ w in targetWindows().first { $0 === w } }) ?? reviewedWindow() else { return nil }
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

    /// The window Review Mode is about. NOT simply the key window: the compose card takes key
    /// while the user types, so from then on none of the app's own windows is key. Fall back to
    /// the last app window that WAS key, then the topmost one by level — never plain
    /// "first window we happen to enumerate", which is an arbitrary window.
    static func reviewedWindow() -> UIWindow? {
        let windows = targetWindows()
        if let key = windows.first(where: { $0.isKeyWindow }) { return key }
        if let last = ReviewModeController.lastKeyAppWindow, windows.contains(where: { $0 === last }) { return last }
        let top = windows.map(\.windowLevel).max()
        return windows.last { $0.windowLevel == top }
    }

    /// What the user is looking at when they open the composer without choosing: the reviewed
    /// window's TOP view controller's view (not the root — a pushed/presented screen is the
    /// thing on screen).
    static func defaultTarget() -> UIView? {
        guard let window = reviewedWindow(),
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

    private static func captureWindowPNG(of pinned: PlatformWindow?) -> Data? {
        let windows = targetWindows()
        guard let window = pinned.flatMap({ w in windows.first { $0 === w } }) ?? reviewedWindow(),
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

    /// The chosen element under `point`: the deepest view — and, when that view sits in a
    /// SwiftUI hosting view, the deepest AX element under the point instead (the view walk
    /// bottoms out at `NSHostingView`; the `AXBridge` node tree is what the user actually sees).
    static func hitTestElement(at point: NSPoint, in window: NSWindow) -> ChosenElement? {
        guard let view = hitTest(at: point, in: window) else { return nil }
        guard let host = sequence(first: view, next: { $0.superview }).first(where: AXBridge.isHostingView) else {
            return .view(view)
        }
        AXBridge.materializeIfNeeded()
        let screenPoint = window.convertPoint(toScreen: point)
        if let element = deepestAXElement(under: screenPoint, from: host) {
            return .axElement(element, host: host)
        }
        return .view(host)
    }

    /// Depth-first descent of the AX-only children, keeping the deepest element whose screen
    /// frame contains the point.
    private static func deepestAXElement(under screenPoint: NSPoint, from root: AnyObject) -> AnyObject? {
        var best: AnyObject?
        func descend(_ node: AnyObject, depth: Int) {
            guard depth < 40 else { return }
            for child in AXBridge.elementChildren(of: node) {
                guard let frame = child.accessibilityFrame?(), frame.contains(screenPoint) else { continue }
                best = child
                descend(child, depth: depth + 1)
            }
        }
        descend(root, depth: 0)
        return best
    }

    /// The AX chain from the hosting view DOWN to `element` (host excluded, element included) —
    /// built by walking parents up until a real view appears, then reversing.
    private static func axChain(from element: AnyObject, to host: NSView) -> [AnyObject] {
        var chain: [AnyObject] = []
        var cursor: AnyObject? = element
        var hops = 0
        while let node = cursor, !(node is NSView), hops < 40 {
            chain.append(node)
            cursor = node.accessibilityParent?() as AnyObject?
            hops += 1
        }
        return chain.reversed()
    }

    /// A wire node for an AX-only element: the bridge's role vocabulary, the raw AX role as the
    /// "class name", and the screen frame converted into the host window's coordinates.
    private static func axNode(for element: AnyObject, in window: NSWindow?) -> FeedbackElementNode {
        let raw = AXBridge.rawRole(element)
        let role = raw.flatMap(AXBridge.genericRole) ?? raw ?? "element"
        let frame = axFrameInWindow(of: element, in: window)
        return FeedbackElementNode(
            role: role, className: raw ?? "AXElement",
            label: AXBridge.label(element), value: AXBridge.value(element, role: role),
            identifier: AXBridge.identifier(element),
            x: frame.map { Double($0.origin.x) }, y: frame.map { Double($0.origin.y) },
            w: frame.map { Double($0.width) }, h: frame.map { Double($0.height) })
    }

    private static func axFrameInWindow(of element: AnyObject, in window: NSWindow?) -> CGRect? {
        guard let frame = element.accessibilityFrame?(), frame.width > 0 || frame.height > 0,
              let window else { return nil }
        let local = window.convertFromScreen(frame)
        guard local.origin.x.isFinite, local.origin.y.isFinite,
              local.width.isFinite, local.height.isFinite else { return nil }
        return local
    }

    /// The app's own ordinary windows — never Review Mode's bar/overlay panels, and nothing
    /// invisible or bar-adjacent (tooltips etc. have no content view worth walking).
    static func targetWindows() -> [NSWindow] {
        (NSApp?.windows ?? []).filter {
            $0.isVisible && !ReviewModeController.isReviewWindow($0) && $0.contentView != nil
        }
    }

    /// The window Review Mode is about — the one the user is working in, and the one every
    /// shot and default element resolves against.
    ///
    /// NOT simply the key window: the compose bar takes key the moment the mode turns on, so
    /// from then on none of the app's own windows is key. Fall back to the last app window
    /// that WAS key, then main, then the FRONTMOST in z-order — `NSApp.windows` is ordered by
    /// creation, so its first element is whichever window the app built first (an app that
    /// opens a welcome window at launch would screenshot that one forever).
    static func reviewedWindow() -> NSWindow? {
        chooseReviewedWindow(from: targetWindows(),
                             lastKey: ReviewModeController.lastKeyAppWindow,
                             main: NSApp?.mainWindow,
                             ordered: NSApp?.orderedWindows ?? [])
    }

    /// The policy behind `reviewedWindow()`, split out so it can be tested without a window
    /// server (the bug it exists for happens precisely when NOTHING in `windows` is key).
    static func chooseReviewedWindow(from windows: [NSWindow], lastKey: NSWindow?,
                                     main: NSWindow?, ordered: [NSWindow]) -> NSWindow? {
        if let key = windows.first(where: { $0.isKeyWindow }) { return key }
        if let lastKey, windows.contains(lastKey) { return lastKey }
        if let main, windows.contains(main) { return main }
        if let front = ordered.first(where: { windows.contains($0) }) { return front }
        return windows.first
    }

    /// What the user is looking at: the reviewed window's content view-controller's view,
    /// falling back to the content view.
    static func defaultTarget() -> NSView? {
        guard let window = reviewedWindow() else { return nil }
        return window.contentViewController?.view ?? window.contentView
    }

    static func windowTitle(of v: NSView) -> String? {
        guard let title = v.window?.title, !title.isEmpty else { return nil }
        return title
    }

    #endif
}
