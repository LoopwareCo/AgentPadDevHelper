import Foundation

#if !canImport(UIKit) && canImport(AppKit)
import AppKit

extension NSView {
    /// The table this view is drawn INSIDE. Starts at the superview on purpose: a table is not one
    /// of its own rows, and acting on the table itself must not silently select something.
    var ap_enclosingTableView: NSTableView? {
        sequence(first: superview, next: { $0?.superview }).compactMap { $0 as? NSTableView }.first
    }
}

/// Rows in an `NSTableView` / `NSOutlineView` — the half of an AppKit app a walk can SEE but a
/// click-free driver could not touch. A row carries no target/action of its own: clicking one
/// SELECTS it, and it's the selection that runs the app (`tableViewSelectionDidChange` opens the
/// file, swaps the detail pane, …). So whatever the caller was handed a ref for — the row view,
/// its cell view, or any label/icon drawn inside one — resolves back to its table + row index and
/// is selected exactly the way a click would do it:
///
/// * the delegate's vetoes (`shouldSelectRow`/`shouldSelectItem`, `selectionShouldChange`) get
///   their say, and so does its filter (`selectionIndexesForProposedSelection`),
/// * the table takes keyboard focus (so the next `ui_key` lands in the list, not the composer),
/// * the selection notification fires EXACTLY ONCE — AppKit posts it itself, so a driver that
///   also calls the delegate by hand makes the app see two clicks (two file opens, two toggles),
/// * and if the selection does not take, that is a refusal, not an `ok`.
enum RowDriver {
    /// What acting on a row did, or why it did nothing. `.refused` is reported as an ERROR: a
    /// no-op that reads as success is the failure mode this whole file exists to kill.
    enum Outcome {
        case done(String)
        case refused(String)
    }

    /// Which way an outline row's disclosure should go. Parsed from the `ui_act` action name.
    enum Expansion {
        case expand, collapse, toggle

        init?(action: String) {
            switch action.lowercased() {
            case "expand": self = .expand
            case "collapse": self = .collapse
            case "toggle", "toggleexpansion", "disclose": self = .toggle
            default: return nil
            }
        }
    }

    // MARK: - Resolution

    /// Where `view` sits in `table`, or -1 when it sits in no row at all. `row(for:)` resolves any
    /// descendant — a label deep inside a cell — and answers -1 for a view that has been removed
    /// from the table, which is the usual real-world failure: a `[ref]` taken before the list
    /// rebuilt its rows.
    static func row(of view: NSView, in table: NSTableView) -> Int {
        table.row(for: view)
    }

    /// What acting on this view's ROW could do — resolved in ONE lookup, because the walk asks for
    /// every node it prints and must not pay two table searches per view.
    static func rowActions(of view: NSView) -> (selectable: Bool, expansion: String?) {
        guard let table = view.ap_enclosingTableView else { return (false, nil) }
        let r = row(of: view, in: table)
        guard r >= 0 else { return (false, nil) }
        let selectable = allowsSelection(row: r, in: table)
        guard let outline = table as? NSOutlineView,
              let item = outline.item(atRow: r), outline.isExpandable(item) else {
            return (selectable, nil)
        }
        return (selectable, outline.isItemExpanded(item) ? "collapse" : "expand")
    }

    /// The outline item a view's row stands for, when that item can be opened or closed.
    static func expandableRow(of view: NSView) -> (outline: NSOutlineView, item: Any, expanded: Bool)? {
        guard let outline = view.ap_enclosingTableView as? NSOutlineView else { return nil }
        let r = row(of: view, in: outline)
        guard r >= 0, let item = outline.item(atRow: r), outline.isExpandable(item) else { return nil }
        return (outline, item, outline.isItemExpanded(item))
    }

    // MARK: - Acting

    /// Select the row a view sits in. nil when the view is in no table at all, so the caller can
    /// carry on to its other branches.
    static func select(rowOf view: NSView, extending: Bool = false) -> Outcome? {
        guard let table = view.ap_enclosingTableView else { return nil }
        let row = row(of: view, in: table)
        guard row >= 0 else {
            return .refused("is no longer in a row of its \(type(of: table)) — the list has rebuilt since this ref was taken; snapshot again.")
        }
        guard allowsSelection(row: row, in: table) else {
            return .refused("sits in row \(row), which the app refuses to select (its shouldSelect said no).")
        }
        var proposed = extending ? table.selectedRowIndexes.union(IndexSet(integer: row)) : IndexSet(integer: row)
        proposed = proposal(proposed, in: table)
        guard proposed.contains(row) else {
            return .refused("sits in row \(row), which the app's selectionIndexesForProposedSelection dropped.")
        }
        // Focus first, exactly like a click: a list that doesn't hold the keyboard sends the next
        // keystroke somewhere else entirely, which is its own class of bug to test for.
        table.window?.makeFirstResponder(table)
        guard table.selectedRowIndexes != proposed else {
            return .done("row \(row) of \(table.numberOfRows) was already selected (focused the list)")
        }
        selectNotifyingOnce(table, proposed)
        // Making the table first responder can end an edit, which can reload the list under us —
        // so believe the table, not the call.
        guard table.selectedRowIndexes.contains(row) else {
            return .refused("could not be selected in row \(row): the list did not take it (it may have reloaded) — snapshot again.")
        }
        return .done("selected row \(row) of \(table.numberOfRows)")
    }

