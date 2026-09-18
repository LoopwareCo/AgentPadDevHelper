import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// `Int(someCGFloat)` TRAPS on NaN/±infinity, and a live hierarchy really does contain such
/// frames (a view mid-layout, an unsatisfiable constraint, a collection-view cell being sized).
/// One of them anywhere in the tree would otherwise abort the whole host app —
/// `Swift runtime failure: Double value cannot be converted to Int` — during a snapshot walk,
/// which is a spectacularly bad failure mode for a debugging SDK embedded in someone else's app.
@inline(__always) func apSafeInt(_ v: CGFloat) -> Int? {
    guard v.isFinite, v >= CGFloat(Int.min), v <= CGFloat(Int.max) else { return nil }
    return Int(v)
}

/// Walks the app's OWN live view hierarchy and drives it IN-PROCESS — no system Accessibility
/// grant, no synthetic events. The same five operations the macOS AgentPad agent exposes over
/// AX (`ui_snapshot/find/act/setvalue/inspect`), but implemented against UIKit/AppKit views by
/// calling their real handlers, which is more reliable than synthesizing taps.
///
/// All methods must run on the main thread (UIKit/AppKit) — `DevToolHandler` hops there.
final class UIDriver {
    fileprivate final class WeakBox { weak var obj: AnyObject?; init(_ o: AnyObject) { obj = o } }
    private var registry: [Int: WeakBox] = [:]
    private var idByObject: [ObjectIdentifier: Int] = [:]
    private var nextId = 1
    /// Which control a grafted menu belongs to. A menu item has no back pointer to the button that
    /// owns its menu, and a pop-up's items are driven by SELECTING them on that button — so the
    /// walk remembers the owner as it grafts the items in (AppKit backend).
    fileprivate var menuOwners: [ObjectIdentifier: WeakBox] = [:]
    /// What the last `perform` actually DID, or why it refused. A driver that answers `ok` for an
    /// element it quietly did nothing to is undiagnosable from the other end — the caller goes on
    /// believing the row is selected — so the backends record an outcome here and `act` reports it.
    var actionNote: String?
    var actionRefusal: String?
    /// Refuse an action, with the reason `act` will print. Always returns false, so a `perform`
    /// branch reads `return refuse("…")`.
    func refuse(_ reason: String) -> Bool { actionRefusal = reason; return false }
    /// Succeed, noting what happened ("selected row 3 of 12"). Always returns true.
    func did(_ note: String) -> Bool { actionNote = note; return true }

    /// Keep a live object's ref STABLE across snapshots (so a ref from one `find`/`snapshot` still
    /// resolves in a later `act`/`inspect`), and just prune entries whose object was deallocated so
    /// the maps don't grow without bound.
    private func reset() {
        for (id, box) in registry where box.obj == nil { registry.removeValue(forKey: id) }
        idByObject = idByObject.filter { registry[$0.value] != nil }
        menuOwners = menuOwners.filter { $0.value.obj != nil }
    }
    private func register(_ obj: AnyObject) -> Int {
        let oid = ObjectIdentifier(obj)
        if let id = idByObject[oid], registry[id]?.obj === obj { return id }   // same object → same ref
        let id = nextId; nextId += 1
        registry[id] = WeakBox(obj); idByObject[oid] = id
        return id
    }
    private func element(_ ref: Int) -> AnyObject? { registry[ref]?.obj }

    // MARK: - Tools (return text exactly like the macOS AX dump)

    func snapshot(maxDepth: Int) -> String {
        reset()
        var out = "app: \(Self.appName)\n"
        for (i, root) in rootElements().enumerated() {
            out += walk(root, depth: 0, maxDepth: maxDepth, into: i == 0 ? nil : "window \(i)")
        }
        return out
    }

    func find(role: String?, label: String?) -> String {
        reset()
        var nodes: [UINode] = []
        for root in rootElements() { collect(root, depth: 0, maxDepth: 40, into: &nodes) }
        let matches = nodes.filter { n in
            let roleOK = role.map { n.role.range(of: $0, options: .caseInsensitive) != nil } ?? true
            let labelOK = label.map { (n.label ?? "").range(of: $0, options: .caseInsensitive) != nil } ?? true
            return (role != nil || label != nil) && roleOK && labelOK
        }
        guard !matches.isEmpty else { return "no matches in \(Self.appName)" }
        return "app: \(Self.appName) — matches:\n" + matches.map { $0.line() }.joined(separator: "\n")
    }

    func act(ref: Int, action: String?) -> String {
        guard let obj = element(ref) else { return "ERROR: unknown ref \(ref) (snapshot/find first)." }
        let name = action ?? "activate"
        actionNote = nil; actionRefusal = nil
        guard perform(obj, action: name) else {
            return "ERROR: [\(ref)] \(actionRefusal ?? "is not activatable.")"
        }
        return "ok: \(name) on [\(ref)]" + (actionNote.map { " — \($0)" } ?? "")
    }

    func setValue(ref: Int, text: String) -> String {
        guard let obj = element(ref) else { return "ERROR: unknown ref \(ref)." }
        return assign(obj, text: text) ? "ok: set [\(ref)] = \"\(text.prefix(40))\""
                                       : "ERROR: [\(ref)] has no settable value."
    }

    /// Write a PNG of one of the app's own windows. The app renders itself into a bitmap, so this
    /// works with no Screen Recording grant — the way to actually LOOK at a UI change from a
    /// headless/automated session where `screencapture` is refused.
    func shot(path: String, window: String?) -> String {
        guard path.hasPrefix("/") else { return "ERROR: 'path' must be absolute." }
        return capture(to: URL(fileURLWithPath: path), window: window)
    }

