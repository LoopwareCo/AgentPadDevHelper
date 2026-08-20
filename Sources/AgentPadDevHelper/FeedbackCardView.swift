import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - the neutral card model

/// Everything a feedback card renders, pre-resolved by the caller — this ONE view draws both
/// AgentPad's UI Feedback Inbox cards (adapted from `UIFeedbackItem` by the viewer, which also
/// supplies the app icon and the origin line) and the SDK's own pending list (adapted from
/// `OutboxItem`). Keeping the model neutral is what lets the view live here: this package can't
/// know either side's item type.
public struct FeedbackCardModel {
    public var id: String
    public var appName: String
    /// "macos" | "ios" — picks the fallback symbol when `icon` is nil.
    public var platform: String?
    public var date: Date
    public var message: String
    /// Display name of the attached element's leaf, nil when the feedback is app-general.
    public var elementLeafName: String?
    /// A trailing context line (the inbox's "from “<session>”"), nil to omit.
    public var originLine: String?
    public var processed: Bool
    #if canImport(UIKit)
    public var icon: UIImage?
    public init(id: String, appName: String, platform: String? = nil, date: Date,
                message: String, elementLeafName: String? = nil, originLine: String? = nil,
                processed: Bool = false, icon: UIImage? = nil) {
        self.id = id; self.appName = appName; self.platform = platform; self.date = date
        self.message = message; self.elementLeafName = elementLeafName
        self.originLine = originLine; self.processed = processed; self.icon = icon
    }
    #else
    public var icon: NSImage?
    public init(id: String, appName: String, platform: String? = nil, date: Date,
                message: String, elementLeafName: String? = nil, originLine: String? = nil,
                processed: Bool = false, icon: NSImage? = nil) {
        self.id = id; self.appName = appName; self.platform = platform; self.date = date
        self.message = message; self.elementLeafName = elementLeafName
        self.originLine = originLine; self.processed = processed; self.icon = icon
    }
    #endif

    /// The leaf's display name, shared by every adapter so an element reads the same on a card
    /// here and in AgentPad: label, else #identifier, else class, always with the role.
    public static func leafDisplayName(role: String, className: String,
                                       label: String?, identifier: String?) -> String {
        if let label, !label.isEmpty { return "\(label) — \(role)" }
        if let identifier, !identifier.isEmpty { return "#\(identifier) — \(role)" }
        return className.isEmpty ? role : className
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()
    var dateText: String { Self.relative.localizedString(for: date, relativeTo: Date()) }
}

// MARK: - AppKit

#if !canImport(UIKit) && canImport(AppKit)

/// One piece of UI feedback: who it's from (app badge + when), what the user said, and the
/// element it's about. Selection ring + click reporting live here; anything host-specific
/// (AgentPad's drag-to-session) belongs in a subclass.
open class FeedbackCardView: NSView {
    public var onClick: ((NSEvent.ModifierFlags) -> Void)?
    /// A drag has started on this card (past the slop) — hosts that support dragging lift the
    /// selection; the base class only reports.
    public var onBeginDrag: ((NSEvent, FeedbackCardView) -> Void)?

    public var isSelected = false {
        didSet { applyBorder() }
    }
    public let model: FeedbackCardModel

    /// The frosted backing; content sits ON the card, not inside it, so a processed card can
    /// drop the material (see-through, outline only) without taking its content with it.
    /// Injectable: AgentPad passes its own glass so the inbox keeps its exact material; the
    /// SDK default is the vibrant-blur equivalent.
    private let backing: NSView

    public init(model: FeedbackCardModel, backing: NSView? = nil) {
        self.model = model
        self.backing = backing ?? Self.defaultBacking(cornerRadius: 12)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        self.backing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(self.backing)
        NSLayoutConstraint.activate([
            self.backing.topAnchor.constraint(equalTo: topAnchor),
            self.backing.bottomAnchor.constraint(equalTo: bottomAnchor),
            self.backing.leadingAnchor.constraint(equalTo: leadingAnchor),
            self.backing.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        applyBorder()

        // Header: app identity + relative time; a checkmark marks a processed item, and the
        // card's material drops — it's history now, kept until deleted.
        let icon = NSImageView()
        icon.image = model.icon
            ?? NSImage(systemSymbolName: model.platform == "ios" ? "iphone" : "macwindow",
                       accessibilityDescription: model.appName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
        ])
        let appLabel = NSTextField(labelWithString: model.appName)
        appLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        appLabel.textColor = .secondaryLabelColor
        let when = NSTextField(labelWithString: model.dateText)
        when.font = .systemFont(ofSize: 11)
        when.textColor = .tertiaryLabelColor
        var headerViews: [NSView] = [icon, appLabel, NSView(), when]
        if model.processed {
            let done = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill",
                                                  accessibilityDescription: "Processed") ?? NSImage())
            done.contentTintColor = .systemGreen
            headerViews.append(done)
        }
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.spacing = 6

