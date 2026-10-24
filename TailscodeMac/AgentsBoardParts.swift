import AppKit
import CodingAgentKit
import TailscodeCore

/// A turn that ended in the last hour: tick or cross, what it came to, how long ago. Unread ones
/// lead and are set heavier; a press on it opens its chat.
@MainActor
final class AgentsFinishRowView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let line = NSTextField(wrappingLabelWithString: "")
    private let unread = NSTextField(labelWithString: "●")
    private let age = NSTextField(labelWithString: "")
    private(set) var finish: AgentFinish?

    var lineText: String { line.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.maximumNumberOfLines = 0
        line.font = MacTheme.Ramp.font(.rowDetail)
        line.textColor = MacTheme.Color.secondaryLabel
        line.maximumNumberOfLines = 2
        line.lineBreakMode = .byTruncatingTail
        for label in [title, line] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        unread.font = MacTheme.Ramp.font(.badge)
        unread.textColor = MacTheme.Color.accent
        unread.setAccessibilityLabel(Localized.text("Unread"))
        age.font = .monospacedDigitSystemFont(
            ofSize: MacTheme.Ramp.font(.rowStamp).pointSize, weight: .regular)
        age.textColor = MacTheme.Color.tertiaryLabel
        for label in [unread, age] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let words = FillingStack(topDown: false, stretches: true)
        words.spacing = MacTheme.Spacing.xs
        words.addArrangedSubview(title)
        words.addArrangedSubview(line)
        let trailing = NSStackView(views: [unread, age])
        trailing.orientation = .horizontal
        trailing.distribution = .fill
        trailing.alignment = .firstBaseline
        trailing.spacing = MacTheme.Spacing.s
        trailing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(words)
        addSubview(trailing)
        let gutter = MacTheme.Spacing.l
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            icon.centerYAnchor.constraint(equalTo: title.firstBaselineAnchor, constant: -4),
            words.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: MacTheme.Spacing.s),
            words.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.s),
            words.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.s),
            words.trailingAnchor.constraint(
                equalTo: trailing.leadingAnchor, constant: -MacTheme.Spacing.s),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            trailing.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ finish: AgentFinish, showsMachine: Bool, now: Date) {
        self.finish = finish
        let symbol: String
        let tone: ActivityTone
        switch finish.outcome {
        case .done: (symbol, tone) = ("checkmark.circle", .quiet)
        case .failed: (symbol, tone) = ("xmark.circle.fill", .danger)
        case .stopped: (symbol, tone) = ("stop.circle", .quiet)
        case .unknown: (symbol, tone) = ("questionmark.circle", .quiet)
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        icon.contentTintColor = tone.color
        title.font = finish.unread ? MacTheme.Ramp.font(.rowTitleStrong) : MacTheme.Ramp.font(.rowTitle)
        title.stringValue = showsMachine ? finish.title + " · " + finish.machine : finish.title
        line.stringValue = finish.line
        unread.isHidden = !finish.unread
        age.stringValue = AgentsWords.ago(finish.endedAt, now: now)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(AgentsWords.spoken(finish: finish, now: now))
    }

    func tick(now: Date) {
        guard let finish else { return }
        let text = AgentsWords.ago(finish.endedAt, now: now)
        if age.stringValue != text { age.stringValue = text }
    }
}

/// The label over a section: its name in small capitals with the count, and for Finished how many
/// have not been read.
@MainActor
final class AgentsSectionHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = MacTheme.Ramp.font(.sectionLabel)
        label.textColor = MacTheme.Color.secondaryLabel
        trailing.font = MacTheme.Ramp.font(.rowMeta)
        trailing.textColor = MacTheme.Color.tertiaryLabel
        for field in [label, trailing] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        let gutter = MacTheme.Spacing.l
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            label.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.l),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.xs),
            trailing.leadingAnchor.constraint(
                greaterThanOrEqualTo: label.trailingAnchor, constant: MacTheme.Spacing.s),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            trailing.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ section: AgentsSection, count: Int, unread: Int) {
        let name = AgentsWords.title(section)
        label.stringValue = name.uppercased() + " · \(count)"
        trailing.stringValue = unread > 0 ? AgentsWords.unreadCount(unread) : ""
        setAccessibilityLabel("\(name), \(count)")
    }

    var text: String { label.stringValue }
}

