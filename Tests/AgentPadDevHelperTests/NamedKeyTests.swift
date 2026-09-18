#if !canImport(UIKit) && canImport(AppKit)
import XCTest
import AppKit
@testable import AgentPadDevHelper

/// `ui_key`'s key table. Characters alone are not a keystroke: an event built with `keyCode: 0`
/// is the "a" key to everything that routes on the code — `keyCode == 49` for Quick Look, the
/// arrows for list navigation, a window's ⌘F monitor — which is most of an AppKit app's keyboard.
final class NamedKeyTests: XCTestCase {

    func testTheNamedKeysCarryTheirVirtualKeyCodes() {
        let expected: [(String, UInt16)] = [
            ("space", 49), ("return", 36), ("tab", 48), ("escape", 53), ("delete", 51),
            ("up", 126), ("down", 125), ("left", 123), ("right", 124),
            ("home", 115), ("end", 119), ("pageup", 116), ("pagedown", 121),
            ("f1", 122), ("f3", 99), ("f12", 111),
        ]
        for (name, code) in expected {
            XCTAssertEqual(KeyMap.stroke(named: name)?.code, code, "\(name) has the wrong key code")
        }
    }

    /// Spelling is forgiving, and the characters are the ones AppKit itself puts on the event —
    /// `charactersIgnoringModifiers == " "` is how a space handler is usually written.
    func testAliasesAndCharacters() {
        XCTAssertEqual(KeyMap.stroke(named: "Esc")?.code, 53)
        XCTAssertEqual(KeyMap.stroke(named: "enter")?.code, 36)
        XCTAssertEqual(KeyMap.stroke(named: "Page Up")?.code, 116)
        XCTAssertEqual(KeyMap.stroke(named: "up_arrow")?.code, 126)
        XCTAssertEqual(KeyMap.stroke(named: "space")?.characters, " ")
        XCTAssertEqual(KeyMap.stroke(named: "return")?.characters, "\r")
        XCTAssertEqual(KeyMap.stroke(named: "tab")?.characters, "\t")
        XCTAssertEqual(KeyMap.stroke(named: "escape")?.characters, "\u{1B}")
        // Arrows carry AppKit's function-key unicode (NSUpArrowFunctionKey…).
        XCTAssertEqual(KeyMap.stroke(named: "up")?.characters.unicodeScalars.first?.value, 0xF700)
        XCTAssertEqual(KeyMap.stroke(named: "right")?.characters.unicodeScalars.first?.value, 0xF703)
        XCTAssertNil(KeyMap.stroke(named: "banana"))
    }

    func testTypedCharactersCarryCodesToo() {
        XCTAssertEqual(KeyMap.stroke(for: "a").code, 0)
        XCTAssertEqual(KeyMap.stroke(for: "f").code, 3)
        XCTAssertEqual(KeyMap.stroke(for: " ").code, 49)
        XCTAssertEqual(KeyMap.stroke(for: "\n"), KeyStroke(code: 36, characters: "\r"))
        // A capital is the shift key held over the same physical key.
        let capital = KeyMap.stroke(for: "F")
        XCTAssertEqual(capital.code, 3)
        XCTAssertEqual(capital.characters, "F")
        XCTAssertEqual(capital.charactersIgnoringModifiers, "f")
        XCTAssertTrue(capital.modifiers.contains(.shift))
        // So is shifted punctuation.
        XCTAssertEqual(KeyMap.stroke(for: "?").code, 44)
        XCTAssertTrue(KeyMap.stroke(for: "?").modifiers.contains(.shift))
        // Something off the table still types; it just has no code to offer.
        XCTAssertEqual(KeyMap.stroke(for: "é").code, 0)
        XCTAssertEqual(KeyMap.stroke(for: "é").characters, "é")
    }

    func testModifiersComeFromNamesOrFromTheKeySpec() {
        XCTAssertEqual(KeyMap.modifierFlags(["command"]), .command)
        XCTAssertEqual(KeyMap.modifierFlags(["cmd", "Shift"]), [.command, .shift])
        XCTAssertEqual(KeyMap.modifierFlags(["alt", "ctrl"]), [.option, .control])
        XCTAssertEqual(KeyMap.modifierFlags(["nonsense"]), [])

        XCTAssertEqual(KeyMap.split("cmd+f").modifiers, .command)
        XCTAssertEqual(KeyMap.split("cmd+f").key, "f")
        XCTAssertEqual(KeyMap.split("shift+tab").modifiers, .shift)
        XCTAssertEqual(KeyMap.split("shift+tab").key, "tab")
        XCTAssertEqual(KeyMap.split("cmd+shift+p").modifiers, [.command, .shift])
        XCTAssertEqual(KeyMap.split("⌘⇧p").modifiers, [.command, .shift])
        XCTAssertEqual(KeyMap.split("⌘⇧p").key, "p")
        XCTAssertEqual(KeyMap.split("space").key, "space")      // no modifiers, untouched
        XCTAssertEqual(KeyMap.split("+").key, "+")              // the plus key itself
        XCTAssertEqual(KeyMap.split("cmd++").key, "+")
    }

