import TailscodeCore
import UIKit

/// A step read out in full: what it was and how it stands, the command or path it came to read,
/// the reasoning that came just before it, what it printed or changed, and what it relates to. It
/// is the card that opens under the cursor row in the account, and the second column of a wide
/// account. Every word is `NeuralReadout`'s; this only sets them.
@MainActor
final class BrainStepCard: UIView {
    struct Style {
        var isPreview = false
        var isLive = false
        var bordered = true
    }

    var onCopy: ((String) -> Void)?
    var onRelation: (([String]) -> Void)?
    var onRelationHover: (([String]?) -> Void)?
    var onOpenAgent: ((String) -> Void)?
    var onToggleOutput: ((Bool) -> Void)?
    var onGoToStep: ((String) -> Void)?
    var onLayoutChange: (() -> Void)?

    private let stack = UIStackView()
    private let edge = UIView()
    private var step: NeuralReadout.Step?
    private var zone = NeuralZone.shell
    private var style = Style()
    private var outputExpanded = false
    private var fullOutput: [NeuralReadout.OutputLine] = []
    private var model: NeuralBrainModel?
    private var showsAllCommand = false
    private var whyExpanded = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.masksToBounds = true
        addSubview(edge)
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        edge.frame = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
    }

    /// How tall the card is at a width: the stack's own height at the width left inside the card's
    /// padding, and the foot's air.
    func fittedHeight(width: CGFloat) -> CGFloat {
        let inner = max(0, width - 17 - 14)
        let size = stack.systemLayoutSizeFitting(
            CGSize(width: inner, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return ceil(size.height) + 8
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyChrome()
    }

    private func applyChrome() {
        backgroundColor = Theme.Color.background
        layer.borderColor = (style.bordered ? BrainCanvas.rule : UIColor.clear).resolvedColor(with: traitCollection).cgColor
        layer.borderWidth = style.bordered ? 1 : 0
        edge.backgroundColor = BrainCanvas.zone(zone)
        alpha = style.isPreview ? 0.92 : 1
    }

    func configure(
        step new: NeuralReadout.Step, model newModel: NeuralBrainModel, style newStyle: Style,
        outputExpanded expanded: Bool, tail: NeuralReadout.Tail? = nil
    ) {
        step = new
        model = newModel
        style = newStyle
        outputExpanded = expanded
        zone = new.header.zone
        fullOutput = []
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        applyChrome()
        stack.addArrangedSubview(header(new))
        stack.addArrangedSubview(body(new, tail: tail))
        stack.addArrangedSubview(footer(new))
        isAccessibilityElement = false
        accessibilityElements = [stack]
    }

    private func header(_ step: NeuralReadout.Step) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: style.isLive ? 34 : 38).isActive = true
        let icon = BrainShapeIcon()
        icon.set(shape: step.header.zone.shape, color: BrainCanvas.zone(step.header.zone))
        let zoneLabel = UILabel()
        zoneLabel.attributedText = NSAttributedString(
            string: step.header.label,
            attributes: Theme.Ramp.attributes(.sectionLabel, color: BrainCanvas.zone(step.header.zone)))
        let chip = BrainChipLabel()
        let tone = BrainCanvas.tone(step.header.chip.tone)
        chip.set(
            text: step.header.chip.word, tone: tone,
            symbol: BrainCanvas.symbol(for: Self.verdict(of: step.header.chip.kind)))
        let pinned = UILabel()
        pinned.attributedText = NSAttributedString(
            string: step.header.isPinned ? "\u{2022} " + NeuralReading.pinnedLabel.lowercased() : "",
            attributes: Theme.Ramp.attributes(.rowNote, color: Theme.Color.secondaryLabel))
        let counter = UILabel()
        counter.attributedText = NSAttributedString(
            string: step.header.counter,
            attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel, alignment: .right))
        counter.textAlignment = .right
        let line = UIStackView(arrangedSubviews: [icon, zoneLabel, chip, pinned, UIView(), counter])
        line.axis = .horizontal
        line.alignment = .center
        line.spacing = 8
        line.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        row.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private static func verdict(of kind: NeuralReadout.ChipKind) -> NeuralVerdict.Step {
        switch kind {
        case .done: return .done
        case .failed, .retried: return .failed
        case .running: return .running
        case .waiting: return .waiting
        case .stalled: return .stalled
        case .stopped: return .stopped
        case .fixed: return .fixed
        case .hitError: return .tryingAgain
        }
    }

    private func body(_ step: NeuralReadout.Step, tail: NeuralReadout.Tail?) -> UIView {
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 14
        column.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
        column.isLayoutMarginsRelativeArrangement = true
        column.addArrangedSubview(subjectSection(step))
        if let detail = step.header.chip.detail { column.addArrangedSubview(fixedSentence(detail)) }
        if !style.isLive, !step.relations.isEmpty { column.addArrangedSubview(relations(step.relations)) }
        if !style.isLive, let why = step.why { column.addArrangedSubview(whySection(why)) }
        if style.isLive, let tail, !tail.lines.isEmpty {
            column.addArrangedSubview(tailSection(tail))
        } else if let result = step.result {
            if let view = resultSection(result, step: step) { column.addArrangedSubview(view) }
        }
        return column
    }

    private func footer(_ step: NeuralReadout.Step) -> UIView {
        let facts = step.facts
        var parts = [facts.message]
        if let clock = facts.clock { parts.append(clock) }
        let left = UILabel()
        left.attributedText = NSAttributedString(
            string: parts.joined(separator: "   "),
            attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel))
        left.numberOfLines = 0
        let right = UILabel()
        right.attributedText = NSAttributedString(
            string: style.isLive ? (facts.started ?? "") : (facts.turnBegan ?? ""),
            attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel, alignment: .right))
        right.textAlignment = .right
        let line = UIStackView(arrangedSubviews: [left, UIView(), right])
        line.axis = .horizontal
        line.spacing = 8
        return line
    }

    private func sectionLabel(_ text: String, right: UIView? = nil) -> UIView {
        let label = UILabel()
        label.attributedText = NSAttributedString(
            string: text.uppercased(),
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.secondaryLabel))
        let row = UIStackView(arrangedSubviews: [label, UIView()] + (right.map { [$0] } ?? []))
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        return row
    }

    private func rightLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.attributedText = NSAttributedString(
            string: text, attributes: Theme.Ramp.attributes(.rowMeta, color: Theme.Color.secondaryLabel))
        return label
    }

    private func tally(added: Int, removed: Int) -> UILabel {
        let label = UILabel()
        let text = NSMutableAttributedString(
            string: "+\(added)", attributes: Theme.Ramp.attributes(.rowMeta, color: Theme.Color.accent))
        text.append(
            NSAttributedString(
                string: " \u{2212}\(removed)",
                attributes: Theme.Ramp.attributes(.rowMeta, color: Theme.Color.danger)))
        label.attributedText = text
        return label
    }

    private func subjectSection(_ step: NeuralReadout.Step) -> UIView {
        let subject = step.subject
        let box = UIStackView()
        box.axis = .vertical
        box.spacing = 6
        let title = UILabel()
        title.numberOfLines = 0
        title.attributedText = NSAttributedString(
            string: subject.title, attributes: Theme.Ramp.attributes(.cardTitle))
        var trailing: UIView?
        if case .subagent(let agent)? = step.result, agent.canOpen {
            let stepID = step.stepID
            trailing = BrainTextButton(title: agent.openLabel, bordered: true) { [weak self] in
                self?.onOpenAgent?(stepID)
            }
        } else if let copy = subject.copyText {
            trailing = BrainTextButton(title: NeuralReading.copyLabel, bordered: true) { [weak self] in
                self?.onCopy?(copy)
            }
        }
        let top = UIStackView(arrangedSubviews: [title] + (trailing.map { [UIView(), $0] } ?? []))
        top.axis = .horizontal
        top.alignment = .center
        top.spacing = 12
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        box.addArrangedSubview(top)
        let zoneInk = BrainCanvas.zone(step.header.zone)
        switch subject.kind {
        case .command:
            box.addArrangedSubview(commandView(subject, zoneInk: zoneInk))
        case .path:
            let text = NSMutableAttributedString(
                string: subject.directory ?? "",
                attributes: Theme.Ramp.attributes(.toolDetail, color: Theme.Color.secondaryLabel))
            text.append(
                NSAttributedString(
                    string: subject.fileName ?? subject.primary,
                    attributes: Theme.Ramp.attributes(.toolName, color: Theme.Color.label)))
            box.addArrangedSubview(wrapped(text))
        case .pattern:
            box.addArrangedSubview(
                wrapped(NSAttributedString(
                    string: subject.primary, attributes: Theme.Ramp.attributes(.toolDetail))))
            if let scope = subject.secondary, !scope.isEmpty {
                let text = NSMutableAttributedString(
                    string: Localized.text("in") + " ",
                    attributes: Theme.Ramp.attributes(.toolDetail, color: Theme.Color.secondaryLabel))
                text.append(
                    NSAttributedString(string: scope, attributes: Theme.Ramp.attributes(.toolDetail)))
                box.addArrangedSubview(wrapped(text))
            }
        case .url, .other:
            box.addArrangedSubview(
                wrapped(NSAttributedString(
                    string: subject.primary, attributes: Theme.Ramp.attributes(.toolDetail))))
        case .agent:
            box.addArrangedSubview(
                wrapped(NSAttributedString(
                    string: subject.primary, attributes: Theme.Ramp.attributes(.cardBody))))
            if let kind = subject.secondary, !kind.isEmpty {
                box.addArrangedSubview(
                    wrapped(NSAttributedString(
                        string: kind,
                        attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel))))
            }
        case .thought, .note:
            box.addArrangedSubview(
                wrapped(NSAttributedString(
                    string: subject.primary, attributes: Theme.Ramp.attributes(.thought))))
        }
        return box
    }

    private func wrapped(_ text: NSAttributedString) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.attributedText = text
        return label
    }

    private func commandView(_ subject: NeuralReadout.Subject, zoneInk: UIColor) -> UIView {
        let box = UIStackView()
        box.axis = .vertical
        box.spacing = 4
        let lines = subject.primary.components(separatedBy: "\n")
        func text(_ shown: [String]) -> NSAttributedString {
            let out = NSMutableAttributedString(
                string: "$ ", attributes: Theme.Ramp.attributes(.toolDetail, color: zoneInk))
            out.append(
                NSAttributedString(
                    string: shown.joined(separator: "\n"), attributes: Theme.Ramp.attributes(.toolDetail)))
            return out
        }
        let label = wrapped(text(showsAllCommand ? lines : Array(lines.prefix(subject.collapsedLines))))
        box.addArrangedSubview(label)
        if subject.hasMore, !showsAllCommand {
            let link = BrainTextButton(title: NeuralReading.showAllLabel, bordered: false) { [weak self, weak label] in
                guard let self, let label else { return }
                self.showsAllCommand = true
                label.attributedText = text(lines)
                self.onLayoutChange?()
            }
            box.addArrangedSubview(link)
        }
        return box
    }

    private func fixedSentence(_ detail: String) -> UIView {
        let label = wrapped(
            NSAttributedString(
                string: detail, attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.label)))
        let icon = UIImageView(
            image: BrainCanvas.image("arrow.trianglehead.2.clockwise.rotate.90", size: 12)?
                .withTintColor(Theme.Color.warning.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal))
        icon.contentMode = .top
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 6
        return row
    }

    private func relations(_ relations: [NeuralReadout.Relation]) -> UIView {
        let box = UIStackView()
        box.axis = .vertical
        box.spacing = 6
        box.addArrangedSubview(sectionLabel(Localized.text("Relations")))
        let flow = BrainFlowView(spacing: 6)
        for relation in relations {
            let numbers = relation.numbers.map(String.init).joined(separator: ", ")
            let prefix = relation.label.replacingOccurrences(of: numbers, with: "")
                .trimmingCharacters(in: .whitespaces)
            let text = NSMutableAttributedString(
                string: prefix + " ",
                attributes: Theme.Ramp.attributes(.chip, color: Theme.Color.secondaryLabel))
            text.append(
                NSAttributedString(
                    string: numbers,
                    attributes: Theme.Ramp.attributes(.chip, color: Theme.Color.label)))
            let ids = relation.stepIDs
            let chip = BrainTextButton(attributed: text, bordered: true) { [weak self] in
                self?.onRelation?(ids)
            }
            chip.onHover = { [weak self] inside in self?.onRelationHover?(inside ? ids : nil) }
            chip.accessibilityLabel = relation.label
            flow.add(chip)
        }
        box.addArrangedSubview(flow)
        return box
    }

    private func whySection(_ why: NeuralReadout.Why) -> UIView {
        let box = UIStackView()
        box.axis = .vertical
        box.spacing = 3
        let label = UILabel()
        label.attributedText = NSAttributedString(
            string: why.label,
            attributes: Theme.Ramp.attributes(.sectionLabel, color: BrainCanvas.zone(zone)))
        box.addArrangedSubview(label)
        let words = whyExpanded ? why.full : why.text
        let text = wrapped(
            NSAttributedString(string: words, attributes: Theme.Ramp.attributes(.thought)))
        box.addArrangedSubview(text)
        if why.isTruncated, !whyExpanded {
            box.addArrangedSubview(
                BrainTextButton(title: NeuralReading.showMoreLabel, bordered: false) { [weak self] in
                    self?.whyExpanded = true
                    text.attributedText = NSAttributedString(
                        string: why.full, attributes: Theme.Ramp.attributes(.thought))
                    self?.onLayoutChange?()
                })
        }
        let rule = UIView()
        rule.backgroundColor = BrainCanvas.zone(zone)
        rule.translatesAutoresizingMaskIntoConstraints = false
        let holder = UIView()
        holder.addSubview(box)
        holder.addSubview(rule)
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            rule.topAnchor.constraint(equalTo: holder.topAnchor),
            rule.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            rule.widthAnchor.constraint(equalToConstant: 2),
            box.leadingAnchor.constraint(equalTo: rule.trailingAnchor, constant: 12),
            box.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            box.topAnchor.constraint(equalTo: holder.topAnchor),
            box.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        return holder
    }

    private func resultSection(_ result: NeuralReadout.Result, step: NeuralReadout.Step) -> UIView? {
        let box = UIStackView()
        box.axis = .vertical
        box.spacing = 6
        let failed = step.header.chip.kind == .failed
        switch result {
        case .shell(let output):
            box.addArrangedSubview(
                sectionLabel(
                    Localized.text("Output"),
                    right: rightLabel(Localized.text("%lld lines", output.total))))
            box.addArrangedSubview(
                outputBlock(
                    output.lines.map { ($0.text, $0.tone) }, hidden: output.hiddenCount, more: output.moreLabel, failed: failed,
                    stepID: step.stepID))
        case .edit(let edit):
            box.addArrangedSubview(
                sectionLabel(
                    Localized.text("Diff"), right: tally(added: edit.added, removed: edit.removed)))
            box.addArrangedSubview(diffBlock(edit))
        case .read(let read):
            box.addArrangedSubview(
                sectionLabel(
                    Localized.text("Read"),
                    right: read.lines.map { rightLabel(Localized.text("%lld lines", $0)) }))
        case .search(let search):
            box.addArrangedSubview(
                sectionLabel(Localized.text("Matches"), right: rightLabel(String(search.total))))
            box.addArrangedSubview(
                outputBlock(
                    search.matches.map { ($0, NeuralReadout.LineTone.dim) },
                    hidden: max(0, search.total - search.matches.count), more: search.moreLabel,
                    failed: false, stepID: step.stepID))
        case .subagent(let agent):
            box.addArrangedSubview(sectionLabel(Localized.text("Result")))
            box.addArrangedSubview(
                outputBlock(
                    agent.summary.map { ($0, NeuralReadout.LineTone.dim) },
                    hidden: max(0, agent.total - agent.summary.count), more: nil, failed: false,
                    stepID: step.stepID))
        case .text(let text):
            guard step.subject.kind != .thought, step.subject.kind != .note else { return nil }
            box.addArrangedSubview(
                wrapped(NSAttributedString(string: text.text, attributes: Theme.Ramp.attributes(.thought))))
        }
        return box
    }

    private func tailSection(_ tail: NeuralReadout.Tail) -> UIView {
        let box = UIStackView()
        box.axis = .vertical
        box.spacing = 6
        box.addArrangedSubview(
            sectionLabel(
                Localized.text("Output"),
                right: rightLabel(Localized.text("last %lld lines", tail.lines.count))))
        let framed = outputText(tail.lines.map { ($0.text, $0.tone) }, failed: false, caret: true)
        box.addArrangedSubview(framedOutput(framed, failed: false))
        return box
    }

    typealias BodyLine = (text: String, tone: NeuralReadout.LineTone)

    private func outputText(
        _ lines: [BodyLine], failed: Bool, caret: Bool = false
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let ink: UIColor
            switch line.tone {
            case .dim: ink = Theme.Color.secondaryLabel
            case .danger: ink = Theme.Color.danger
            case .emphasis: ink = Theme.Color.label
            }
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(
                NSAttributedString(
                    string: line.text,
                    attributes: Theme.Ramp.attributes(
                        .toolOutput, color: failed && line.tone == .dim ? Theme.Color.danger : ink)))
        }
        if caret {
            out.append(
                NSAttributedString(
                    string: " \u{258C}",
                    attributes: Theme.Ramp.attributes(.toolOutput, color: Theme.Color.accent)))
        }
        return out
    }

    private func framedOutput(_ text: NSAttributedString, failed: Bool) -> UIView {
        let label = wrapped(text)
        let holder = UIView()
        let rule = UIView()
        rule.backgroundColor = failed ? Theme.Color.danger : BrainCanvas.rule
        label.translatesAutoresizingMaskIntoConstraints = false
        rule.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(rule)
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            rule.topAnchor.constraint(equalTo: holder.topAnchor),
            rule.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            rule.widthAnchor.constraint(equalToConstant: 1),
            label.leadingAnchor.constraint(equalTo: rule.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            label.topAnchor.constraint(equalTo: holder.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -8),
        ])
        return holder
    }

    private static let expandedLineCap = 400

    private func outputBlock(
        _ lines: [BodyLine], hidden: Int, more: String?, failed: Bool, stepID: String
    ) -> UIView {
        let box = UIStackView()
        box.axis = .vertical
        box.spacing = 6
        var shown = lines
        var rest = hidden
        if outputExpanded, hidden > 0, let model, let source = model.step(id: stepID) {
            let all = NeuralReadout.fullOutput(of: source)
            shown = all.prefix(Self.expandedLineCap).map { ($0.text, $0.tone) }
            rest = max(0, all.count - shown.count)
        }
        box.addArrangedSubview(framedOutput(outputText(shown, failed: failed), failed: failed))
        if hidden > 0, let more {
            let title = outputExpanded
                ? (rest > 0 ? Localized.text("%lld more lines are in the list", rest) : Localized.text("Fold"))
                : more
            let link = BrainTextButton(title: title, bordered: false) { [weak self] in
                guard let self else { return }
                self.outputExpanded.toggle()
                self.onToggleOutput?(self.outputExpanded)
            }
            link.isEnabled = !(outputExpanded && rest > 0)
            box.addArrangedSubview(link)
        }
        return box
    }

    private func diffBlock(_ edit: NeuralReadout.Edit) -> UIView {
        let frame = UIStackView()
        frame.axis = .vertical
        frame.spacing = 0
        frame.layer.borderWidth = 1
        frame.layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor
        frame.layer.cornerRadius = 6
        frame.layer.masksToBounds = true
        for line in edit.lines {
            let mark: String
            let wash: UIColor
            let ink: UIColor
            switch line.kind {
            case .add: (mark, wash, ink) = ("+", Theme.Color.accent.wash(0.14), Theme.Color.accent)
            case .remove: (mark, wash, ink) = ("\u{2212}", Theme.Color.danger.wash(0.14), Theme.Color.danger)
            case .context: (mark, wash, ink) = (" ", .clear, Theme.Color.secondaryLabel)
            }
            let gutter = UILabel()
            gutter.attributedText = NSAttributedString(
                string: mark, attributes: Theme.Ramp.attributes(.diff, color: ink, alignment: .center))
            gutter.textAlignment = .center
            gutter.widthAnchor.constraint(equalToConstant: 22).isActive = true
            let text = wrapped(
                NSAttributedString(
                    string: line.text.isEmpty ? " " : line.text, attributes: Theme.Ramp.attributes(.diff)))
            let row = UIStackView(arrangedSubviews: [gutter, text])
            row.axis = .horizontal
            row.alignment = .top
            row.backgroundColor = wash
            row.isLayoutMarginsRelativeArrangement = true
            row.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 4)
            frame.addArrangedSubview(row)
        }
        let holder = UIStackView(arrangedSubviews: [frame])
        holder.axis = .vertical
        holder.spacing = 4
        if edit.hiddenCount > 0, let more = edit.moreLabel {
            holder.addArrangedSubview(rightLabel(more))
        }
        return holder
    }
}

