import Foundation

/// A value a widget control writes back into the app (the `onControl` payload).
public enum AgentPadValue {
    case number(Double)
    case bool(Bool)
    case string(String)

    public var double: Double? { if case let .number(n) = self { return n }; if case let .bool(b) = self { return b ? 1 : 0 }; if case let .string(s) = self { return Double(s) }; return nil }
    public var bool: Bool { if case let .bool(b) = self { return b }; if case let .number(n) = self { return n != 0 }; return false }
    public var string: String { switch self { case let .number(n): return n == n.rounded() ? String(Int(n)) : String(n); case let .bool(b): return b ? "true" : "false"; case let .string(s): return s } }
}

/// The app-facing entry point for **AgentPad custom widgets**: declare widgets, push live values, and
/// receive control writes. The widget shows up in AgentPad's inspector; a slider/font-picker in that
/// widget calls back here via `onControl`. Deliberately standalone (Foundation only) — it emits the
/// same WidgetSpec JSON AgentPad renders, without depending on the protocol package.
///
/// ```swift
/// AgentPadDev.shared.onControl = { widgetId, key, value in
///     if key == "angle" { self.layer.rotation = value.double ?? 0 }
/// }
/// AgentPadDev.shared.widget("anim", title: "Animation") { c in
///     c.slider("Angle", key: "angle", min: 0, max: 360)
///     c.labelValue("FPS", "$fps")
///     c.fontPicker("Font", key: "font")
/// }
/// AgentPadDev.shared.push("anim", ["angle": 42, "fps": 58])
/// ```
public final class AgentPadDev {
    public static let shared = AgentPadDev()
    private init() {}

    private let lock = NSLock()
    private var order: [String] = []                     // widget ids, declaration order
    private var specs: [String: [String: Any]] = [:]     // widgetId → WidgetSpec JSON dict
    private var values: [String: [String: Any]] = [:]    // widgetId → { key: value }

    /// Called (on the main thread) when a control in a widget is changed in AgentPad — apply it to
    /// your app here. Set this before/after declaring widgets; it's read live.
    public var onControl: ((_ widgetId: String, _ key: String, _ value: AgentPadValue) -> Void)?

    /// Fired (any thread) whenever the declared widget list changes (`widget`/`removeWidget`) — the
    /// dial-out client (`DevKitClient`) hooks this to push a fresh `specsArrayJSON()` to every live
    /// connection. Internal: not part of the public app-facing API.
    var onWidgetsChanged: (() -> Void)?
    /// Fired (any thread) after `push` merges new values into one widget — `widgetId` plus that
    /// widget's now-current merged values as JSON (`Self.jsonValue`). Internal.
    var onValueChanged: ((_ widgetId: String, _ valuesJSON: String) -> Void)?

    /// Declare (or replace) a widget. The closure builds its rows.
    public func widget(_ id: String, title: String, symbol: String? = nil, _ build: (WidgetBuilder) -> Void) {
        let b = WidgetBuilder()
        build(b)
        var spec: [String: Any] = ["id": id, "title": title, "rows": b.rows]
        if let symbol { spec["symbol"] = symbol }
        lock.lock()
        if specs[id] == nil { order.append(id) }
        specs[id] = spec
        if values[id] == nil { values[id] = [:] }
        lock.unlock()
        onWidgetsChanged?()
    }

    /// Push live values into a widget (merged — send only what changed). Keys match the widget's
    /// `$bindings` / control `key`s.
    public func push(_ widgetId: String, _ newValues: [String: Any]) {
        lock.lock()
        var v = values[widgetId] ?? [:]
        for (k, val) in newValues { v[k] = val }
        values[widgetId] = v
        lock.unlock()
        if let json = Self.jsonValue(v) { onValueChanged?(widgetId, json) }
    }

    /// Remove a declared widget.
    public func removeWidget(_ id: String) {
        lock.lock(); specs[id] = nil; values[id] = nil; order.removeAll { $0 == id }; lock.unlock()
        onWidgetsChanged?()
    }

    // MARK: MCP backing (called by DevToolHandler, in response to a `.call` from the server)

    /// `{"widgets":[<spec>…]}` — the declared widget specs, in declaration order.
    func widgetsListJSON() -> String {
        lock.lock(); let list = order.compactMap { specs[$0] }; lock.unlock()
        return Self.json(["widgets": list])
    }

    /// `{"values":{widgetId:{…}}}` — current live values for every widget.
    func widgetsValuesJSON() -> String {
        lock.lock(); let snapshot = values; lock.unlock()
        return Self.json(["values": snapshot])
    }

