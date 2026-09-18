#if !canImport(UIKit) && canImport(AppKit)
import XCTest
import AppKit
@testable import AgentPadDevHelper

/// Selecting a row in an `NSTableView`/`NSOutlineView`. A row carries no target/action, so a
/// driver that only knows how to press controls could walk a list but never click one — and
/// everything downstream of a selection (the file a row opens, the pane it swaps in) was
/// unreachable. The rule: acting on the ROW, its CELL, or anything drawn inside one selects that
/// row through the app's own delegate, exactly once.
final class RowSelectionTests: XCTestCase {

    /// A list that behaves like the inspector's Changes section: row 0 is a header that refuses
    /// selection, and the selection is what runs the app.
    private final class Source: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var selections: [Int] = []
        var proposalsSeen = 0
        /// Stand-in for a filter like the inspector's, which keeps multi-select to file rows.
        var rejectsProposals = false
        func numberOfRows(in tableView: NSTableView) -> Int { 4 }
        func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            let cell = NSTableCellView()
            let inner = NSView()                       // a row body view, as the app's rows have
            inner.addSubview(NSImageView())            // the file's icon — an NSControl with no action
            inner.addSubview(NSTextField(labelWithString: "row \(row)"))
            cell.addSubview(inner)
            return cell
        }
        func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool { row != 0 }
        func tableView(_ t: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
            proposalsSeen += 1
            return rejectsProposals ? IndexSet() : proposed
        }
        func tableViewSelectionDidChange(_ n: Notification) {
            selections.append((n.object as? NSTableView)?.selectedRow ?? -1)
        }
    }

    private func makeTable(_ source: Source) -> (NSWindow, NSTableView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        let column = NSTableColumn(identifier: .init("c")); column.width = 300
        table.addTableColumn(column)
        table.delegate = source; table.dataSource = source
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        scroll.documentView = table
        window.contentView?.addSubview(scroll)
        table.reloadData(); table.layoutSubtreeIfNeeded()
        return (window, table)
    }

    /// The three things a caller can end up holding a ref for — and all three must select.
    func testRowCellAndDescendantAllSelectTheRow() throws {
        _ = NSApplication.shared
        let source = Source()
        let (_, table) = makeTable(source)
        let driver = UIDriver()
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 2, makeIfNecessary: true))
        let rowView = try XCTUnwrap(table.rowView(atRow: 2, makeIfNecessary: true))
        let label = try XCTUnwrap(cell.subviews.first?.subviews.compactMap { $0 as? NSTextField }.first)

        for (name, target) in [("row view", rowView), ("cell", cell), ("label", label)] {
            table.deselectAll(nil)
            source.selections = []
            XCTAssertTrue(driver.perform(target, action: "activate"), "acting on the \(name) refused")
            XCTAssertEqual(table.selectedRow, 2, "acting on the \(name) did not select row 2")
            XCTAssertEqual(source.selections, [2], "the \(name) fired the selection delegate \(source.selections.count) times")
        }
    }

    /// An icon is an `NSControl` with no action: `performClick` on one does NOTHING, so it has to
    /// fall through to the row rule. It used to answer a bare `ok` and leave the list untouched —
    /// the same hollow success this whole change is about, one layer in.
    func testAnIconInARowSelectsTheRowRatherThanClickingIntoTheVoid() throws {
        _ = NSApplication.shared
        let source = Source()
        let (_, table) = makeTable(source)
        let driver = UIDriver()
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 2, makeIfNecessary: true))
        let icon = try XCTUnwrap(cell.subviews.first?.subviews.compactMap { $0 as? NSImageView }.first)
        XCTAssertTrue(driver.perform(icon, action: "activate"))
        XCTAssertEqual(table.selectedRow, 2)
        XCTAssertEqual(source.selections, [2])
        XCTAssertEqual(driver.makeNode(for: icon, ref: 1).actions, ["activate"], "the walk must promise what the act does")
    }

    /// The app's filter is the other veto, and dropping the row is a refusal — not an `ok`.
    func testAProposalTheAppRewritesAwayIsRefused() throws {
        _ = NSApplication.shared
        let source = Source()
        source.rejectsProposals = true
        let (_, table) = makeTable(source)
        let driver = UIDriver()
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        XCTAssertFalse(driver.perform(cell, action: "activate"))
        XCTAssertEqual(table.selectedRow, -1)
        XCTAssertEqual(source.proposalsSeen, 1)
        XCTAssertTrue((driver.actionRefusal ?? "").contains("selectionIndexesForProposedSelection"),
                      "refusal was: \(driver.actionRefusal ?? "none")")
    }

    /// AppKit posts the selection notification itself. A driver that also calls the delegate by
    /// hand makes the app see two clicks — two file opens, two toggles.
    func testSelectionDelegateRunsExactlyOnce() {
        _ = NSApplication.shared
        let source = Source()
        let (_, table) = makeTable(source)
        let driver = UIDriver()
        let cell = table.view(atColumn: 0, row: 1, makeIfNecessary: true)!
        XCTAssertTrue(driver.perform(cell, action: "activate"))
        XCTAssertEqual(source.selections, [1])
        // Re-acting on an already-selected row is a no-op for the app, exactly as a second click is.
        XCTAssertTrue(driver.perform(cell, action: "activate"))
        XCTAssertEqual(source.selections, [1])
        XCTAssertEqual(driver.actionNote, "row 1 of 4 was already selected (focused the list)")
    }

    /// Clicking a row focuses its list — otherwise the next `ui_key` lands somewhere else entirely,
    /// which is the bug a keyboard test is usually looking for.
    func testSelectingARowFocusesTheTable() {
        _ = NSApplication.shared
        let source = Source()
        let (window, table) = makeTable(source)
        window.makeFirstResponder(window.contentView)
        let driver = UIDriver()
        XCTAssertTrue(driver.perform(table.view(atColumn: 0, row: 3, makeIfNecessary: true)!, action: "activate"))
        XCTAssertTrue(window.firstResponder === table, "the list did not take keyboard focus")
    }

    /// The app's own veto is honoured, and a refusal is reported as one — not as a hollow "ok".
    func testARowTheAppRefusesToSelectIsReportedAsAnError() {
        _ = NSApplication.shared
        let source = Source()
        let (_, table) = makeTable(source)
        let driver = UIDriver()
        let header = table.view(atColumn: 0, row: 0, makeIfNecessary: true)!
        XCTAssertFalse(driver.perform(header, action: "activate"))
        XCTAssertEqual(table.selectedRow, -1)
        XCTAssertTrue((driver.actionRefusal ?? "").contains("shouldSelect"), "refusal was: \(driver.actionRefusal ?? "none")")
    }

    /// A ref taken before the list rebuilt points at an orphan. That used to answer "ok: activate"
    /// (the AX layer claims every view can be pressed) and do nothing at all.
    func testAnOrphanedRowViewIsRefusedRatherThanReportedOK() {
        _ = NSApplication.shared
        let source = Source()
        let (_, table) = makeTable(source)
        let driver = UIDriver()
        let cell = table.view(atColumn: 0, row: 1, makeIfNecessary: true)!
        cell.removeFromSuperview()
        XCTAssertFalse(driver.perform(cell, action: "activate"))
        XCTAssertEqual(table.selectedRow, -1)
        XCTAssertTrue((driver.actionRefusal ?? "").contains("no action"), "refusal was: \(driver.actionRefusal ?? "none")")
    }

    /// A list is not a button: `performClick` on the table itself does nothing, and used to say ok.
    func testActingOnTheTableItselfPointsAtItsRows() {
        _ = NSApplication.shared
        let source = Source()
        let (_, table) = makeTable(source)
        let driver = UIDriver()
        XCTAssertFalse(driver.perform(table, action: "activate"))
        XCTAssertTrue((driver.actionRefusal ?? "").contains("ROWS"), "refusal was: \(driver.actionRefusal ?? "none")")
    }

    /// What `ui_snapshot`/`ui_inspect` advertise has to match what `ui_act` will really do.
    func testRowsAdvertiseActivateAndPlainViewsDoNot() throws {
        _ = NSApplication.shared
        let source = Source()
        let (_, table) = makeTable(source)
        let driver = UIDriver()
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 2, makeIfNecessary: true))
        let rowView = try XCTUnwrap(table.rowView(atRow: 2, makeIfNecessary: true))
        XCTAssertEqual(driver.makeNode(for: rowView, ref: 1).actions, ["activate"])
        XCTAssertEqual(driver.makeNode(for: rowView, ref: 1).role, "row")
        XCTAssertEqual(driver.makeNode(for: cell, ref: 2).actions, ["activate"])
        XCTAssertEqual(driver.makeNode(for: cell, ref: 2).role, "cell")
        // Row 0 refuses selection, so nothing in it claims to be activatable.
        let header = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true))
        XCTAssertEqual(driver.makeNode(for: header, ref: 3).actions, [])
        // A label inside a row selects it; the same label outside any list does nothing (it is an
        // NSControl, but `performClick` on a static label has never done anything).
        let label = try XCTUnwrap(cell.subviews.first?.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(driver.makeNode(for: label, ref: 4).actions, ["activate"])
        XCTAssertEqual(driver.makeNode(for: NSTextField(labelWithString: "loose"), ref: 5).actions, [])
        // And a plain container that is in no list at all never did anything to begin with.
        XCTAssertEqual(driver.makeNode(for: NSView(), ref: 6).actions, [])
    }
}
#endif