        // The feedback itself — selectable so it can be copied, via a subclass that ALSO
        // reports the mouseDown: a selectable label consumes clicks for text selection, which
        // silently opted the message area out of click-to-select-the-card.
        let message = MessageLabel(wrappingLabelWithString: model.message)
        message.font = .systemFont(ofSize: 13)
        message.textColor = .labelColor
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.onMouseDown = { [weak self] modifiers in
            // Select the card on a text click — but never TOGGLE an already-selected card
            // here, or starting a text drag on it would deselect it mid-gesture.
            guard let self, !self.isSelected else { return }
            self.onClick?(modifiers)
        }

        var rows: [NSView] = [header, message]

        // The element: leaf token (what they tapped).
        if let leafName = model.elementLeafName {
            let tokenIcon = NSImageView(image: NSImage(systemSymbolName: "viewfinder",
                                                       accessibilityDescription: nil) ?? NSImage())
            tokenIcon.symbolConfiguration = .init(pointSize: 10, weight: .medium)
            tokenIcon.contentTintColor = .secondaryLabelColor
            let tokenLabel = NSTextField(labelWithString: leafName)
            tokenLabel.font = .systemFont(ofSize: 11, weight: .medium)
            tokenLabel.textColor = .secondaryLabelColor
            tokenLabel.lineBreakMode = .byTruncatingMiddle
            let token = NSStackView(views: [tokenIcon, tokenLabel])
            token.orientation = .horizontal
            token.spacing = 4
            token.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
            token.wantsLayer = true
            token.layer?.cornerRadius = 10
            token.layer?.borderWidth = 1
            token.layer?.borderColor = NSColor.separatorColor.cgColor
            token.heightAnchor.constraint(equalToConstant: 20).isActive = true
            let tokenRow = NSStackView(views: [token, NSView()])
            tokenRow.orientation = .horizontal
            rows.append(tokenRow)
        }

        if let origin = model.originLine, !origin.isEmpty {
            let originLine = NSTextField(labelWithString: origin)
            originLine.font = .systemFont(ofSize: 10)
            originLine.textColor = .tertiaryLabelColor
            originLine.lineBreakMode = .byTruncatingTail
            originLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            rows.append(originLine)
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        // Completed cards drop the material — see-through, just the outline.
        self.backing.isHidden = model.processed
    }

    public required init?(coder: NSCoder) { fatalError("programmatic only") }

    /// The SDK's stand-in for AgentPad's glass: a vibrant blur clipped to the same pill.
    private static func defaultBacking(cornerRadius r: CGFloat) -> NSView {
        let ve = NSVisualEffectView()
        ve.material = .hudWindow
        ve.blendingMode = .withinWindow
        ve.state = .active
        let d = r * 2 + 2
        let mask = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        ve.maskImage = mask
        return ve
    }

    // MARK: clicks + drag reporting

    private var dragStarted = false
    /// A plain press on an ALREADY-SELECTED card defers its click to mouseUp — the standard
    /// Mac list rule, so starting a drag from a multi-selection lifts the whole selection
    /// instead of collapsing it to the pressed card first.
    private var deferredClick = false

    open override func mouseDown(with event: NSEvent) {
        dragStarted = false
        let modified = !event.modifierFlags.intersection([.shift, .command]).isEmpty
        if isSelected, !modified {
            deferredClick = true
        } else {
            deferredClick = false
            onClick?(event.modifierFlags)
        }
    }

    open override func mouseUp(with event: NSEvent) {
        if deferredClick, !dragStarted { onClick?(event.modifierFlags) }
        deferredClick = false
        dragStarted = false
    }

    open override func mouseDragged(with event: NSEvent) {
        guard !dragStarted else { return }
        dragStarted = true
        onBeginDrag?(event, self)
    }