    // MARK: dial-out wire shapes (called by DevKitClient)

    /// `[<spec>…]` — the bare JSON ARRAY the ingress `widgets` frame carries (vs `widgetsListJSON()`'s
    /// `{"widgets":[…]}` wrapper, which is the local `widgets_list` tool-call reply shape).
    func specsArrayJSON() -> String {
        lock.lock(); let list = order.compactMap { specs[$0] }; lock.unlock()
        return Self.jsonValue(list) ?? "[]"
    }

    /// Every widget's current merged values, as `(widgetId, valuesJSON)` pairs — what a newly
    /// connected/reconnected session seeds itself with right after its first `widgets` push.
    func valuesSnapshot() -> [(widgetId: String, json: String)] {
        lock.lock(); let snapshot = values; lock.unlock()
        return snapshot.compactMap { id, v in Self.jsonValue(v).map { (id, $0) } }
    }

    /// Apply a control write from AgentPad. Optimistically records the value too, so a `widgets_values`
    /// poll reflects it even before the app pushes back. Returns false if there's no handler.
    @discardableResult
    func applyControl(widgetId: String, key: String, rawValue: Any) -> Bool {
        let value: AgentPadValue
        switch rawValue {
        case let b as Bool:   value = .bool(b)
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): value = .bool(n.boolValue)
        case let n as NSNumber: value = .number(n.doubleValue)
        case let d as Double: value = .number(d)
        case let s as String: value = .string(s)
        default: value = .string(String(describing: rawValue))
        }
        push(widgetId, [key: rawValue])   // optimistic echo
        let handler = onControl
        DispatchQueue.main.async { handler?(widgetId, key, value) }
        return handler != nil
    }

    private static func json(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Like `json(_:)` but for any JSON-serializable top-level value (an array, for `specsArrayJSON`,
    /// or a bare dict, for one widget's values) — `JSONSerialization` requires an array/dict at the
    /// top level, so this covers both without a wrapper key.
    fileprivate static func jsonValue(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Builds a widget's rows into WidgetSpec-shaped JSON dictionaries. A `value` is a literal string, a
/// number, or a live binding written as `"$name"`.
public final class WidgetBuilder {
    fileprivate var rows: [[String: Any]] = []

    // display
    public func labelValue(_ label: String, _ value: Any) { rows.append(["type": "labelValue", "label": label, "value": value]) }
    public func text(_ value: Any) { rows.append(["type": "text", "value": value]) }
    public func gauge(_ label: String, _ value: Any, max: Any = 1) { rows.append(["type": "gauge", "label": label, "value": value, "max": max]) }
    public func bar(_ label: String, _ value: Any, max: Any = 1) { rows.append(["type": "bar", "label": label, "value": value, "max": max]) }
    public func sparkline(_ label: String, _ series: Any) { rows.append(["type": "sparkline", "label": label, "series": series]) }
    public func keyValueGrid(_ entries: [(String, Any)]) { rows.append(["type": "keyValueGrid", "entries": entries.map { ["key": $0.0, "value": $0.1] }]) }
    public func button(_ title: String, action: String) { rows.append(["type": "button", "title": title, "action": action]) }

    // controls (write back via onControl)
    public func slider(_ label: String, key: String, min: Double, max: Double, step: Double? = nil) {
        var r: [String: Any] = ["type": "slider", "label": label, "key": key, "min": min, "max": max]; if let step { r["step"] = step }; rows.append(r)
    }
    public func stepper(_ label: String, key: String, min: Double, max: Double, step: Double? = nil) {
        var r: [String: Any] = ["type": "stepper", "label": label, "key": key, "min": min, "max": max]; if let step { r["step"] = step }; rows.append(r)
    }
    public func toggle(_ label: String, key: String) { rows.append(["type": "toggle", "label": label, "key": key]) }
    public func segmented(_ label: String, key: String, options: [String]) { rows.append(["type": "segmented", "label": label, "key": key, "options": options]) }
    public func textField(_ label: String, key: String, placeholder: String? = nil) {
        var r: [String: Any] = ["type": "textField", "label": label, "key": key]; if let placeholder { r["placeholder"] = placeholder }; rows.append(r)
    }
    public func colorWell(_ label: String, key: String) { rows.append(["type": "colorWell", "label": label, "key": key]) }
    public func fontPicker(_ label: String, key: String) { rows.append(["type": "fontPicker", "label": label, "key": key]) }
}
