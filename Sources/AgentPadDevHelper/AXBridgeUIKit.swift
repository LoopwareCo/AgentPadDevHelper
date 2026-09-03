import Foundation

#if canImport(UIKit)
import UIKit

/// The UIKit half of `AXBridge`: reach into the content the `UIView.subviews` walk cannot see —
/// SwiftUI hosted in a `UIHostingView`/`_UIHostingView`. Those views draw their controls without
/// any UIView behind them; the controls exist only as accessibility elements, reached through the
/// UIAccessibilityContainer protocol (`accessibilityElements`, or `accessibilityElementCount` +
/// `accessibilityElement(at:)`).
///
/// Every element answers the UIAccessibility *informal* protocol on NSObject (label, value,
/// traits, frame, activate, increment…), so plain calls work on whatever object comes back —
/// SwiftUI's `AccessibilityNode`, a `UIAccessibilityElement`, or a private UIKit wrapper.
///
/// (The iOS 26 navigation-bar platters are NOT this case: `NavigationButtonBar.ItemWrapperView`
/// wraps a real `_UIButtonBarButton` control, which the view walk reaches — see
/// `UIDriver.isUnrepresentedBarButton`.)
extension AXBridge {
    private static var materialized = false

    /// Make SwiftUI build its AX node tree. Idempotent; call before any walk, on the main thread.
    ///
    /// SwiftUI's tree is lazy on iOS exactly as on macOS, but the gate is different. Disassembly
    /// of `_UIHostingView.uiKitAccessibilityElements(options:)` (iOS 26/27 SwiftUI) shows the
    /// getter enables itself when EITHER `_AXSAccessibilityEnabled()` is true OR
    /// `NSClassFromString("AXUIKitGlue")` resolves — and re-checks on every call, so nothing has
    /// to be posted afterwards. The first is a device-wide libAccessibility preference (the one
    /// VoiceOver/XCUITest flip via `_AXSApplicationAccessibilitySetEnabled` /
    /// `_AXSAutomationSetEnabled`); writing it from a sandboxed dev build is neither in-process
    /// nor reversible, so it is not used. The second is the principal class of UIKit's own
    /// accessibility bundle (`/System/Library/AccessibilityBundles/UIKit.axbundle`). On the
    /// simulator that class already resolves in a fresh process (the runtime's shared cache
    /// publishes it before the bundle is loaded), so the gate is open and nothing is done. Where
    /// it does not resolve, the bundle is loaded here the way the AX runtime does when an
    /// assistive client connects — in-process, no preference touched, a system library path
    /// (sandbox-safe; dyld resolves it inside the simulator runtime root as well as on device).
    ///
    /// Loading it has the side effects VoiceOver users already see: UIKit's AX categories enrich
    /// labels (system bar items get "Add") and report switch values as "1"/"0" —
    /// `UIDriver.value(_:)` reads `UISwitch.isOn` first so the view walk's output stays stable.
    /// A bundle can't be unloaded, so it stays for the process lifetime. DEBUG dev builds only,
    /// the same trade the macOS flag makes.
    static func materializeIfNeeded() {
        guard !materialized else { return }
        materialized = true
        guard NSClassFromString("AXUIKitGlue") == nil else { return }   // gate already open
        if dlopen("/System/Library/AccessibilityBundles/UIKit.axbundle/UIKit", RTLD_NOW) == nil {
            NSLog("AgentPadDevHelper: could not load UIKit.axbundle — SwiftUI content stays invisible to ui_*")
        }
    }

    /// A view whose AX-only elements are worth grafting into the walk: any container that is not
    /// a real control and not itself one accessibility element (see `isGraftPoint(isControl:…)`).
    static func isGraftPoint(_ v: UIView) -> Bool {
        isGraftPoint(isControl: v is UIControl, isAccessibilityElement: v.isAccessibilityElement)
    }

    /// AX-only children of a container: its accessibility elements minus anything the view walk
    /// already covers (UIViews, and UIBarItems the navigation-bar walk synthesises itself).
    static func elementChildren(of obj: AnyObject) -> [AnyObject] {
        var raw: [AnyObject] = []
        if let list = obj.accessibilityElements as? [AnyObject], !list.isEmpty {
            raw = list
        } else if let count = obj.accessibilityElementCount?(), count != NSNotFound, count > 0 {
            // Containers that implement only the count/index pair (the older protocol shape).
            for i in 0..<min(count, 500) {
                if let e = obj.accessibilityElement?(at: i) { raw.append(e as AnyObject) }
            }
        }
        return raw.filter { !($0 is UIView) && !($0 is UIBarItem) }
    }

    /// The element's parent in the AX tree (`accessibilityContainer`), nil at a view boundary.
    static func parent(of obj: AnyObject) -> AnyObject? {
        (obj.accessibilityContainer ?? nil) as AnyObject?
    }

    /// The view the element is drawn in — the first UIView up its container chain.
    static func hostView(of obj: AnyObject) -> UIView? {
        var cursor: AnyObject? = obj
        var hops = 0
        while let node = cursor, hops < 40 {
            if let v = node as? UIView { return v }
            cursor = parent(of: node)
            hops += 1
        }
        return nil
    }

