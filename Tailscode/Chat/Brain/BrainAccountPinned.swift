import CodingAgentKit
import TailscodeCore
import UIKit

/// The entity and its vitals: who is working and how hard, what the turn came to in one word, how
/// long it took, and the counts. It sits above the story and never scrolls with it. A narrow one
/// wraps its sentence and its counts onto lines of their own.
@MainActor
final class BrainAccountHeaderView: UIView {
    private let dot = UIView()
    private let name = UILabel()
    private let bars = EffortMeterView()
    private let pill = BrainChipLabel()
    private let sentence = UILabel()
    private let counts = UILabel()
    private let rule = UIView()
    private var wide = false
    private var pulse: CAAnimation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        dot.layer.cornerRadius = 5
        for view in [rule, dot, name, bars, pill, sentence, counts] { addSubview(view) }
        sentence.adjustsFontForContentSizeCategory = true
        sentence.numberOfLines = 0
        counts.numberOfLines = 0
        counts.adjustsFontForContentSizeCategory = true
        name.adjustsFontForContentSizeCategory = true
        rule.backgroundColor = Theme.Color.separator
        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(header: NeuralAccount.Header, vitals: NeuralAccount.Vitals) {
        let family = Theme.Color.modelFamily(header.family)
        dot.backgroundColor = family
        name.attributedText = NSAttributedString(
            string: header.speaker,
            attributes: Theme.Ramp.attributes(.rowTitleStrong, color: Theme.Color.label))
        bars.reading = EffortMeterView.Reading(
            heat: header.face.effort, level: header.effort, isPower: header.face.rainbow,
            isServer: header.face.hollow, isEmber: header.face.ember)
        bars.isHidden = false
        let tone = BrainCanvas.tone(header.tone, face: header.face)
        pill.set(text: header.pillWord.uppercased(), tone: tone, symbol: BrainCanvas.symbol(for: header.verdict))
        var line = NSMutableAttributedString(
            string: vitals.sentence,
            attributes: Theme.Ramp.attributes(.panelLabel, color: Theme.Color.secondaryLabel))
        if let clause = header.clause, !header.isRunning,
            let range = vitals.sentence.range(of: clause)
        {
            let ns = NSRange(range, in: vitals.sentence)
            line.addAttributes(
                [.foregroundColor: Theme.Color.warning.resolvedColor(with: traitCollection)], range: ns)
            if let image = BrainCanvas.image("arrow.trianglehead.2.clockwise.rotate.90", size: 11)?
                .withTintColor(Theme.Color.warning.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
            {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(x: 0, y: -1.5, width: image.size.width, height: image.size.height)
                let icon = NSAttributedString(attachment: attachment)
                line.insert(NSAttributedString(string: " "), at: ns.location)
                line.insert(icon, at: ns.location)
            }
        }
        if header.isRunning, let silent = vitals.silentWords {
            line = NSMutableAttributedString(
                string: silent,
                attributes: Theme.Ramp.attributes(.panelLabel, color: Theme.Color.warning))
        }
        sentence.attributedText = line
        counts.attributedText = NSAttributedString(
            string: vitals.counts,
            attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel, alignment: .right))
        accessibilityLabel = Localized.text("%1$@, %2$@, %3$@", header.speaker, header.pillWord, vitals.sentence)
        accessibilityValue = vitals.counts
        let animated = header.isRunning && header.verdict == .working && !UIAccessibility.isReduceMotionEnabled
        if animated, dot.layer.animation(forKey: "swell") == nil, let animation = BrainSwell.level(for: .breath) {
            dot.layer.setRepeatingMotion(animation, forKey: "swell", meaning: .working)
        } else if !animated {
            dot.layer.removeAnimation(forKey: "swell")
        }
        setNeedsLayout()
    }

    /// The header's height for a width: one line when the sentence and the counts fit beside the
    /// name, two or three when they do not.
    func height(forWidth width: CGFloat) -> CGFloat {
        let layout = place(width: width)
        return layout.height
    }

    private struct Placement {
        var height: CGFloat
        var frames: [(UIView, CGRect)]
    }

