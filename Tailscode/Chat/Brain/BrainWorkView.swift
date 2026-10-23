import TailscodeCore
import UIKit

@MainActor
final class BrainWorkView: UIView, BrainAccountContent {
    private let line = UIControl()
    private let chevron = UIImageView()
    private var markViews: [UIView] = []
    private let words = UILabel()
    private let chip = BrainTextButton(title: " ", bordered: false) {}
    private let frameView = UIView()
    private var rowViews: [BrainStepRowView] = []
    private var cards: [(stepID: String, card: BrainStepCard)] = []
    private let moreButton = BrainTextButton(title: " ", bordered: false) {}
    private let moreNote = UILabel()
    private var item: BrainAccountItem?
    private var work: BrainAccountItem.Work?
    private var env: BrainAccountEnv?
    private var open = false
    private var shown: [String] = []
    private var cardAfter: [String: BrainAccountEnv.CardSpec] = [:]
    private var capped = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        line.layer.cornerRadius = 8
        line.layer.cornerCurve = .continuous
        line.layer.borderWidth = 1
        line.addTarget(self, action: #selector(lineTapped), for: .touchUpInside)
        chevron.contentMode = .center
        line.addSubview(chevron)
        words.lineBreakMode = .byTruncatingTail
        line.addSubview(words)
        line.addSubview(chip)
        addSubview(line)
        frameView.layer.borderWidth = 1
        frameView.layer.cornerRadius = 8
        frameView.layer.cornerCurve = .continuous
        frameView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        addSubview(frameView)
        frameView.addSubview(moreButton)
        moreNote.numberOfLines = 0
        frameView.addSubview(moreNote)
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func lineTapped() {
        guard let item, let env else { return }
        Theme.Haptics.selection()
        env.toggleWork(item.id)
    }

    func configure(item newItem: BrainAccountItem, work newWork: BrainAccountItem.Work, env newEnv: BrainAccountEnv) {
        item = newItem
        work = newWork
        env = newEnv
        open = newEnv.isOpen(newItem.id, work: newWork)
        chevron.image = BrainCanvas.image(open ? "chevron.down" : "chevron.right", size: 9, weight: .bold)?
            .withTintColor(Theme.Color.secondaryLabel.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
        line.backgroundColor = BrainCanvas.raised
        line.layer.borderColor = (open ? BrainCanvas.rule : Theme.Color.separator).resolvedColor(with: traitCollection).cgColor
        line.layer.maskedCorners =
            open ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        frameView.backgroundColor = BrainCanvas.raised.wash(0.6)
        frameView.layer.borderColor = BrainCanvas.rule.resolvedColor(with: traitCollection).cgColor
        buildLine(newWork)
        buildRows(newWork)
        accessibilityElements = [line] + rowViews
        line.isAccessibilityElement = true
        line.accessibilityLabel = words.attributedText?.string
        line.accessibilityTraits = .button
        line.accessibilityValue = open ? Localized.text("Expanded") : Localized.text("Collapsed")
        setNeedsLayout()
    }

    private func buildLine(_ work: BrainAccountItem.Work) {
        for view in markViews { view.removeFromSuperview() }
        markViews = []
        for cluster in work.clusters.prefix(4) {
            let icon = BrainShapeIcon()
            icon.set(shape: cluster.zone.shape, color: BrainCanvas.zone(cluster.zone))
            line.addSubview(icon)
            markViews.append(icon)
        }
        let out = NSMutableAttributedString()
        let (shown, more) = clauses(work)
        for (index, clause) in shown.enumerated() {
            if index > 0 {
                out.append(
                    NSAttributedString(
                        string: "  \u{00B7}  ",
                        attributes: Theme.Ramp.attributes(.control, color: Theme.Color.secondaryLabel)))
            }
            let ink: UIColor
            var symbol: String?
            switch clause.verdict {
            case .failed: (ink, symbol) = (Theme.Color.danger, "xmark")
            case .tryingAgain: (ink, symbol) = (Theme.Color.warning, "exclamationmark.triangle")
            default: (ink, symbol) = (Theme.Color.label, nil)
            }
            if let symbol, let image = BrainCanvas.image(symbol, size: 10) {
                let attachment = NSTextAttachment()
                attachment.image = image.withTintColor(ink.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
                attachment.bounds = CGRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
                out.append(NSAttributedString(attachment: attachment))
                out.append(NSAttributedString(string: " "))
            }
            out.append(
                NSAttributedString(string: clause.text, attributes: Theme.Ramp.attributes(.control, color: ink)))
            if clause.verdict == .done, isCheck(clause), let image = BrainCanvas.image("checkmark", size: 10, weight: .bold) {
                let attachment = NSTextAttachment()
                attachment.image = image.withTintColor(Theme.Color.accent.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
                attachment.bounds = CGRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
                out.append(NSAttributedString(string: " "))
                out.append(NSAttributedString(attachment: attachment))
            }
        }
        for fixed in work.fixedWords.prefix(1) {
            out.append(
                NSAttributedString(
                    string: "   ", attributes: Theme.Ramp.attributes(.control, color: Theme.Color.warning)))
            if let image = BrainCanvas.image("arrow.trianglehead.2.clockwise.rotate.90", size: 10) {
                let attachment = NSTextAttachment()
                attachment.image = image.withTintColor(Theme.Color.warning.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
                attachment.bounds = CGRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
                out.append(NSAttributedString(attachment: attachment))
                out.append(NSAttributedString(string: " "))
            }
            out.append(
                NSAttributedString(
                    string: fixed, attributes: Theme.Ramp.attributes(.control, color: Theme.Color.warning)))
        }
        if more > 0 {
            out.append(
                NSAttributedString(
                    string: "  " + Localized.text("+%lld more", more),
                    attributes: Theme.Ramp.attributes(.control, color: Theme.Color.secondaryLabel)))
        }
        words.attributedText = out
        let range = work.numbers.first.map { first -> String in
            let last = work.numbers.last ?? first
            return first == last ? "#\(first)" : "#\(first)\u{2013}\(last)"
        } ?? ""
        let target = work.firstFailedStepID ?? work.stepIDs.first
        chip.configure(title: range, bordered: false) { [weak self] in
            guard let target else { return }
            self?.env?.chooseStep(target, false)
        }
        chip.accessibilityLabel = Localized.text("Steps %@", range)
    }

    /// At most four clauses and how many more there are.
    private func clauses(_ work: BrainAccountItem.Work) -> ([BrainAccountItem.Clause], Int) {
        let limit = 4
        guard work.clauses.count > limit else { return (work.clauses, 0) }
        return (Array(work.clauses.prefix(limit)), work.clauses.count - limit)
    }

    private func isCheck(_ clause: BrainAccountItem.Clause) -> Bool {
        guard let env, let id = clause.stepIDs.first, let step = env.model.step(id: id),
            let command = step.call?.call.input?["command"]?.stringValue
        else { return false }
        return NeuralHuman.classify(command).checkKind != nil
    }

    private static let initialRows = 40
    private static let rowStride = 40
    private static let rowMax = 400

    private func buildRows(_ work: BrainAccountItem.Work) {
        for view in rowViews { view.removeFromSuperview() }
        rowViews = []
        for entry in cards { entry.card.removeFromSuperview() }
        cards = []
        cardAfter = [:]
        shown = []
        guard open, let env, let itemID = item?.id else {
            frameView.isHidden = true
            return
        }
        frameView.isHidden = false
        let specs = env.cardSpecs(for: work)
        var cap = min(work.stepIDs.count, env.interaction.rowCaps[itemID] ?? Self.initialRows)
        for spec in specs {
            if let at = work.stepIDs.firstIndex(of: spec.stepID) { cap = max(cap, min(work.stepIDs.count, at + 1)) }
        }
        capped = cap
        shown = Array(work.stepIDs.prefix(cap))
        let list = env.list
        for (index, id) in shown.enumerated() {
            guard let row = list.row(id: id) else { continue }
            let view = BrainStepRowView()
            var context = BrainStepRowView.Context()
            context.previous = index > 0 ? list.row(id: shown[index - 1]) : nil
            context.next = index + 1 < shown.count ? list.row(id: shown[index + 1]) : nil
            context.isCursor = env.cursor == id
            context.isHovered = env.hovered == id && env.cursor != id
            context.query = list.filter.query
            context.input = env.input
            context.total = list.total
            view.configure(row: row, context: context)
            view.onClick = { [weak env] id, double in env?.chooseStep(id, double) }
            view.onHover = { [weak env] id in env?.hoverStep(id) }
            view.onMenu = { [weak env] item, id in env?.menu(item, id) }
            view.onCopy = { [weak env] id in env?.copyStep(id) }
            frameView.addSubview(view)
            rowViews.append(view)
        }
        for spec in specs where shown.contains(spec.stepID) {
            guard let card = env.makeCard(for: spec) else { continue }
            card.onLayoutChange = { [weak env] in env?.heightChanged() }
            frameView.addSubview(card)
            cards.append((spec.stepID, card))
            cardAfter[spec.stepID] = spec
        }
        let remaining = work.stepIDs.count - cap
        if remaining > 0 {
            moreButton.isHidden = cap >= Self.rowMax
            moreNote.isHidden = cap < Self.rowMax
            if cap >= Self.rowMax {
                moreNote.attributedText = NSAttributedString(
                    string: Localized.text("%lld more steps are in the list", remaining),
                    attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel))
            } else {
                let step = min(remaining, Self.rowStride)
                moreButton.configure(
                    title: step == 1 ? Localized.text("Show 1 more step") : Localized.text("Show %lld more steps", step),
                    bordered: false
                ) { [weak env] in
                    env?.moreRows(itemID)
                }
            }
        } else {
            moreButton.isHidden = true
            moreNote.isHidden = true
        }
    }

    private struct Placement {
        var line: CGFloat
        var rows: [CGRect]
        var cards: [CGRect]
        var more: CGFloat
        var frame: CGFloat
        var total: CGFloat
    }

    private func placement(width: CGFloat) -> Placement {
        let line: CGFloat = 36
        guard open, let env else {
            return Placement(line: line, rows: [], cards: [], more: 0, frame: 0, total: line)
        }
        let inner = width - 2
        var y: CGFloat = 4
        var rowFrames: [CGRect] = []
        var cardFrames: [CGRect] = []
        let list = env.list
        var cardIndex = 0
        for id in shown {
            let height = CGFloat(list.row(id: id)?.height(input: env.input) ?? 28)
            rowFrames.append(CGRect(x: 0, y: y, width: inner, height: height))
            y += height
            if cardIndex < cards.count, cards[cardIndex].stepID == id {
                let card = cards[cardIndex].card
                let cardWidth = inner - 36 - 12
                let fit = card.fittedHeight(width: cardWidth)
                cardFrames.append(CGRect(x: 36, y: y + 4, width: cardWidth, height: fit))
                y += fit + 12
                cardIndex += 1
            }
        }
        var more: CGFloat = 0
        if !moreButton.isHidden || !moreNote.isHidden {
            more = 30
            y += more
        }
        y += 4
        return Placement(line: line, rows: rowFrames, cards: cardFrames, more: more, frame: y, total: line + y)
    }

    static func fit(_ view: UIView, width: CGFloat) -> CGFloat {
        view.frame = CGRect(x: 0, y: 0, width: width, height: 10)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return ceil(
            view.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            ).height)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard work != nil else { return 36 }
        return placement(width: width).total
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let place = placement(width: bounds.width)
        line.frame = CGRect(x: 0, y: 0, width: bounds.width, height: place.line)
        chevron.frame = CGRect(x: 6, y: 0, width: 14, height: place.line)
        var x: CGFloat = 24
        for view in markViews {
            view.frame = CGRect(x: x, y: (place.line - 18) / 2, width: 18, height: 18)
            x += 20
        }
        let chipSize = chip.intrinsicContentSize
        chip.frame = CGRect(x: bounds.width - 10 - chipSize.width, y: (place.line - chipSize.height) / 2, width: chipSize.width, height: chipSize.height)
        let textSize = words.attributedText?.size() ?? .zero
        words.frame = CGRect(x: x + 6, y: (place.line - ceil(textSize.height)) / 2, width: max(0, chip.frame.minX - x - 14), height: ceil(textSize.height))
        guard open else { return }
        frameView.frame = CGRect(x: 0, y: place.line, width: bounds.width, height: place.frame)
        for (view, frame) in zip(rowViews, place.rows) { view.frame = frame }
        for (entry, frame) in zip(cards, place.cards) { entry.card.frame = frame }
        if place.more > 0 {
            let y = (place.rows.last?.maxY ?? 4) + (place.cards.last.map { $0.maxY + 8 - (place.rows.last?.maxY ?? 0) } ?? 0)
            let base = max(y, (place.cards.last?.maxY ?? 0) + 8)
            let size = moreButton.intrinsicContentSize
            moreButton.frame = CGRect(x: 14, y: base + 4, width: size.width, height: 22)
            moreNote.frame = CGRect(x: 14, y: base + 4, width: bounds.width - 28, height: 22)
        }
    }
}
