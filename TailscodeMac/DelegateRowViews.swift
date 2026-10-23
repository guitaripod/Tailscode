import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// One run in the board's list: its motion, the goal and the pill saying where it stands, the line
/// under it, and the run's ladder at the size of a row beside the repository and the age.
@MainActor
final class DelegateRunRowView: NSView {
    var onClick: (() -> Void)?
    private let ground = RowKit.Ground(frame: .zero)

    init(row: DelegateRunRow, selected: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        ground.fill = selected ? MacTheme.Color.accent.withAlphaComponent(0.14) : nil
        ground.radius = MacTheme.Radius.control
        addSubview(ground)

        let glyph = Self.glyph(row)
        let title = RowKit.label(row.headline, font: MacTheme.Ramp.font(.rowTitle), color: MacTheme.Color.label)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var head: [NSView] = [title]
        if let badge = row.badge { head.append(DelegatePill(badge, tone: row.tone)) }
        let titleRow = NSStackView(views: head)
        titleRow.orientation = .horizontal
        titleRow.distribution = .fill
        titleRow.alignment = .centerY
        titleRow.spacing = MacTheme.Spacing.s
        let detail = RowKit.label(row.detail, font: MacTheme.Ramp.font(.rowDetail), color: MacTheme.Color.secondaryLabel)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var meta: [NSView] = [DelegatePipsView(row.rungs)]
        let facts = [row.repo, row.age].filter { !$0.isEmpty }.joined(separator: " · ")
        if !facts.isEmpty {
            let label = RowKit.label(facts, font: MacTheme.Ramp.font(.rowMeta), color: MacTheme.Color.tertiaryLabel)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            meta.append(label)
        }
        let metaRow = NSStackView(views: meta)
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.setHuggingPriority(.defaultHigh, for: .horizontal)
        metaRow.spacing = MacTheme.Spacing.s
        let lines = NSStackView(views: [titleRow, detail, metaRow])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 3
        for line in [titleRow, detail, metaRow] {
            line.widthAnchor.constraint(lessThanOrEqualTo: lines.widthAnchor).isActive = true
        }
        titleRow.widthAnchor.constraint(equalTo: lines.widthAnchor).isActive = true
        let line = NSStackView(views: [glyph, lines])
        line.orientation = .horizontal
        line.alignment = .top
        line.spacing = MacTheme.Spacing.s
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            ground.topAnchor.constraint(equalTo: topAnchor),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.s),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.s),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        toolTip = row.spoken
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.spoken)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The row's state in its own motion while it works or waits; a settled run holds still as a
    /// dot in its tone, because stillness is how a reader tells an ending from a slow run.
    private static func glyph(_ row: DelegateRunRow) -> NSView {
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        let size = MacTheme.Ramp.font(.rowTitle).pointSize + 4
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: size),
            slot.heightAnchor.constraint(equalToConstant: size),
        ])
        let mark: NSView
        if let activity = row.activity {
            let badge = ActivityBadgeView(pointSize: size - 5)
            badge.show(activity.icon, spoken: activity.spoken)
            mark = badge
        } else {
            mark = DelegateDot(color: row.tone.color, diameter: 7)
        }
        mark.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
        ])
        return slot
    }

    @objc private func clicked() { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// A word in a capsule of its tone — a run's Review, Applied or Failed.
@MainActor
final class DelegatePill: NSView {
    private let tone: ActivityTone

    init(_ text: String, tone: ActivityTone) {
        self.tone = tone
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: text)
        label.font = MacTheme.Ramp.font(.pill)
        label.textColor = Self.ink(tone)
        label.translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func ink(_ tone: ActivityTone) -> NSColor {
        tone == .quiet ? MacTheme.Color.secondaryLabel : tone.color
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.ink(tone).withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// A still mark in one colour.
@MainActor
final class DelegateDot: NSView {
    private let color: NSColor
    private let diameter: CGFloat

    init(color: NSColor, diameter: CGFloat) {
        self.color = color
        self.diameter = diameter
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// A run's ladder at the size of a row: one pip per rung, cheapest first, lit where it passed or is
/// working, marked where it failed or was held, faint where the run could never go.
@MainActor
final class DelegatePipsView: NSView {
    private let states: [DelegateRungState]
    private static let pip: CGFloat = 6
    private static let gap: CGFloat = 3

    init(_ states: [DelegateRungState]) {
        self.states = states
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(states.count)
        return NSSize(width: max(0, count * Self.pip + (count - 1) * Self.gap), height: Self.pip)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, state) in states.enumerated() {
            let rect = NSRect(
                x: CGFloat(index) * (Self.pip + Self.gap), y: (bounds.height - Self.pip) / 2,
                width: Self.pip, height: Self.pip)
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            switch state {
            case .current, .passed, .failed, .held:
                state.tone.color.setFill()
                path.fill()
            case .pending:
                MacTheme.Color.tertiaryLabel.setStroke()
                path.lineWidth = 1
                path.stroke()
            case .belowStart, .beyondCeiling, .skipped:
                MacTheme.Color.tertiaryLabel.withAlphaComponent(0.35).setFill()
                path.fill()
            }
        }
    }
}

/// One file of a run's patch: its name, its folder faint beside it, and how much it changes.
@MainActor
final class DelegateFileRowView: NSView {
    var onClick: (() -> Void)?
    private let ground = RowKit.Ground(frame: .zero)

    init(_ file: DelegateFileRow) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        ground.radius = MacTheme.Radius.control
        addSubview(ground)
        let name = RowKit.label(file.name, font: MacTheme.Ramp.font(.rowTitle), color: MacTheme.Color.label)
        name.setContentHuggingPriority(.required, for: .horizontal)
        var views: [NSView] = [name]
        if !file.folder.isEmpty {
            let folder = RowKit.label(file.folder, font: MacTheme.Ramp.font(.rowMeta), color: MacTheme.Color.tertiaryLabel)
            folder.lineBreakMode = .byTruncatingHead
            folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(folder)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        views.append(spacer)
        if let added = file.added, let removed = file.removed, added + removed > 0 {
            if added > 0 { views.append(Self.count("+\(added)", MacTheme.Color.success)) }
            if removed > 0 { views.append(Self.count("−\(removed)", MacTheme.Color.danger)) }
        } else if let counts = file.counts {
            views.append(Self.count(counts, MacTheme.Color.tertiaryLabel))
        }
        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = MacTheme.Spacing.s
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            ground.topAnchor.constraint(equalTo: topAnchor),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.xs + 1),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(MacTheme.Spacing.xs + 1)),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        toolTip = file.path
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([file.path, file.counts].compactMap { $0 }.joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func count(_ text: String, _ color: NSColor) -> NSTextField {
        let label = RowKit.label(text, font: MacTheme.Ramp.font(.code), color: color)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    override func mouseEntered(with event: NSEvent) {
        ground.fill = MacTheme.Color.canvasRaised
        ground.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        ground.fill = nil
        ground.needsDisplay = true
    }

    @objc private func clicked() { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
