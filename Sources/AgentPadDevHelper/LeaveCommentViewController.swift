import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The "leave a comment" compose surface — one small box: an optional title row, a text field
/// with an optional crosshair ("Choose UI") button and a send button, and an optional target
/// token ("what this comment is about") underneath.
///
/// It started life as Review UI Mode's floating bar and is still exactly that in
/// `.floatingBar` style:
///
///     Review Mode — <App>                      [Done]
///     [ Leave UI feedback about <App>… ] [Choose UI] [Send]
///     [⌖ attached element ✕]
///
/// The same class, configured `.popover`, is what AgentPad shows for every OTHER kind of
/// comment (source lines, a whole file, a web element) inside an `NSPopover` — one compose
/// box for all of them, so they can never drift apart. It lives in this package, and is
/// `public`, because the bar has to run INSIDE a reviewed app, which only embeds this SDK.
///
/// Model-agnostic on purpose (this package has no dependencies): it takes a target NAME and
/// an SF Symbol and hands back text. Mapping that to AgentPad's `Comment` is the app's job.
///
/// On iOS it stays exactly what it was — `ReviewBarViewController`, presented as a bottom card
/// in the compose overlay window. It renders a *recreation* of AgentPad's capsule look (this
/// package can't import the app's `GlassPill`/`ComposeViewController`), on the same 4pt grid.
///
/// Pure UI: everything it can do is a callback, wired by its host (`ReviewModeController` for
/// the bar, `ComposeViewController`/`InspectorDetailViewController` for the popovers).

// MARK: - AppKit

#if !canImport(UIKit) && canImport(AppKit)

/// Everything that varies between the review bar and a comment popover. Defaults describe a
/// popover; `.reviewBar(appName:)` is the floating bar.
public struct LeaveCommentConfiguration {
    public enum Style {
        /// The Review UI Mode bar: HUD glass root, 560 wide, title row with Done.
        case floatingBar
        /// Content for an `NSPopover` (which supplies the material): plain root, 360 wide.
        case popover
    }

    public var style: Style
    /// nil hides the title row entirely (a popover shown from a labelled anchor needs none).
    public var title: String?
    public var placeholder: String
    /// The crosshair (`scope`) "Choose UI" button next to the field.
    public var showsChooseButton: Bool
    /// The trailing "Done" button in the title row — the bar's way out. Bar only.
    public var showsDoneButton: Bool
    /// nil = the `arrow.up.circle.fill` glyph (new comment); a title (e.g. "Save") = edit mode,
    /// which keeps the text in the field after sending.
    public var sendTitle: String?
    public var initialText: String
    public var width: CGFloat

    public init(style: Style = .popover,
                title: String? = nil,
                placeholder: String = "Leave a comment…",
                showsChooseButton: Bool = false,
                showsDoneButton: Bool = false,
                sendTitle: String? = nil,
                initialText: String = "",
                width: CGFloat = 360) {
        self.style = style
        self.title = title
        self.placeholder = placeholder
        self.showsChooseButton = showsChooseButton
        self.showsDoneButton = showsDoneButton
        self.sendTitle = sendTitle
        self.initialText = initialText
        self.width = width
    }

    /// Review UI Mode's floating bar, exactly as it has always looked.
    public static func reviewBar(appName: String) -> LeaveCommentConfiguration {
        LeaveCommentConfiguration(style: .floatingBar,
                                  title: "Review Mode — \(appName)",
                                  placeholder: "Leave UI feedback about \(appName)…",
                                  showsChooseButton: true,
                                  showsDoneButton: true,
                                  sendTitle: nil,
                                  initialText: "",
                                  width: 560)
    }

    public static func popover(title: String?,
                               placeholder: String,
                               showsChooseButton: Bool,
                               sendTitle: String? = nil,
                               initialText: String = "") -> LeaveCommentConfiguration {
        LeaveCommentConfiguration(style: .popover,
                                  title: title,
                                  placeholder: placeholder,
                                  showsChooseButton: showsChooseButton,
                                  showsDoneButton: false,   // a popover is dismissed, not "Done"
                                  sendTitle: sendTitle,
                                  initialText: initialText,
                                  // Wider than the bar's field is tall: a comment is prose, and
                                  // the box below it is 5 lines, so a narrow popover wastes both.
                                  width: 420)
    }
}

