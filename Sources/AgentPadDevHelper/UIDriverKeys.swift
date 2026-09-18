import Foundation

#if !canImport(UIKit) && canImport(AppKit)
import AppKit

/// What `ui_key` needs to post a REAL keystroke: the virtual key code, and the characters AppKit
/// would put on the event.
///
/// Characters alone are not a keystroke. Half of an AppKit app routes on the CODE — `keyCode == 49`
/// for Quick Look, `NavigationDirection(keyCode:)` for the arrows, a window's key monitor picking
/// off ⌘F — and an event built with `keyCode: 0` is, to all of that, the "a" key. Named keys
/// (`"space"`, `"up"`, `"cmd+f"`) and plain typed text both come through here so they carry the
/// code the app is actually looking at.
struct KeyStroke: Equatable {
    var code: UInt16
    /// What `characters` reports — the shifted form when a modifier changes it ("A", "!").
    var characters: String
    /// What `charactersIgnoringModifiers` reports; the unshifted form when they differ.
    var charactersIgnoringModifiers: String
    var modifiers: NSEvent.ModifierFlags = []

    init(code: UInt16, characters: String, unmodified: String? = nil, modifiers: NSEvent.ModifierFlags = []) {
        self.code = code
        self.characters = characters
        self.charactersIgnoringModifiers = unmodified ?? characters
        self.modifiers = modifiers
    }
}

/// The ANSI keyboard, as much of it as a UI driver needs. Deliberately a table rather than a
/// `UCKeyTranslate` round trip: the app under test is being driven, not typed into by a human, and
/// a fixed table is testable with no input source, no layout and no keyboard hardware.
enum KeyMap {
    /// Keys asked for BY NAME — the ones with no character to type at all (arrows, escape) and the
    /// ones whose handler keys on the code (space = Quick Look). Aliases included: a caller
    /// writing "esc", "enter" or "uparrow" means the obvious thing.
    static let named: [String: KeyStroke] = {
        var m: [String: KeyStroke] = [:]
        func add(_ names: [String], _ code: UInt16, _ characters: String,
                 _ modifiers: NSEvent.ModifierFlags = []) {
            for n in names { m[n] = KeyStroke(code: code, characters: characters, modifiers: modifiers) }
        }
        // The real events carry these, and a handler is entitled to filter on them.
        let arrow: NSEvent.ModifierFlags = [.function, .numericPad]
        let fnKey: NSEvent.ModifierFlags = [.function]
        add(["space", "spacebar"], 49, " ")
        add(["return", "enter"], 36, "\r")
        add(["keypadenter"], 76, "\u{3}")
        add(["tab"], 48, "\t")
        add(["escape", "esc"], 53, "\u{1B}")
        add(["delete", "backspace", "del"], 51, "\u{7F}")   // NSDeleteCharacter, what the real key sends
        add(["forwarddelete", "deleteforward", "fwddelete"], 117, fn(0xF728), fnKey)
        add(["up", "uparrow"], 126, fn(0xF700), arrow)
        add(["down", "downarrow"], 125, fn(0xF701), arrow)
        add(["left", "leftarrow"], 123, fn(0xF702), arrow)
        add(["right", "rightarrow"], 124, fn(0xF703), arrow)
        add(["home"], 115, fn(0xF729), fnKey)
        add(["end"], 119, fn(0xF72B), fnKey)
        add(["pageup", "pgup"], 116, fn(0xF72C), fnKey)
        add(["pagedown", "pgdn"], 121, fn(0xF72D), fnKey)
        add(["help"], 114, fn(0xF746), fnKey)
        let functionCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in functionCodes.enumerated() {
            add(["f\(i + 1)"], code, fn(UInt16(0xF704 + i)), fnKey)
        }
        return m
    }()

    /// Every name a caller may pass, for the error message when they pass something else.
    static var knownNames: [String] { named.keys.sorted() }

    /// Look up a named key. Spelling is forgiving — case, spaces, hyphens and underscores are all
    /// the same name ("Page Up", "page_up", "pageup").
    static func stroke(named name: String) -> KeyStroke? {
        named[normalize(name)]
    }

    /// One typed character as a keystroke. Letters and the US punctuation row carry their real
    /// code (and `.shift` where the character needs it), so a handler keying on the code or on
    /// `charactersIgnoringModifiers` sees what a typist would have sent. An unknown character
    /// still types — it just has no code to offer.
    static func stroke(for character: Character) -> KeyStroke {
        switch character {
        case "\r", "\n": return KeyStroke(code: 36, characters: "\r")
        case "\t": return KeyStroke(code: 48, characters: "\t")
        default: break
        }
        let s = String(character)
        let lowered = s.lowercased()
        if lowered.count == 1, let lower = lowered.first, lower != character, let code = ansi[lower] {
            return KeyStroke(code: code, characters: s, unmodified: lowered, modifiers: .shift)
        }
        if let code = ansi[character] {
            return KeyStroke(code: code, characters: s)
        }
        if let base = shifted[character], let code = ansi[base] {
            return KeyStroke(code: code, characters: s, unmodified: String(base), modifiers: .shift)
        }
        return KeyStroke(code: 0, characters: s)
    }

    /// One key named by a single character — the "f" in `cmd+f`. NOT the same as typing it: the
    /// letter names the physical KEY, so "F" is the f key (shift comes from the spec, not from the
    /// capital — `"Cmd+F"` must not silently become ⌘⇧F), and a character with no key on the
    /// layout is no key at all rather than a keyCode-0 event that poses as "a".
    static func stroke(keyNamed key: String) -> KeyStroke? {
        if let named = stroke(named: key) { return named }
        guard key.count == 1 else { return nil }
        let lowered = key.lowercased()
        guard lowered.count == 1, let ch = lowered.first else { return nil }
        if let code = ansi[ch] { return KeyStroke(code: code, characters: String(ch)) }
        if let base = shifted[ch], let code = ansi[base] {
            return KeyStroke(code: code, characters: String(ch), unmodified: String(base), modifiers: .shift)
        }
        return nil
    }

