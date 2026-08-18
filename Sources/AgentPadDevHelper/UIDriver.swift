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
    private final class WeakBox { weak var obj: AnyObject?; init(_ o: AnyObject) { obj = o } }
    private var registry: [Int: WeakBox] = [:]
    private var idByObject: [ObjectIdentifier: Int] = [:]
    private var nextId = 1

    /// Keep a live object's ref STABLE across snapshots (so a ref from one `find`/`snapshot` still
    /// resolves in a later `act`/`inspect`), and just prune entries whose object was deallocated so
    /// the maps don't grow without bound.
    private func reset() {
        for (id, box) in registry where box.obj == nil { registry.removeValue(forKey: id) }
        idByObject = idByObject.filter { registry[$0.value] != nil }
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
        return perform(obj, action: action ?? "activate") ? "ok: \(action ?? "activate") on [\(ref)]"
                                                           : "ERROR: [\(ref)] is not activatable."
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
    func focus() -> String { focusReport() }

    /// Type `text` as real key events posted to the app's own event queue, so local event
    /// monitors and the responder chain see them exactly as they see a keystroke. Unlike
    /// `ui_setvalue` this does NOT target an element: it tests where the keystroke LANDS.
    func key(text: String, window: String?) -> String { sendKey(text: text, window: window) }

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
            return items + (nav.subviews.filter { !Self.isBarButtonInternal($0) } as [AnyObject])
        }
        // Drop the private bar-button container/control subtrees everywhere — they're duplicates of
        // the actionable UIBarButtonItem nodes.
        return ((obj as? UIView)?.subviews ?? []).filter { !Self.isBarButtonInternal($0) }
    }

    func isVisible(_ obj: AnyObject) -> Bool {
        if obj is UIBarButtonItem { return true }
        guard let v = obj as? UIView else { return false }
        return !v.isHidden && v.alpha > 0.01
    }

    func makeNode(for obj: AnyObject, ref: Int) -> UINode {
        if let item = obj as? UIBarButtonItem {
            return UINode(ref: ref, role: "button", label: Self.barLabel(item), value: nil,
                          identifier: item.accessibilityIdentifier, enabled: item.isEnabled, actions: ["activate"])
        }
        let v = obj as! UIView
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
        guard let v = obj as? UIView else { return false }
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

    /// Which responder holds keyboard focus (UIKit: the first responder in the key window).
    func focusReport() -> String {
        let windows = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
        guard let win = windows.first else { return "no key window" }
        guard let fr = win.ap_firstResponder else { return "key window: no first responder" }
        var out = "firstResponder: \(type(of: fr))"
        if let v = fr as? UIView, let id = v.accessibilityIdentifier { out += " #\(id)" }
        return out
    }

    /// UIKit has no equivalent of posting into the app's own event queue; text input arrives
    /// through the keyboard system, which a hosted process can't drive. `ui_setvalue` instead.
    func sendKey(text: String, window: String?) -> String {
        "ERROR: ui_key is macOS-only (no in-process key events on iOS) — use ui_setvalue."
    }

    func assign(_ obj: AnyObject, text: String) -> Bool {
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
        case is UIControl: return "control"
        default: return String(describing: type(of: v))
        }
    }
    static func label(_ v: UIView) -> String? {
        if let nav = v as? UINavigationBar { return nav.topItem?.title ?? v.accessibilityLabel }
        if let l = v.accessibilityLabel, !l.isEmpty { return l }
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
        if let val = v.accessibilityValue, !val.isEmpty { return val }
        if let tf = v as? UITextField { return tf.text }
        if let tv = v as? UITextView { return tv.text }
        if let sw = v as? UISwitch { return sw.isOn ? "on" : "off" }
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
private extension NSView {
    var ap_enclosingTableView: NSTableView? {
        sequence(first: superview, next: { $0?.superview }).compactMap { $0 as? NSTableView }.first
    }
}

extension UIDriver {
    static var appName: String { ProcessInfo.processInfo.processName }

    func rootElements() -> [AnyObject] {
        // Root at the window's frame view (`contentView.superview`), not `contentView`, so the
        // titlebar + toolbar are walked too — otherwise custom toolbar controls (e.g. the project
        // title control) are invisible and unreachable. Fall back to `contentView` if there's no
        // frame view. An open NSPopover is its own window, so it shows up here as another root.
        NSApp?.windows.filter { $0.isVisible }.compactMap { $0.contentView?.superview ?? $0.contentView } ?? []
    }

    func childElements(of obj: AnyObject) -> [AnyObject] { (obj as? NSView)?.subviews ?? [] }

    func isVisible(_ obj: AnyObject) -> Bool {
        guard let v = obj as? NSView else { return false }
        return !v.isHidden
    }

    func makeNode(for obj: AnyObject, ref: Int) -> UINode {
        let v = obj as! NSView
        let center = v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        return UINode(ref: ref, role: Self.role(v), label: Self.label(v), value: Self.value(v),
                      identifier: v.identifier?.rawValue,
                      x: apSafeInt(center.x), y: apSafeInt(center.y),
                      enabled: (v as? NSControl)?.isEnabled ?? true, actions: Self.actions(v))
    }

    func perform(_ obj: AnyObject, action: String) -> Bool {
        // "focus" puts KEYBOARD FOCUS on the element (a table row focuses its table, the way
        // clicking a row does) without activating it — the starting state for a `ui_key` test.
        if action == "focus", let v = obj as? NSView {
            let target: NSView = (v is NSTableView) ? v : (v.ap_enclosingTableView ?? v)
            return v.window?.makeFirstResponder(target) ?? false
        }
        // Scroll before the NSControl branch: NSTableView IS an NSControl, and a scroll request
        // aimed at a table must not turn into a performClick.
        if action == "scrollDown" || action == "scrollUp", let v = obj as? NSView,
           let sv = (v as? NSScrollView) ?? v.enclosingScrollView ?? v.subviews.compactMap({ $0 as? NSScrollView }).first {
            let clip = sv.contentView
            let dy = clip.bounds.height * 0.8 * (action == "scrollDown" ? 1 : -1)
            var origin = clip.bounds.origin
            origin.y += clip.isFlipped ? dy : -dy
            let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
            clip.scroll(to: constrained)
            sv.reflectScrolledClipView(clip)
            return true
        }
        // A static NSTextField label is technically an NSControl, but performClick on it is a
        // no-op — let it fall through to the row-selection branch below instead (a row's own text
        // is exactly what a caller aims at when it means "click this row").
        let inertLabel = (obj as? NSTextField).map { !$0.isEditable && $0.action == nil } ?? false
        if let c = obj as? NSControl, !inertLabel { c.performClick(nil); return true }
        // Table/outline rows: select through the real delegate, the way a click does. (Row views
        // carry no target/action, so without this a list — the sidebar's sessions, say — is walkable
        // but not clickable.) `selectRowIndexes` alone doesn't notify, hence the explicit call.
        if let v = obj as? NSView, let table = v.ap_enclosingTableView {
            let row = table.row(for: v)
            if row >= 0, table.delegate?.tableView?(table, shouldSelectRow: row) ?? true {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.delegate?.tableViewSelectionDidChange?(
                    Notification(name: NSTableView.selectionDidChangeNotification, object: table))
                return true
            }
        }
        // Custom controls (e.g. the toolbar project/status title) carry no target/action — they're
        // driven by a click gesture recognizer. Invoke its action directly, the same way a click
        // would, so these are actionable without synthesizing a system event.
        if let v = obj as? NSView {
            for case let click as NSClickGestureRecognizer in v.gestureRecognizers {
                if let action = click.action, NSApp.sendAction(action, to: click.target, from: click) { return true }
            }
        }
        return false
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
    func focusReport() -> String {
        guard let win = NSApp?.keyWindow ?? NSApp?.mainWindow ?? NSApp?.windows.first(where: { $0.isVisible }) else {
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

    /// Post a keyDown/keyUp pair into the app's own event queue (not a CGEvent, so no
    /// Accessibility grant and no need to be frontmost). Everything downstream — local monitors,
    /// `keyDown(with:)`, the field editor — sees an ordinary keystroke.
    func sendKey(text: String, window: String?) -> String {
        let windows = (NSApp?.windows ?? []).filter { $0.isVisible }
        let target = window.flatMap { want in windows.first { $0.title.range(of: want, options: .caseInsensitive) != nil } }
            ?? NSApp?.keyWindow ?? windows.first
        guard let win = target else { return "ERROR: no visible window to type into." }
        guard !text.isEmpty else { return "ERROR: 'text' is empty." }
        for ch in text {
            let s = String(ch)
            for down in [true, false] {
                guard let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero,
                                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: win.windowNumber, context: nil,
                                               characters: s, charactersIgnoringModifiers: s,
                                               isARepeat: false, keyCode: 0) else {
                    return "ERROR: could not make a key event for \"\(s)\"."
                }
                NSApp?.postEvent(e, atStart: false)
            }
        }
        return "ok: typed \"\(text)\" into window \"\(win.title)\" (ui_focus to see where it landed)"
    }

    func assign(_ obj: AnyObject, text: String) -> Bool {
        // Numeric controls: parse the text and drive them like a user gesture (value + action).
        if let s = obj as? NSSlider, let d = Double(text) { s.doubleValue = d; s.sendAction(s.action, to: s.target); return true }
        if let st = obj as? NSStepper, let d = Double(text) { st.doubleValue = d; st.sendAction(st.action, to: st.target); return true }
        if let tf = obj as? NSTextField { tf.stringValue = text; tf.sendAction(tf.action, to: tf.target); return true }
        // `string =` alone mutates the storage silently — `didChangeText()` is what posts
        // NSText.didChangeNotification, so the view's delegate sees the edit like a typed one.
        if let tv = obj as? NSTextView { tv.string = text; tv.didChangeText(); return true }
        return false
    }

    static func role(_ v: NSView) -> String {
        switch v {
        case let b as NSButton:
            switch b.accessibilityRole() {
            case .some(.checkBox): return "checkbox"
            case .some(.radioButton): return "radio"
            default: return "button"
            }
        case is NSSwitch: return "switch"
        case let tf as NSTextField: return tf.isEditable ? "textField" : "text"
        case is NSTextView: return "textView"
        case is NSImageView: return "image"
        case is NSTableView: return "table"
        case is NSScrollView: return "scrollView"
        case is NSControl: return "control"
        default: return String(describing: type(of: v))
        }
    }
    static func label(_ v: NSView) -> String? {
        if let l = v.accessibilityLabel(), !l.isEmpty { return l }
        if let b = v as? NSButton { return b.title }
        if let tf = v as? NSTextField, !tf.isEditable { return tf.stringValue }
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
        if let b = v as? NSButton, b.accessibilityRole() == .checkBox || b.accessibilityRole() == .radioButton {
            return stateString(b.state)
        }
        return nil
    }
    private static func stateString(_ s: NSControl.StateValue) -> String {
        switch s { case .on: return "on"; case .mixed: return "mixed"; default: return "off" }
    }
    private static func actions(_ v: NSView) -> [String] {
        var a: [String] = []
        if v is NSControl { a.append("activate") }
        else if v.gestureRecognizers.contains(where: { $0 is NSClickGestureRecognizer }) { a.append("activate") }
        if let tf = v as? NSTextField, tf.isEditable { a.append("setValue") }
        if v is NSTextView { a.append("setValue") }
        return a
    }
}
#endif
