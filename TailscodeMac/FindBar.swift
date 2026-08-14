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
    private lazy var fieldWidth = field.widthAnchor.constraint(equalToConstant: 220)
    private var scale = MacTheme.UIScale.factor

    var query: String { field.stringValue }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = Localized.text("Find in this conversation")
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.translatesAutoresizingMaskIntoConstraints = false
        fieldWidth.isActive = true

        countLabel.textColor = MacTheme.Color.onGlassSecondary
        applyScale()

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

    /// The bar is built once and floats over a transcript that rebuilds every row at each step of
    /// the type scale, so without this it would keep the type — and the field width the placeholder
    /// has to fit in — it was born with.
    override func viewWillDraw() {
        super.viewWillDraw()
        guard scale != MacTheme.UIScale.factor else { return }
        scale = MacTheme.UIScale.factor
        applyScale()
    }

    /// The counter is the one thing here that changes under the pointer, so it is set in figures
    /// that share a width — stepping 1/12 to 2/12 must not slide the capsule and its buttons.
    private func applyScale() {
        fieldWidth.constant = 220 * scale
        field.font = MacTheme.Ramp.font(.panelLabel)
        countLabel.font = MacTheme.Ramp.font(.metricDetail)
    }

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
            onStep?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }
}
