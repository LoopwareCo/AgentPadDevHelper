#if !canImport(UIKit) && canImport(AppKit)
import XCTest
import AppKit
@testable import AgentPadDevHelper

/// The AppKit walk's menu-button rule. An NSMenu's items are the only thing a menu button really
/// offers, and no view stands for them — so the walk grafts them in as the button's children
/// (exactly as the UIKit walk grafts a navigation bar's `UIBarButtonItem`s), and the button itself
/// is NOT activatable in-process: `performClick` would start modal menu tracking, which owns the
/// main thread until a mouse dismisses the menu — a hang, from the driver's side.
final class MenuButtonWalkTests: XCTestCase {

    private final class Target: NSObject {
        var picked: [String] = []
        @objc func pick(_ sender: NSMenuItem) { picked.append(sender.title) }
    }

    private func menu(_ titles: [String], target: Target) -> NSMenu {
        let m = NSMenu(title: "Add")
        m.autoenablesItems = false
        let heading = NSMenuItem(title: "Add to Inspector", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        m.addItem(heading)
        for t in titles {
            let mi = NSMenuItem(title: t, action: #selector(Target.pick(_:)), keyEquivalent: "")
            mi.target = target
            m.addItem(mi)
        }
        m.addItem(.separator())
        let hidden = NSMenuItem(title: "not shown", action: #selector(Target.pick(_:)), keyEquivalent: "")
        hidden.target = target
        hidden.isHidden = true
        m.addItem(hidden)
        return m
    }

    func testMenuChildrenSkipSeparatorsAndHiddenItems() {
        let target = Target()
        let m = menu(["macOS VM", "iOS Simulator"], target: target)
        let kids = UIDriver.menuChildren(m).compactMap { $0 as? NSMenuItem }
        XCTAssertEqual(kids.map(\.title), ["Add to Inspector", "macOS VM", "iOS Simulator"])
    }

    /// Menus are filled lazily — `menuNeedsUpdate` is where an app puts its items. Without asking
    /// for that update first a menu button reads as having no choices at all.
    func testMenuChildrenAskTheDelegateToFillTheMenu() {
        final class Filler: NSObject, NSMenuDelegate {
            func menuNeedsUpdate(_ menu: NSMenu) {
                menu.removeAllItems()
                menu.addItem(NSMenuItem(title: "filled in", action: nil, keyEquivalent: ""))
            }
        }
        let filler = Filler()
        let m = NSMenu(title: "lazy")
        m.delegate = filler
        XCTAssertTrue(m.items.isEmpty)
        XCTAssertEqual(UIDriver.menuChildren(m).compactMap { ($0 as? NSMenuItem)?.title }, ["filled in"])
    }

    func testMenuItemNodeCarriesTitleAndEnabledState() {
        let target = Target()
        let m = menu(["macOS VM"], target: target)
        let driver = UIDriver()
        let heading = driver.makeNode(for: m.items[0], ref: 1)
        let pick = driver.makeNode(for: m.items[1], ref: 2)
        XCTAssertEqual(heading.role, "menuItem")
        XCTAssertEqual(heading.label, "Add to Inspector")
        XCTAssertFalse(heading.enabled)
        XCTAssertTrue(heading.actions.isEmpty, "a heading has no action to send")
        XCTAssertEqual(pick.label, "macOS VM")
        XCTAssertEqual(pick.actions, ["activate"])
    }

    func testActivatingAMenuItemSendsItsAction() {
        _ = NSApplication.shared          // `sendAction` needs an app object
        let target = Target()
        let m = menu(["macOS VM", "iOS Simulator"], target: target)
        let driver = UIDriver()
        XCTAssertTrue(driver.perform(m.items[2], action: "activate"))
        XCTAssertEqual(target.picked, ["iOS Simulator"])
        XCTAssertFalse(driver.perform(m.items[0], action: "activate"), "a disabled heading does nothing")
        XCTAssertEqual(target.picked, ["iOS Simulator"])
    }

    /// The button that owns the menu: its items are the drivable part, and pressing IT in-process
    /// would hand the main thread to menu tracking.
    func testAMenuButtonIsWalkedThroughItsItemsAndIsNotItselfActivatable() {
        _ = NSApplication.shared
        let target = Target()
        let button = NSButton(title: "＋", target: target, action: #selector(Target.pick(_:)))
        button.menu = menu(["macOS VM", "iOS Simulator"], target: target)
        let driver = UIDriver()
        let kids = driver.childElements(of: button).compactMap { $0 as? NSMenuItem }
        XCTAssertEqual(kids.map(\.title), ["Add to Inspector", "macOS VM", "iOS Simulator"])
        XCTAssertFalse(driver.perform(button, action: "activate"))
        XCTAssertEqual(target.picked, [], "the button's own action must not fire either")
        XCTAssertTrue(driver.perform(kids[1], action: "activate"))
        XCTAssertEqual(target.picked, ["macOS VM"])
    }

    /// A pop-up's items carry no action of their own — choosing one IS the click, so the driver
    /// selects it on the button the walk saw it under and sends THAT action.
    func testChoosingAPopUpItemSelectsItAndSendsThePopUpsAction() {
        _ = NSApplication.shared
        final class Watcher: NSObject {
            var fired = 0
            @objc func changed(_ sender: Any?) { fired += 1 }
        }
        let watcher = Watcher()
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: ["Small", "Medium", "Large"])
        popUp.target = watcher
        popUp.action = #selector(Watcher.changed(_:))
        let driver = UIDriver()
        let kids = driver.childElements(of: popUp).compactMap { $0 as? NSMenuItem }
        XCTAssertEqual(kids.map(\.title), ["Small", "Medium", "Large"])
        XCTAssertTrue(driver.perform(kids[2], action: "activate"))
        XCTAssertEqual(popUp.titleOfSelectedItem, "Large")
        XCTAssertEqual(watcher.fired, 1)
    }
}
#endif
