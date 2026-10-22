import AppKit
import TailscodeCore

/// What the main pane says when the app holds no real server: Core's `EmptyWelcome` drawn as a
/// title, a sentence, the one step standing between this person and a conversation, and the buttons
/// that open the checklist. It is content on the opaque canvas, so it carries no glass, and it
/// invents no sentence: what each button does is the hub's to say, through `onAction`.
@MainActor
final class EmptyWelcomeView: NSView {
    var onAction: ((EmptyWelcome.Intent) -> Void)?

    private let column = FillingStack(topDown: true, stretches: false)
    private(set) var shown: EmptyWelcome?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        column.spacing = MacTheme.Spacing.m
        column.alignment = .centerX
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var buttonTitles: [String] {
        var found: [String] = []
        func gather(_ view: NSView) {
            if let button = view as? NSButton { found.append(button.title) }
            view.subviews.forEach(gather)
        }
        gather(self)
        return found
    }

    @objc private func repaint() {
        guard let shown else { return }
        show(shown)
    }

    func show(_ welcome: EmptyWelcome) {
        shown = welcome
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        column.addArrangedSubview(emblem())
        column.addArrangedSubview(centered(welcome.title, role: .headline, color: MacTheme.Color.label))
        column.addArrangedSubview(
            centered(welcome.detail, role: .panelDetail, color: MacTheme.Color.secondaryLabel))
        column.addArrangedSubview(step(welcome.step))
        column.addArrangedSubview(buttons(welcome))
        column.setCustomSpacing(MacTheme.Spacing.l, after: column.arrangedSubviews[2])
        column.setCustomSpacing(MacTheme.Spacing.l, after: column.arrangedSubviews[3])
    }

    private func emblem() -> NSView {
        let image = NSImageView()
        image.image = NSImage(
            systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 30 * MacTheme.UIScale.factor, weight: .light))
        image.contentTintColor = MacTheme.Color.accent
        image.setAccessibilityElement(false)
        return image
    }

    private func centered(_ text: String, role: TypeRole, color: NSColor) -> NSTextField {
        let label = RowKit.wrapping(text, font: MacTheme.Ramp.font(role), color: color)
        label.alignment = .center
        label.isSelectable = false
        label.preferredMaxLayoutWidth = 420
        return label
    }

    private func step(_ step: EmptyWelcome.Step) -> NSView {
        let blocked = step.fix != nil
        let card = RowKit.card(
            symbol: blocked ? "exclamationmark.triangle" : "desktopcomputer", title: step.title,
            detail: step.detail, tint: blocked ? MacTheme.Color.warning : MacTheme.Color.accent)
        if let fix = step.fix {
            card.addArrangedSubview(
                FirstRunBlocks.buttonRow([button(fix, primary: false)]))
        }
        card.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return card
    }

    private func buttons(_ welcome: EmptyWelcome) -> NSView {
        let row = NSStackView(
            views: [button(welcome.primary, primary: true)]
                + welcome.secondary.map { button($0, primary: false) })
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func button(_ action: EmptyWelcome.Action, primary: Bool) -> NSButton {
        let button = RowKit.ActionButton(title: action.title) { [weak self] in
            self?.onAction?(action.intent)
        }
        button.toolTip = action.help
        button.setAccessibilityHelp(action.help)
        if primary {
            button.keyEquivalent = "\r"
            button.setAccessibilityIdentifier("welcome.primary")
        }
        return button
    }
}