/// The popover's placeholder: a label the mouse falls through, so clicking the prompt text puts
/// the caret in the text view underneath it.
private final class PassthroughPlaceholder: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

open class LeaveCommentViewController: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {
    public var onSend: ((String) -> Void)?
    public var onChooseUI: (() -> Void)?
    public var onCancelChoose: (() -> Void)?
    public var onDone: (() -> Void)?
    public var onRemoveTarget: (() -> Void)?

    private let configuration: LeaveCommentConfiguration
    private var choosing = false

    private let titleLabel = NSTextField(labelWithString: "")
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    /// The bar's one-line field. A POPOVER uses `textView` instead — a comment is prose, and a
    /// single line of it is a keyhole; see `usesTextView`.
    private let field = NSTextField(string: "")
    private let textView = NSTextView()
    private let textScroll = NSScrollView()
    private let placeholderLabel = PassthroughPlaceholder(labelWithString: "")
    /// Multi-line compose. The floating bar keeps its one-line field (its size is unchanged).
    private var usesTextView: Bool { configuration.style == .popover }
    /// ~5 lines of 13pt text plus the container insets, on the 4pt grid.
    private let textViewHeight: CGFloat = 88
    private let chooseButton = NSButton(title: "Choose UI", target: nil, action: nil)
    private let sendButton = NSButton(title: "", target: nil, action: nil)
    private let composeRow = NSStackView()
    private let tokenRow = NSStackView()
    private let tokenIcon = NSImageView()
    private let tokenLabel = NSTextField(labelWithString: "")
    /// nil when the configuration asks for neither a title nor a Done button.
    private var titleRow: NSStackView?

    public init(configuration: LeaveCommentConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }
    public required init?(coder: NSCoder) { fatalError("programmatic only") }

