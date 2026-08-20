import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The on-device "View & Send UI Feedbacks" list: every outbox item still on this device,
/// rendered with the SAME `FeedbackCardView` AgentPad's inbox uses. ONE class for both
/// platforms (the `ReviewBarViewController` pattern).
///
/// Actions, per the feature sketch: Delete the selected feedbacks, or Send to Developer via
/// the standard share panel — with nothing selected, Send takes ALL outstanding items, in one
/// `.agentpadfeedback` file the developer double-clicks into AgentPad.
///
/// Hosted by `FeedbackEntryPoints` (a plain window on the Mac, a temporary window with a nav
/// controller on iOS); pure UI otherwise — items come from `FeedbackOutbox.shared`, refreshed
/// on its change notification.

// MARK: - shared adapter

extension OutboxItem {
    /// This device's outbox only ever holds THIS app's feedback, so identity comes from
    /// `AppIdentity`, not from the item.
    func cardModel() -> FeedbackCardModel {
        let leaf = payload.element?.path.last
        return FeedbackCardModel(
            id: id,
            appName: AppIdentity.displayName,
            platform: AppIdentity.platform,
            date: capturedAt,
            message: payload.message,
            elementLeafName: leaf.map {
                FeedbackCardModel.leafDisplayName(role: $0.role, className: $0.className,
                                                  label: $0.label, identifier: $0.identifier)
            },
            icon: AppIdentity.decodedIcon())
    }
}

// MARK: - AppKit

#if !canImport(UIKit) && canImport(AppKit)

final class PendingFeedbackListViewController: NSViewController {
    private let scroll = NSScrollView()
    private let column = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString:
        "No pending UI feedback.\n\nUse “Leave UI Review Feedback…” in the Help menu to capture some.")
    private let statusLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let sendButton = NSButton(title: "Send to Developer…", target: nil, action: nil)

    private var items: [OutboxItem] = []
    private var cardsByID: [String: FeedbackCardView] = [:]
    private var selectedIDs: Set<String> = []
    private var observer: NSObjectProtocol?

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        column.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedDocumentView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(column)

        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)

        // The action bar: Delete works the selection; Send takes the selection or everything.
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .regular
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .regular
        sendButton.keyEquivalent = "\r"
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        let bar = NSStackView(views: [statusLabel, NSView(), deleteButton, sendButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 12, right: 16)
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 560),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            column.topAnchor.constraint(equalTo: doc.topAnchor),
            column.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -20),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])
        view = root
        observer = NotificationCenter.default.addObserver(
            forName: FeedbackOutbox.didChangeNotification, object: FeedbackOutbox.shared,
            queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func refresh() {
        items = FeedbackOutbox.shared.all().reversed()   // newest first for reading
        selectedIDs.formIntersection(items.map(\.id))
        column.arrangedSubviews.forEach { column.removeArrangedSubview($0); $0.removeFromSuperview() }
        cardsByID.removeAll()
        for item in items {
            let card = FeedbackCardView(model: item.cardModel())
            card.isSelected = selectedIDs.contains(item.id)
            card.onClick = { [weak self] modifiers in self?.cardClicked(id: item.id, modifiers: modifiers) }
            column.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32).isActive = true
            cardsByID[item.id] = card
        }
        emptyLabel.isHidden = !items.isEmpty
        scroll.isHidden = items.isEmpty
        refreshBar()
    }

    private func cardClicked(id: String, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        } else {
            selectedIDs = selectedIDs == [id] ? [] : [id]
        }
        for (cardID, card) in cardsByID { card.isSelected = selectedIDs.contains(cardID) }
        refreshBar()
    }

    private func refreshBar() {
        deleteButton.isEnabled = !selectedIDs.isEmpty
        sendButton.isEnabled = !items.isEmpty
        sendButton.title = selectedIDs.isEmpty ? "Send All to Developer…" : "Send to Developer…"
        statusLabel.stringValue = FeedbackEntryPoints.shared.pendingStatusLine(count: items.count)
    }

    @objc private func deleteTapped() {
        FeedbackOutbox.shared.delete(ids: Array(selectedIDs))
        selectedIDs.removeAll()
    }

    @objc private func sendTapped() {
        let chosen = selectedIDs.isEmpty ? items : items.filter { selectedIDs.contains($0.id) }
        guard !chosen.isEmpty, let url = try? FeedbackArchive.write(items: chosen) else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: sendButton.bounds, of: sendButton, preferredEdge: .minY)
    }

    /// Flipped so the column grows downward from the top.
    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }
}