    /// Selectable message text that still participates in card selection: report the
    /// mouseDown, THEN let NSTextField run its normal text-selection behavior.
    private final class MessageLabel: NSTextField {
        var onMouseDown: ((NSEvent.ModifierFlags) -> Void)?
        override func mouseDown(with event: NSEvent) {
            onMouseDown?(event.modifierFlags)
            super.mouseDown(with: event)
        }
    }

    /// The backing IS the fill; this layer only draws the ring — a CALayer border renders above
    /// sublayers, so the selection accent sits cleanly on top of the material's edge.
    /// Colors resolve inside the view's OWN appearance so the ring is the user's accent (and
    /// the right separator) rather than whatever appearance happened to be current.
    private func applyBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.borderWidth = isSelected ? 2 : 1
            layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor
                                            : NSColor.separatorColor.cgColor
        }
    }

    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorder()   // re-resolve dynamic colors into the layer
    }
}

#endif

// MARK: - UIKit

#if canImport(UIKit)

/// The UIKit body: same content rows on a rounded system-background card. Selection is drawn
/// the same way (accent ring).
///
/// It deliberately installs NO gesture recognizer: the card is normally a table cell's content,
/// and a recognizer here swallowed the touch before `UITableView` could select the row — which
/// silently broke edit-mode multi-select (Delete stayed disabled and Send always fell back to
/// "everything"). Hosts that want a tap add their own.
open class FeedbackCardView: UIView {
    public var isSelected = false {
        didSet { applyBorder() }
    }
    public let model: FeedbackCardModel

    public init(model: FeedbackCardModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = model.processed ? .clear : .secondarySystemBackground
        layer.cornerRadius = 12
        applyBorder()

        let icon = UIImageView()
        icon.image = model.icon
            ?? UIImage(systemName: model.platform == "ios" ? "iphone" : "macwindow")
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
        ])
        let appLabel = UILabel()
        appLabel.text = model.appName
        appLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        appLabel.textColor = .secondaryLabel
        let when = UILabel()
        when.text = model.dateText
        when.font = .systemFont(ofSize: 11)
        when.textColor = .tertiaryLabel
        var headerViews: [UIView] = [icon, appLabel, UIView(), when]
        if model.processed {
            let done = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            done.tintColor = .systemGreen
            headerViews.append(done)
        }
        let header = UIStackView(arrangedSubviews: headerViews)
        header.axis = .horizontal
        header.spacing = 6

        let message = UILabel()
        message.text = model.message
        message.font = .systemFont(ofSize: 13)
        message.textColor = .label
        message.numberOfLines = 0

        var rows: [UIView] = [header, message]

        if let leafName = model.elementLeafName {
            let tokenIcon = UIImageView(image: UIImage(systemName: "viewfinder"))
            tokenIcon.tintColor = .secondaryLabel
            tokenIcon.setContentHuggingPriority(.required, for: .horizontal)
            let tokenLabel = UILabel()
            tokenLabel.text = leafName
            tokenLabel.font = .systemFont(ofSize: 11, weight: .medium)
            tokenLabel.textColor = .secondaryLabel
            tokenLabel.lineBreakMode = .byTruncatingMiddle
            let token = UIStackView(arrangedSubviews: [tokenIcon, tokenLabel])
            token.axis = .horizontal
            token.spacing = 4
            token.isLayoutMarginsRelativeArrangement = true
            token.layoutMargins = UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
            token.layer.cornerRadius = 10
            token.layer.borderWidth = 1
            token.layer.borderColor = UIColor.separator.cgColor
            let tokenRow = UIStackView(arrangedSubviews: [token, UIView()])
            tokenRow.axis = .horizontal
            rows.append(tokenRow)
        }

        if let origin = model.originLine, !origin.isEmpty {
            let originLine = UILabel()
            originLine.text = origin
            originLine.font = .systemFont(ofSize: 10)
            originLine.textColor = .tertiaryLabel
            originLine.lineBreakMode = .byTruncatingTail
            rows.append(originLine)
        }

        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
    }

    public required init?(coder: NSCoder) { fatalError("programmatic only") }

    private func applyBorder() {
        layer.borderWidth = isSelected ? 2 : 1
        layer.borderColor = isSelected ? tintColor.cgColor : UIColor.separator.cgColor
    }

    open override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyBorder()
    }
}

#endif