    /// A key SPEC names a physical key; the capital is not a shift. "Cmd+F" that arrives as ⌘⇧F
    /// never fires a monitor written as `flags == .command`, and the driver said ok.
    func testACapitalisedShortcutDoesNotGainShift() {
        let (modifiers, key) = KeyMap.split("Cmd+F")
        XCTAssertEqual(modifiers, .command)
        let stroke = KeyMap.stroke(keyNamed: key)
        XCTAssertEqual(stroke?.code, 3)
        XCTAssertEqual(stroke?.modifiers ?? [], [], "the capital F added a phantom Shift")
        // Shifted punctuation named as a key still carries the shift it genuinely needs.
        XCTAssertEqual(KeyMap.stroke(keyNamed: "?")?.code, 44)
        XCTAssertEqual(KeyMap.stroke(keyNamed: "?")?.modifiers, .shift)
        // A character with no key on the layout is no key at all — not a keyCode-0 event posing as "a".
        XCTAssertNil(KeyMap.stroke(keyNamed: "🙂"))
        XCTAssertNil(KeyMap.stroke(keyNamed: "nonsense"))
    }

    /// The characters and flags a REAL key event carries, which handlers filter on.
    func testSpecialKeysLookLikeRealEvents() {
        XCTAssertEqual(KeyMap.stroke(named: "delete")?.characters, "\u{7F}", "Delete sends NSDeleteCharacter")
        XCTAssertEqual(KeyMap.stroke(named: "del")?.code, 51, "\"del\" is the key people mean by Delete")
        XCTAssertEqual(KeyMap.stroke(named: "forwarddelete")?.code, 117)
        XCTAssertEqual(KeyMap.stroke(named: "up")?.modifiers, [.function, .numericPad])
        XCTAssertEqual(KeyMap.stroke(named: "pageup")?.modifiers, .function)
        XCTAssertEqual(KeyMap.stroke(named: "f3")?.modifiers, .function)
        XCTAssertEqual(KeyMap.stroke(named: "space")?.modifiers ?? [], [])
    }

    /// Arguments that would silently cancel each other out are refused instead.
    func testConflictingArgumentsAreRefused() {
        _ = NSApplication.shared
        let driver = UIDriver()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Probe"
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer { window.close() }
        XCTAssertTrue(driver.key(text: "hello", named: "space", keyCode: nil, modifiers: [], window: "Probe")
            .contains("not both"))
        XCTAssertTrue(driver.key(text: "hello", named: nil, keyCode: 49, modifiers: [], window: "Probe")
            .contains("at most one character"))
    }

    /// The tool surface: one of text/key/keyCode is required, and an unknown name says what it
    /// knows rather than quietly typing the letters of the name.
    func testTheToolRejectsAnEmptyOrUnknownRequest() {
        _ = NSApplication.shared
        let driver = UIDriver()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Probe"
        window.isReleasedWhenClosed = false    // else `close()` releases it under ARC's feet
        window.orderBack(nil)
        XCTAssertTrue(driver.key(text: nil, named: nil, keyCode: nil, modifiers: [], window: "Probe")
            .hasPrefix("ERROR"))
        XCTAssertTrue(driver.key(text: nil, named: "banana", keyCode: nil, modifiers: [], window: "Probe")
            .contains("unknown key"))
        XCTAssertTrue(driver.key(text: nil, named: nil, keyCode: 99999, modifiers: [], window: "Probe")
            .contains("out of range"))
        XCTAssertTrue(driver.key(text: nil, named: "space", keyCode: nil, modifiers: [], window: "Probe")
            .hasPrefix("ok: sent space (keyCode 49)"))
        window.close()
    }

    /// The whole point: what reaches the app's event queue is an event its own `keyDown` (or key
    /// monitor, or `performKeyEquivalent`) recognises — code, characters and modifiers all set.
    func testAPostedNamedKeyCarriesItsCodeOnTheEventQueue() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Probe"
        window.isReleasedWhenClosed = false    // else `close()` releases it under ARC's feet
        window.orderBack(nil)
        defer { window.close() }

        let driver = UIDriver()
        XCTAssertTrue(driver.key(text: nil, named: "space", keyCode: nil, modifiers: [], window: "Probe").hasPrefix("ok"))
        let space = NSApp.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(1),
                                    inMode: .default, dequeue: true)
        XCTAssertEqual(space?.keyCode, 49, "the space key did not arrive as keyCode 49")
        XCTAssertEqual(space?.charactersIgnoringModifiers, " ")

        XCTAssertTrue(driver.key(text: nil, named: "cmd+f", keyCode: nil, modifiers: [], window: "Probe").hasPrefix("ok"))
        // The key-up of the first stroke is still in the queue; take the next DOWN.
        var found: NSEvent?
        while found == nil, let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(1),
                                                    inMode: .default, dequeue: true) {
            if e.type == .keyDown { found = e }
        }
        XCTAssertEqual(found?.keyCode, 3, "⌘F did not arrive as the f key")
        XCTAssertEqual(found?.modifierFlags.contains(.command), true)
    }
}
#endif