/// A status chip: the words in capitals in a tone, with the shape of what it says, and a hairline
/// round it.
@MainActor
final class BrainChipLabel: UIView {
    private let label = UILabel()
    private let icon = UIImageView()
    private var tone = UIColor.label

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        icon.contentMode = .center
        addSubview(icon)
        addSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(text: String, tone new: UIColor, symbol: String?) {
        tone = new
        label.attributedText = NSAttributedString(
            string: text, attributes: Theme.Ramp.attributes(.badge, color: new))
        icon.image = symbol.flatMap {
            BrainCanvas.image($0, size: 9)?.withTintColor(
                new.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
        }
        icon.isHidden = symbol == nil
        layer.borderColor = new.resolvedColor(with: traitCollection).cgColor
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        let text = label.attributedText?.size() ?? .zero
        return CGSize(width: ceil(text.width) + 18 + (icon.isHidden ? 0 : 13), height: 20)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let text = label.attributedText?.size() ?? .zero
        var x: CGFloat = 8
        if !icon.isHidden {
            icon.frame = CGRect(x: 6, y: 0, width: 12, height: bounds.height)
            x = 19
        }
        label.frame = CGRect(x: x, y: (bounds.height - text.height) / 2, width: ceil(text.width) + 1, height: ceil(text.height))
    }
}

/// A small text button: a bordered pill (Copy, a relation) or a quiet underlined link (Show all).
@MainActor
final class BrainTextButton: UIControl {
    var onHover: ((Bool) -> Void)?
    private let label = UILabel()
    private var action: () -> Void
    private var bordered: Bool