    /// Open or close the outline row a view sits in — the disclosure triangle's job, done from the
    /// row itself. nil when the view is in no outline, so the caller can carry on.
    static func setExpansion(_ want: Expansion, forRowOf view: NSView) -> Outcome? {
        guard let outline = view.ap_enclosingTableView as? NSOutlineView else { return nil }
        let row = row(of: view, in: outline)
        guard row >= 0, let item = outline.item(atRow: row) else {
            return .refused("is no longer in a row of its outline — the list has rebuilt since this ref was taken; snapshot again.")
        }
        guard outline.isExpandable(item) else {
            return .refused("sits in row \(row), which has no children to open.")
        }
        let expanded = outline.isItemExpanded(item)
        let wantExpanded: Bool
        switch want {
        case .expand: wantExpanded = true
        case .collapse: wantExpanded = false
        case .toggle: wantExpanded = !expanded
        }
        guard wantExpanded != expanded else {
            return .done("row \(row) is already \(expanded ? "expanded" : "collapsed")")
        }
        // `expandItem`/`collapseItem` are the same calls the triangle makes, so the delegate's
        // shouldExpand/shouldCollapse and its didExpand/didCollapse notifications all run.
        if wantExpanded { outline.expandItem(item) } else { outline.collapseItem(item) }
        guard outline.isItemExpanded(item) == wantExpanded else {
            return .refused("sits in row \(row), which the app refused to \(wantExpanded ? "expand" : "collapse").")
        }
        return .done("\(wantExpanded ? "expanded" : "collapsed") row \(row) — \(outline.numberOfRows) rows now")
    }

    // MARK: - The app's own selection rules

    /// `selectRowIndexes` does NOT consult the delegate (that's only done for selections the user
    /// drives), so a driver that means "click this row" has to ask on its behalf — both the
    /// per-row veto and the "not right now" one an app uses while an edit is pending.
    static func allowsSelection(row: Int, in table: NSTableView) -> Bool {
        guard row >= 0, row < table.numberOfRows else { return false }
        if let outline = table as? NSOutlineView {
            if outline.delegate?.selectionShouldChange?(in: outline) == false { return false }
            guard let item = outline.item(atRow: row) else { return true }
            return outline.delegate?.outlineView?(outline, shouldSelectItem: item) ?? true
        }
        if table.delegate?.selectionShouldChange?(in: table) == false { return false }
        return table.delegate?.tableView?(table, shouldSelectRow: row) ?? true
    }

    /// The app's chance to rewrite a proposed selection (AgentPad's own Changes list uses it to
    /// keep multi-select to files) — the same call AppKit makes for a click.
    private static func proposal(_ proposed: IndexSet, in table: NSTableView) -> IndexSet {
        if let outline = table as? NSOutlineView {
            return outline.delegate?.outlineView?(outline, selectionIndexesForProposedSelection: proposed) ?? proposed
        }
        return table.delegate?.tableView?(table, selectionIndexesForProposedSelection: proposed) ?? proposed
    }

    /// Select, and make sure the selection notification lands exactly once. AppKit posts it itself
    /// from `selectRowIndexes` — the delegate runs from THAT — so the driver only posts when
    /// AppKit stayed quiet AND the selection really did move (posting a change that didn't happen
    /// would have the app act on a stale `selectedRow`).
    private static func selectNotifyingOnce(_ table: NSTableView, _ indexes: IndexSet) {
        let name = table is NSOutlineView ? NSOutlineView.selectionDidChangeNotification
                                          : NSTableView.selectionDidChangeNotification
        var posted = false
        let token = NotificationCenter.default.addObserver(forName: name, object: table, queue: nil) { _ in posted = true }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        NotificationCenter.default.removeObserver(token)
        if !posted, table.selectedRowIndexes == indexes {
            NotificationCenter.default.post(name: name, object: table)
        }
    }
}
#endif
