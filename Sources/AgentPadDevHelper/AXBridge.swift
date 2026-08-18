import Foundation

#if !canImport(UIKit) && canImport(AppKit)
import AppKit

/// In-process bridge to the surfaces the NSView walk can't see: SwiftUI content and (macOS 26+)
/// the SwiftUI-rendered internals of AppKit controls, most visibly toolbar items.
///
/// SwiftUI is fully accessibility-compatible — but its AX tree is built LAZILY, only once an
/// assistive client announces itself. Until then `NSHostingView.accessibilityChildren()` returns
/// nothing, which is easily misread as "SwiftUI dropped accessibility". `materializeIfNeeded()`
/// flips the same app-level flag VoiceOver sets (`AXEnhancedUserInterface`), after which SwiftUI
/// vends its `AccessibilityNode` objects to plain in-process calls — no system Accessibility
/// grant, no AX server round trip, sandbox-safe.
///
/// Those nodes answer the modern `NSAccessibilityProtocol` *messages* (role, label, value,
/// press…) but do not declare Swift protocol conformance, so `as? NSAccessibilityProtocol`
/// fails on them — every accessor here goes through `AnyObject` dynamic lookup instead.
enum AXBridge {
    private static var materialized = false

    /// Make SwiftUI (and AppKit's SwiftUI-backed internals) build their AX node trees.
    /// Idempotent; call before any walk. Main thread (the driver already hops there).
    static func materializeIfNeeded() {
        guard !materialized, let app = NSApp else { return }
        materialized = true
        // The legacy setter takes object arguments, so it's callable through `perform` without
        // ABI games. Left ON for the process lifetime: dropping it back would freeze the node
        // tree for views created later. Dev builds only, so the known cosmetic side effects of
        // the flag (VoiceOver-style window animations in a few apps) are acceptable.
        let sel = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: sel) {
            _ = app.perform(sel, with: true as NSNumber, with: "AXEnhancedUserInterface" as NSString)
        }
    }

    /// True for the public SwiftUI hosting views (`NSHostingView<...>`), whose AX children are
    /// the only route to the SwiftUI elements inside. Deliberately does NOT match AppKit's
    /// internal `_NSCoreHostingView` render layers — those sit *inside* real controls and
    /// grafting there would duplicate the control itself.
    static func isHostingView(_ v: NSView) -> Bool {
        String(describing: type(of: v)).hasPrefix("NSHostingView")
    }

    /// AX-only children of an element: the modern children list minus anything the view walk
    /// already covers (NSViews) and minus platform cells (`_SystemTextFieldCell` et al.), whose
    /// backing control appears in the view tree as a subview.
    static func elementChildren(of obj: AnyObject) -> [AnyObject] {
        let kids = (obj.accessibilityChildren?() ?? []).map { $0 as AnyObject }
        return kids.filter { !($0 is NSView) && !($0 is NSCell) }
    }

    static func label(_ obj: AnyObject) -> String? {
        if let l = obj.accessibilityLabel?() ?? nil, !l.isEmpty { return l }
        if let t = obj.accessibilityTitle?() ?? nil, !t.isEmpty { return t }
        return nil
    }

    static func identifier(_ obj: AnyObject) -> String? {
        guard let id = obj.accessibilityIdentifier?() ?? nil, !id.isEmpty else { return nil }
        return id
    }

    static func rawRole(_ obj: AnyObject) -> String? {
        (obj.accessibilityRole?() ?? nil)?.rawValue
    }

    /// Map an AX role onto the driver's small shared role vocabulary (UINode.role).
    static func genericRole(_ raw: String) -> String? {
        switch raw {
        case "AXButton": return "button"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "radio"
        case "AXTextField": return "textField"
        case "AXTextArea": return "textView"
        case "AXStaticText": return "text"
        case "AXImage": return "image"
        case "AXGroup": return "group"
        case "AXToolbar": return "toolbar"
        case "AXPopUpButton", "AXMenuButton": return "popUpButton"
        case "AXSlider": return "slider"
        case "AXSwitch": return "switch"
        case "AXLink": return "link"
        case "AXList": return "list"
        case "AXTable", "AXOutline": return "table"
        default: return nil
        }
    }

    static func value(_ obj: AnyObject, role: String?) -> String? {
        // Several @objc overloads share this name — pin the NSAccessibilityProtocol signature.
        guard let getter = obj.accessibilityValue as (() -> Any?)?, let v = getter() else { return nil }
        // Checkbox/switch values arrive as NSNumber 0/1 — render them the way the view
        // backend renders NSControl.StateValue.
        if role == "checkbox" || role == "switch" || role == "radio", let n = v as? NSNumber {
            return n.intValue == 0 ? "off" : (n.intValue == 1 ? "on" : "mixed")
        }
        let s = String(describing: v)
        return s.isEmpty ? nil : s
    }

    private static let pressSel = NSSelectorFromString("accessibilityPerformPress")
    private static let setValueSel = NSSelectorFromString("setAccessibilityValue:")

    static func canPress(_ obj: AnyObject) -> Bool {
        obj.isAccessibilitySelectorAllowed?(pressSel) ?? obj.responds(to: pressSel)
    }

    /// Perform the AX press. Some AppKit hosts (NSToolbarItemViewer) fire the action but still
    /// RETURN false from `accessibilityPerformPress`, so a press on an element that advertises
    /// press-ability is reported as success regardless of the raw return value.
    static func press(_ obj: AnyObject) -> Bool {
        guard canPress(obj) else { return false }
        _ = obj.accessibilityPerformPress?()
        return true
    }

    static func canSetValue(_ obj: AnyObject) -> Bool {
        obj.isAccessibilitySelectorAllowed?(setValueSel) ?? false
    }

    static func setValue(_ obj: AnyObject, text: String) -> Bool {
        guard canSetValue(obj) else { return false }
        obj.setAccessibilityValue?(text as NSString)
        return true
    }

    /// Center of the element in window coordinates (matching the view backend's `convert(to: nil)`),
    /// via the AX screen frame + the element's own window. nil coordinates when either is missing.
    static func center(_ obj: AnyObject) -> (x: Int, y: Int)? {
        guard let frame = obj.accessibilityFrame?(), frame.width > 0 || frame.height > 0 else { return nil }
        guard let win = (obj.accessibilityWindow?() ?? nil) as? NSWindow else { return nil }
        let local = win.convertFromScreen(frame)
        guard let x = apSafeInt(local.midX), let y = apSafeInt(local.midY) else { return nil }
        return (x, y)
    }

    /// A `UINode` for an AX-only element (no NSView behind it — e.g. SwiftUI's AccessibilityNode).
    static func node(for obj: AnyObject, ref: Int) -> UINode {
        let role = rawRole(obj).flatMap(genericRole) ?? rawRole(obj) ?? "element"
        var actions: [String] = []
        if canPress(obj) { actions.append("activate") }
        if canSetValue(obj) { actions.append("setValue") }
        let c = center(obj)
        return UINode(ref: ref, role: role, label: label(obj), value: value(obj, role: role),
                      identifier: identifier(obj), x: c?.x, y: c?.y,
                      enabled: obj.isAccessibilityEnabled?() ?? true, actions: actions)
    }
}
#endif
