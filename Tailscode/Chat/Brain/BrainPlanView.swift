import TailscodeCore
import UIKit

@MainActor
final class BrainPlanView: UIView, BrainAccountContent {
    private let card = UIView()
    private let chevron = UIImageView()
    private let label = UILabel()
    private let count = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private var rows: [(mark: UIImageView, text: UILabel)] = []
    private var plan: NeuralAccount.Plan?
    private var env: BrainAccountEnv?
    private var open = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        track.layer.cornerRadius = 2
        fill.layer.cornerRadius = 2
        addSubview(card)
        for view in [chevron, label, count, track] { card.addSubview(view) }
        track.addSubview(fill)
        card.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        chevron.contentMode = .center
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var isLiveCompact: Bool { env?.isRunning == true }

    func configure(plan new: NeuralAccount.Plan, env newEnv: BrainAccountEnv) {
        plan = new
        env = newEnv
        let finished = new.done == new.total
        open = newEnv.interaction.planExpanded ?? !finished
        card.backgroundColor = BrainCanvas.raised
        card.layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor
        chevron.image = BrainCanvas.image(open ? "chevron.down" : "chevron.right", size: 9, weight: .bold)?
            .withTintColor(Theme.Color.secondaryLabel.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
        label.attributedText = NSAttributedString(
            string: Localized.text("PLAN"),
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.secondaryLabel))
        count.attributedText = NSAttributedString(
            string: new.label, attributes: Theme.Ramp.attributes(.rowMeta, color: Theme.Color.label))
        track.backgroundColor = Theme.Color.accent.wash(0.16)
        fill.backgroundColor = Theme.Color.accent
        for row in rows {
            row.mark.removeFromSuperview()
            row.text.removeFromSuperview()
        }
        rows = []
        if open {
            for item in new.items {
                let mark = UIImageView()
                mark.contentMode = .center
                let text = UILabel()
                text.numberOfLines = 1
                text.lineBreakMode = .byTruncatingTail
                switch item.state {
                case .done:
                    mark.image = BrainCanvas.image("checkmark", size: 10, weight: .bold)?
                        .withTintColor(Theme.Color.accent.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
                    text.attributedText = NSAttributedString(
                        string: item.text, attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.secondaryLabel))
                case .inProgress:
                    mark.image = BrainCanvas.image("circle.fill", size: 8)?
                        .withTintColor(Theme.Color.accent.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
                    text.attributedText = NSAttributedString(
                        string: item.activeForm ?? item.text,
                        attributes: Theme.Ramp.attributes(.rowTitleStrong, color: Theme.Color.label))
                case .pending:
                    mark.image = BrainCanvas.image("circle", size: 8)?
                        .withTintColor(Theme.Color.secondaryLabel.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
                    text.attributedText = NSAttributedString(
                        string: item.text, attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.label))
                }
                card.addSubview(mark)
                card.addSubview(text)
                rows.append((mark, text))
            }
        }
        accessibilityLabel = Localized.text("Plan, %@", new.label)
        setNeedsLayout()
    }

    @objc private func tapped() {
        guard let env else { return }
        Theme.Haptics.selection()
        env.interaction.planExpanded = !open
        env.heightChanged()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let plan else { return 0 }
        let body = open ? CGFloat(plan.items.count) * 24 + 8 : 0
        return 8 + 28 + body + 6
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let plan else { return }
        card.frame = CGRect(x: 16, y: 8, width: bounds.width - 32, height: bounds.height - 14)
        chevron.frame = CGRect(x: 10, y: 0, width: 14, height: 28)
        let labelSize = label.attributedText?.size() ?? .zero
        label.frame = CGRect(x: 28, y: (28 - labelSize.height) / 2, width: ceil(labelSize.width) + 1, height: ceil(labelSize.height))
        let countSize = count.attributedText?.size() ?? .zero
        count.frame = CGRect(x: label.frame.maxX + 10, y: (28 - countSize.height) / 2, width: ceil(countSize.width) + 1, height: ceil(countSize.height))
        let trackWidth = min(160, max(0, card.bounds.width - count.frame.maxX - 24))
        track.frame = CGRect(x: count.frame.maxX + 12, y: 12, width: trackWidth, height: 4)
        let share = plan.total == 0 ? 0 : CGFloat(plan.done) / CGFloat(plan.total)
        fill.frame = CGRect(x: 0, y: 0, width: trackWidth * share, height: 4)
        for (index, row) in rows.enumerated() {
            let y = 32 + CGFloat(index) * 24
            row.mark.frame = CGRect(x: 10, y: y, width: 14, height: 24)
            row.text.frame = CGRect(x: 32, y: y, width: card.bounds.width - 32 - 12, height: 24)
        }
    }
}
