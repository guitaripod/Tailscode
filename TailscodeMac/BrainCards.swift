import AppKit
import TailscodeCore

/// What a node says when it is pointed at, laid over the head beside the node: the tool and how it
/// ended, the command, path or words, the lines it printed, and where the step sits in the turn.
///
/// It is content on the stage rather than a window of its own: an opaque card with a hairline, set
/// in the app's ramp, that never takes the keyboard and never answers the pointer, so the pointer
/// that raised it can move on to the next node without going through it.
@MainActor
final class BrainCardView: NSView {
    static let width: CGFloat = 292

    private let stack = NSStackView()
    private(set) var reading: NeuralReading.Card?
    private var inks: BrainInks?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The card for a node, drawn in these colours. Returns the card's height at its fixed width.
    @discardableResult
    func show(_ card: NeuralReading.Card, inks: BrainInks) -> CGFloat {
        guard card != reading || inks.palette != self.inks?.palette else { return frame.height }
        reading = card
        self.inks = inks
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let tone = zoneInk(card, inks)
        let title = Self.label(
            card.title, role: .toolName, color: inks.text, lines: 1, truncate: .byTruncatingTail)
        let word = Self.statusWord(card, inks: inks)
        let head = NSStackView(views: [Self.marker(card, tone: tone), title, Self.stretch(), word])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 7
        add(head)
        if !card.body.isEmpty {
            add(
                Self.label(
                    card.body, role: .code, color: inks.text, lines: 4,
                    truncate: .byTruncatingTail))
        }
        if let tally = card.tally {
            add(Self.label(tally, role: .diff, color: tone, lines: 1, truncate: .byTruncatingTail))
        }
        if !card.output.isEmpty {
            add(output(card.output, inks: inks))
        }
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        add(rule)
        add(
            Self.label(
                card.footer, role: .hint, color: inks.textDim, lines: 3,
                truncate: .byTruncatingTail))
        layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height)
        setFrameSize(NSSize(width: Self.width, height: height))
        paint(inks)
        return height
    }

    func hide() {
        isHidden = true
        reading = nil
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(
            equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
        ).isActive = true
    }

    private func paint(_ inks: BrainInks) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = inks.raised.blended(withFraction: 0.35, of: inks.canvas)?
                .withAlphaComponent(0.97).cgColor
            layer?.borderColor = inks.rule.cgColor
            layer?.borderWidth = 1
            layer?.cornerRadius = MacTheme.Radius.control
            layer?.cornerCurve = .continuous
        }
    }

    private func zoneInk(_ card: NeuralReading.Card, _ inks: BrainInks) -> NSColor {
        switch card.status {
        case .failed: return NSColor(hex: inks.palette.danger) ?? inks.text
        case .waitingApproval, .waitingAnswer, .stalled:
            return NSColor(hex: inks.palette.warn) ?? inks.text
        default: return inks.page(card.zone)
        }
    }

    private static func marker(_ card: NeuralReading.Card, tone: NSColor) -> NSView {
        let size: CGFloat = 16
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: size).isActive = true
        view.heightAnchor.constraint(equalToConstant: size).isActive = true
        let shape = CAShapeLayer()
        shape.path = BrainShapes.path(card.zone.shape, radius: size / 2 - 1.5)
        shape.frame = CGRect(x: 1.5, y: 1.5, width: size - 3, height: size - 3)
        shape.fillColor = nil
        shape.strokeColor = tone.cgColor
        shape.lineWidth = 1.4
        view.layer?.addSublayer(shape)
        view.setAccessibilityElement(false)
        return view
    }

    private static func statusWord(_ card: NeuralReading.Card, inks: BrainInks) -> NSView {
        let ink = NSColor(hex: wordHex(card.status, inks)) ?? inks.textDim
        let label = NSTextField(labelWithString: card.statusWord.uppercased())
        label.font = MacTheme.Ramp.font(.hint)
        label.textColor = ink
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let pill = NSView()
        pill.wantsLayer = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -1),
        ])
        pill.layer?.borderColor = ink.cgColor
        pill.layer?.borderWidth = 1
        pill.layer?.cornerRadius = 8
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        return pill
    }

    private static func wordHex(_ status: NeuralStatus, _ inks: BrainInks) -> String {
        switch status {
        case .failed: return inks.palette.danger
        case .waitingApproval, .waitingAnswer, .stalled: return inks.palette.warn
        case .running: return inks.palette.accent
        case .ok, .stopped: return inks.palette.textDim
        }
    }

    private func output(_ lines: [String], inks: BrainInks) -> NSView {
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = inks.rule.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        let text = Self.label(
            lines.joined(separator: "\n"), role: .toolOutput, color: inks.textDim, lines: 4,
            truncate: .byTruncatingTail)
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(rule)
        box.addSubview(text)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            rule.topAnchor.constraint(equalTo: box.topAnchor),
            rule.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            rule.widthAnchor.constraint(equalToConstant: 2),
            text.leadingAnchor.constraint(equalTo: rule.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            text.topAnchor.constraint(equalTo: box.topAnchor),
            text.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    static func label(
        _ text: String, role: TypeRole, color: NSColor, lines: Int,
        truncate: NSLineBreakMode
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = MacTheme.Ramp.font(role)
        field.textColor = color
        field.maximumNumberOfLines = lines
        field.lineBreakMode = truncate
        field.cell?.truncatesLastVisibleLine = true
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityElement(false)
        return field
    }

    private static func stretch() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }
}