    convenience init(title: String, bordered: Bool, action: @escaping () -> Void) {
        self.init(
            attributed: Self.attributed(title, bordered: bordered), bordered: bordered, action: action)
    }

    private static func attributed(_ title: String, bordered: Bool) -> NSAttributedString {
        let ink = bordered ? Theme.Color.label : Theme.Color.secondaryLabel
        var attributes = Theme.Ramp.attributes(bordered ? .control : .rowMeta, color: ink)
        if !bordered { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: title, attributes: attributes)
    }

    /// Gives a button that a cell reuses its next words and action.
    func replace(title: String, bordered isBordered: Bool, action next: @escaping () -> Void) {
        action = next
        bordered = isBordered
        label.attributedText = Self.attributed(title, bordered: isBordered)
        accessibilityLabel = title
        layer.cornerRadius = isBordered ? 12 : 0
        layer.borderWidth = isBordered ? 1 : 0
        layer.borderColor = BrainCanvas.rule.resolvedColor(with: traitCollection).cgColor
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    init(attributed: NSAttributedString, bordered isBordered: Bool, action onAction: @escaping () -> Void) {
        bordered = isBordered
        action = onAction
        super.init(frame: .zero)
        label.attributedText = attributed
        label.isUserInteractionEnabled = false
        addSubview(label)
        if bordered {
            layer.cornerRadius = 12
            layer.cornerCurve = .continuous
            layer.borderWidth = 1
            layer.borderColor = BrainCanvas.rule.resolvedColor(with: traitCollection).cgColor
        }
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = attributed.string
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() {
        Theme.Haptics.selection()
        action()
    }

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed: onHover?(true)
        default: onHover?(false)
        }
    }

