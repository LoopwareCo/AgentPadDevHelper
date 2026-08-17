import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The Review UI Mode compose surface, ONE class for both platforms (the `UIDriver` pattern:
/// a shared contract, a UIKit body and an AppKit body).
///
/// Layout, per the feature sketch:
///
///     Review Mode — <App>                      [Done]
///     [ Leave UI feedback about <App>… ] [Choose UI] [Send]
///     [⌖ attached element ✕]
///
/// On the Mac it's the content of the floating `NSPanel` `ReviewModeController` hovers above
/// the Dock; on iOS it's presented as a bottom card in the compose overlay window. It renders
/// a *recreation* of AgentPad's capsule look (this package can't import the app's `GlassPill`/
/// `ComposeViewController` — it has no dependencies), on the same 4pt grid.
///
/// Pure UI: everything it can do is a callback, wired by `ReviewModeController`.

// MARK: - AppKit

#if !canImport(UIKit) && canImport(AppKit)

final class ReviewBarViewController: NSViewController, NSTextFieldDelegate {
    var onSend: ((String) -> Void)?
    var onChooseUI: (() -> Void)?
    var onCancelChoose: (() -> Void)?
    var onDone: (() -> Void)?
    var onRemoveElement: (() -> Void)?

    private let appName: String
    private var choosing = false

    private let titleLabel = NSTextField(labelWithString: "")
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let field = NSTextField(string: "")
    private let chooseButton = NSButton(title: "Choose UI", target: nil, action: nil)
    private let sendButton = NSButton(title: "", target: nil, action: nil)
    private let composeRow = NSStackView()
    private let tokenRow = NSStackView()
    private let tokenLabel = NSTextField(labelWithString: "")

    init(appName: String) {
        self.appName = appName
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("programmatic only") }

    static let barWidth: CGFloat = 560

    override func loadView() {
        // The glass: NSVisualEffectView behind everything, rounded 20 (the bar rests at
        // 3 × 4pt-grid rows and this radius is what makes it read as AgentPad's capsule).
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 20
        effect.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .small
        doneButton.font = .systemFont(ofSize: 11)
        doneButton.target = self
        doneButton.action = #selector(doneTapped)

        let titleRow = NSStackView(views: [titleLabel, NSView(), doneButton])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8

        field.placeholderString = "Leave UI feedback about \(appName)…"
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .regular
        chooseButton.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "Choose UI")
        chooseButton.imagePosition = .imageLeading
        chooseButton.target = self
        chooseButton.action = #selector(chooseTapped)

        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .regular
        sendButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.keyEquivalent = "\r"

        composeRow.orientation = .horizontal
        composeRow.spacing = 8
        [field, chooseButton, sendButton].forEach { composeRow.addArrangedSubview($0) }

        let tokenIcon = NSImageView(image: NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil) ?? NSImage())
        tokenIcon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        tokenIcon.contentTintColor = .secondaryLabelColor
        tokenLabel.font = .systemFont(ofSize: 11, weight: .medium)
        tokenLabel.textColor = .secondaryLabelColor
        tokenLabel.lineBreakMode = .byTruncatingMiddle
        let removeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove") ?? NSImage(),
                                    target: self, action: #selector(removeElementTapped))
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

        let stack = NSStackView(views: [titleRow, composeRow, tokenRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        composeRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        tokenRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            effect.widthAnchor.constraint(equalToConstant: Self.barWidth),
        ])
        view = effect
        setChoosing(false)
        refreshSendEnabled()
    }

    // MARK: state from the controller

    /// nil hides the token row (feedback about the app in general).
    func setElementName(_ name: String?) {
        tokenRow.isHidden = (name == nil)
        tokenLabel.stringValue = name ?? ""
    }

    func setChoosing(_ on: Bool) {
        choosing = on
        titleLabel.stringValue = on ? "Choose which part of the UI to give feedback on"
                                    : "Review Mode — \(appName)"
        titleLabel.textColor = on ? .labelColor : .secondaryLabelColor
        doneButton.title = on ? "Cancel" : "Done"
        // "Dim the field": alpha only — never restructure the stack mid-flight.
        composeRow.alphaValue = on ? 0.4 : 1
        tokenRow.alphaValue = on ? 0.4 : 1
        field.isEnabled = !on
        sendButton.isEnabled = !on && !trimmedMessage.isEmpty
        chooseButton.isEnabled = !on
    }

    func focusField() {
        view.window?.makeFirstResponder(field)
    }

    private var trimmedMessage: String {
        field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: actions

    @objc private func doneTapped() { choosing ? onCancelChoose?() : onDone?() }
    @objc private func chooseTapped() { onChooseUI?() }
    @objc private func removeElementTapped() { onRemoveElement?() }
    @objc private func sendTapped() {
        let message = trimmedMessage
        guard !message.isEmpty else { return }
        onSend?(message)
        field.stringValue = ""
        refreshSendEnabled()
    }

    func controlTextDidChange(_ obj: Notification) { refreshSendEnabled() }
    private func refreshSendEnabled() { sendButton.isEnabled = !choosing && !trimmedMessage.isEmpty }
}

#endif

// MARK: - UIKit

#if canImport(UIKit)

final class ReviewBarViewController: UIViewController, UITextFieldDelegate {
    var onSend: ((String) -> Void)?
    var onChooseUI: (() -> Void)?
    var onCancelChoose: (() -> Void)?
    var onDone: (() -> Void)?
    var onRemoveElement: (() -> Void)?

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

        let tokenIcon = UIImageView(image: UIImage(systemName: "viewfinder"))
        tokenIcon.tintColor = .secondaryLabel
        tokenIcon.setContentHuggingPriority(.required, for: .horizontal)
        tokenLabel.font = .systemFont(ofSize: 12, weight: .medium)
        tokenLabel.textColor = .secondaryLabel
        tokenLabel.lineBreakMode = .byTruncatingMiddle
        let removeButton = UIButton(type: .system)
        removeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        removeButton.tintColor = .tertiaryLabel
        removeButton.addTarget(self, action: #selector(removeElementTapped), for: .touchUpInside)

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
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        setChoosing(false)
        refreshSendEnabled()
    }

    // MARK: state from the controller

    func setElementName(_ name: String?) {
        tokenRow.isHidden = (name == nil)
        tokenLabel.text = name
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
        choosing ? onCancelChoose?() : onDone?()
    }
    @objc private func doneTapped() { choosing ? onCancelChoose?() : onDone?() }
    @objc private func chooseTapped() { onChooseUI?() }
    @objc private func removeElementTapped() { onRemoveElement?() }
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
