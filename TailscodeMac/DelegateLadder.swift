import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// One rung as a card: its tier and label, the model answering there, and a line or two of what
/// matters about it here — health and record on the board, where it stands on a run, the numbers
/// for the class in the composer. A run's state decides the card's ground; the board's cards have
/// no state and stand plain.
@MainActor
final class DelegateRungCard: NSView {
    var onClick: ((Bool) -> Void)?

    init(title: String, model: String?, fullModel: String?, notes: [(String?, ActivityTone)], state: DelegateRungState?, cap: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let ground = RowKit.Ground(frame: .zero)
        let ink: NSColor
        let quiet: NSColor
        var toned = true
        switch state {
        case .current, .passed:
            ground.fill = MacTheme.Color.success
            ink = MacTheme.Color.onAccent
            quiet = MacTheme.Color.onAccent.withAlphaComponent(0.85)
            toned = false
        case .failed:
            ground.fill = MacTheme.Color.danger.withAlphaComponent(0.10)
            ground.stroke = MacTheme.Color.danger
            ink = MacTheme.Color.label
            quiet = MacTheme.Color.secondaryLabel
        case .held:
            ground.fill = MacTheme.Color.warning.withAlphaComponent(0.12)
            ground.stroke = MacTheme.Color.warning
            ink = MacTheme.Color.label
            quiet = MacTheme.Color.secondaryLabel
        case .pending:
            ground.fill = MacTheme.Color.canvasRaised
            ground.stroke = MacTheme.Color.accent.withAlphaComponent(0.5)
            ink = MacTheme.Color.label
            quiet = MacTheme.Color.secondaryLabel
        case .skipped, .belowStart, .beyondCeiling:
            ground.fill = MacTheme.Color.canvasRaised.withAlphaComponent(0.5)
            ink = MacTheme.Color.tertiaryLabel
            quiet = MacTheme.Color.tertiaryLabel
            toned = false
        case nil:
            ground.fill = MacTheme.Color.canvasRaised
            ground.stroke = MacTheme.Color.separator
            ink = MacTheme.Color.label
            quiet = MacTheme.Color.secondaryLabel
        }
        ground.radius = MacTheme.Radius.control
        addSubview(ground)
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        hug.isActive = true
        var views: [NSView] = [
            RowKit.label(title + (cap ? " ⌃" : ""), font: MacTheme.Ramp.font(.rowTitleStrong), color: ink)
        ]
        if let model, !model.isEmpty {
            let label = RowKit.label(model, font: MacTheme.Ramp.font(.code), color: quiet)
            label.toolTip = fullModel
            views.append(label)
        }
        for (text, tone) in notes {
            guard let text, !text.isEmpty else { continue }
            let color = toned && tone != .quiet ? tone.color : quiet
            views.append(RowKit.label(text, font: MacTheme.Ramp.font(.rowMeta), color: color))
        }
        for view in views {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let lines = NSStackView(views: views)
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)
        NSLayoutConstraint.activate([
            ground.topAnchor.constraint(equalTo: topAnchor),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.s),
            lines.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -MacTheme.Spacing.s),
            lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MacTheme.Spacing.s),
        ])
        for view in views {
            view.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2 * MacTheme.Spacing.s).isActive = true
        }
        let said = ([title, model] + notes.map { $0.0 }).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        toolTip = said
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(said)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Cards side by side, each as wide as the next and joined by a chevron, cheapest first.
    static func row(_ cards: [DelegateRungCard]) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        for (index, card) in cards.enumerated() {
            if index > 0 {
                let link = RowKit.label("›", font: MacTheme.Ramp.font(.rowMeta), color: MacTheme.Color.tertiaryLabel)
                link.setContentHuggingPriority(.required, for: .horizontal)
                link.setContentCompressionResistancePriority(.required, for: .horizontal)
                row.addArrangedSubview(link)
            }
            card.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(card)
            if index > 0 {
                card.widthAnchor.constraint(equalTo: cards[0].widthAnchor).isActive = true
                card.heightAnchor.constraint(equalTo: cards[0].heightAnchor).isActive = true
            }
        }
        return row
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { return super.mouseDown(with: event) }
        onClick(event.modifierFlags.contains(.shift))
    }

    /// A rung the composer lets a person pick is a stop in the Tab loop with Full Keyboard
    /// Access on: Space or Return picks it the way a click does, and with Shift the way a
    /// Shift-click does. The ladder was the one part of a packet only a mouse could set.
    override var acceptsFirstResponder: Bool {
        onClick != nil && NSApp.isFullKeyboardAccessEnabled
    }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds, xRadius: MacTheme.Radius.control,
            yRadius: MacTheme.Radius.control
        ).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard let onClick, [49, 36, 76].contains(event.keyCode) else {
            return super.keyDown(with: event)
        }
        onClick(event.modifierFlags.contains(.shift))
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(false)
        return onClick != nil
    }
}

