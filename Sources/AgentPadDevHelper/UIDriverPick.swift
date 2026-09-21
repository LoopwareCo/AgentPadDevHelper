import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One pointable element, in the shape `AgentPadProtocol.PickableElement` decodes.
///
/// Mirrored rather than shared: this package has no dependencies (it is embedded into other
/// people's apps), exactly as `ElementPath` mirrors `UIElementDescriptor`. Keep the keys in step.
struct PickNode: Encodable {
    var role: String
    var label: String?
    var identifier: String?
    var window: String?
    /// Fractions of the device's screen, top-left origin — see `PickableElement`.
    var x: Double, y: Double, w: Double, h: Double
}

struct PickTree: Encodable {
    var appName: String
    var elements: [PickNode]
}

extension UIDriver {
    /// A flat list of everything on screen a user could point at, for the viewer's "Choose UI"
    /// crosshair to hit-test locally.
    ///
    /// Back-to-front, normalized against the device's screen, so a viewer never needs to know the
    /// guest's backing scale or display size. Elements with no frame at all (menu items, bar
    /// button items, views mid-layout) are left out: you cannot point at what has no rectangle.
    func pickTreeJSON(maxDepth: Int = 40) -> String {
        // No `reset()` and no refs: nothing here is ACTED on later, so the registry stays out of it.
        var out: [PickNode] = []
        for root in rootElements() {
            collectPickable(root, depth: 0, maxDepth: maxDepth, into: &out)
            if out.count >= Self.pickElementCap { break }
        }
        let tree = PickTree(appName: Self.appName, elements: out)
        guard let data = try? JSONEncoder().encode(tree), let json = String(data: data, encoding: .utf8) else {
            return #"{"appName":"\#(Self.appName)","elements":[]}"#
        }
        return json
    }

    /// A ceiling on one answer's size. A deeply nested app can walk into the thousands, and past
    /// this point extra leaves add nothing a user could aim at but do add wire bytes on a link
    /// that may be a phone's.
    static var pickElementCap: Int { 4000 }

    private func collectPickable(_ obj: AnyObject, depth: Int, maxDepth: Int, into acc: inout [PickNode]) {
        guard isVisible(obj), acc.count < Self.pickElementCap else { return }
        if let frame = normalizedScreenFrame(of: obj) {
            let node = makeNode(for: obj, ref: 0)
            acc.append(PickNode(role: node.role, label: node.label, identifier: node.identifier,
                                window: windowTitle(of: obj),
                                x: frame.origin.x, y: frame.origin.y,
                                w: frame.width, h: frame.height))
        }
        guard depth < maxDepth else { return }
        for child in childElements(of: obj) {
            collectPickable(child, depth: depth + 1, maxDepth: maxDepth, into: &acc)
        }
    }
}

// MARK: - per-platform geometry

extension UIDriver {
#if canImport(UIKit)
    func windowTitle(of obj: AnyObject) -> String? { nil }   // an iOS app is one screen of UI

    /// The element's frame as fractions of the device screen, top-left origin — or nil when it has
    /// no usable rectangle (not view-backed, no window yet, degenerate, or entirely off screen).
    func normalizedScreenFrame(of obj: AnyObject) -> CGRect? {
        guard let view = obj as? UIView, let window = view.window else { return nil }
        let screen = window.screen.bounds
        guard screen.width > 0, screen.height > 0 else { return nil }
        let onScreen = window.convert(view.convert(view.bounds, to: nil), to: nil as UIWindow?)
        return Self.fraction(onScreen, in: screen)
    }
#elseif canImport(AppKit)
    func windowTitle(of obj: AnyObject) -> String? {
        guard let title = (obj as? NSView)?.window?.title, !title.isEmpty else { return nil }
        return title
    }

    func normalizedScreenFrame(of obj: AnyObject) -> CGRect? {
        guard let view = obj as? NSView, let window = view.window,
              let reference = NSScreen.screens.first?.frame, reference.height > 0 else { return nil }
        // AppKit's global space is bottom-left-origin and spans every display; the device feed's
        // is top-left-origin over the ONE display a VM has. Flip against that display.
        let global = window.convertToScreen(view.convert(view.bounds, to: nil))
        let flipped = CGRect(x: global.minX - reference.minX,
                             y: reference.maxY - global.maxY,
                             width: global.width, height: global.height)
        return Self.fraction(flipped, in: CGRect(origin: .zero, size: reference.size))
    }
#endif

    /// `rect` (device points, top-left origin) as fractions of `screen`. nil when it is degenerate
    /// or misses the screen entirely; a partly-off rect is kept whole so its visible part still
    /// hit-tests.
    static func fraction(_ rect: CGRect, in screen: CGRect) -> CGRect? {
        guard rect.width > 0.5, rect.height > 0.5, rect.intersects(screen),
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        return CGRect(x: rect.minX / screen.width, y: rect.minY / screen.height,
                      width: rect.width / screen.width, height: rect.height / screen.height)
    }
}
