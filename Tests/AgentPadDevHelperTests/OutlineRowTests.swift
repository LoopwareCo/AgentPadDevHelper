#if !canImport(UIKit) && canImport(AppKit)
import XCTest
import AppKit
@testable import AgentPadDevHelper

/// An `NSOutlineView` — a file browser's tree — adds a second thing a row has to do: open and
/// close. The disclosure triangle is one small button drawn inside the row; a caller holding the
/// row shouldn't have to go find it, so `expand`/`collapse` act on the row itself.
final class OutlineRowTests: XCTestCase {

    /// Two folders, one with children. Mirrors a file tree closely enough to exercise selection,
    /// expansion, and the delegate calls both make.
    private final class Tree: NSObject, NSOutlineViewDelegate, NSOutlineViewDataSource {
        var selections: [Int] = []
        var expandedItems: [String] = []
        var refusesToExpand = false
        func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item = item as? String else { return 2 }        // "Sources", "README.md"
            return item == "Sources" ? 2 : 0
        }
        func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            item == nil ? ["Sources", "README.md"][index] : "Sources/file\(index).swift"
        }
        func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? String) == "Sources" }
        func outlineView(_ o: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
            let cell = NSTableCellView()
            cell.addSubview(NSTextField(labelWithString: item as? String ?? "?"))
            return cell
        }
        func outlineView(_ o: NSOutlineView, shouldExpandItem item: Any) -> Bool { !refusesToExpand }
        func outlineViewItemDidExpand(_ n: Notification) {
            expandedItems.append(n.userInfo?["NSObject"] as? String ?? "?")
        }
        func outlineViewSelectionDidChange(_ n: Notification) {
            selections.append((n.object as? NSOutlineView)?.selectedRow ?? -1)
        }
    }

    private func makeOutline(_ tree: Tree) -> (NSWindow, NSOutlineView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        let column = NSTableColumn(identifier: .init("c")); column.width = 300
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.delegate = tree; outline.dataSource = tree
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        scroll.documentView = outline
        window.contentView?.addSubview(scroll)
        outline.reloadData(); outline.layoutSubtreeIfNeeded()
        return (window, outline)
    }

    func testActingOnAnOutlineRowSelectsItThroughTheOutlineDelegate() throws {
        _ = NSApplication.shared
        let tree = Tree()
        let (_, outline) = makeOutline(tree)
        let driver = UIDriver()
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 1, makeIfNecessary: true))
        XCTAssertTrue(driver.perform(cell, action: "activate"))
        XCTAssertEqual(outline.selectedRow, 1)
        XCTAssertEqual(tree.selections, [1], "outlineViewSelectionDidChange ran \(tree.selections.count) times")
    }

    func testExpandAndCollapseFromTheRow() throws {
        _ = NSApplication.shared
        let tree = Tree()
        let (_, outline) = makeOutline(tree)
        let driver = UIDriver()
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: true))
        XCTAssertEqual(outline.numberOfRows, 2)

        XCTAssertTrue(driver.perform(cell, action: "expand"))
        XCTAssertEqual(outline.numberOfRows, 4, "the folder's children did not appear")
        XCTAssertEqual(tree.expandedItems, ["Sources"], "the app's own didExpand did not run")
        XCTAssertEqual(driver.actionNote, "expanded row 0 — 4 rows now")

        XCTAssertTrue(driver.perform(cell, action: "expand"))
        XCTAssertEqual(driver.actionNote, "row 0 is already expanded")

        XCTAssertTrue(driver.perform(cell, action: "collapse"))
        XCTAssertEqual(outline.numberOfRows, 2)
    }

    /// The row a caller is handed may be any view inside it — including the disclosure button.
    func testExpandWorksFromTheRowViewAndFromADescendant() throws {
        _ = NSApplication.shared
        let tree = Tree()
        let (_, outline) = makeOutline(tree)
        let driver = UIDriver()
        let rowView = try XCTUnwrap(outline.rowView(atRow: 0, makeIfNecessary: true))
        XCTAssertTrue(driver.perform(rowView, action: "expand"))
        XCTAssertEqual(outline.numberOfRows, 4)
        XCTAssertTrue(driver.perform(rowView, action: "collapse"))

        let label = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: true)?.subviews.first)
        XCTAssertTrue(driver.perform(label, action: "toggle"))
        XCTAssertEqual(outline.numberOfRows, 4)
    }

    func testAnOutlineRowAdvertisesTheDisclosureItWouldDo() throws {
        _ = NSApplication.shared
        let tree = Tree()
        let (_, outline) = makeOutline(tree)
        let driver = UIDriver()
        let folder = try XCTUnwrap(outline.rowView(atRow: 0, makeIfNecessary: true))
        XCTAssertEqual(driver.makeNode(for: folder, ref: 1).actions, ["activate", "expand"])
        outline.expandItem("Sources")
        outline.layoutSubtreeIfNeeded()
        XCTAssertEqual(driver.makeNode(for: folder, ref: 1).actions, ["activate", "collapse"])
        // A leaf has nothing to open.
        let leaf = try XCTUnwrap(outline.rowView(atRow: 3, makeIfNecessary: true))
        XCTAssertEqual(driver.makeNode(for: leaf, ref: 2).actions, ["activate"])
    }

    /// An app that refuses the expansion is reported as a refusal, not as a silent success.
    func testARefusedExpansionIsAnError() throws {
        _ = NSApplication.shared
        let tree = Tree()
        tree.refusesToExpand = true
        let (_, outline) = makeOutline(tree)
        let driver = UIDriver()
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: true))
        XCTAssertFalse(driver.perform(cell, action: "expand"))
        XCTAssertEqual(outline.numberOfRows, 2)
        XCTAssertTrue((driver.actionRefusal ?? "").contains("refused to expand"), "refusal was: \(driver.actionRefusal ?? "none")")
    }

    /// "toggle" is the natural word for a checkbox too, and taking it for the disclosure broke
    /// every control that isn't in an outline row.
    func testToggleStillFlipsAControlOutsideAnOutline() {
        _ = NSApplication.shared
        let box = NSButton(checkboxWithTitle: "Run in a copy", target: nil, action: nil)
        XCTAssertEqual(box.state, .off)
        let driver = UIDriver()
        XCTAssertTrue(driver.perform(box, action: "toggle"))
        XCTAssertEqual(box.state, .on, "toggle did not flip the checkbox")
    }

    func testExpandOutsideAnOutlineIsRefused() {
        _ = NSApplication.shared
        let driver = UIDriver()
        XCTAssertFalse(driver.perform(NSView(), action: "expand"))
        XCTAssertTrue((driver.actionRefusal ?? "").contains("nothing to expand"), "refusal was: \(driver.actionRefusal ?? "none")")
    }
}
#endif