    open override func loadView() {
        let root: NSView
        if configuration.style == .floatingBar {
            // The glass: NSVisualEffectView behind everything. No rounding of our own — the bar
            // lives in a standard (titled, controls-hidden) window, and the WINDOW owns the
            // shape, so the shadow and the corners always agree.
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            root = effect
        } else {
            // A popover draws its own material and its own corners; a second one behind this
            // content would only darken it.
            root = NSView()
        }

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .small
        doneButton.font = .systemFont(ofSize: 11)
        doneButton.target = self
        doneButton.action = #selector(doneTapped)

        if configuration.title != nil || configuration.showsDoneButton {
            var views: [NSView] = [titleLabel, NSView()]
            if configuration.showsDoneButton { views.append(doneButton) }
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.spacing = 8
            titleRow = row
        }

        field.placeholderString = configuration.placeholder
        field.stringValue = configuration.initialText
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        textView.font = .systemFont(ofSize: 13)
        textView.string = configuration.initialText
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.drawsBackground = true
        textScroll.backgroundColor = .textBackgroundColor
        textScroll.borderType = .bezelBorder
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textScroll.heightAnchor.constraint(equalToConstant: textViewHeight).isActive = true

        placeholderLabel.stringValue = configuration.placeholder
        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textScroll.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: textScroll.leadingAnchor, constant: 9),
            placeholderLabel.topAnchor.constraint(equalTo: textScroll.topAnchor, constant: 6),
        ])
        placeholderLabel.isHidden = !configuration.initialText.isEmpty

        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .regular
        chooseButton.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "Choose UI")
        chooseButton.imagePosition = .imageLeading
        chooseButton.target = self
        chooseButton.action = #selector(chooseTapped)

        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .regular
        if let sendTitle = configuration.sendTitle ?? (usesTextView ? "Add Comment" : nil) {
            sendButton.title = sendTitle
            sendButton.image = nil
        } else {
            sendButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")
        }
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.keyEquivalent = "\r"

        composeRow.orientation = .horizontal
        composeRow.spacing = 8
        composeRow.alignment = .centerY
        // Floating bar: field and buttons on one line. Popover: the 5-line box is its own row and
        // the buttons sit BELOW it, pushed to the trailing edge.
        var composeViews: [NSView] = usesTextView ? [NSView()] : [field]
        if configuration.showsChooseButton { composeViews.append(chooseButton) }
        composeViews.append(sendButton)
        composeViews.forEach { composeRow.addArrangedSubview($0) }

        tokenIcon.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil) ?? NSImage()
        tokenIcon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        tokenIcon.contentTintColor = .secondaryLabelColor
        tokenLabel.font = .systemFont(ofSize: 11, weight: .medium)
        tokenLabel.textColor = .secondaryLabelColor
        tokenLabel.lineBreakMode = .byTruncatingMiddle
        let removeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove") ?? NSImage(),
                                    target: self, action: #selector(removeTargetTapped))
        removeButton.isBordered = false
        removeButton.contentTintColor = .tertiaryLabelColor

        // The token capsule (icon + name + ✕) sits alone on its row, hugging its content.
        let chip = NSStackView(views: [tokenIcon, tokenLabel, removeButton])
        chip.orientation = .horizontal
        chip.spacing = 4
        chip.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 4)
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 12
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = NSColor.separatorColor.cgColor
        chip.heightAnchor.constraint(equalToConstant: 24).isActive = true

        tokenRow.orientation = .horizontal
        tokenRow.spacing = 8
        tokenRow.addArrangedSubview(chip)
        tokenRow.addArrangedSubview(NSView())   // left-align the chip

        var rows: [NSView] = []
        if let titleRow { rows.append(titleRow) }
        rows.append(contentsOf: usesTextView ? [textScroll, tokenRow, composeRow] : [composeRow, tokenRow])
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let inset: CGFloat = configuration.style == .floatingBar ? 16 : 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: inset, bottom: 12, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset * 2).isActive = true
        }

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: configuration.width),
        ])
        view = root
        setTarget(name: nil, symbolName: nil)
        setChoosing(false)
        refreshSendEnabled()
        if configuration.style == .popover {
            // An NSPopover sizes itself from this; without it a plain-NSView content view
            // opens at AppKit's default 320×240 box.
            root.layoutSubtreeIfNeeded()
            preferredContentSize = root.fittingSize
        }
    }

    // MARK: state from the host

    /// What this comment is about. nil hides the token row (a comment about the app / file in
    /// general); `symbolName` defaults to `viewfinder`.
    public func setTarget(name: String?, symbolName: String? = nil) {
        tokenRow.isHidden = (name == nil)
        tokenLabel.stringValue = name ?? ""
        let symbol = symbolName ?? "viewfinder"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            tokenIcon.image = image
        }
        if configuration.style == .popover, isViewLoaded {
            view.layoutSubtreeIfNeeded()
            preferredContentSize = view.fittingSize
        }
    }

    public func setChoosing(_ on: Bool) {
        choosing = on
        // No title row means nothing to say it in — the host's own chrome carries the mode.
        if titleRow != nil {
            titleLabel.stringValue = on ? "Choose which part of the UI to give feedback on"
                                        : (configuration.title ?? "")
            titleLabel.textColor = on ? .labelColor : .secondaryLabelColor
            doneButton.title = on ? "Cancel" : "Done"
        }
        // "Dim the field": alpha only — never restructure the stack mid-flight.
        composeRow.alphaValue = on ? 0.4 : 1
        textScroll.alphaValue = on ? 0.4 : 1
        tokenRow.alphaValue = on ? 0.4 : 1
        field.isEnabled = !on
        textView.isEditable = !on
        sendButton.isEnabled = !on && !trimmedMessage.isEmpty
        chooseButton.isEnabled = !on
    }

    public func focusField() {
        view.window?.makeFirstResponder(usesTextView ? textView : field)
    }

    public var text: String {
        get { usesTextView ? textView.string : field.stringValue }
        set {
            if usesTextView {
                textView.string = newValue
                placeholderLabel.isHidden = !newValue.isEmpty
            } else {
                field.stringValue = newValue
            }
            refreshSendEnabled()
        }
    }

    private var trimmedMessage: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: actions

    @objc private func doneTapped() { choosing ? onCancelChoose?() : onDone?() }
    @objc private func chooseTapped() { onChooseUI?() }
    @objc private func removeTargetTapped() { onRemoveTarget?() }
    @objc private func sendTapped() {
        let message = trimmedMessage
        guard !message.isEmpty else { return }
        onSend?(message)
        // The bar stays open for the next thought, so it clears. A popover is dismissed by its
        // host and may be an EDIT of existing text ("Save") — clearing it there would wipe the
        // comment on the way out.
        if configuration.style == .floatingBar { field.stringValue = "" }
        refreshSendEnabled()
    }

    public func controlTextDidChange(_ obj: Notification) { refreshSendEnabled() }

    public func textDidChange(_ notification: Notification) {
        placeholderLabel.isHidden = !textView.string.isEmpty
        refreshSendEnabled()
    }

    /// Return sends. (Send's `\r` key equivalent normally gets there first; this is the path
    /// when it doesn't — e.g. while the button is disabled and then isn't.) Shift-Return and
    /// ⌥Return fall through to the text view as a newline.
    public func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)),
              !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) else { return false }
        sendTapped()
        return true
    }
    private func refreshSendEnabled() { sendButton.isEnabled = !choosing && !trimmedMessage.isEmpty }
}