    static func traits(_ obj: AnyObject) -> TraitFlags {
        guard let t = obj.accessibilityTraits else { return [] }
        var f: TraitFlags = []
        let pairs: [(UIAccessibilityTraits, TraitFlags)] = [
            (.button, .button), (.link, .link), (.image, .image), (.selected, .selected),
            (.staticText, .staticText), (.notEnabled, .notEnabled), (.searchField, .searchField),
            (.adjustable, .adjustable), (.header, .header), (.keyboardKey, .keyboardKey),
            (.tabBar, .tabBar),
        ]
        for (ui, flag) in pairs where t.contains(ui) { f.insert(flag) }
        if #available(iOS 17.0, *), t.contains(.toggleButton) { f.insert(.toggleButton) }
        return f
    }

    static func label(_ obj: AnyObject) -> String? {
        guard let l = obj.accessibilityLabel ?? nil, !l.isEmpty else { return nil }
        return l
    }

    static func identifier(_ obj: AnyObject) -> String? {
        guard let id = obj.accessibilityIdentifier ?? nil, !id.isEmpty else { return nil }
        return id
    }

    /// Role from the traits; "element" when they say nothing (the Mac's fallback for a node with
    /// no AX role — the class name of an AccessibilityNode would tell the reader nothing more).
    static func role(_ obj: AnyObject) -> String {
        genericRole(traits: traits(obj)) ?? "element"
    }

    static func value(_ obj: AnyObject, role: String) -> String? {
        guard let v = obj.accessibilityValue ?? nil, !v.isEmpty else { return nil }
        return role == "switch" || role == "checkbox" ? toggleValue(v) : v
    }

    static func isEnabled(_ obj: AnyObject) -> Bool { !traits(obj).contains(.notEnabled) }

    static func canPress(_ obj: AnyObject) -> Bool { isPressable(traits: traits(obj)) }

    /// `accessibilityActivate()` is the one public activation path for an AX-only element; UIKit
    /// and SwiftUI route it to the element's real action. Reported as success for any element
    /// that advertises press-ability, matching the Mac (some hosts fire the action yet return
    /// false).
    static func press(_ obj: AnyObject) -> Bool {
        guard canPress(obj) else { return false }
        _ = obj.accessibilityActivate?()
        return true
    }

    static func adjust(_ obj: AnyObject, up: Bool) -> Bool {
        guard traits(obj).contains(.adjustable) else { return false }
        if up { obj.accessibilityIncrement?() } else { obj.accessibilityDecrement?() }
        return true
    }

    private static let privateSetValueSel = NSSelectorFromString("_accessibilitySetValue:")

    /// Whether the element takes typed text on the AX layer. The public `accessibilityValue`
    /// setter only stores a string on a wrapper object; the one that reaches the hosted control
    /// is the assistive-tech entry `_accessibilitySetValue:`, which text-bearing elements
    /// implement and buttons do not.
    static func canSetValue(_ obj: AnyObject) -> Bool {
        obj.responds(to: privateSetValueSel) && !canPress(obj)
    }

    static func setValue(_ obj: AnyObject, text: String) -> Bool {
        guard canSetValue(obj) else { return false }
        _ = obj.perform(privateSetValueSel, with: text as NSString)
        return true
    }

    /// The element's screen frame in its host WINDOW's coordinates (what the view backend's
    /// `convert(to: nil)` yields), nil when there is no frame or no window to express it in.
    static func frameInWindow(of obj: AnyObject, in window: UIWindow?) -> CGRect? {
        guard let frame = obj.accessibilityFrame, frame.width > 0 || frame.height > 0,
              let window = window ?? hostView(of: obj)?.window else { return nil }
        let local: CGRect
        if let screen = window.windowScene?.screen {
            local = window.convert(frame, from: screen.coordinateSpace)
        } else {
            local = window.convert(frame, from: nil as UIView?)
        }
        guard local.origin.x.isFinite, local.origin.y.isFinite,
              local.width.isFinite, local.height.isFinite else { return nil }
        return local
    }

    static func center(_ obj: AnyObject) -> (x: Int, y: Int)? {
        guard let f = frameInWindow(of: obj, in: nil),
              let x = apSafeInt(f.midX), let y = apSafeInt(f.midY) else { return nil }
        return (x, y)
    }

    static func actions(_ obj: AnyObject) -> [String] {
        var a: [String] = []
        if canPress(obj) { a.append("activate") }
        if traits(obj).contains(.adjustable) { a += ["increment", "decrement"] }
        if canSetValue(obj) { a.append("setValue") }
        return a
    }

    /// Drive an AX-only element: the press, or the adjustable steps.
    static func perform(_ obj: AnyObject, action: String) -> Bool {
        switch action {
        case "increment": return adjust(obj, up: true)
        case "decrement": return adjust(obj, up: false)
        default: return press(obj)
        }
    }

    /// A `UINode` for an AX-only element (no UIView behind it — e.g. SwiftUI's AccessibilityNode).
    static func node(for obj: AnyObject, ref: Int) -> UINode {
        let role = role(obj)
        let c = center(obj)
        return UINode(ref: ref, role: role, label: label(obj), value: value(obj, role: role),
                      identifier: identifier(obj), x: c?.x, y: c?.y,
                      enabled: isEnabled(obj), actions: actions(obj))
    }
}
#endif