/// A machine on the board: its name, how many it is running, and whether it still answers, said in
/// words as well as in the dot.
@MainActor
final class AgentsMachineChip: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.font = MacTheme.Ramp.font(.rowMeta)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: MacTheme.Spacing.xs),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private var reachable: Bool?

    func configure(_ machine: AgentMachine) {
        reachable = machine.reachable
        var text = machine.name
        if machine.running > 0 { text += " · \(machine.running)" }
        if machine.reachable == false { text += " · " + Localized.text("not answering") }
        label.stringValue = text
        setAccessibilityLabel(text)
        label.textColor = machine.reachable == false ? MacTheme.Color.tertiaryLabel : MacTheme.Color.secondaryLabel
        paint()
    }

    private func paint() {
        layer?.backgroundColor = MacTheme.Color.label.withAlphaComponent(0.07).cgColor
        let tint: NSColor =
            switch reachable {
            case .some(true): MacTheme.Color.success
            case .some(false): MacTheme.Color.danger
            case .none: MacTheme.Color.tertiaryLabel
            }
        dot.layer?.backgroundColor = tint.cgColor
    }
}

/// The head of the board: the sentence, what is being watched, and the machines when there is more
/// than one. The sentence and the watch line are Core's, word for word.
@MainActor
final class AgentsSummaryView: NSView {
    private let sentence = NSTextField(wrappingLabelWithString: "")
    private let watch = NSTextField(wrappingLabelWithString: "")
    private let chips = NSStackView()
    private let column = FillingStack(topDown: false, stretches: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        sentence.maximumNumberOfLines = 0
        watch.font = MacTheme.Ramp.font(.rowDetail)
        watch.textColor = MacTheme.Color.secondaryLabel
        watch.maximumNumberOfLines = 0
        for label in [sentence, watch] {
            label.isSelectable = false
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        chips.orientation = .horizontal
        chips.spacing = MacTheme.Spacing.xs
        chips.alignment = .centerY
        chips.translatesAutoresizingMaskIntoConstraints = false
        chips.setHuggingPriority(.defaultLow, for: .horizontal)
        column.spacing = MacTheme.Spacing.xs
        column.addArrangedSubview(sentence)
        column.addArrangedSubview(watch)
        column.addArrangedSubview(chips)
        addSubview(column)
        let gutter = MacTheme.Spacing.l
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            column.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.s),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.s),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var sentenceText: String { sentence.stringValue }
    var watchText: String { watch.stringValue }
    var machineCount: Int { chips.arrangedSubviews.count }

    func configure(_ board: AgentBoard) {
        sentence.attributedStringValue = Self.coloured(board)
        watch.stringValue = board.watchLine
        for view in chips.arrangedSubviews {
            chips.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        chips.isHidden = !board.showsMachines
        if board.showsMachines {
            for machine in board.machines {
                let chip = AgentsMachineChip()
                chip.configure(machine)
                chips.addArrangedSubview(chip)
            }
        }
        setAccessibilityLabel(board.sentence + ". " + board.watchLine)
    }

    /// Each clause of Core's sentence in the tone it is about, split on the separator Core joins
    /// them with; when the count of clauses is not what the headline says, the sentence stays plain.
    private static func coloured(_ board: AgentBoard) -> NSAttributedString {
        let font = MacTheme.Ramp.font(.statusSentence)
        let clauses = board.sentence.components(separatedBy: " · ")
        var tones: [NSColor] = []
        if board.headline.working > 0 { tones.append(MacTheme.Color.success) }
        if board.headline.needsYou > 0 { tones.append(MacTheme.Color.warning) }
        if tones.isEmpty { tones.append(MacTheme.Color.secondaryLabel) }
        guard tones.count == clauses.count else {
            return NSAttributedString(
                string: board.sentence,
                attributes: [.font: font, .foregroundColor: MacTheme.Color.label])
        }
        let text = NSMutableAttributedString()
        for (index, clause) in clauses.enumerated() {
            if index > 0 {
                text.append(
                    NSAttributedString(
                        string: " · ",
                        attributes: [.font: font, .foregroundColor: MacTheme.Color.tertiaryLabel]))
            }
            text.append(
                NSAttributedString(
                    string: clause, attributes: [.font: font, .foregroundColor: tones[index]]))
        }
        return text
    }
}

/// What the board says when nothing is running: what it is for, in words, rather than a spinner.
@MainActor
final class AgentsEmptyView: NSView {
    private let title = NSTextField(wrappingLabelWithString: AgentsWords.emptyTitle)
    private let detail = NSTextField(wrappingLabelWithString: AgentsWords.emptyDetail)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        title.font = MacTheme.Ramp.font(.cardTitle)
        detail.font = MacTheme.Ramp.font(.cardBody)
        detail.textColor = MacTheme.Color.secondaryLabel
        for label in [title, detail] {
            label.maximumNumberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let column = FillingStack(topDown: false, stretches: true)
        column.spacing = MacTheme.Spacing.xs
        column.addArrangedSubview(title)
        column.addArrangedSubview(detail)
        addSubview(column)
        let gutter = MacTheme.Spacing.l
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            column.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.l),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.l),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel(AgentsWords.emptyTitle + ". " + AgentsWords.emptyDetail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