#endif

// MARK: - UIKit

#if canImport(UIKit)

final class PendingFeedbackListViewController: UITableViewController {
    /// Tear down the hosting window (set by `FeedbackEntryPoints`).
    var onDismiss: (() -> Void)?

    private var items: [OutboxItem] = []
    private var observer: NSObjectProtocol?
    private let shareButton = UIBarButtonItem(barButtonSystemItem: .action, target: nil, action: nil)
    private let deleteButton = UIBarButtonItem(title: "Delete", style: .plain, target: nil, action: nil)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "UI Feedback"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self,
                                                           action: #selector(closeTapped))
        navigationItem.rightBarButtonItem = editButtonItem

        tableView.separatorStyle = .none
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.register(CardCell.self, forCellReuseIdentifier: "card")

        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.tintColor = .systemRed
        shareButton.target = self
        shareButton.action = #selector(sendTapped)
        toolbarItems = [deleteButton, UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                        shareButton]
        navigationController?.setToolbarHidden(false, animated: false)

        observer = NotificationCenter.default.addObserver(
            forName: FeedbackOutbox.didChangeNotification, object: FeedbackOutbox.shared,
            queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func refresh() {
        items = FeedbackOutbox.shared.all().reversed()   // newest first for reading
        tableView.reloadData()
        refreshBar()
    }

    private func refreshBar() {
        let selected = tableView.indexPathsForSelectedRows?.count ?? 0
        deleteButton.isEnabled = isEditing && selected > 0
        shareButton.isEnabled = !items.isEmpty
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        refreshBar()
    }

    // MARK: table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "card", for: indexPath) as! CardCell
        cell.show(items[indexPath.row].cardModel())
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if !isEditing { tableView.deselectRow(at: indexPath, animated: false) }
        refreshBar()
    }
    override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        refreshBar()
    }

    /// Swipe-to-delete outside edit mode.
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        FeedbackOutbox.shared.delete(ids: [items[indexPath.row].id])
    }

    // MARK: actions

    @objc private func closeTapped() { onDismiss?() }

    @objc private func deleteTapped() {
        let ids = (tableView.indexPathsForSelectedRows ?? []).map { items[$0.row].id }
        guard !ids.isEmpty else { return }
        FeedbackOutbox.shared.delete(ids: ids)
    }

    @objc private func sendTapped() {
        let selectedRows = Set((tableView.indexPathsForSelectedRows ?? []).map(\.row))
        let chosen = selectedRows.isEmpty ? items : items.enumerated()
            .filter { selectedRows.contains($0.offset) }.map(\.element)
        guard !chosen.isEmpty, let url = try? FeedbackArchive.write(items: chosen) else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.barButtonItem = shareButton
        present(activity, animated: true)
    }

    /// One card per row; the table's own edit-mode checkmarks handle selection, so the card
    /// stays inert (no tap handler, no ring).
    private final class CardCell: UITableViewCell {
        private var card: FeedbackCardView?

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            backgroundColor = .clear
            selectionStyle = .default
        }
        required init?(coder: NSCoder) { fatalError("programmatic only") }

        func show(_ model: FeedbackCardModel) {
            card?.removeFromSuperview()
            let card = FeedbackCardView(model: model)
            contentView.addSubview(card)
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
                card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
                card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            ])
            self.card = card
        }
    }
}

#endif
