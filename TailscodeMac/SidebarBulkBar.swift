import AppKit
import CodingAgentKit
import TailscodeCore

/// What is held, and the verbs that act on all of it.
///
/// It appears only while chats are marked, and every word on it comes from `BulkChatCopy` so this
/// Mac names a count exactly the way the phone and the Linux desktop do. Content rather than
/// chrome: the sidebar is already the system's own glass and glass never stacks on glass, so this
/// is a tinted strip inside the list, never a second material floating over it.
@MainActor
final class SidebarBulkBar: NSView {
    var onAction: ((BulkChatAction) -> Void)?
    var onClear: (() -> Void)?
    var onSplit: ((SplitArrangement) -> Void)?

    private let badge = NSTextField(labelWithString: "")
    private let verbs = NSStackView()
    private let secondary = NSStackView()
    private let splitHeader = NSTextField(labelWithString: "")
    private let splitRow = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control
        applyWash()

        badge.textColor = MacTheme.Color.accent
        badge.setContentHuggingPriority(.required, for: .horizontal)

        let clear = NSButton(title: "✕", target: self, action: #selector(clearMarks))
        clear.isBordered = false
        clear.bezelStyle = .accessoryBar
        clear.font = MacTheme.Ramp.font(.panelFootnote)
        clear.contentTintColor = MacTheme.Color.secondaryLabel
        clear.toolTip = Localized.text("Clear the marks")
        clear.setAccessibilityLabel(Localized.text("Clear the marks"))
        clear.setContentHuggingPriority(.required, for: .horizontal)

        verbs.orientation = .horizontal
        verbs.spacing = MacTheme.Spacing.xs
        verbs.alignment = .centerY
        secondary.orientation = .horizontal
        secondary.spacing = MacTheme.Spacing.xs
        secondary.alignment = .centerY
        secondary.distribution = .fillProportionally
        splitHeader.textColor = MacTheme.Color.secondaryLabel
        splitRow.orientation = .horizontal
        splitRow.spacing = MacTheme.Spacing.xs
        splitRow.alignment = .centerY
        splitRow.distribution = .fillProportionally

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [badge, verbs, spacer, clear])
        top.orientation = .horizontal
        top.spacing = MacTheme.Spacing.xs
        top.alignment = .centerY

        let column = FillingStack(views: [top, secondary, splitHeader, splitRow])
        column.spacing = MacTheme.Spacing.xs
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            column.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.xs),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.xs),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The wash is a `CGColor`, which keeps the appearance it was resolved in — so it is written
    /// again wherever the light behind it could have changed, rather than once at construction.
    private func applyWash() {
        layer?.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.12).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyWash()
    }

    /// - Parameter actions: the destructive verb first, then the three that flip with what is
    ///   held, so a button never offers the opposite of what its own word says.
    func render(count: Int, actions: [BulkChatAction]) {
        applyWash()
        badge.font = MacTheme.Ramp.font(.badge)
        badge.stringValue = "\(count)"
        badge.setAccessibilityLabel("\(count)")
        splitHeader.font = MacTheme.Ramp.font(.panelFootnote)
        for stack in [verbs, secondary, splitRow] {
            for view in stack.arrangedSubviews {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }
        for action in actions {
            let button = self.button(action, count: count)
            if action.isDestructive {
                verbs.addArrangedSubview(button)
            } else {
                secondary.addArrangedSubview(button)
            }
        }
        let arrangements = SplitEven.offers(count: count)
        splitHeader.isHidden = arrangements.isEmpty
        splitRow.isHidden = arrangements.isEmpty
        splitHeader.stringValue = SplitEven.header(count: count)
        for arrangement in arrangements {
            splitRow.addArrangedSubview(splitButton(arrangement, count: count))
        }
    }

    private func splitButton(_ arrangement: SplitArrangement, count: Int) -> NSButton {
        let button = NSButton(
            title: arrangement.title, target: self, action: #selector(splitPicked))
        button.isBordered = false
        button.bezelStyle = .accessoryBar
        button.font = MacTheme.Ramp.font(.panelFootnote)
        button.contentTintColor = MacTheme.Color.accent
        button.image = NSImage(
            systemSymbolName: arrangement.symbolName,
            accessibilityDescription: arrangement.title)
        button.imagePosition = .imageLeading
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.toolTip = arrangement.caption(count: count)
        button.setAccessibilityLabel(arrangement.accessibleLabel(count: count))
        button.identifier = NSUserInterfaceItemIdentifier("split." + arrangement.rawValue)
        return button
    }

    @objc private func splitPicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue.split(separator: ".").last,
            let arrangement = SplitArrangement(rawValue: String(raw))
        else { return }
        onSplit?(arrangement)
    }

    private func button(_ action: BulkChatAction, count: Int) -> NSButton {
        let title = BulkChatCopy.button(action, count: count)
        let button = NSButton(title: title, target: self, action: #selector(verbPicked))
        button.isBordered = false
        button.bezelStyle = .accessoryBar
        button.font = MacTheme.Ramp.font(.panelFootnote)
        button.contentTintColor =
            action.isDestructive ? MacTheme.Color.danger : MacTheme.Color.accent
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.toolTip = title
        button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        return button
    }

    @objc private func verbPicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let action = BulkChatAction(rawValue: raw)
        else { return }
        onAction?(action)
    }

    @objc private func clearMarks() {
        onClear?()
    }
}
