import Foundation

/// One node in an app's in-process UI tree. Produced by `AgentPadDevHelper` walking the live
/// view hierarchy; rendered to the same compact text format the AgentPad agent already drives
/// on macOS (`[ref] role "label" ="value" #identifier ✗disabled @x,y`), so a model's mental
/// model + prompts transfer across platforms unchanged.
public struct UINode: Codable, Sendable, Hashable {
    /// Stable-within-snapshot id used to target this element from `ui_act`/`ui_setvalue`.
    public var ref: Int
    /// Generic role ("button", "textField", "text", "cell", …) — platform classes mapped to a
    /// small shared vocabulary so iOS and macOS read the same.
    public var role: String
    public var label: String?
    public var value: String?
    public var identifier: String?
    public var x: Int?
    public var y: Int?
    public var enabled: Bool
    /// Actions this element supports in-process (e.g. "activate", "setValue").
    public var actions: [String]
    public var children: [UINode]

    public init(ref: Int, role: String, label: String? = nil, value: String? = nil,
                identifier: String? = nil, x: Int? = nil, y: Int? = nil,
                enabled: Bool = true, actions: [String] = [], children: [UINode] = []) {
        self.ref = ref; self.role = role; self.label = label; self.value = value
        self.identifier = identifier; self.x = x; self.y = y
        self.enabled = enabled; self.actions = actions; self.children = children
    }
}

public extension UINode {
    /// One element's line in the compact text format (no children), matching the macOS AX dump.
    func line(indent: Int = 0) -> String {
        var s = String(repeating: "  ", count: indent) + "[\(ref)] \(role)"
        // 200, not 80: enough that list rows and short messages read whole in a snapshot.
        // For FULL text (transcripts, long labels) use ui_read — that's its whole job.
        if let label, !label.isEmpty { s += " \"\(label.prefix(200))\"" }
        if let value, !value.isEmpty, value != label { s += " =\"\(value.prefix(200))\"" }
        if let identifier, !identifier.isEmpty { s += " #\(identifier)" }
        if !enabled { s += " ✗disabled" }
        if let x, let y { s += " @\(x),\(y)" }
        return s
    }

    /// The whole subtree rendered as compact indented text.
    func render(indent: Int = 0) -> String {
        var out = line(indent: indent)
        for child in children { out += "\n" + child.render(indent: indent + 1) }
        return out
    }

    /// Depth-first flatten (self first), for queries that ignore hierarchy.
    var flattened: [UINode] {
        [self] + children.flatMap(\.flattened)
    }
}
