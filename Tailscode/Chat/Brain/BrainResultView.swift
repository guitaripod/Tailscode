import TailscodeCore
import UIKit

@MainActor
final class BrainResultView: UIView, BrainAccountContent {
    private let card = UIView()
    private var result: NeuralAccount.Result?
    private var env: BrainAccountEnv?
    private var groups: [UIView] = []
    private var answerButton: UIControl?

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        addSubview(card)
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func label(_ text: String) -> UILabel {
        let label = UILabel()
        label.attributedText = NSAttributedString(
            string: text.uppercased(),
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.secondaryLabel))
        return label
    }

    func configure(result new: NeuralAccount.Result, env newEnv: BrainAccountEnv) {
        result = new
        env = newEnv
        card.backgroundColor = BrainCanvas.raised
        card.layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor
        for view in groups { view.removeFromSuperview() }
        groups = []
        let title = UILabel()
        title.attributedText = NSAttributedString(
            string: Localized.text("RESULT"),
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.label))
        let head = BrainResultGroup(title: title)
        groups.append(head)
        if !new.changes.isEmpty {
            let group = BrainResultGroup(title: label(NeuralReading.changedLabel))
            let maxChange = max(1, new.changes.map { $0.added + $0.removed }.max() ?? 1)
            for change in new.changes.prefix(8) {
                group.add(changeRow(change, maxChange: maxChange))
            }
            if new.changes.count > 8 {
                group.add(note(Localized.text("%lld more files", new.changes.count - 8)))
            }
            groups.append(group)
        } else if let words = new.changedWords {
            let group = BrainResultGroup(title: nil)
            group.add(note(words))
            groups.append(group)
        }
        if !new.checks.isEmpty {
            let group = BrainResultGroup(title: label(Localized.text("Checks")))
            for check in new.checks { group.add(checkRow(check)) }
            groups.append(group)
        }
        if !new.unfixed.isEmpty {
            let group = BrainResultGroup(title: label(Localized.text("Still failing")))
            for item in new.unfixed.prefix(6) { group.add(unfixedRow(item)) }
            groups.append(group)
        }
        if new.answer != nil || new.answerWords != nil {
            let group = BrainResultGroup(title: label(NeuralReading.thenItAnswered))
            if let answer = new.answer {
                let text = UILabel()
                text.numberOfLines = 0
                text.attributedText = NSAttributedString(
                    string: answer, attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.label))
                group.add(text)
                group.onTap = { [weak self] in self?.env?.goToAnswer() }
            } else if let words = new.answerWords {
                group.add(note(words))
            }
            groups.append(group)
        }
        for (index, view) in groups.enumerated() {
            (view as? BrainResultGroup)?.ruled = index > 0
            card.addSubview(view)
        }
        accessibilityElements = groups
        setNeedsLayout()
    }

    private func note(_ text: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.attributedText = NSAttributedString(
            string: text, attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.secondaryLabel))
        return label
    }

    private func changeRow(_ change: NeuralAccount.Change, maxChange: Int) -> UIView {
        BrainChangeRow(change: change, maxChange: maxChange) { [weak self] in
            self?.env?.chooseStep(change.stepID, false)
        }
    }

    private func checkRow(_ check: NeuralAccount.Check) -> UIView {
        BrainCheckRow(check: check) { [weak self] in
            self?.env?.chooseStep(check.stepID, false)
        }
    }

    private func unfixedRow(_ item: NeuralAccount.Unfixed) -> UIView {
        BrainUnfixedRow(item: item) { [weak self] in self?.env?.chooseStep(item.stepID, false) }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = width - 32 - 24
        let total = groups.reduce(CGFloat(0)) { sum, view in
            sum + ((view as? BrainResultGroup)?.height(forWidth: inner) ?? 0)
        }
        return 12 + total + 12 + 16
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = CGRect(x: 16, y: 12, width: bounds.width - 32, height: bounds.height - 12 - 16)
        let inner = card.bounds.width - 24
        var y: CGFloat = 12
        for view in groups {
            guard let group = view as? BrainResultGroup else { continue }
            let height = group.height(forWidth: inner)
            group.frame = CGRect(x: 12, y: y, width: inner, height: height)
            y += height
        }
    }
}

/// One group of the result block, ruled off from the one above it.
@MainActor
final class BrainResultGroup: UIView {
    var ruled = false { didSet { setNeedsLayout() } }
    var onTap: (() -> Void)?
    private let title: UIView?
    private var rows: [UIView] = []
    private let rule = UIView()

    init(title newTitle: UIView?) {
        title = newTitle
        super.init(frame: .zero)
        if let title { addSubview(title) }
        rule.backgroundColor = Theme.Color.separator
        addSubview(rule)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }

    func add(_ view: UIView) {
        rows.append(view)
        addSubview(view)
    }

    private var topPad: CGFloat { ruled ? 10 : 0 }

    func height(forWidth width: CGFloat) -> CGFloat {
        var y = topPad + 2
        if let title { y += ceil(title.intrinsicContentSize.height > 0 ? title.intrinsicContentSize.height : 16) + 6 }
        for row in rows { y += rowHeight(row, width: width) + 6 }
        return y + (ruled ? 6 : 0)
    }

    private func rowHeight(_ row: UIView, width: CGFloat) -> CGFloat {
        if let label = row as? UILabel {
            return BrainText.height(label.attributedText, width: width)
        }
        return row.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rule.isHidden = !ruled
        rule.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1 / max(UIScreen.main.scale, 1))
        var y = topPad + 2
        if let title {
            let size = title.intrinsicContentSize
            let height = ceil(size.height > 0 ? size.height : 16)
            title.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            y += height + 6
        }
        for row in rows {
            let height = rowHeight(row, width: bounds.width)
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            y += height + 6
        }
    }
}