    func inspect(ref: Int) -> String {
        guard let obj = element(ref) else { return "ERROR: unknown ref \(ref)." }
        let node = makeNode(for: obj, ref: ref)
        return node.line() + "\n  value: \(node.value ?? "(none)")\n  actions: \(node.actions.isEmpty ? "(none)" : node.actions.joined(separator: ", "))"
    }

    /// Full text content of a subtree (or the whole app) in reading order — labels and values
    /// only, untruncated, no refs/roles/geometry. This is the cheap way to READ what's on screen
    /// (a transcript, a list, an alert): the same content as a screenshot at a fraction of the
    /// tokens. `ui_snapshot` stays the structural view; this is the prose view.
    func readText(ref: Int?, maxChars: Int) -> String {
        reset()
        let roots: [AnyObject]
        if let ref {
            guard let obj = element(ref) else { return "ERROR: unknown ref \(ref) (snapshot/find first)." }
            roots = [obj]
        } else {
            roots = rootElements()
        }
        var lines: [String] = []
        for root in roots { collectText(root, depth: 0, into: &lines) }
        guard !lines.isEmpty else { return "(no visible text)" }
        var out = ""
        for line in lines {
            if out.count + line.count + 1 > max(200, maxChars) {
                return out + "…(truncated at \(maxChars) chars — pass a ref to narrow, or raise maxChars)"
            }
            out += line + "\n"
        }
        return out
    }

    private func collectText(_ obj: AnyObject, depth: Int, into lines: inout [String]) {
        guard isVisible(obj), depth < 60 else { return }
        let node = makeNode(for: obj, ref: register(obj))
        if let label = node.label, !label.isEmpty, lines.last != label { lines.append(label) }
        if let value = node.value, !value.isEmpty, value != node.label, lines.last != value { lines.append(value) }
        for child in childElements(of: obj) { collectText(child, depth: depth + 1, into: &lines) }
    }
    /// Which view holds keyboard focus right now. The in-process actions above bypass the event
    /// path entirely, so this (with `key`) is how a focus-routing bug — "typing here should land
    /// in the message field" — is observed at all.
    ///
    /// With `window`, it first BRINGS THAT WINDOW UP: the app activates itself, and the window is
    /// ordered front and made key. In-process actions can open a window but never make it the KEY
    /// window of a background app, and surfaces that behave differently while they're being looked
    /// at — the environment pop-out only streams its 60 fps `active` tier while it is key — can't
    /// be exercised at all until something does this.
    func focus(window: String? = nil) -> String { focusReport(window: window) }

    /// Type `text`, or press one named key (`"space"`, `"up"`, `"cmd+f"`) / one explicit
    /// `keyCode`, as real key events posted to the app's own event queue — so local event
    /// monitors and the responder chain see them exactly as they see a keystroke. Unlike
    /// `ui_setvalue` this does NOT target an element: it tests where the keystroke LANDS.
    func key(text: String?, named: String? = nil, keyCode: Int? = nil,
             modifiers: [String] = [], window: String? = nil) -> String {
        sendKey(text: text, named: named, keyCode: keyCode, modifiers: modifiers, window: window)
    }

    // MARK: - Shared walk

    private func walk(_ obj: AnyObject, depth: Int, maxDepth: Int, into prefix: String?) -> String {
        guard isVisible(obj) else { return "" }
        let ref = register(obj)
        let node = makeNode(for: obj, ref: ref)
        var out = (prefix.map { String(repeating: "  ", count: depth) + "// \($0)\n" } ?? "") + node.line(indent: depth) + "\n"
        if depth < maxDepth {
            for child in childElements(of: obj) { out += walk(child, depth: depth + 1, maxDepth: maxDepth, into: nil) }
        }
        return out
    }

    private func collect(_ obj: AnyObject, depth: Int, maxDepth: Int, into acc: inout [UINode]) {
        guard isVisible(obj) else { return }
        let ref = register(obj)
        acc.append(makeNode(for: obj, ref: ref))
        if depth < maxDepth { for child in childElements(of: obj) { collect(child, depth: depth + 1, maxDepth: maxDepth, into: &acc) } }
    }
}

// MARK: - UIKit backend

#if canImport(UIKit)
private extension UIView {
    var ap_enclosingTableView: UITableView? {
        sequence(first: superview, next: { $0?.superview }).compactMap { $0 as? UITableView }.first
    }
    /// Depth-first search for the focused responder (UIKit exposes no direct accessor).
    var ap_firstResponder: UIResponder? {
        if isFirstResponder { return self }
        for sub in subviews { if let r = sub.ap_firstResponder { return r } }
        return nil
    }
}

