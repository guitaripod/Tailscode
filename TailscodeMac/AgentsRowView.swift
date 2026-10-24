import AppKit
import CodingAgentKit
import TailscodeCore

/// A todo list's progress as a small bar: how many of an agent's steps are done, drawn from the
/// two numbers and never from a colour alone, since the count sits beside it.
@MainActor
final class AgentsTodoBar: NSView {
    var fraction: Double = 0 {
        didSet { if fraction != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 4) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        MacTheme.Color.tertiaryLabel.withAlphaComponent(0.35).setFill()
        track.fill()
        var done = bounds
        done.size.width = bounds.width * CGFloat(min(max(fraction, 0), 1))
        guard done.width > 0 else { return }
        MacTheme.Color.success.setFill()
        NSBezierPath(roundedRect: done, xRadius: 2, yRadius: 2).fill()
    }
}

/// One agent a session has out, hanging under it: a subagent with what it is doing and how far
/// through its todos it is, or the background task with its age.
@MainActor
final class AgentsChildLineView: NSView {
    private let icon = NSImageView()
    private let words = NSTextField(wrappingLabelWithString: "")
    private let bar = AgentsTodoBar()
    private let count = NSTextField(labelWithString: "")
    private let age = NSTextField(labelWithString: "")
    private var startedAt: Date?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = MacTheme.Color.secondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false
        words.maximumNumberOfLines = 2
        words.lineBreakMode = .byTruncatingTail
        words.translatesAutoresizingMaskIntoConstraints = false
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        words.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        bar.setContentHuggingPriority(.required, for: .horizontal)
        for label in [count, age] {
            label.font = .monospacedDigitSystemFont(
                ofSize: MacTheme.Ramp.font(.rowStamp).pointSize, weight: .regular)
            label.textColor = MacTheme.Color.tertiaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let row = NSStackView(views: [icon, words, bar, count, age])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .firstBaseline
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ child: AgentChild, now: Date) {
        let background = child.kind == .background
        icon.image = NSImage(
            systemSymbolName: background ? "clock" : (child.isActive ? "circle.dotted" : "circle"),
            accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        let text = NSMutableAttributedString(
            string: child.title,
            attributes: [
                .font: MacTheme.Ramp.font(.rowTitleStrong), .foregroundColor: MacTheme.Color.label,
            ])
        if !child.line.isEmpty {
            text.append(
                NSAttributedString(
                    string: " " + child.line,
                    attributes: [
                        .font: MacTheme.Ramp.font(.rowDetail),
                        .foregroundColor: MacTheme.Color.secondaryLabel,
                    ]))
        }
        words.attributedStringValue = text
        if let todos = child.todos {
            bar.isHidden = false
            bar.fraction = Double(todos.done) / Double(max(todos.total, 1))
            count.stringValue = AgentsWords.todos(todos)
            count.isHidden = child.line.contains(count.stringValue)
        } else {
            bar.isHidden = true
            count.isHidden = true
        }
        startedAt = child.kind == .agent ? nil : child.startedAt
        tick(now: now)
        setAccessibilityLabel(
            [child.title, child.line, child.todos.map(AgentsWords.todos), age.stringValue]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }

    func tick(now: Date) {
        let text = startedAt.map { AgentsWords.elapsed(now.timeIntervalSince($0)) } ?? ""
        if age.stringValue != text { age.stringValue = text }
    }
}

/// A session at work: the glyph in its tone, the title, how long, the line of words for what it is
/// doing, the pulse of the last minute, the machine and model, and the agents it has out.
@MainActor
final class AgentsRowView: NSView {
    private let badge = ActivityBadgeView(pointSize: 12)
    private let title = NSTextField(wrappingLabelWithString: "")
    private let unread = NSTextField(labelWithString: "●")
    private let elapsed = NSTextField(labelWithString: "")
    private let line = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let strip = AgentBeatStripView()
    private let word = NSTextField(labelWithString: "")
    private let origin = NSTextField(labelWithString: "")
    private let tree = FillingStack(topDown: false, stretches: true)
    private let folded = NSTextField(labelWithString: "")
    private let content = FillingStack(topDown: false, stretches: true)
    private var children: [AgentsChildLineView] = []
    private var startedAt: Date?
    private(set) var row: AgentRow?
    private(set) var section: AgentsSection = .working

    var elapsedText: String { elapsed.stringValue }
    var noteText: String { note.isHidden ? "" : note.stringValue }
    var showsStrip: Bool { !strip.isHidden }
    var childLines: Int { children.count }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        title.maximumNumberOfLines = 0
        title.isSelectable = false
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        unread.font = MacTheme.Ramp.font(.badge)
        unread.textColor = MacTheme.Color.accent
        unread.setAccessibilityLabel(Localized.text("Unread"))
        unread.translatesAutoresizingMaskIntoConstraints = false
        unread.setContentHuggingPriority(.required, for: .horizontal)
        elapsed.font = .monospacedDigitSystemFont(
            ofSize: MacTheme.Ramp.font(.rowStamp).pointSize, weight: .regular)
        elapsed.textColor = MacTheme.Color.tertiaryLabel
        elapsed.alignment = .right
        elapsed.translatesAutoresizingMaskIntoConstraints = false
        elapsed.setContentHuggingPriority(.required, for: .horizontal)
        elapsed.setContentCompressionResistancePriority(.required, for: .horizontal)
        line.font = MacTheme.Ramp.font(.rowDetail)
        line.textColor = MacTheme.Color.secondaryLabel
        line.maximumNumberOfLines = 2
        line.lineBreakMode = .byTruncatingTail
        line.translatesAutoresizingMaskIntoConstraints = false
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.font = MacTheme.Ramp.font(.panelFootnote)
        note.textColor = MacTheme.Color.warning
        note.maximumNumberOfLines = 0
        note.translatesAutoresizingMaskIntoConstraints = false
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [word, origin, folded] {
            label.font = MacTheme.Ramp.font(.rowMeta)
            label.textColor = MacTheme.Color.tertiaryLabel
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        origin.alignment = .right
        word.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let head = NSStackView(views: [title, unread, elapsed])
        head.orientation = .horizontal
        head.distribution = .fill
        head.alignment = .firstBaseline
        head.spacing = MacTheme.Spacing.s
        head.translatesAutoresizingMaskIntoConstraints = false
        let meta = NSStackView(views: [strip, word, origin])
        meta.orientation = .horizontal
        meta.distribution = .fill
        meta.alignment = .centerY
        meta.spacing = MacTheme.Spacing.m
        meta.translatesAutoresizingMaskIntoConstraints = false
        origin.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        strip.setContentHuggingPriority(.required, for: .horizontal)
        tree.spacing = MacTheme.Spacing.xs

        content.spacing = MacTheme.Spacing.xs
        content.addArrangedSubview(head)
        content.addArrangedSubview(line)
        content.addArrangedSubview(note)
        content.addArrangedSubview(meta)
        content.addArrangedSubview(tree)
        addSubview(badge)
        addSubview(content)
        let gutter = MacTheme.Spacing.l
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            badge.centerYAnchor.constraint(equalTo: title.firstBaselineAnchor, constant: -4),
            content.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: MacTheme.Spacing.s),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            content.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.m),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.m),
        ])
    }

    func configure(_ row: AgentRow, section: AgentsSection, showsMachine: Bool, context: AgentsContext) {
        self.row = row
        self.section = section
        let now = context.now()
        badge.show(
            section.icon(tone: row.tone, motion: row.motion),
            spoken: AgentsWords.state(word: row.word, section: section))
        title.font = row.unread ? MacTheme.Ramp.font(.rowTitleStrong) : MacTheme.Ramp.font(.rowTitle)
        title.stringValue = row.title
        unread.isHidden = !row.unread
        startedAt = row.startedAt
        line.stringValue = row.line ?? ""
        line.isHidden = (row.line ?? "").isEmpty
        let away = row.isAway
        note.stringValue = away ? AgentsWords.lastSeen(context.lastHeard(row.profileID), now: now) : ""
        note.isHidden = !away
        if let beat = row.beat, section != .background {
            strip.isHidden = false
            strip.beat = beat
            strip.tone = row.tone
            word.isHidden = true
        } else {
            strip.isHidden = true
            word.isHidden = (row.word ?? "").isEmpty
            word.stringValue = row.word ?? ""
        }
        let words = NSMutableAttributedString(attributedString: Self.origin(row, showsMachine: showsMachine))
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        words.addAttribute(.paragraphStyle, value: right, range: NSRange(location: 0, length: words.length))
        origin.attributedStringValue = words
        origin.isHidden = words.length == 0
        syncChildren(row, now: now)
        alphaValue = away ? 0.6 : 1
        tick(now: now)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(
            AgentsWords.spoken(row: row, section: section, now: now, showsMachine: showsMachine))
    }

    private static func origin(_ row: AgentRow, showsMachine: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if let chip = row.chip { text.append(SidebarSessionCell.chipText(chip)) }
        if showsMachine, !row.machine.isEmpty {
            if text.length > 0 {
                text.append(NSAttributedString(string: "  ", attributes: [.font: MacTheme.Ramp.font(.rowMeta)]))
            }
            text.append(
                NSAttributedString(
                    string: row.machine,
                    attributes: [
                        .font: MacTheme.Ramp.font(.rowMeta),
                        .foregroundColor: MacTheme.Color.tertiaryLabel,
                    ]))
        }
        return text
    }

    private func syncChildren(_ row: AgentRow, now: Date) {
        let wanted = row.children
        while children.count > wanted.count {
            let view = children.removeLast()
            tree.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        while children.count < wanted.count {
            let view = AgentsChildLineView()
            tree.addArrangedSubview(view)
            children.append(view)
        }
        for (view, child) in zip(children, wanted) { view.configure(child, now: now) }
        if folded.superview != nil {
            tree.removeArrangedSubview(folded)
            folded.removeFromSuperview()
        }
        if row.listedAgents > wanted.count {
            folded.stringValue = AgentsWords.agents(row.listedAgents)
            tree.addArrangedSubview(folded)
        }
        tree.isHidden = wanted.isEmpty && row.listedAgents <= wanted.count
    }

    func tick(now: Date) {
        if let startedAt {
            let text = AgentsWords.elapsed(now.timeIntervalSince(startedAt))
            if elapsed.stringValue != text { elapsed.stringValue = text }
        } else if !elapsed.stringValue.isEmpty {
            elapsed.stringValue = ""
        }
        for child in children { child.tick(now: now) }
    }
}
