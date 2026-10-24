import AppKit
import CodingAgentKit
import TailscodeCore

/// Words in capsules that wrap onto as many lines as they need: the files an agent has touched.
/// Placed by frame from the width it is given, and tells Auto Layout how tall that makes it.
@MainActor
final class AgentsChipFlow: NSView {
    private var chips: [NSView] = []
    private var laidWidth: CGFloat = 0
    private static let spacing: CGFloat = 6

    var titles: [String] = [] {
        didSet {
            guard titles != oldValue else { return }
            for chip in chips { chip.removeFromSuperview() }
            chips = titles.map(Self.chip)
            for chip in chips { addSubview(chip) }
            invalidateIntrinsicContentSize()
            needsLayout = true
            setAccessibilityLabel(titles.joined(separator: ", "))
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static func chip(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.rowMeta)
        label.textColor = MacTheme.Color.secondaryLabel
        label.lineBreakMode = .byTruncatingMiddle
        label.sizeToFit()
        let box = RowKit.Ground(frame: .zero)
        box.translatesAutoresizingMaskIntoConstraints = true
        box.fill = MacTheme.Color.label.withAlphaComponent(0.08)
        box.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = true
        label.frame.origin = NSPoint(x: 8, y: 3)
        box.frame.size = NSSize(width: label.frame.width + 16, height: label.frame.height + 6)
        box.radius = box.frame.height / 2
        return box
    }

    private func placement(for width: CGFloat) -> (frames: [NSRect], height: CGFloat) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [NSRect] = []
        for chip in chips {
            var size = chip.frame.size
            size.width = min(size.width, max(width, 40))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + Self.spacing
                rowHeight = 0
            }
            frames.append(NSRect(origin: NSPoint(x: x, y: y), size: size))
            x += size.width + Self.spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, y + rowHeight)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: chips.isEmpty ? 0 : placement(for: laidWidth > 0 ? laidWidth : 280).height)
    }

    override func layout() {
        super.layout()
        let (frames, _) = placement(for: bounds.width)
        for (chip, frame) in zip(chips, frames) { chip.frame = frame }
        if abs(bounds.width - laidWidth) > 0.5 {
            laidWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// A figure and the bar it is a share of: how full the context is, in the tone Core gives it.
@MainActor
final class AgentsMeterBar: NSView {
    var fraction: Double = 0 {
        didSet { if fraction != oldValue { needsDisplay = true } }
    }
    var tint: NSColor = MacTheme.Color.success {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        MacTheme.Color.tertiaryLabel.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        var filled = bounds
        filled.size.width = max(bounds.height, bounds.width * CGFloat(min(max(fraction, 0), 1)))
        guard fraction > 0 else { return }
        tint.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}

/// One step an agent took: what it did in words, how it came out, and when this device first saw
/// it. Never how long it took: a tool call carries no duration.
@MainActor
final class AgentsStepRow: NSView {
    private let icon = NSImageView()
    private let words = NSTextField(wrappingLabelWithString: "")
    private let seen = NSTextField(labelWithString: "")
    private var seenAt: Date?
    private var current = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false
        words.font = MacTheme.Ramp.font(.rowDetail)
        words.maximumNumberOfLines = 0
        words.translatesAutoresizingMaskIntoConstraints = false
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        seen.font = .monospacedDigitSystemFont(
            ofSize: MacTheme.Ramp.font(.rowStamp).pointSize, weight: .regular)
        seen.textColor = MacTheme.Color.tertiaryLabel
        seen.translatesAutoresizingMaskIntoConstraints = false
        seen.setContentHuggingPriority(.required, for: .horizontal)
        seen.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, words, seen])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .firstBaseline
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ step: AgentStep, now: Date) {
        let symbol: String
        let tone: ActivityTone
        switch step.outcome {
        case .running: (symbol, tone) = ("circle.dotted", .live)
        case .done: (symbol, tone) = ("checkmark", .quiet)
        case .failed: (symbol, tone) = ("xmark", .danger)
        case .stopped: (symbol, tone) = ("stop", .quiet)
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        icon.contentTintColor = tone.color
        words.stringValue = step.words
        words.textColor = step.outcome == .running ? MacTheme.Color.label : MacTheme.Color.secondaryLabel
        seenAt = step.seen
        tick(now: now)
        setAccessibilityLabel(
            [step.words, seen.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    func tick(now: Date) {
        let text = seenAt.map { Localized.text("seen %@ ago", AgentsWords.elapsed(now.timeIntervalSince($0))) } ?? ""
        if seen.stringValue != text { seen.stringValue = text }
    }
}