/// The ladder as rungs in a row. Reading, each wears its state and the run's word for it;
/// composing, a click is the start rung and a shift-click is the ceiling, and a click on the start
/// rung again unsets it.
@MainActor
final class MacLadderView: NSView {
    var compose = false
    var rungs: [DelegateRung] = [] { didSet { rebuild() } }
    private(set) var start: String?
    private(set) var ceiling: String?
    /// Where the run will start and stop when nothing is set — the class's own range, drawn so
    /// "the class decides" is a picture rather than a shrug.
    private var impliedStart: String?
    private var impliedCeiling: String?
    private var ladder: DelegateLadder?
    var onChange: ((String?, String?) -> Void)?
    private var row: NSStackView?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        hug.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A run's ladder, each rung saying where it stands in the run's own words.
    func show(_ ladder: DelegateLadder) {
        self.ladder = ladder
        toolTip = ladder.spoken
        rungs = ladder.rungs
    }

    func set(start: String?, ceiling: String?) {
        self.start = start
        self.ceiling = ceiling
        rebuild()
    }

    func setImplied(start: String?, ceiling: String?) {
        guard impliedStart != start || impliedCeiling != ceiling else { return }
        impliedStart = start
        impliedCeiling = ceiling
        rebuild()
    }

    private func index(of tier: String) -> Int { rungs.firstIndex { $0.tier == tier } ?? 0 }

    private func rebuild() {
        row?.removeFromSuperview()
        let chosenStart = start.map(index(of:))
        let startIndex = chosenStart ?? impliedStart.map(index(of:))
        let ceilingIndex = (ceiling ?? impliedCeiling).map(index(of:))
        var cards: [DelegateRungCard] = []
        for (offset, rung) in rungs.enumerated() {
            let state: DelegateRungState
            if compose {
                if let startIndex, offset < startIndex {
                    state = .belowStart
                } else if let ceilingIndex, offset > ceilingIndex {
                    state = .beyondCeiling
                } else if let chosenStart, offset == chosenStart {
                    state = .current
                } else {
                    state = .pending
                }
            } else {
                state = rung.state
            }
            let word = compose ? rung.note : (ladder?.word(for: rung) ?? DelegateLadder.word(state))
            let card = DelegateRungCard(
                title: rung.label.isEmpty ? rung.tier : "\(rung.tier) · \(rung.label)",
                model: rung.model.map(DelegateWords.shortModel), fullModel: rung.model,
                notes: [(word, compose ? .quiet : state.tone)], state: state,
                cap: compose && ceilingIndex == offset)
            if compose {
                card.onClick = { [weak self] shift in self?.clicked(rung.tier, shift: shift) }
            }
            cards.append(card)
        }
        let row = DelegateRungCard.row(cards)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        self.row = row
    }

    private func clicked(_ tier: String, shift: Bool) {
        guard compose else { return }
        if shift {
            ceiling = tier
            if let start, index(of: tier) < index(of: start) { self.start = tier }
        } else {
            start = start == tier ? nil : tier
            if let start, let ceiling, index(of: ceiling) < index(of: start) { self.ceiling = start }
        }
        rebuild()
        onChange?(start, ceiling)
    }
}

/// The one thing that matters about a run right now, in a card tinted by what it means: why it
/// stopped with the verifier's own last lines, the rung waiting for you, the patch to review.
@MainActor
final class DelegateLeadCard: NSView {
    init(_ lead: DelegateRunReading.Lead) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let tint = lead.tone == .quiet ? MacTheme.Color.secondaryLabel : lead.tone.color
        let ground = RowKit.Ground(frame: .zero)
        ground.fill = tint.withAlphaComponent(0.08)
        ground.radius = MacTheme.Radius.card
        addSubview(ground)
        let bar = RowKit.Ground(frame: .zero)
        bar.fill = tint
        bar.radius = 1.5
        addSubview(bar)

        let title = RowKit.label(lead.title, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var top: [NSView] = [title]
        if let caption = lead.caption {
            let label = RowKit.label(caption, font: MacTheme.Ramp.font(.rowMeta), color: MacTheme.Color.secondaryLabel)
            label.alignment = .right
            label.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            top.append(label)
        }
        let topRow = NSStackView(views: top)
        topRow.orientation = .horizontal
        topRow.distribution = .fill
        topRow.alignment = .firstBaseline
        topRow.spacing = MacTheme.Spacing.m
        var views: [NSView] = [topRow]
        if let body = lead.body, !body.isEmpty {
            if lead.bodyIsOutput {
                let text = RowKit.wrapping(body, font: MacTheme.Ramp.font(.code), color: MacTheme.Color.label)
                let box = NSView()
                box.translatesAutoresizingMaskIntoConstraints = false
                RowKit.ground(behind: box, fill: MacTheme.Color.codeBackground, radius: MacTheme.Radius.control)
                box.addSubview(text)
                NSLayoutConstraint.activate([
                    text.topAnchor.constraint(equalTo: box.topAnchor, constant: MacTheme.Spacing.s),
                    text.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -MacTheme.Spacing.s),
                    text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: MacTheme.Spacing.s),
                    text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -MacTheme.Spacing.s),
                ])
                views.append(box)
            } else {
                views.append(RowKit.wrapping(body, font: MacTheme.Ramp.font(.cardBody), color: MacTheme.Color.secondaryLabel))
            }
        }
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.s
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        for view in views {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            ground.topAnchor.constraint(equalTo: topAnchor),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.s),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.s),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.xs),
            bar.widthAnchor.constraint(equalToConstant: 3),
            column.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.m),
            column.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: MacTheme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.m),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
