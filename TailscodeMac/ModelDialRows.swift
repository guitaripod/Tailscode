import AppKit
import CodingAgentKit
import TailscodeCore

@MainActor
final class ColumnFrameView: NSView {
    var owns = false {
        didSet { if owns != oldValue { needsDisplay = true } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard owns else { return }
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        MacTheme.Color.accent.withAlphaComponent(0.06).setFill()
        shape.fill()
        MacTheme.Color.accent.withAlphaComponent(0.45).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

/// One model row: the star, the family's dot, the name, its capabilities in the quieter register,
/// the pinned pair's level as the pill's own word and meter, the door or the machine, the wall in
/// front of it, and a check on the row this chat runs. The row under the cursor wears a wash and
/// an accent edge; hovering moves the cursor, so the mouse and the arrows are one cursor. A row
/// that is a message — a search that found nothing — is two quiet lines and answers nothing.
@MainActor
final class DialModelRowView: NSView {
    var onHover: (() -> Void)?
    var onPress: (() -> Void)?
    var isFocused = false {
        didSet { if isFocused != oldValue { needsDisplay = true } }
    }
    private var row: ModelDialRow
    private var tracking: NSTrackingArea?

    private let line = NSStackView()
    private let star = NSTextField(labelWithString: "")
    private let dot = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let chips = NSStackView()
    private var chipFacts: [ModelFact] = []
    private let spacer = NSView()
    private let wall = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let level = DialLevelMeter()
    private let check = NSTextField(labelWithString: "")
    private let messageTitle = NSTextField(wrappingLabelWithString: "")
    private let messageDetail = NSTextField(wrappingLabelWithString: "")

    init(row: ModelDialRow) {
        self.row = row
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        if row.isMessage { buildMessage() } else { buildModel() }
        apply()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A fresh reading of the same row: only the words that differ are written, because a list a
    /// pointer hovers or a query re-ranks hands the same rows back many times a second.
    func update(_ fresh: ModelDialRow) {
        guard fresh != row else { return }
        row = fresh
        apply()
    }

    /// The list's width less the row's insets, so the message wraps where it will be drawn and the
    /// list is measured tall enough to hold it.
    private static var messageWidth: CGFloat { ModelDialPanel.listWidth - 20 }

    private func buildModel() {
        setAccessibilityRole(.button)
        star.font = MacTheme.Ramp.font(.rowMeta)
        star.alignment = .center
        dot.font = MacTheme.Ramp.font(.chip)
        dot.setContentHuggingPriority(.required, for: .horizontal)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        chips.orientation = .horizontal
        chips.spacing = 3
        chips.setContentCompressionResistancePriority(.required, for: .horizontal)
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        wall.font = MacTheme.Ramp.font(.rowNote)
        wall.textColor = MacTheme.Color.danger
        wall.lineBreakMode = .byTruncatingTail
        wall.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        detail.font = MacTheme.Ramp.font(.rowNote)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        check.font = MacTheme.Ramp.font(.rowMeta)
        check.textColor = MacTheme.Color.accent
        check.alignment = .center
        line.orientation = .horizontal
        line.alignment = .centerY
        line.distribution = .fill
        line.spacing = MacTheme.Spacing.s
        line.translatesAutoresizingMaskIntoConstraints = false
        line.setViews(
            [star, dot, title, chips, spacer, wall, detail, level, check], in: .leading)
        line.setCustomSpacing(5, after: dot)
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            line.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            star.widthAnchor.constraint(equalToConstant: 14 * MacTheme.UIScale.factor),
            check.widthAnchor.constraint(equalToConstant: 12 * MacTheme.UIScale.factor),
        ])
    }

    /// The search that found nothing says so in two lines — what was asked and where it looked —
    /// in the quiet ink of a caption, because it is an answer and not a row to take.
    private func buildMessage() {
        setAccessibilityRole(.staticText)
        messageTitle.font = MacTheme.Ramp.font(.rowTitle)
        messageTitle.textColor = MacTheme.Color.secondaryLabel
        messageTitle.isSelectable = false
        messageTitle.preferredMaxLayoutWidth = Self.messageWidth
        messageDetail.font = MacTheme.Ramp.font(.rowNote)
        messageDetail.textColor = MacTheme.Color.tertiaryLabel
        messageDetail.isSelectable = false
        messageDetail.preferredMaxLayoutWidth = Self.messageWidth
        let stack = NSStackView(views: [messageTitle, messageDetail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            messageTitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageDetail.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func apply() {
        guard !row.isMessage else {
            setAccessibilityLabel(
                [row.title, row.detail].filter { !$0.isEmpty }.joined(separator: ". "))
            messageTitle.stringValue = row.title
            messageDetail.stringValue = row.detail
            messageDetail.isHidden = row.detail.isEmpty
            return
        }
        let levelWords = row.level.map { Localized.text("%@ effort", $0.word) }
        setAccessibilityLabel(
            [row.title, levelWords, row.detail, row.isStarred ? Localized.text("pinned") : nil]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityValue(row.isCurrent ? Localized.text("current") : nil)
        star.stringValue = row.candidate == nil ? "" : (row.isStarred ? "★" : "☆")
        star.textColor = row.isStarred ? MacTheme.Color.mark : MacTheme.Color.tertiaryLabel
        dot.isHidden = row.candidate == nil
        dot.textColor =
            row.candidate.flatMap {
                ModelBadge.chip(
                    model: $0.selection.modelID, effort: nil, providerID: nil,
                    catalog: [$0.primary.model])
            }
            .map(MacTheme.Color.modelIdentity) ?? MacTheme.Color.tertiaryLabel
        title.stringValue = row.title
        title.font = MacTheme.Ramp.font(row.isCurrent ? .rowTitleStrong : .rowTitle)
        title.textColor =
            row.kind == .serverDefault || row.opensCatalog
            ? MacTheme.Color.secondaryLabel : MacTheme.Color.label
        title.toolTip = row.title
        applyChips()
        wall.isHidden = row.wall == nil
        if let quota = row.wall {
            wall.stringValue = QuotaSurface.rowNote(quota)
            wall.toolTip = QuotaSurface.bannerBody(quota)
        }
        let showsDetail = row.level == nil || row.candidate?.isElsewhere == true
        detail.stringValue = row.detail
        detail.toolTip = row.detail
        detail.isHidden = !(showsDetail && !row.detail.isEmpty)
        level.isHidden = row.level == nil
        if let level = row.level { self.level.show(level) }
        check.stringValue = row.isCurrent ? "✓" : ""
        toolTip = [row.title, row.detail].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    /// The capability marks in the quieter register, rebuilt only when the facts behind them
    /// changed: a row keeps its frames and labels across a redraw that says the same thing.
    private func applyChips() {
        let facts = row.wall == nil ? row.facts.filter(\.isCapability) : []
        chips.isHidden = facts.isEmpty
        guard facts != chipFacts else { return }
        chipFacts = facts
        chips.setViews(facts.map(Self.chip), in: .leading)
    }

    /// A capability is worth a word in a thin frame and nothing louder.
    private static func chip(_ fact: ModelFact) -> NSView {
        let label = NSTextField(labelWithString: fact.tag)
        label.font = MacTheme.Ramp.font(.chip)
        label.textColor = MacTheme.Color.secondaryLabel
        label.toolTip = fact.label
        label.translatesAutoresizingMaskIntoConstraints = false
        let frame = NSView()
        frame.wantsLayer = true
        frame.layer?.cornerRadius = 4
        frame.layer?.borderWidth = 1
        frame.layer?.borderColor = MacTheme.Color.separator.cgColor
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: frame.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -1),
        ])
        return frame
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isFocused, !row.isMessage else { return }
        let wash = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        MacTheme.Color.accent.withAlphaComponent(0.12).setFill()
        wash.fill()
        let edge = NSBezierPath(
            roundedRect: NSRect(x: 0, y: 4, width: 3, height: bounds.height - 8), xRadius: 1.5,
            yRadius: 1.5)
        MacTheme.Color.accent.setFill()
        edge.fill()
    }
}

/// A pinned pair's level, drawn the way the pill draws it: the word in its tier's ink and the five
/// bars carrying the heat, so a pair reads the same in the list as it will on the pill. The word
/// and the bars are written only when the level changed, since a row handed the same pair again
/// on every redraw has nothing new to wear.
@MainActor
final class DialLevelMeter: NSView {
    private let word = NSTextField(labelWithString: "")
    private let meter = EffortMeterView()
    private var shown: ModelDialRow.Level?

    init() {
        super.init(frame: .zero)
        word.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [word, meter])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ level: ModelDialRow.Level) {
        guard level != shown else { return }
        shown = level
        let size = MacTheme.Ramp.font(.rowNote).pointSize
        if level.isPower {
            word.attributedStringValue = DialPill.rainbow(level.word, pointSize: size)
            meter.set(lit: level.heat, tint: nil, rainbow: true, cold: false, glow: 6)
        } else if level.isServer {
            word.attributedStringValue = NSAttributedString(
                string: level.word,
                attributes: EffortHeat.attributes(
                    EffortHeat.Style(weight: .regular, glow: 0), pointSize: size,
                    colour: MacTheme.Color.tertiaryLabel))
            meter.set(lit: 0, tint: nil, rainbow: false, cold: true, glow: 0)
        } else {
            word.attributedStringValue = NSAttributedString(
                string: level.word,
                attributes: EffortHeat.attributes(
                    level.word, pointSize: size, colour: MacTheme.Color.secondaryLabel))
            meter.set(
                lit: level.heat,
                tint: MacTheme.Color.modelEffort(level.word) ?? MacTheme.Color.secondaryLabel,
                rainbow: false, cold: false, glow: EffortHeat.style(level.word).glow,
                ember: level.isEmber)
        }
    }
}

/// The heading a group of rows sits under, built once for as long as its group is drawn: a list
/// that is walked again does not attribute and measure the same word again.
@MainActor
final class DialSectionHeader: NSView {
    private let label = NSTextField(labelWithString: "")
    private var top: NSLayoutConstraint?
    private var shown: String?
    private var first = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let top = label.topAnchor.constraint(equalTo: topAnchor, constant: 2)
        self.top = top
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            top,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ section: String, first: Bool) {
        if shown != section {
            shown = section
            label.attributedStringValue = NSAttributedString(
                string: section,
                attributes: MacTheme.Ramp.attributes(
                    .sectionLabel, color: MacTheme.Color.secondaryLabel))
        }
        if self.first != first {
            self.first = first
            top?.constant = first ? 2 : MacTheme.Spacing.s
        }
    }
}

/// One rung of the ladder: its digit, its word in ink over what it means, and its bars in the
/// tier's heat — hue is who answers and heat is how hard, so colour lives on the bars and the
/// frame, never on the word. The rung in force wears the tier's wash and border; the power wears
/// the rainbow.
@MainActor
final class DialRungView: NSView {
    var onPress: (() -> Void)?
    private let rung: EffortRung
    private let isCurrent: Bool
    private let tint: NSColor
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    init(rung: EffortRung, isCurrent: Bool) {
        self.rung = rung
        self.isCurrent = isCurrent
        tint =
            rung.isServer
            ? MacTheme.Color.secondaryLabel
            : rung.isPower
                ? MacTheme.Color.danger
                : (rung.level.flatMap(MacTheme.Color.modelEffort) ?? MacTheme.Color.secondaryLabel)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(rung.title), \(rung.caption)")
        toolTip = "\(rung.title) — \(rung.caption)"

        let key = NSTextField(labelWithString: String(rung.key))
        key.font = MacTheme.Ramp.font(.rowMeta)
        key.textColor = MacTheme.Color.secondaryLabel
        key.alignment = .right

        let title = NSTextField(labelWithString: "")
        if rung.isPower {
            title.attributedStringValue = DialPill.rainbow(
                rung.title, pointSize: MacTheme.Ramp.font(.rowTitleStrong).pointSize)
        } else {
            title.stringValue = rung.title
            title.font = MacTheme.Ramp.font(rung.isServer ? .rowTitle : .rowTitleStrong)
            title.textColor = rung.isServer ? MacTheme.Color.secondaryLabel : MacTheme.Color.label
        }
        title.lineBreakMode = .byTruncatingTail
        let caption = FittedWrapLabel()
        caption.stringValue = rung.caption
        caption.font = MacTheme.Ramp.font(.rowNote)
        caption.textColor = MacTheme.Color.secondaryLabel
        caption.maximumNumberOfLines = 2
        let words = NSStackView(views: [title, caption])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 0
        words.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        words.setContentHuggingPriority(.init(1), for: .horizontal)

        let meter = EffortMeterView()
        meter.set(
            lit: rung.heat, tint: rung.isServer ? nil : tint, rainbow: rung.isPower,
            cold: rung.isServer, glow: rung.level.map { EffortHeat.style($0).glow } ?? 0,
            ember: rung.isEmber)

        let line = NSStackView(views: [key, words, meter])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.distribution = .fill
        line.spacing = MacTheme.Spacing.s
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            line.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            key.widthAnchor.constraint(equalToConstant: 14 * MacTheme.UIScale.factor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        if rung.isPower {
            let stops = (0..<7).map {
                MacTheme.Color.modelRainbowLetter($0, of: 7).withAlphaComponent(
                    isCurrent ? 0.22 : 0.12)
            }
            NSGradient(colors: stops)?.draw(in: shape, angle: 0)
        } else if isCurrent {
            tint.withAlphaComponent(0.14).setFill()
            shape.fill()
        }
        if isCurrent {
            tint.withAlphaComponent(0.55).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        } else if hovered {
            MacTheme.Color.separator.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
    }
}

/// A list read top-down: the scroll view's document starts at the top of its clip rather than at
/// AppKit's bottom-left origin, so a short list sits under the search field and a long one
/// opens on its first row.
@MainActor
final class FlippedStackView: NSStackView {
    nonisolated override var isFlipped: Bool { true }
}

/// Pinned pairs over the chooser's fixture fleet, so the dial's pairs, previews and carry notices
/// can be drawn on a desk with no servers and no pins of its own: one pair this chat runs, one
/// whose level the model lacks, one on another machine kept as a bare star.
enum ModelDialDemo {
    static var presets: [ModelPreset] {
        [
            ModelPreset(selection: ModelChooserDemo.selected, effort: .level("high")),
            ModelPreset(
                selection: ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5"),
                effort: .level("max")),
            ModelPreset(
                selection: ModelSelection(providerID: "opencode-go", modelID: "gpt-5.6-luna"),
                effort: .server),
            ModelPreset(
                selection: ModelSelection(providerID: "ollama", modelID: "qwen3-coder:30b"),
                effort: .keep),
        ]
    }
}