extension UIDriver {
    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "app"
    }

    func rootElements() -> [AnyObject] {
        AXBridge.materializeIfNeeded()   // SwiftUI AX nodes before any walk (a no-op today, see it)
        var windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        // Alert/action-sheet windows (and some system windows) aren't always in a scene's window
        // list, so union the app-wide windows too. Deprecated but fine for a debug helper.
        windows += UIApplication.shared.windows
        var seen = Set<ObjectIdentifier>()
        return windows
            .filter { !$0.isHidden && $0.alpha > 0.01 && seen.insert(ObjectIdentifier($0)).inserted }
            .sorted { $0.windowLevel < $1.windowLevel }
    }

    func childElements(of obj: AnyObject) -> [AnyObject] {
        // Bar buttons aren't reachable/actionable as their private internal views, so expose the
        // UINavigationBar's UIBarButtonItems as first-class children (and skip the private button
        // subviews to avoid non-actionable duplicates).
        if let nav = obj as? UINavigationBar, let top = nav.items?.last {
            let items = (top.leftBarButtonItems ?? []) + (top.rightBarButtonItems ?? [])
            return items + (nav.subviews.filter(Self.keepsInWalk) as [AnyObject])
        }
        guard let v = obj as? UIView else {
            // An AX-only element (SwiftUI AccessibilityNode): descend through its own AX children.
            // Views are excluded — anything view-backed is reached by the view walk.
            return obj is UIBarButtonItem ? [] : AXBridge.elementChildren(of: obj)
        }
        // The Back platter's control is the whole button: its visual-provider subviews carry the
        // button trait but no action, and would read as a second, dead "button".
        if Self.isUnrepresentedBarButton(v) { return [] }
        var kids: [AnyObject] = v.subviews.filter(Self.keepsInWalk)
        // SwiftUI hosting views draw their controls without any UIView behind them; the elements
        // live only on the (materialized) AX layer, so graft those in as extra children.
        if AXBridge.isGraftPoint(v) { kids += AXBridge.elementChildren(of: v) }
        return kids
    }

    /// Drop the private bar-button container/control subtrees everywhere — they're duplicates of
    /// the actionable UIBarButtonItem nodes — EXCEPT a bar button no synthesized item stands for.
    private static func keepsInWalk(_ v: UIView) -> Bool {
        !isBarButtonInternal(v) || isUnrepresentedBarButton(v)
    }

    /// A private bar-button CONTROL (`_UIButtonBarButton`) whose `UIBarButtonItem` is not among
    /// the navigation item's left/right items — on iOS 26 that is the Back button, which lives
    /// inside the SwiftUI-rendered platter (`NavigationButtonBar.ItemWrapperView`) and is backed by
    /// an internal item the walk never synthesizes. It's a real `UIControl`, so it's driven like
    /// one; it just must not be filtered away with the duplicates.
    static func isUnrepresentedBarButton(_ v: UIView) -> Bool {
        guard v is UIControl, String(describing: type(of: v)).contains("ButtonBarButton") else { return false }
        guard let nav = sequence(first: v.superview, next: { $0?.superview }).compactMap({ $0 as? UINavigationBar }).first,
              let top = nav.items?.last else { return true }
        let represented = ((top.leftBarButtonItems ?? []) + (top.rightBarButtonItems ?? []))
            .compactMap { $0.value(forKey: "view") as? UIView }
        return !represented.contains { $0 === v }
    }

    func isVisible(_ obj: AnyObject) -> Bool {
        if obj is UIBarButtonItem { return true }
        guard let v = obj as? UIView else { return true }   // AX elements are walked as-is
        return !v.isHidden && v.alpha > 0.01
    }

    func makeNode(for obj: AnyObject, ref: Int) -> UINode {
        if let item = obj as? UIBarButtonItem {
            return UINode(ref: ref, role: "button", label: Self.barLabel(item), value: nil,
                          identifier: item.accessibilityIdentifier, enabled: item.isEnabled, actions: ["activate"])
        }
        guard let v = obj as? UIView else { return AXBridge.node(for: obj, ref: ref) }
        let center = v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        return UINode(ref: ref, role: Self.role(v), label: Self.label(v), value: Self.value(v),
                      identifier: v.accessibilityIdentifier?.isEmpty == false ? v.accessibilityIdentifier : nil,
                      x: apSafeInt(center.x), y: apSafeInt(center.y),
                      enabled: (v as? UIControl)?.isEnabled ?? true, actions: Self.actions(v))
    }

    func perform(_ obj: AnyObject, action: String) -> Bool {
        if action == "focus" { return (obj as? UIResponder)?.becomeFirstResponder() ?? false }
        if let item = obj as? UIBarButtonItem {
            guard let action = item.action else { return false }
            return UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
        }
        // AX-only elements (SwiftUI controls, iOS 26 nav-bar platter items) are driven on the AX layer.
        guard let v = obj as? UIView else { return AXBridge.perform(obj, action: action) }
        // Table/collection cells: route through the real selection delegate.
        if let cell = v as? UITableViewCell, let table = cell.ap_enclosingTableView, let ip = table.indexPath(for: cell) {
            table.selectRow(at: ip, animated: false, scrollPosition: .none)
            table.delegate?.tableView?(table, didSelectRowAt: ip)
            return true
        }
        // iOS 26/27 alert buttons (`_UIInterfaceActionCustomViewRepresentationView`) are custom
        // representation views whose `accessibilityActivate()` is a NO-OP — route through the
        // owning UIAlertController instead: match the action by its title and run its handler,
        // then dismiss. (The general fix — synthesized touches — is tracked separately; this
        // covers the alert case that blocks any flow ending in a confirm button.)
        if NSStringFromClass(type(of: v)).contains("ActionCustomViewRepresentationView") {
            var responder: UIResponder? = v
            while let cur = responder, !(cur is UIAlertController) { responder = cur.next }
            if let alert = responder as? UIAlertController,
               let title = v.accessibilityLabel,
               let action = alert.actions.first(where: { $0.title == title && $0.isEnabled }) {
                alert.dismiss(animated: false) {
                    if let block = action.value(forKey: "handler") {
                        typealias Handler = @convention(block) (UIAlertAction) -> Void
                        unsafeBitCast(block as AnyObject, to: Handler.self)(action)
                    }
                }
                return true
            }
        }
        // The Back platter (`_UIButtonBarButton`, see isUnrepresentedBarButton): its AX activate
        // only works once UIKit's accessibility bundle is loaded, and its touch-up actions are
        // internal, so pop the way the button does. A controller-managed bar must be popped
        // through its UINavigationController (popping the bar directly raises), a bare bar
        // through the bar itself.
        if Self.isUnrepresentedBarButton(v) {
            if v.accessibilityActivate() { return true }
            if let nav = sequence(first: v.superview, next: { $0?.superview }).compactMap({ $0 as? UINavigationBar }).first,
               nav.backItem != nil {
                if let controller = nav.delegate as? UINavigationController {
                    return controller.popViewController(animated: true) != nil
                }
                nav.popItem(animated: true)
                return true
            }
        }
        // Prefer accessibilityActivate(): UIKit routes it to the real action for buttons, BAR
        // buttons (whose internal control ignores touchUpInside), switches, etc. Fall back to
        // sendActions for custom UIControls that don't implement activation.
        if v.accessibilityActivate() { return true }
        if let control = v as? UIControl {
            control.sendActions(for: .primaryActionTriggered)
            control.sendActions(for: .touchUpInside)
            return true
        }
        return false
    }

    func capture(to url: URL, window: String?) -> String {
        let windows = rootElements().compactMap { ($0 as? UIView)?.window }
        let target = window.flatMap { want in
            windows.first { ($0.rootViewController?.title ?? "").range(of: want, options: .caseInsensitive) != nil }
        } ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? windows.last
        guard let win = target else { return "ERROR: no visible window to capture." }
        let image = UIGraphicsImageRenderer(bounds: win.bounds).image { _ in
            win.drawHierarchy(in: win.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else { return "ERROR: could not encode PNG." }
        do { try data.write(to: url) } catch { return "ERROR: \(error.localizedDescription)" }
        return "ok: wrote \(url.path) — \(Int(win.bounds.width))x\(Int(win.bounds.height)) pts"
    }

    /// Which responder holds keyboard focus (UIKit: the first responder in the key window). iOS has
    /// no window activation to perform, so `window` is accepted and ignored.
    func focusReport(window: String? = nil) -> String {
        let windows = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
        guard let win = windows.first else { return "no key window" }
        guard let fr = win.ap_firstResponder else { return "key window: no first responder" }
        var out = "firstResponder: \(type(of: fr))"
        if let v = fr as? UIView, let id = v.accessibilityIdentifier { out += " #\(id)" }
        return out
    }

    /// UIKit has no equivalent of posting into the app's own event queue; text input arrives
    /// through the keyboard system, which a hosted process can't drive. `ui_setvalue` instead.
    func sendKey(text: String?, named: String?, keyCode: Int?, modifiers: [String], window: String?) -> String {
        "ERROR: ui_key is macOS-only (no in-process key events on iOS) — use ui_setvalue."
    }

    func assign(_ obj: AnyObject, text: String) -> Bool {
        // AX-only elements (SwiftUI text fields): the AX value setter is the only input path.
        if !(obj is UIView) { return AXBridge.setValue(obj, text: text) }
        if let tf = obj as? UITextField { tf.text = text; tf.sendActions(for: .editingChanged); return true }
        if let tv = obj as? UITextView { tv.text = text; tv.delegate?.textViewDidChange?(tv); return true }
        return false
    }

    static func role(_ v: UIView) -> String {
        switch v {
        case is UISwitch: return "switch"
        case is UITextField: return "textField"
        case is UITextView: return "textView"
        case is UIButton: return "button"
        case is UILabel: return "text"
        case is UITableViewCell, is UICollectionViewCell: return "cell"
        case is UITableView: return "table"
        case is UICollectionView: return "collection"
        case is UIImageView: return "image"
        case is UINavigationBar: return "navBar"
        // A private control that calls itself a button on the AX layer, or IS the nav bar's
        // Back platter (`_UIButtonBarButton`), reads as one — not as an anonymous "control".
        case is UIControl:
            return v.accessibilityTraits.contains(.button) || isUnrepresentedBarButton(v) ? "button" : "control"
        default: return String(describing: type(of: v))
        }
    }
    static func label(_ v: UIView) -> String? {
        if let nav = v as? UINavigationBar { return nav.topItem?.title ?? v.accessibilityLabel }
        if let l = v.accessibilityLabel, !l.isEmpty { return l }
        // The iOS 26 Back platter carries no label of its own (VoiceOver names it through the
        // navigation bar), so it is named here — it's the only bar button the item walk can't.
        if isUnrepresentedBarButton(v) { return "Back" }
        if let b = v as? UIButton { return b.currentTitle ?? b.titleLabel?.text }
        if let l = v as? UILabel { return l.text }
        if let tf = v as? UITextField { return tf.placeholder }
        return nil
    }
    static func barLabel(_ item: UIBarButtonItem) -> String? {
        if let t = item.title, !t.isEmpty { return t }
        if let l = item.accessibilityLabel, !l.isEmpty { return l }
        // System items (.add, .done, …) have no title; borrow their backing view's a11y label
        // ("Add", "Wi-Fi", …). Debug-only helper, so the private `view` accessor is acceptable.
        if let v = item.value(forKey: "view") as? UIView, let l = v.accessibilityLabel, !l.isEmpty { return l }
        return nil
    }
    /// Private bar-button container/control classes whose taps we drive via the UIBarButtonItem
    /// instead (so we skip them when walking a navigation bar's subviews).
    static func isBarButtonInternal(_ v: UIView) -> Bool {
        let n = String(describing: type(of: v))
        return n.contains("ButtonBar") || n.contains("BarButton")
    }
    static func value(_ v: UIView) -> String? {
        // Before the AX value: once UIKit's accessibility bundle is loaded (AXBridge) a switch's
        // accessibilityValue is "1"/"0", and the walk's output must not change with it.
        if let sw = v as? UISwitch { return sw.isOn ? "on" : "off" }
        if let val = v.accessibilityValue, !val.isEmpty { return val }
        if let tf = v as? UITextField { return tf.text }
        if let tv = v as? UITextView { return tv.text }
        return nil
    }
    private static func actions(_ v: UIView) -> [String] {
        var a: [String] = []
        if v is UIControl || v is UITableViewCell || v is UICollectionViewCell { a.append("activate") }
        // Accessibility elements that aren't UIControls still activate through
        // `accessibilityActivate()` — modern UIKit chrome (alert ACTION views, nav-bar platter
        // items) is built this way, and gating on UIControl made every iOS 27 alert button read
        // as "not activatable" while the perform path below would have handled it fine.
        else if v.isAccessibilityElement && v.accessibilityTraits.contains(.button) { a.append("activate") }
        if v is UITextField || v is UITextView { a.append("setValue") }
        return a
    }
}
#endif

// MARK: - AppKit backend

#if !canImport(UIKit) && canImport(AppKit)
extension UIDriver {
    static var appName: String { ProcessInfo.processInfo.processName }

    func rootElements() -> [AnyObject] {
        // Root at the window's frame view (`contentView.superview`), not `contentView`, so the
        // titlebar + toolbar are walked too — otherwise custom toolbar controls (e.g. the project
        // title control) are invisible and unreachable. Fall back to `contentView` if there's no
        // frame view. An open NSPopover is its own window, so it shows up here as another root.
        AXBridge.materializeIfNeeded()   // make SwiftUI build its AX nodes before any walk
        return NSApp?.windows.filter { $0.isVisible }.compactMap { $0.contentView?.superview ?? $0.contentView } ?? []
    }

    func childElements(of obj: AnyObject) -> [AnyObject] {
        guard let v = obj as? NSView else {
            // An AX-only element (SwiftUI AccessibilityNode): descend through its own AX
            // children. Views are excluded — anything view-backed is reached by the view walk.
            return AXBridge.elementChildren(of: obj)
        }
        var kids: [AnyObject] = v.subviews
        // SwiftUI hosting views draw most controls without any NSView behind them; the elements
        // live only on the (materialized) AX layer, so graft those in as extra children.
        if AXBridge.isHostingView(v) { kids += AXBridge.elementChildren(of: v) }
        // A button that OWNS a menu (a pop-up, or the app's "•••" / "＋" menu buttons) hides its
        // real choices in NSMenuItems no view stands for — the same problem UIKit's bar buttons
        // have above, and the same answer: graft the items in as children.
        if let b = v as? NSButton, let menu = b.menu {
            menuOwners[ObjectIdentifier(menu)] = WeakBox(b)
            kids += Self.menuChildren(menu)
        }
        return kids
    }

    /// A menu's drivable items. Menus in AppKit are filled LAZILY — `menuNeedsUpdate` is where the
    /// app puts its items — so ask for that update first, exactly as AppKit does before showing
    /// one; without it a menu button reads as having no choices at all.
    static func menuChildren(_ menu: NSMenu) -> [AnyObject] {
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }
    }

    /// The control whose menu this item belongs to, as noted by the walk that grafted it in.
    func menuOwner(of item: NSMenuItem) -> AnyObject? {
        guard let menu = item.menu else { return nil }
        return menuOwners[ObjectIdentifier(menu)]?.obj
    }

    func isVisible(_ obj: AnyObject) -> Bool {
        guard let v = obj as? NSView else { return !(obj is NSCell) }   // AX elements are walked as-is
        return !v.isHidden
    }

    func makeNode(for obj: AnyObject, ref: Int) -> UINode {
        if let mi = obj as? NSMenuItem {
            return UINode(ref: ref, role: "menuItem", label: mi.title,
                          value: mi.state == .on ? "on" : nil, identifier: mi.identifier?.rawValue,
                          enabled: mi.isEnabled,
                          actions: mi.action == nil && mi.submenu == nil ? [] : ["activate"])
        }
        guard let v = obj as? NSView else { return AXBridge.node(for: obj, ref: ref) }
        // A WINDOW root reports as the window it is. `rootElements` roots each window at its frame
        // view (`NSThemeFrame`), whose AX layer carries no name at all — so a multi-window snapshot
        // was a list of anonymous `NSThemeFrame`s and the only way to tell one window from another
        // was to read the first label INSIDE it. That is how the environment pop-out came to be
        // read as "Paused" (its status chip) and Settings ▸ VMs & Simulators as "Server:" (the
        // pane's server chooser). The window's own title is the answer, and `isSheet` distinguishes
        // a sheet — a modal put up ON a window — from a window of its own.
        if let win = v.window, (win.contentView?.superview ?? win.contentView) === v {
            return UINode(ref: ref, role: win.isSheet ? "sheet" : "window",
                          label: win.title.isEmpty ? nil : win.title,
                          identifier: v.identifier?.rawValue, actions: [])
        }
        let center = v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        return UINode(ref: ref, role: Self.role(v), label: Self.label(v), value: Self.value(v),
                      identifier: v.identifier?.rawValue,
                      x: apSafeInt(center.x), y: apSafeInt(center.y),
                      enabled: (v as? NSControl)?.isEnabled ?? true, actions: Self.actions(v))
    }

    func perform(_ obj: AnyObject, action: String) -> Bool {
        // A grafted menu item. A CHOOSER pop-up's items carry the button's own action rather than
        // one of their own, and picking one is a selection — so select it on the button the walk
        // saw it under, then send that action. Everything else (pull-downs, plain menus) is its
        // item's target/action, sent the way NSMenu sends it.
        if let mi = obj as? NSMenuItem {
            guard mi.isEnabled else { return refuse("is a disabled menu item.") }
            if let popUp = menuOwner(of: mi) as? NSPopUpButton, !popUp.pullsDown {
                popUp.select(mi)
                popUp.sendAction(popUp.action, to: popUp.target)
                return did("chose \"\(mi.title)\"")
            }
            guard let sel = mi.action else { return refuse("is a menu item with no action (a heading, or the parent of a submenu).") }
            return NSApp.sendAction(sel, to: mi.target, from: mi) ? did("chose \"\(mi.title)\"")
                 : refuse("is a menu item whose action \(sel) nothing answered.")
        }
        // AX-only elements (SwiftUI controls) have exactly one way to be driven: the AX press.
        guard let v = obj as? NSView else {
            guard AXBridge.canPress(obj) else { return refuse("has no press on its accessibility layer.") }
            return AXBridge.press(obj)
        }
        // "focus" puts KEYBOARD FOCUS on the element (a table row focuses its table, the way
        // clicking a row does) without activating it — the starting state for a `ui_key` test.
        if action == "focus" {
            let target: NSView = (v is NSTableView) ? v : (v.ap_enclosingTableView ?? v)
            guard let window = v.window else { return refuse("is not in a window, so nothing can focus it.") }
            guard window.makeFirstResponder(target) else { return refuse("refused first-responder status.") }
            return did("focused \(type(of: target))")
        }
        // Scroll before the NSControl branch: NSTableView IS an NSControl, and a scroll request
        // aimed at a table must not turn into a performClick.
        if action == "scrollDown" || action == "scrollUp" {
            guard let sv = (v as? NSScrollView) ?? v.enclosingScrollView ?? v.subviews.compactMap({ $0 as? NSScrollView }).first else {
                return refuse("is not in a scroll view, so there is nothing to \(action).")
            }
            let clip = sv.contentView
            let dy = clip.bounds.height * 0.8 * (action == "scrollDown" ? 1 : -1)
            var origin = clip.bounds.origin
            origin.y += clip.isFlipped ? dy : -dy
            let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
            clip.scroll(to: constrained)
            sv.reflectScrolledClipView(clip)
            return did("scrolled \(action == "scrollDown" ? "down" : "up") one page")
        }
        // Open/close an outline row from the ROW — the disclosure triangle is one small button
        // drawn inside it, and a caller who has the row should not have to go find it.
        // `toggle` is ALSO the natural word for flipping a checkbox or a switch, so it only means
        // the disclosure when this view's row really has something to open; otherwise it falls
        // through to activation below. `expand`/`collapse` are outline-only and say so.
        if let want = RowDriver.Expansion(action: action),
           want != .toggle || RowDriver.expandableRow(of: v) != nil {
            guard let outcome = RowDriver.setExpansion(want, forRowOf: v) else {
                return refuse("is not inside an NSOutlineView row, so there is nothing to \(action).")
            }
            return report(outcome)
        }
        // A button that owns a menu is a MENU button: `performClick` starts modal menu tracking,
        // which holds the main thread for as long as the menu is up — the driver's next call would
        // never be serviced, so it reads as a hang. Its items are grafted in as its children (see
        // `childElements`); press one of those instead.
        if action == "activate", let b = obj as? NSButton, b.menu != nil {
            return refuse("owns a menu — activate one of its items instead (the walk lists them as its children).")
        }
        // A table IS an NSControl, but clicking one does nothing unless the app wired an action to
        // it: what a caller means by "click the list" is one of its rows.
        if let table = obj as? NSTableView, table.action == nil {
            return refuse("is a list — act on one of its ROWS to select (the row view, its cell, or anything drawn inside one).")
        }
        // Only a control a click can actually MOVE is clicked. A static label, a file's icon
        // (`NSImageView` is an NSControl too) and any other action-less control click into the
        // void — they fall through to the row-selection branch below, which is exactly what a
        // caller aiming at a row's own text or icon means.
        if let c = obj as? NSControl, Self.clickDoesSomething(c) {
            guard c.isEnabled else { return refuse("is disabled.") }
            c.performClick(nil)
            return did("clicked \(Self.role(v))")
        }
        // Table/outline rows: select through the real delegate, the way a click does. (Row views
        // carry no target/action, so without this a list — the sidebar's sessions, the inspector's
        // Changes, a file browser — is walkable but not clickable, and nothing downstream of a
        // selection can be driven at all.) See `RowDriver`.
        var rowRefusal: String?
        if let outcome = RowDriver.select(rowOf: v) {
            if case .refused(let why) = outcome { rowRefusal = why } else { return report(outcome) }
        }
        // Custom controls (e.g. the toolbar project/status title) carry no target/action — they're
        // driven by a click gesture recognizer. Invoke its action directly, the same way a click
        // would, so these are actionable without synthesizing a system event.
        for case let click as NSClickGestureRecognizer in v.gestureRecognizers {
            if let action = click.action, NSApp.sendAction(action, to: click.target, from: click) { return true }
        }
        // Last resort: views that are actionable only on the AX layer. The one that matters is
        // NSToolbarItemViewer — on macOS 26+ a toolbar item's label AND press-ability live here,
        // while the inner control (if any) is an anonymous SwiftUI-rendered shell.
        if AXBridge.canPress(v) { return AXBridge.press(v) }
        // Nothing did anything, so say so — with the row's reason when there was one, since a
        // caller aiming at a list row wants to hear about the row, not about the view's class.
        return refuse(rowRefusal ?? ("has no action: it is not a control, not inside a table row, carries no click gesture, and offers no press on its accessibility layer (role \(Self.role(v)))."
            // A view that does its own click handling is the one case worth naming: the driver
            // deliberately doesn't synthesize mouse events (a view that runs its own tracking loop
            // would hold the main thread until a mouseUp that is never coming).
            + (Self.handlesItsOwnClicks(v) ? " It handles clicks in its own mouseDown, which is not synthesized — act on its enclosing row, or give it an accessibility press." : "")))
    }

    /// Can `performClick` on this control actually do anything? It sends the control's action if
    /// there is one, and flips a checkbox / radio / switch / segmented control even when there
    /// isn't. Everything else — an image view, a static label, a custom control wired some other
    /// way — is a silent no-op, and reporting `ok` for one is the whole bug this file's rules are
    /// about.
    static func clickDoesSomething(_ c: NSControl) -> Bool {
        if c.action != nil { return true }
        if let b = c as? NSButton { return axRole(b) == .checkBox || axRole(b) == .radioButton }
        return c is NSSwitch || c is NSSegmentedControl
    }

    /// Does this view implement `mouseDown` itself, rather than inheriting NSView's?
    static func handlesItsOwnClicks(_ v: NSView) -> Bool {
        let sel = #selector(NSView.mouseDown(with:))
        return class_getMethodImplementation(type(of: v), sel) != class_getMethodImplementation(NSView.self, sel)
    }

    /// Report a `RowDriver` outcome as this driver's own note/refusal.
    private func report(_ outcome: RowDriver.Outcome) -> Bool {
        switch outcome {
        case .done(let note): return did(note)
        case .refused(let why): return refuse(why)
        }
    }

    func capture(to url: URL, window: String?) -> String {
        let windows = (NSApp?.windows ?? []).filter { $0.isVisible }
        let target = window.flatMap { want in
            windows.first { $0.title.range(of: want, options: .caseInsensitive) != nil }
        } ?? NSApp?.keyWindow ?? windows.last
        // Capture the frame view when there is one, so the titlebar/toolbar is in the picture too.
        guard let win = target, let view = win.contentView?.superview ?? win.contentView else {
            return "ERROR: no visible window\(window.map { " matching \"\($0)\"" } ?? "") to capture."
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return "ERROR: could not make a bitmap for \(Int(view.bounds.width))x\(Int(view.bounds.height))."
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "ERROR: could not encode PNG." }
        do { try data.write(to: url) } catch { return "ERROR: \(error.localizedDescription)" }
        return "ok: wrote \(url.path) — window \"\(win.title)\", \(rep.pixelsWide)x\(rep.pixelsHigh) px"
    }

    /// The key window's first responder, plus the field editor's delegate when one is focused (the
    /// editor is a shared NSTextView, so the interesting identity is the field BEING edited), and
    /// whether it's editable — the distinction focus-routing code keys on.
    func focusReport(window: String? = nil) -> String {
        let visible = (NSApp?.windows ?? []).filter { $0.isVisible }
        let named = window.flatMap { want in visible.first { $0.title.range(of: want, options: .caseInsensitive) != nil } }
        // A named window is BROUGHT UP first: activate the app, order it front, make it key — the
        // state a user's own click would leave it in. Self-activation is all a hosted process can
        // do; if the app is refused it, the report's `key=` tells the caller so rather than
        // pretending it worked.
        if let want = window {
            guard let named else { return "ERROR: no visible window whose title contains " + want + "." }
            NSApp?.activate(ignoringOtherApps: true)
            named.makeKeyAndOrderFront(nil)
        }
        guard let win = named ?? NSApp?.keyWindow ?? NSApp?.mainWindow ?? visible.first else {
            return "no visible window"
        }
        guard let fr = win.firstResponder else { return "window \"\(win.title)\": no first responder" }
        var out = "window \"\(win.title)\" (key=\(win.isKeyWindow)) firstResponder: \(type(of: fr))"
        if let text = fr as? NSText {
            out += " — NSText editable=\(text.isEditable)"
            if let editing = win.fieldEditor(false, for: nil) === text ? (text.delegate as AnyObject?) : nil {
                out += ", fieldEditor for \(type(of: editing))"
            }
        }
        if let v = fr as? NSView, let id = v.identifier?.rawValue { out += " #\(id)" }
        return out
    }

    func assign(_ obj: AnyObject, text: String) -> Bool {
        // AX-only elements (SwiftUI text fields): the AX value setter is the real input path.
        if !(obj is NSView) { return AXBridge.setValue(obj, text: text) }
        // Numeric controls: parse the text and drive them like a user gesture (value + action).
        if let s = obj as? NSSlider, let d = Double(text) { s.doubleValue = d; s.sendAction(s.action, to: s.target); return true }
        if let st = obj as? NSStepper, let d = Double(text) { st.doubleValue = d; st.sendAction(st.action, to: st.target); return true }
        if let tf = obj as? NSTextField { tf.stringValue = text; tf.sendAction(tf.action, to: tf.target); return true }
        // `string =` alone mutates the storage silently — `didChangeText()` is what posts
        // NSText.didChangeNotification, so the view's delegate sees the edit like a typed one.
        if let tv = obj as? NSTextView { tv.string = text; tv.didChangeText(); return true }
        return false
    }

    /// The real AX role of a view. **Cell-backed controls answer `AXUnknown` at the VIEW level**
    /// on macOS 27 — `NSButton.accessibilityRole()` is `AXUnknown` while its `NSButtonCell` says
    /// `AXCheckBox` — so every checkbox in the app read as a plain `button` with no value, and a
    /// driver had no way to see whether a destructive toggle ("Run in a copy") was ticked. Ask the
    /// cell whenever the view has nothing to say.
    static func axRole(_ v: NSView) -> NSAccessibility.Role? {
        if let own = v.accessibilityRole(), own != .unknown { return own }
        return (v as? NSControl)?.cell?.accessibilityRole()
    }

    static func role(_ v: NSView) -> String {
        switch v {
        case let b as NSButton:
            switch axRole(b) {
            case .some(.checkBox): return "checkbox"
            case .some(.radioButton): return "radio"
            default: return "button"
            }
        case is NSSwitch: return "switch"
        case let tf as NSTextField: return tf.isEditable ? "textField" : "text"
        case is NSTextView: return "textView"
        case is NSImageView: return "image"
        case is NSTableView: return "table"
        // A row and its cell read as what they ARE, not as the app's private subclass name
        // (`InspectorFileCell`) — the same vocabulary the iOS walk uses, so `ui_find role:row`
        // finds the thing a caller means to click.
        case is NSTableRowView: return "row"
        case is NSTableCellView: return "cell"
        case is NSScrollView: return "scrollView"
        case is NSControl: return "control"
        default:
            // Views whose real identity lives on the AX layer (NSToolbarItemViewer is
            // role=AXButton there) read as their generic role instead of a private class name.
            if let raw = AXBridge.rawRole(v), let generic = AXBridge.genericRole(raw), generic != "group" {
                return generic
            }
            return String(describing: type(of: v))
        }
    }
    static func label(_ v: NSView) -> String? {
        if let l = v.accessibilityLabel(), !l.isEmpty { return l }
        if let b = v as? NSButton { return b.title }
        if let tf = v as? NSTextField {
            if !tf.isEditable { return tf.stringValue }
            // An editable field is NAMED by its placeholder (what iOS already does) — it's also
            // the only handle a SwiftUI TextField's platform view carries.
            if let p = tf.placeholderString, !p.isEmpty { return p }
        }
        // A custom control wired with a click gesture (e.g. the toolbar project title) has no title
        // of its own — surface its first descendant label so it's findable by its visible text.
        if v.gestureRecognizers.contains(where: { $0 is NSClickGestureRecognizer }) {
            return firstLabelText(in: v)
        }
        return nil
    }
    /// Depth-first text of the first non-empty descendant `NSTextField` — a label for container
    /// controls that draw their text with child labels rather than a `title`.
    private static func firstLabelText(in v: NSView) -> String? {
        for sub in v.subviews {
            if let tf = sub as? NSTextField, !tf.stringValue.isEmpty { return tf.stringValue }
            if let t = firstLabelText(in: sub) { return t }
        }
        return nil
    }
    static func value(_ v: NSView) -> String? {
        if let tf = v as? NSTextField, tf.isEditable { return tf.stringValue }
        if let tv = v as? NSTextView { return tv.string }
        if let sw = v as? NSSwitch { return stateString(sw.state) }
        // Checkboxes / radios carry a meaningful on/off/mixed state; momentary push buttons don't.
        if let b = v as? NSButton, axRole(b) == .checkBox || axRole(b) == .radioButton {
            return stateString(b.state)
        }
        return nil
    }
    private static func stateString(_ s: NSControl.StateValue) -> String {
        switch s { case .on: return "on"; case .mixed: return "mixed"; default: return "off" }
    }
    private static func actions(_ v: NSView) -> [String] {
        var a: [String] = []
        // A menu button isn't activatable in-process (see `perform`) — its items are.
        if let b = v as? NSButton, b.menu != nil { return [] }
        // Mirror `perform` exactly, or the walk promises something the act won't do (and vice
        // versa): a control counts only when a click can move it (a list is a container of rows;
        // a static label or an icon clicks into the void), while a click gesture or an AX press
        // counts wherever it is.
        let clickable = (v as? NSControl).map { c in
            (c as? NSTableView).map { $0.action != nil } ?? clickDoesSomething(c)
        } ?? false
        let row = RowDriver.rowActions(of: v)                   // one lookup, not one per question
        if clickable
            || v.gestureRecognizers.contains(where: { $0 is NSClickGestureRecognizer })
            || AXBridge.canPress(v) {                           // AX-layer actionability (toolbar items)
            a.append("activate")
        } else if row.selectable {
            a.append("activate")                                // a row, its cell, or anything in one: selects
        }
        if let expansion = row.expansion { a.append(expansion) }
        if let tf = v as? NSTextField, tf.isEditable { a.append("setValue") }
        if v is NSTextView { a.append("setValue") }
        return a
    }
}
#endif
