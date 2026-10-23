import TailscodeCore
import UIKit

@MainActor
final class BrainThoughtView: UIView, BrainAccountContent {
    private let glyph = BrainShapeIcon()
    private let text = UILabel()
    private let toggle = BrainTextButton(title: " ", bordered: false) {}
    private let chip = BrainTextButton(title: " ", bordered: false) {}
    private var thought: NeuralAccount.Thought?
    private var env: BrainAccountEnv?
    private var itemID = ""
    private var expanded = false
    private var isCursor = false
    private var isHover = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 6
        for view in [glyph, text, toggle, chip] { addSubview(view) }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(item: BrainAccountItem, thought new: NeuralAccount.Thought, env newEnv: BrainAccountEnv) {
        thought = new
        env = newEnv
        itemID = item.id
        expanded = newEnv.interaction.expandedText.contains(item.id)
        isCursor = newEnv.cursor == new.stepID
        isHover = newEnv.hovered == new.stepID
        glyph.set(shape: .circle, color: BrainCanvas.zone(.think))
        text.numberOfLines = expanded ? 0 : 1
        text.lineBreakMode = .byTruncatingTail
        text.attributedText = NSAttributedString(
            string: expanded ? new.text : new.firstLine,
            attributes: Theme.Ramp.attributes(.thought, color: Theme.Color.secondaryLabel))
        chip.configure(title: "#\(new.number)", bordered: false) { [weak self] in
            guard let self, let thought = self.thought else { return }
            self.env?.chooseStep(thought.stepID, false)
        }
        backgroundColor = isCursor ? Theme.Color.accent.wash(0.07) : (isHover ? Theme.Color.accent.wash(0.04) : .clear)
        accessibilityLabel = Localized.text("Thought, %@", new.firstLine)
        accessibilityTraits = isCursor ? [.button, .selected] : .button
        setNeedsLayout()
    }

    @objc private func tapped() {
        guard let thought, let env else { return }
        Theme.Haptics.selection()
        env.chooseStep(thought.stepID, false)
    }

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        guard let thought, let env else { return }
        switch gesture.state {
        case .began, .changed: env.hoverStep(thought.stepID)
        default: env.hoverStep(nil)
        }
    }

    private var canUnfold: Bool {
        guard let thought else { return false }
        if thought.canUnfold { return true }
        let room = bounds.width - 19 - 8 - 18 - 10 - 90
        return (thought.firstLine as NSString).size(withAttributes: [.font: Theme.Ramp.font(.thought)]).width > room
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard thought != nil else { return 24 }
        guard expanded else { return 28 }
        let room = width - 19 - 8 - 18 - 10 - 90
        return max(28, BrainText.height(text.attributedText, width: room) + 10)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let chipSize = chip.intrinsicContentSize
        let showsToggle = canUnfold
        toggle.isHidden = !showsToggle
        glyph.frame = CGRect(x: 19, y: expanded ? 5 : (bounds.height - 18) / 2, width: 18, height: 18)
        chip.frame = CGRect(x: bounds.width - 12 - chipSize.width, y: expanded ? 4 : (bounds.height - chipSize.height) / 2, width: chipSize.width, height: chipSize.height)
        var right = chip.frame.minX - 8
        if showsToggle {
            toggle.configure(
                title: expanded ? Localized.text("Hide") : Localized.text("Show"), bordered: false
            ) { [weak self] in
                guard let self else { return }
                self.env?.toggleText(self.itemID)
            }
            let size = toggle.intrinsicContentSize
            toggle.frame = CGRect(x: right - size.width, y: expanded ? 4 : (bounds.height - size.height) / 2, width: size.width, height: size.height)
            right = toggle.frame.minX - 8
        }
        let width = max(0, right - 44)
        let height = expanded ? BrainText.height(text.attributedText, width: width) : ceil(text.attributedText?.size().height ?? 18)
        text.frame = CGRect(x: 44, y: expanded ? 5 : (bounds.height - height) / 2, width: width, height: height)
    }
}