    override var intrinsicContentSize: CGSize {
        let size = label.attributedText?.size() ?? .zero
        return bordered
            ? CGSize(width: ceil(size.width) + 22, height: max(24, ceil(size.height) + 8))
            : CGSize(width: ceil(size.width), height: ceil(size.height) + 4)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = label.attributedText?.size() ?? .zero
        label.frame = CGRect(
            x: (bounds.width - ceil(size.width)) / 2, y: (bounds.height - ceil(size.height)) / 2,
            width: ceil(size.width) + 1, height: ceil(size.height))
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        TouchSlop.area(of: bounds).contains(point)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.5 }
    }
}

/// Views laid left to right and wrapped, which is what a row of chips is when it is wider than the
/// room.
@MainActor
final class BrainFlowView: UIView {
    private let spacing: CGFloat
    private var items: [UIView] = []

    init(spacing newSpacing: CGFloat) {
        spacing = newSpacing
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func add(_ view: UIView) {
        items.append(view)
        addSubview(view)
        invalidateIntrinsicContentSize()
    }

    func removeAll() {
        for item in items { item.removeFromSuperview() }
        items = []
        invalidateIntrinsicContentSize()
    }

    private var laidWidth: CGFloat = 0

    private func arrange(width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        for item in items {
            let size = item.intrinsicContentSize
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, y + rowHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = arrange(width: bounds.width)
        for (item, frame) in zip(items, layout.frames) { item.frame = frame }
        if abs(laidWidth - bounds.width) > 0.5 {
            laidWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: arrange(width: size.width).height)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: arrange(width: bounds.width > 0 ? bounds.width : 300).height)
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        CGSize(width: targetSize.width, height: arrange(width: targetSize.width).height)
    }
}