    private func place(width: CGFloat) -> Placement {
        let padding: CGFloat = 16
        let inner = max(0, width - padding * 2)
        let nameSize = name.attributedText?.size() ?? .zero
        let pillSize = pill.intrinsicContentSize
        let barSize = EffortMeterView.size
        let sentenceSize = sentence.attributedText?.size() ?? .zero
        let countSize = counts.attributedText?.size() ?? .zero
        var frames: [(UIView, CGRect)] = []
        let rowHeight = max(28, ceil(nameSize.height), pillSize.height)
        var x = padding
        func center(_ height: CGFloat, in row: CGFloat = 0) -> CGFloat { row + (rowHeight - height) / 2 }
        frames.append((dot, CGRect(x: x, y: center(10), width: 10, height: 10)))
        x += 10 + 8
        frames.append((name, CGRect(x: x, y: center(ceil(nameSize.height)), width: ceil(nameSize.width) + 1, height: ceil(nameSize.height))))
        x += ceil(nameSize.width) + 8
        frames.append((bars, CGRect(x: x, y: center(barSize.height), width: barSize.width, height: barSize.height)))
        x += barSize.width + 10
        frames.append((pill, CGRect(x: x, y: center(pillSize.height), width: pillSize.width, height: pillSize.height)))
        x += pillSize.width + 10
        let wideFits = x + ceil(sentenceSize.width) + 16 + ceil(countSize.width) <= width - padding
        if wideFits {
            frames.append((sentence, CGRect(x: x, y: center(ceil(sentenceSize.height)), width: ceil(sentenceSize.width) + 1, height: ceil(sentenceSize.height))))
            frames.append((counts, CGRect(x: width - padding - ceil(countSize.width) - 1, y: center(ceil(countSize.height)), width: ceil(countSize.width) + 1, height: ceil(countSize.height))))
            return Placement(height: rowHeight + 8, frames: frames)
        }
        var y = rowHeight + 2
        let sentenceFits = x + ceil(sentenceSize.width) <= width - padding
        if sentenceFits {
            frames.append((sentence, CGRect(x: x, y: center(ceil(sentenceSize.height)), width: ceil(sentenceSize.width) + 1, height: ceil(sentenceSize.height))))
            y = rowHeight + 2
        } else {
            let rect = sentence.attributedText?.boundingRect(
                with: CGSize(width: inner, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, context: nil) ?? .zero
            frames.append((sentence, CGRect(x: padding, y: y, width: inner, height: ceil(rect.height))))
            y += ceil(rect.height) + 2
        }
        let countRect = counts.attributedText?.boundingRect(
            with: CGSize(width: inner, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, context: nil) ?? .zero
        frames.append((counts, CGRect(x: padding, y: y, width: inner, height: ceil(countRect.height))))
        y += ceil(countRect.height) + 8
        return Placement(height: y, frames: frames)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = place(width: bounds.width)
        for (view, frame) in layout.frames { view.frame = frame }
        let wideFits = (layout.frames.first { $0.0 === counts }?.1.minX ?? 0) > 100
        counts.textAlignment = wideFits ? .right : .left
        sentence.numberOfLines = 0
        rule.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1 / max(UIScreen.main.scale, 1))
    }
}

/// What the agent is stopped to ask the person: a pinned card in the warning tone, in the agent's
/// own words, with the command or question it is about and the one button that goes to the real
/// approval or question card, which is never duplicated here.
@MainActor
final class BrainAskCardView: UIView {
    var onGo: (() -> Void)?
    var onShow: ((String) -> Void)?