    /// Split a key spec into its modifiers and the key itself: `"cmd+f"`, `"shift+tab"`,
    /// `"⌘⇧p"`. A lone or trailing `"+"` is still the plus key.
    static func split(_ spec: String) -> (modifiers: NSEvent.ModifierFlags, key: String) {
        var flags: NSEvent.ModifierFlags = []
        var key = spec
        while let plus = key.firstIndex(of: "+"), plus != key.startIndex, key.index(after: plus) != key.endIndex {
            let head = String(key[key.startIndex..<plus])
            let headFlags = modifierFlags([head])
            guard !headFlags.isEmpty else { break }
            flags.formUnion(headFlags)
            key = String(key[key.index(after: plus)...])
        }
        // Glyph form ("⌘⇧p") — strip the symbols off the front and fold them in.
        while let first = key.first, let flag = glyphModifiers[first], key.count > 1 {
            flags.formUnion(flag)
            key.removeFirst()
        }
        return (flags, key)
    }

    /// Modifier names as a caller writes them, in any mix of spellings.
    static func modifierFlags(_ names: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for raw in names {
            switch normalize(raw) {
            case "cmd", "command", "meta", "⌘": flags.insert(.command)
            case "shift", "⇧": flags.insert(.shift)
            case "opt", "option", "alt", "⌥": flags.insert(.option)
            case "ctrl", "control", "⌃": flags.insert(.control)
            case "fn", "function": flags.insert(.function)
            case "caps", "capslock": flags.insert(.capsLock)
            default: break
            }
        }
        return flags
    }

    private static let glyphModifiers: [Character: NSEvent.ModifierFlags] =
        ["⌘": .command, "⇧": .shift, "⌥": .option, "⌃": .control]

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { !" -_".contains($0) }
    }

    /// The private-use unicode AppKit puts on a function/arrow key event.
    private static func fn(_ scalar: UInt16) -> String {
        String(UnicodeScalar(scalar) ?? " ")
    }

    /// kVK_ANSI_* — the US layout's physical keys.
    private static let ansi: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]

    /// The shifted punctuation row, back to the key it's typed on.
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\",
        ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]
}

/// `ui_key`'s macOS half: build the strokes above into real events and post them.
extension UIDriver {
    /// Post a keyDown/keyUp pair into the app's own event queue (not a CGEvent, so no
    /// Accessibility grant and no need to be frontmost). Everything downstream — local monitors,
    /// `keyDown(with:)`, `performKeyEquivalent`, the field editor — sees an ordinary keystroke.
    ///
    /// Each stroke carries its real VIRTUAL KEY CODE (`KeyMap`), because that is what half of an
    /// AppKit app routes on: `keyCode == 49` for Quick Look, the arrows for list navigation, a
    /// window's key monitor picking off ⌘F. Events built from characters alone with `keyCode: 0`
    /// were the "a" key as far as all of that was concerned.
    func sendKey(text: String?, named: String?, keyCode: Int?, modifiers: [String], window: String?) -> String {
        let windows = (NSApp?.windows ?? []).filter { $0.isVisible }
        let target = window.flatMap { want in windows.first { $0.title.range(of: want, options: .caseInsensitive) != nil } }
            ?? NSApp?.keyWindow ?? windows.first
        guard let win = target else { return "ERROR: no visible window to type into." }
        var flags = KeyMap.modifierFlags(modifiers)
        let strokes: [KeyStroke]
        let what: String
        if let named, !named.isEmpty {
            // "cmd+f", "⇧tab", "space", or just "f" — modifiers off the front, then the key.
            let (specFlags, key) = KeyMap.split(named)
            flags.formUnion(specFlags)
            guard text == nil else {
                return "ERROR: pass either 'text' (to type) or 'key' (one key press), not both."
            }
            guard let stroke = KeyMap.stroke(keyNamed: key) else {
                return "ERROR: unknown key \"\(key)\" — pass a single character, an explicit keyCode, or one of: \(KeyMap.knownNames.joined(separator: ", "))."
            }
            strokes = [stroke]
            what = "\(named) (keyCode \(stroke.code))"
        } else if let keyCode {
            guard (0...0xFFFF).contains(keyCode) else { return "ERROR: keyCode \(keyCode) is out of range." }
            guard (text?.count ?? 0) <= 1 else {
                return "ERROR: 'keyCode' presses ONE key — pass at most one character as 'text', or drop keyCode to type."
            }
            let characters = text ?? ""
            strokes = [KeyStroke(code: UInt16(keyCode), characters: characters)]
            what = "keyCode \(keyCode)"
        } else if let text, !text.isEmpty {
            strokes = text.map { KeyMap.stroke(for: $0) }
            what = "\"\(text)\""
        } else {
            return "ERROR: pass 'text' to type, or 'key'/'keyCode' for one named key (e.g. key=\"space\", key=\"cmd+f\")."
        }
        for stroke in strokes {
            for down in [true, false] {
                guard let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero,
                                               modifierFlags: flags.union(stroke.modifiers),
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: win.windowNumber, context: nil,
                                               characters: stroke.characters,
                                               charactersIgnoringModifiers: stroke.charactersIgnoringModifiers,
                                               isARepeat: false, keyCode: stroke.code) else {
                    return "ERROR: could not make a key event for \(what)."
                }
                NSApp?.postEvent(e, atStart: false)
            }
        }
        return "ok: sent \(what) to window \"\(win.title)\" (ui_focus to see where it landed)"
    }
}
#endif
