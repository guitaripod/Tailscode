import TailscodeCore
import UIKit

@MainActor
final class BrainAskedView: UIView, BrainAccountContent {
    private let label = UILabel()
    private let text = UILabel()
    private let more = BrainTextButton(title: " ", bordered: false) {}
    private var asked: NeuralAccount.Asked?
    private var env: BrainAccountEnv?
    private var expanded = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [label, text, more] { addSubview(view) }
        text.numberOfLines = 0
        isAccessibilityElement = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(asked new: NeuralAccount.Asked, env newEnv: BrainAccountEnv) {
        asked = new
        env = newEnv
        expanded = newEnv.interaction.askedExpanded
        label.attributedText = NSAttributedString(
            string: Localized.text("ASKED"),
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.secondaryLabel))
        let words = expanded ? new.text : new.lines.joined(separator: "\n")
        text.attributedText = NSAttributedString(
            string: words, attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.secondaryLabel))
        accessibilityLabel = Localized.text("Asked, %@", new.text)
        setNeedsLayout()
    }

    private var measure: CGFloat { 0 }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let asked else { return 0 }
        let inner = min(width - 32, CGFloat(NeuralStageMetrics.proseMeasure))
        let lines = expanded ? 0 : 2
        let textHeight = BrainText.height(text.attributedText, width: inner, lines: lines)
        return 6 + 16 + 4 + textHeight + (asked.hasMore ? 22 : 0) + 8
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let asked else { return }
        let inner = min(bounds.width - 32, CGFloat(NeuralStageMetrics.proseMeasure))
        let labelSize = label.attributedText?.size() ?? .zero
        label.frame = CGRect(x: 16, y: 6, width: ceil(labelSize.width) + 1, height: 16)
        text.numberOfLines = expanded ? 0 : 2
        let height = BrainText.height(text.attributedText, width: inner, lines: expanded ? 0 : 2)
        text.frame = CGRect(x: 16, y: 26, width: inner, height: height)
        more.isHidden = !asked.hasMore
        if asked.hasMore {
            more.configure(
                title: expanded ? Localized.text("Hide") : NeuralReading.showAllLabel, bordered: false
            ) { [weak self] in
                guard let self, let env = self.env else { return }
                env.interaction.askedExpanded.toggle()
                env.heightChanged()
            }
            let size = more.intrinsicContentSize
            more.frame = CGRect(x: 16, y: text.frame.maxY + 2, width: size.width, height: 20)
        }
    }
}