/// Review UI Mode's bar. **Keep this name and this module**: the injected build of this SDK
/// (`Sources/AgentPadDevHelperInject/InjectEntry.swift`) detects an app that already embeds the
/// package by looking up the mangled runtime name `_TtC17AgentPadDevHelper23ReviewBarViewController`,
/// and `InjectGuardProbeTests` pins it.
final class ReviewBarViewController: LeaveCommentViewController {
    init(appName: String) {
        super.init(configuration: .reviewBar(appName: appName))
    }
    required init?(coder: NSCoder) { fatalError("programmatic only") }
}

#endif

// MARK: - UIKit

#if canImport(UIKit)

final class ReviewBarViewController: UIViewController, UITextFieldDelegate {
    var onSend: ((String) -> Void)?
    var onChooseUI: (() -> Void)?
    var onCancelChoose: (() -> Void)?
    var onDone: (() -> Void)?
    var onRemoveTarget: (() -> Void)?

    private let appName: String
    private var choosing = false

    private let card = UIView()
    private let titleLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let field = UITextField()
    private let chooseButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let composeRow = UIStackView()
    private let tokenRow = UIStackView()
    private let tokenIcon = UIImageView()
    private let tokenLabel = UILabel()

    init(appName: String) {
        self.appName = appName
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("programmatic only") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Bottom card over a dimmed backdrop; tapping the backdrop = Done.
        view.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(backdropTapped(_:))))

        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 20
        card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), doneButton])
        titleRow.axis = .horizontal
        titleRow.spacing = 8

        field.placeholder = "Leave UI feedback about \(appName)…"
        field.font = .systemFont(ofSize: 15)
        field.backgroundColor = .tertiarySystemBackground
        field.layer.cornerRadius = 14
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 8))
        field.leftViewMode = .always
        field.delegate = self
        field.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        field.heightAnchor.constraint(equalToConstant: 40).isActive = true

        chooseButton.setImage(UIImage(systemName: "scope"), for: .normal)
        chooseButton.addTarget(self, action: #selector(chooseTapped), for: .touchUpInside)
        sendButton.setImage(UIImage(systemName: "arrow.up.circle.fill"), for: .normal)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        composeRow.axis = .horizontal
        composeRow.spacing = 8
        composeRow.alignment = .center
        [field, chooseButton, sendButton].forEach { composeRow.addArrangedSubview($0) }

        tokenIcon.image = UIImage(systemName: "viewfinder")
        tokenIcon.tintColor = .secondaryLabel
        tokenIcon.setContentHuggingPriority(.required, for: .horizontal)
        tokenLabel.font = .systemFont(ofSize: 12, weight: .medium)
        tokenLabel.textColor = .secondaryLabel
        tokenLabel.lineBreakMode = .byTruncatingMiddle
        let removeButton = UIButton(type: .system)
        removeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        removeButton.tintColor = .tertiaryLabel
        removeButton.addTarget(self, action: #selector(removeTargetTapped), for: .touchUpInside)

        let chip = UIStackView(arrangedSubviews: [tokenIcon, tokenLabel, removeButton])
        chip.axis = .horizontal
        chip.spacing = 4
        chip.isLayoutMarginsRelativeArrangement = true
        chip.layoutMargins = UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 4)
        chip.layer.cornerRadius = 12
        chip.layer.borderWidth = 1
        chip.layer.borderColor = UIColor.separator.cgColor

        tokenRow.axis = .horizontal
        tokenRow.addArrangedSubview(chip)
        tokenRow.addArrangedSubview(UIView())

        let stack = UIStackView(arrangedSubviews: [titleRow, composeRow, tokenRow])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The card's BOX still reaches the bottom of the screen — what rides the keyboard is
            // its content. With the keyboard up the lower part is simply hidden behind it, so the
            // card can't leave a strip of dimmed backdrop under itself as it moves.
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            // The compose row must stay visible while you type in it, so the content is pinned to
            // the KEYBOARD, not to the card's safe area: `keyboardLayoutGuide` (iOS 15, this
            // package's floor) sits at the safe-area bottom while the keyboard is away — i.e.
            // exactly where this used to be — and rises with it, animating in step because UIKit
            // moves the guide inside the keyboard's own animation.
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
        ])
        setChoosing(false)
        refreshSendEnabled()
    }

    // MARK: state from the controller

    /// What this feedback is about. nil hides the token row; `symbolName` defaults to
    /// `viewfinder` (same contract as the AppKit body, which the shared controller calls).
    func setTarget(name: String?, symbolName: String? = nil) {
        tokenRow.isHidden = (name == nil)
        tokenLabel.text = name
        if let image = UIImage(systemName: symbolName ?? "viewfinder") { tokenIcon.image = image }
    }

    func setChoosing(_ on: Bool) {
        choosing = on
        titleLabel.text = on ? "Choose which part of the UI to give feedback on"
                             : "Review Mode — \(appName)"
        titleLabel.textColor = on ? .label : .secondaryLabel
        doneButton.setTitle(on ? "Cancel" : "Done", for: .normal)
        composeRow.alpha = on ? 0.4 : 1
        tokenRow.alpha = on ? 0.4 : 1
        field.isEnabled = !on
        chooseButton.isEnabled = !on
        refreshSendEnabled()
    }

    func focusField() { field.becomeFirstResponder() }

    private var trimmedMessage: String {
        (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: actions

    @objc private func backdropTapped(_ g: UITapGestureRecognizer) {
        guard !card.frame.contains(g.location(in: view)) else { return }
        leave()
    }
    @objc private func doneTapped() { leave() }

    /// Both ways out of the composer. While CHOOSING, "Done" reads Cancel and only backs out of
    /// the picker — the message survives, so there's nothing to ask about. Otherwise leaving
    /// throws away whatever is in the field, so a non-empty field asks first: on a phone the two
    /// exits are a tap on the backdrop and a tap on Done, both easy to hit by accident.
    private func leave() {
        guard !choosing else { onCancelChoose?(); return }
        guard !trimmedMessage.isEmpty else { onDone?(); return }
        let alert = UIAlertController(title: "Discard this feedback?",
                                      message: "You haven't sent what you wrote.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel) { [weak self] _ in
            self?.field.becomeFirstResponder()
        })
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
            self?.field.text = ""
            self?.onDone?()
        })
        present(alert, animated: true)
    }
    @objc private func chooseTapped() { onChooseUI?() }
    @objc private func removeTargetTapped() { onRemoveTarget?() }
    @objc private func sendTapped() {
        let message = trimmedMessage
        guard !message.isEmpty else { return }
        onSend?(message)
        field.text = ""
        refreshSendEnabled()
    }
    @objc private func textChanged() { refreshSendEnabled() }
    private func refreshSendEnabled() { sendButton.isEnabled = !choosing && !trimmedMessage.isEmpty }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool { sendTapped(); return true }
}

#endif