    private let edge = UIView()
    private let head = UILabel()
    private let meta = UILabel()
    private let dot = UIView()
    private let words = UILabel()
    private let command = UILabel()
    private let commandBox = UIView()
    private let options = BrainFlowView(spacing: 6)
    private let go = UIButton(type: .system)
    private var ask: NeuralAccount.Ask?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.masksToBounds = true
        dot.layer.cornerRadius = 4
        meta.adjustsFontSizeToFitWidth = true
        meta.minimumScaleFactor = 0.7
        meta.lineBreakMode = .byTruncatingTail
        words.numberOfLines = 0
        command.numberOfLines = 0
        command.lineBreakMode = .byCharWrapping
        commandBox.layer.cornerRadius = 6
        commandBox.layer.borderWidth = 1
        commandBox.addSubview(command)
        for view in [edge, dot, head, meta, words, commandBox, options, go] { addSubview(view) }
        go.addAction(UIAction { [weak self] _ in self?.onGo?() }, for: .touchUpInside)
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(ask new: NeuralAccount.Ask, step: NeuralStep?) {
        ask = new
        backgroundColor = Theme.Color.warning.wash(0.09)
        layer.borderColor = Theme.Color.warning.wash(0.55).resolvedColor(with: traitCollection).cgColor
        edge.backgroundColor = Theme.Color.warning
        dot.backgroundColor = Theme.Color.warning
        head.attributedText = NSAttributedString(
            string: Localized.text("NEEDS YOU"),
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.warning))
        var metaText = ""
        if let clock = step?.at.map({ NeuralReading.clock($0) }) {
            metaText = Localized.text("waiting since %@", clock)
        }
        meta.attributedText = NSAttributedString(
            string: metaText,
            attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel, alignment: .right))
        let said = new.why?.text ?? new.sentence
        words.attributedText = NSAttributedString(
            string: said, attributes: Theme.Ramp.attributes(.answer, color: Theme.Color.label))
        if new.subjectKind == .command, !new.subject.isEmpty {
            let text = NSMutableAttributedString(
                string: "$ ", attributes: Theme.Ramp.attributes(.toolDetail, color: Theme.Color.warning))
            text.append(
                NSAttributedString(string: new.subject, attributes: Theme.Ramp.attributes(.toolDetail)))
            command.attributedText = text
            commandBox.isHidden = false
            commandBox.backgroundColor = Theme.Color.background.wash(0.7)
            commandBox.layer.borderColor = BrainCanvas.rule.resolvedColor(with: traitCollection).cgColor
        } else if !new.subject.isEmpty, new.subject != said {
            command.attributedText = NSAttributedString(
                string: new.subject, attributes: Theme.Ramp.attributes(.cardTitle))
            commandBox.isHidden = false
            commandBox.backgroundColor = .clear
            commandBox.layer.borderColor = UIColor.clear.cgColor
        } else {
            commandBox.isHidden = true
        }
        for view in options.subviews { view.removeFromSuperview() }
        options.removeAll()
        for option in new.options {
            let chip = BrainTextButton(
                attributed: NSAttributedString(
                    string: option, attributes: Theme.Ramp.attributes(.chip, color: Theme.Color.label)),
                bordered: true) {}
            chip.isEnabled = false
            chip.alpha = 1
            options.add(chip)
        }
        options.isHidden = new.options.isEmpty
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = Theme.Color.warning
        config.baseForegroundColor = Theme.Color.background
        config.cornerStyle = .capsule
        config.attributedTitle = AttributedString(
            NSAttributedString(
                string: new.actionLabel + " \u{2193}",
                attributes: Theme.Ramp.attributes(.control, color: Theme.Color.background)))
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        go.configuration = config
        showButton?.removeFromSuperview()
        let stepID = new.stepID
        let number = new.number
        let ghost = BrainTextButton(
            title: Localized.text("Show step #%lld", number), bordered: true) { [weak self] in
            self?.onShow?(stepID)
        }
        addSubview(ghost)
        showButton = ghost
        accessibilityLabel = Localized.text("%1$@. %2$@", Localized.text("Needs you"), said)
        if dot.layer.animation(forKey: "knock") == nil, !UIAccessibility.isReduceMotionEnabled,
            let animation = BrainSwell.level(for: .heartbeat)
        {
            dot.layer.setRepeatingMotion(animation, forKey: "knock", meaning: .attention)
        }
        setNeedsLayout()
    }

    private var showButton: BrainTextButton?

    func height(forWidth width: CGFloat) -> CGFloat {
        layoutFrames(width: width).height
    }

    private struct Frames {
        var height: CGFloat
        var items: [(UIView, CGRect)]
    }

    private func layoutFrames(width: CGFloat) -> Frames {
        var items: [(UIView, CGRect)] = []
        let left: CGFloat = 19
        let right: CGFloat = 16
        let inner = max(0, width - left - right)
        var y: CGFloat = 14
        let headSize = head.attributedText?.size() ?? .zero
        items.append((dot, CGRect(x: left, y: y + (headSize.height - 8) / 2, width: 8, height: 8)))
        items.append((head, CGRect(x: left + 16, y: y, width: ceil(headSize.width) + 1, height: ceil(headSize.height))))
        let metaWidth = max(0, inner - 16 - ceil(headSize.width) - 8)
        let metaSize = meta.attributedText?.size() ?? .zero
        items.append((meta, CGRect(x: width - right - metaWidth, y: y, width: metaWidth, height: ceil(metaSize.height))))
        y += max(ceil(headSize.height), ceil(metaSize.height)) + 8
        let wordsHeight = ceil(
            (words.attributedText?.boundingRect(
                with: CGSize(width: inner, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin,
                context: nil).height) ?? 0)
        items.append((words, CGRect(x: left, y: y, width: inner, height: wordsHeight)))
        y += wordsHeight
        if !commandBox.isHidden {
            y += 10
            let commandHeight = ceil(
                (command.attributedText?.boundingRect(
                    with: CGSize(width: inner - 24, height: .greatestFiniteMagnitude),
                    options: .usesLineFragmentOrigin, context: nil).height) ?? 0)
            items.append((commandBox, CGRect(x: left, y: y, width: inner, height: commandHeight + 16)))
            y += commandHeight + 16
        }
        if !options.isHidden {
            y += 10
            let size = options.sizeThatFits(CGSize(width: inner, height: 0))
            items.append((options, CGRect(x: left, y: y, width: inner, height: size.height)))
            y += size.height
        }
        y += 12
        let goSize = go.sizeThatFits(CGSize(width: inner, height: 40))
        items.append((go, CGRect(x: left, y: y, width: goSize.width, height: max(32, goSize.height))))
        if let showButton {
            let size = showButton.intrinsicContentSize
            items.append((showButton, CGRect(x: left + goSize.width + 8, y: y + (max(32, goSize.height) - size.height) / 2, width: size.width, height: size.height)))
        }
        y += max(32, goSize.height) + 14
        return Frames(height: y, items: items)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        edge.frame = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
        let frames = layoutFrames(width: bounds.width)
        for (view, frame) in frames.items { view.frame = frame }
        command.frame = commandBox.bounds.insetBy(dx: 12, dy: 8)
    }
}

