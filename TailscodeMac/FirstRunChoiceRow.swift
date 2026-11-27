import AppKit
import CodingAgentKit
import TailscodeCore

/// One answer to first run's question, or one way in for a machine that is already set up, as a
/// row the whole of which is the press: a mark in the agent's own colour, the name, the sentence
/// that says what it means and a chevron that says it goes somewhere. A bezelled button with its
/// sentence loose underneath read as a form to fill in; an answer is a press that moves on.
///
/// It is a press for the keyboard and for VoiceOver too: it takes its place in the key loop,
/// answers Space and Return, and wears the system's focus ring in its own shape.
@MainActor
final class FirstRunChoiceRow: NSView {
    private let action: () -> Void
    private let surface: PressSurface

    init(symbol: String, tint: NSColor, title: String, detail: String, action: @escaping () -> Void) {
        self.action = action
        surface = PressSurface(
            content: Self.content(symbol: symbol, tint: tint, title: title, detail: detail),
            outset: NSEdgeInsets(), radius: MacTheme.Radius.control)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        surface.onPress = action
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp(detail)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    convenience init(way: FirstRunPlan.Way, action: @escaping () -> Void) {
        self.init(
            symbol: Self.symbol(for: way.kind), tint: MacTheme.Color.accent, title: way.title,
            detail: way.detail, action: action)
    }

    convenience init(choice: FirstRunPlan.AgentChoice, action: @escaping () -> Void) {
        self.init(
            symbol: MacTheme.brandSymbol(choice.agent), tint: MacTheme.Color.brand(choice.agent),
            title: choice.title, detail: choice.detail, action: action)
    }

    /// The same four marks the phone's ways wear, so a way looks like itself on every client.
    private static func symbol(for kind: FirstRunPlan.Way.Kind) -> String {
        switch kind {
        case .scan: return "qrcode.viewfinder"
        case .link: return "link"
        case .install: return "terminal"
        case .tailnet: return "dot.radiowaves.left.and.right"
        }
    }

    private static func content(symbol: String, tint: NSColor, title: String, detail: String) -> NSView {
        let scale = MacTheme.UIScale.factor
        let mark = NSImageView()
        mark.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15 * scale, weight: .semibold))
        mark.contentTintColor = tint
        mark.imageAlignment = .alignCenter
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.setAccessibilityElement(false)

        let heading = RowKit.label(title, font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.label)
        let caption = RowKit.wrapping(
            detail, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
        caption.isSelectable = false
        let words = FillingStack(topDown: true)
        words.spacing = 1
        words.addArrangedSubview(heading)
        words.addArrangedSubview(caption)

        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10 * scale, weight: .semibold))
        chevron.contentTintColor = MacTheme.Color.tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.setAccessibilityElement(false)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        chevron.translatesAutoresizingMaskIntoConstraints = false
        for part in [mark, words, chevron] { row.addSubview(part) }
        let inset = MacTheme.Spacing.m
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: inset),
            mark.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 22 * scale),
            words.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: inset),
            words.topAnchor.constraint(equalTo: row.topAnchor, constant: MacTheme.Spacing.s + 2),
            words.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -(MacTheme.Spacing.s + 2)),
            words.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -inset),
            chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -inset),
            chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        RowKit.ground(
            behind: row, fill: MacTheme.Color.subagentBackground, stroke: MacTheme.Color.separator,
            radius: MacTheme.Radius.control)
        return row
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds, xRadius: MacTheme.Radius.control, yRadius: MacTheme.Radius.control
        ).fill()
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r": action()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