/// The list a dive ends in: the steps of one zone, in the order they ran, over the head's own
/// interior that fills the stage behind it. A row is a step; pressing one pins its node, which is
/// the same press the node itself takes.
@MainActor
final class BrainDiveList: NSView {
    private let column = FillingStack(topDown: true)
    private lazy var scroll = MacDialogs.scrollColumn(holding: column)
    private let header = NSTextField(labelWithString: "")
    private let back = NSTextField(labelWithString: "")
    private var rowIDs: [String] = []

    var onPick: ((String) -> Void)?
    var onBack: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = true
        column.spacing = 2
        column.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        addSubview(header)
        addSubview(back)
        addSubview(scroll)
        back.addGestureRecognizer(RowKit.PressGesture { [weak self] in self?.onBack?() })
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The list for `zone`, with the zone's name and the way back.
    func show(zone: NeuralZone, steps: [NeuralStep], inks: BrainInks, pinned: String?) {
        for view in column.arrangedSubviews {
            column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowIDs = steps.map(\.id)
        header.stringValue = Localized.text("%1$@ · %2$lld steps", zone.label, steps.count)
        header.font = MacTheme.Ramp.font(.toolName)
        header.textColor = NSColor(hex: inks.palette.text) ?? .labelColor
        back.stringValue = Localized.text("← Back to the head  esc")
        back.font = MacTheme.Ramp.font(.hint)
        back.textColor = inks.page(zone)
        for step in steps {
            column.addArrangedSubview(row(step, inks: inks, pinned: step.id == pinned))
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
            layer?.cornerRadius = 12
        }
        isHidden = false
        needsLayout = true
    }

    func hide() { isHidden = true }

    override func layout() {
        super.layout()
        let inset: CGFloat = 14
        header.sizeToFit()
        back.sizeToFit()
        header.frame.origin = NSPoint(x: inset, y: bounds.height - inset - header.frame.height)
        back.frame.origin = NSPoint(
            x: bounds.width - inset - back.frame.width, y: header.frame.minY)
        scroll.frame = NSRect(
            x: inset, y: inset, width: bounds.width - inset * 2,
            height: max(0, header.frame.minY - inset - 6))
    }

    private func row(_ step: NeuralStep, inks: BrainInks, pinned: Bool) -> NSView {
        let tone: NSColor =
            switch step.status {
            case .failed: NSColor(hex: inks.palette.danger) ?? .systemRed
            case .waitingApproval, .waitingAnswer, .stalled:
                NSColor(hex: inks.palette.warn) ?? .systemOrange
            default: inks.page(step.zone)
            }
        let number = NSTextField(labelWithString: "\(step.index + 1)")
        number.font = MacTheme.Ramp.font(.responseStat)
        number.textColor = tone
        number.setContentHuggingPriority(.required, for: .horizontal)
        number.widthAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
        let title = NSTextField(labelWithString: NeuralReading.title(of: step))
        title.font = MacTheme.Ramp.font(.toolName)
        title.textColor = NSColor(hex: inks.palette.text) ?? .labelColor
        title.setContentHuggingPriority(.required, for: .horizontal)
        let said =
            NeuralReading.isThought(step) || NeuralReading.isNote(step) ? step.text : step.detail
        let detail = NSTextField(labelWithString: String(said.prefix(160)))
        detail.font = MacTheme.Ramp.font(.toolDetail)
        detail.textColor = NSColor(hex: inks.palette.textDim) ?? .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentHuggingPriority(.init(1), for: .horizontal)
        detail.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        let word = NSTextField(labelWithString: NeuralReading.statusWord(step.status))
        word.font = MacTheme.Ramp.font(.hint)
        word.textColor = tone
        word.setContentHuggingPriority(.required, for: .horizontal)
        let line = NSStackView(views: [number, title, detail, word])
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 8
        line.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        line.wantsLayer = true
        line.layer?.cornerRadius = 6
        if pinned { line.layer?.backgroundColor = tone.withAlphaComponent(0.18).cgColor }
        let id = step.id
        line.addGestureRecognizer(RowKit.PressGesture { [weak self] in self?.onPick?(id) })
        line.setAccessibilityElement(true)
        line.setAccessibilityRole(.button)
        line.setAccessibilityLabel(
            NeuralReading.announcement(for: step, of: rowIDs.count))
        return line
    }

    var rowCount: Int { rowIDs.count }
}
