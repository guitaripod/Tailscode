import AppKit
import TailscodeCore

/// The transcript's own search, over what the rows say rather than what the server indexes: it
/// works offline, on a saved copy, and mid-turn. A glass capsule floating over the top of the
/// conversation — a control, so it gets material; the hits stay in the opaque canvas below.
@MainActor
final class FindBar: NSView {
    var onQueryChanged: ((String) -> Void)?
    var onStep: ((Int) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")

    var query: String { field.stringValue }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = Localized.text("Find in this conversation")
        field.font = MacTheme.Font.body()
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true

        countLabel.font = MacTheme.Font.caption()
        countLabel.textColor = MacTheme.Color.secondaryLabel

        let previous = symbolButton("chevron.up", tip: Localized.text("Previous match")) {
            [weak self] in self?.onStep?(-1)
        }
        let next = symbolButton("chevron.down", tip: Localized.text("Next match")) {
            [weak self] in self?.onStep?(1)
        }
        let close = symbolButton("xmark", tip: Localized.text("Close")) {
            [weak self] in self?.onClose?()
        }

        let row = NSStackView(views: [field, countLabel, previous, next, close])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.m)
        row.translatesAutoresizingMaskIntoConstraints = false

        let glass = MacTheme.glass(around: row, cornerRadius: 18)
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setCount(_ text: String) {
        countLabel.stringValue = text
    }

    func focusField() {
        window?.makeFirstResponder(field)
    }

    func clear() {
        field.stringValue = ""
        countLabel.stringValue = ""
    }

    private func symbolButton(_ symbol: String, tip: String, action: @escaping () -> Void)
        -> NSButton
    {
        let button = RowKit.ActionButton(title: "", action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.isBordered = false
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
}

extension FindBar: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        onQueryChanged?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector)
        -> Bool
    {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            onStep?(1)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }
}