/// The step in flight, while the turn runs, in the reader's words: its plain title, what it was
/// given, the last lines it printed with a caret, and how long since anything arrived, which turns
/// to the warning tone and says so when nothing has for forty seconds.
@MainActor
final class BrainNowView: UIView {
    var onTap: ((String) -> Void)?

    private let pulse = UIView()
    private let label = UILabel()
    private let title = UILabel()
    private let argument = UILabel()
    private let output = UILabel()
    private let age = UILabel()
    private var stepID: String?
    private let rule = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        pulse.layer.cornerRadius = 4
        output.numberOfLines = 2
        argument.numberOfLines = 1
        argument.lineBreakMode = .byTruncatingTail
        for view in [rule, pulse, label, title, argument, output, age] { addSubview(view) }
        rule.backgroundColor = Theme.Color.separator
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() {
        if let stepID { onTap?(stepID) }
    }

    func configure(live: NeuralAccount.LiveStep, vitals: NeuralAccount.Vitals, face: NeuralFace) {
        stepID = live.stepID
        let silent = vitals.isSilent
        let tone = silent ? Theme.Color.warning : Theme.Color.accent
        pulse.backgroundColor = tone
        label.attributedText = NSAttributedString(
            string: NeuralReading.nowLabel,
            attributes: Theme.Ramp.attributes(.sectionLabel, color: tone))
        title.attributedText = NSAttributedString(
            string: live.title, attributes: Theme.Ramp.attributes(.rowTitleStrong))
        argument.attributedText = NSAttributedString(
            string: live.argument,
            attributes: Theme.Ramp.attributes(.rowDetail, color: Theme.Color.secondaryLabel))
        let lines = NSMutableAttributedString()
        for (index, line) in live.tail.suffix(2).enumerated() {
            if index > 0 { lines.append(NSAttributedString(string: "\n")) }
            lines.append(
                NSAttributedString(
                    string: line.text,
                    attributes: Theme.Ramp.attributes(
                        .toolOutput,
                        color: line.tone == .danger ? Theme.Color.warning : Theme.Color.secondaryLabel)))
        }
        if !live.tail.isEmpty {
            lines.append(
                NSAttributedString(
                    string: " \u{258C}", attributes: Theme.Ramp.attributes(.toolOutput, color: Theme.Color.accent)))
        }
        output.attributedText = lines
        let words = vitals.silentWords ?? vitals.lastOutputWords ?? ""
        age.attributedText = NSAttributedString(
            string: words,
            attributes: Theme.Ramp.attributes(
                .rowStamp, color: silent ? Theme.Color.warning : Theme.Color.secondaryLabel, alignment: .right))
        accessibilityLabel = Localized.text("%1$@, %2$@", live.title, live.argument)
        accessibilityValue = words
        if !UIAccessibility.isReduceMotionEnabled, !silent, pulse.layer.animation(forKey: "swell") == nil,
            let animation = BrainSwell.level(for: .breath)
        {
            pulse.layer.setRepeatingMotion(animation, forKey: "swell", meaning: .working)
        } else if silent {
            pulse.layer.removeAnimation(forKey: "swell")
        }
        setNeedsLayout()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = width - 32
        let titleSize = title.attributedText?.size() ?? .zero
        var height: CGFloat = 8 + max(18, ceil(titleSize.height)) + 2
        if (output.attributedText?.length ?? 0) > 0 {
            height += ceil(
                (output.attributedText?.boundingRect(
                    with: CGSize(width: inner, height: .greatestFiniteMagnitude),
                    options: .usesLineFragmentOrigin, context: nil).height) ?? 0) + 2
        }
        return height + 8
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rule.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1 / max(UIScreen.main.scale, 1))
        let inner = bounds.width - 32
        var y: CGFloat = 8
        let labelSize = label.attributedText?.size() ?? .zero
        let titleSize = title.attributedText?.size() ?? .zero
        let row = max(18, ceil(titleSize.height))
        pulse.frame = CGRect(x: 16, y: y + (row - 8) / 2, width: 8, height: 8)
        label.frame = CGRect(x: 30, y: y + (row - labelSize.height) / 2, width: ceil(labelSize.width) + 1, height: ceil(labelSize.height))
        let ageSize = age.attributedText?.size() ?? .zero
        let ageWidth = min(ceil(ageSize.width) + 1, inner * 0.4)
        age.frame = CGRect(x: bounds.width - 16 - ageWidth, y: y + (row - ageSize.height) / 2, width: ageWidth, height: ceil(ageSize.height))
        var x = label.frame.maxX + 10
        let titleWidth = min(ceil(titleSize.width) + 1, max(0, age.frame.minX - x - 8))
        title.frame = CGRect(x: x, y: y, width: titleWidth, height: row)
        x = title.frame.maxX + 8
        argument.frame = CGRect(x: x, y: y + (row - ceil(argument.attributedText?.size().height ?? 14)) / 2, width: max(0, age.frame.minX - x - 8), height: ceil(argument.attributedText?.size().height ?? 14))
        y += row + 2
        if (output.attributedText?.length ?? 0) > 0 {
            let height = ceil(
                (output.attributedText?.boundingRect(
                    with: CGSize(width: inner, height: .greatestFiniteMagnitude),
                    options: .usesLineFragmentOrigin, context: nil).height) ?? 0)
            output.frame = CGRect(x: 16, y: y, width: inner, height: height)
        } else {
            output.frame = .zero
        }
    }
}
