import TailscodeCore
import UIKit

@MainActor
final class BrainChangeRow: UIControl {
    private let path = UILabel()
    private let bar = BrainChangeBar()
    private let tally = UILabel()
    private let numbers = UILabel()

    init(change: NeuralAccount.Change, maxChange: Int, action: @escaping () -> Void) {
        super.init(frame: .zero)
        let text = NSMutableAttributedString(
            string: change.shortDirectory,
            attributes: Theme.Ramp.attributes(.toolDetail, color: Theme.Color.secondaryLabel))
        text.append(
            NSAttributedString(
                string: change.fileName, attributes: Theme.Ramp.attributes(.toolName, color: Theme.Color.label)))
        path.attributedText = text
        path.lineBreakMode = .byTruncatingMiddle
        bar.set(added: change.added, removed: change.removed, maxChange: maxChange)
        let tallyText = NSMutableAttributedString(
            string: "+\(change.added)", attributes: Theme.Ramp.attributes(.rowMeta, color: Theme.Color.accent))
        tallyText.append(
            NSAttributedString(
                string: " \u{2212}\(change.removed)", attributes: Theme.Ramp.attributes(.rowMeta, color: Theme.Color.danger)))
        tally.attributedText = tallyText
        numbers.attributedText = NSAttributedString(
            string: change.numbers.map { "#\($0)" }.joined(separator: ", "),
            attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel, alignment: .right))
        numbers.lineBreakMode = .byTruncatingHead
        for view in [path, bar, tally, numbers] { addSubview(view) }
        addAction(UIAction { _ in action() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = Localized.text("%1$@, %2$@", change.fileName, change.tally ?? "")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: 28) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let numberSize = numbers.attributedText?.size() ?? .zero
        let numberWidth = min(ceil(numberSize.width) + 1, bounds.width * 0.22)
        numbers.frame = CGRect(x: bounds.width - numberWidth, y: (bounds.height - numberSize.height) / 2, width: numberWidth, height: ceil(numberSize.height))
        let tallySize = tally.attributedText?.size() ?? .zero
        tally.frame = CGRect(x: numbers.frame.minX - 8 - ceil(tallySize.width) - 1, y: (bounds.height - tallySize.height) / 2, width: ceil(tallySize.width) + 1, height: ceil(tallySize.height))
        bar.frame = CGRect(x: tally.frame.minX - 8 - 64, y: (bounds.height - 6) / 2, width: 64, height: 6)
        let pathSize = path.attributedText?.size() ?? .zero
        path.frame = CGRect(x: 0, y: (bounds.height - pathSize.height) / 2, width: max(0, bar.frame.minX - 10), height: ceil(pathSize.height))
    }
}

/// A file's lines added and removed as a short bar: accent for what was added, danger for what
/// went, scaled to the busiest file.
@MainActor
final class BrainChangeBar: UIView {
    private let added = UIView()
    private let removed = UIView()
    private var share = (added: CGFloat(0), removed: CGFloat(0))

    override init(frame: CGRect) {
        super.init(frame: frame)
        added.backgroundColor = Theme.Color.accent
        removed.backgroundColor = Theme.Color.danger
        layer.cornerRadius = 3
        layer.masksToBounds = true
        backgroundColor = Theme.Color.separator
        addSubview(added)
        addSubview(removed)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(added a: Int, removed r: Int, maxChange: Int) {
        let total = CGFloat(max(1, maxChange))
        share = (CGFloat(a) / total, CGFloat(r) / total)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        added.frame = CGRect(x: 0, y: 0, width: bounds.width * share.added, height: bounds.height)
        removed.frame = CGRect(x: added.frame.maxX, y: 0, width: bounds.width * share.removed, height: bounds.height)
    }
}

@MainActor
final class BrainCheckRow: UIControl {
    private let icon = UIImageView()
    private let name = UILabel()
    private let command = UILabel()
    private let verdict = UILabel()
    private let numbers = UILabel()

    init(check: NeuralAccount.Check, action: @escaping () -> Void) {
        super.init(frame: .zero)
        let tone: UIColor
        let symbol: String
        switch check.verdict {
        case .fixed: (tone, symbol) = (Theme.Color.warning, "arrow.trianglehead.2.clockwise.rotate.90")
        case .failed, .tryingAgain: (tone, symbol) = (Theme.Color.danger, "xmark")
        case .running: (tone, symbol) = (Theme.Color.accent, "circle.dotted")
        default: (tone, symbol) = (Theme.Color.accent, "checkmark")
        }
        icon.image = BrainCanvas.image(symbol, size: 11, weight: .bold)?
            .withTintColor(tone.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
        icon.contentMode = .center
        name.attributedText = NSAttributedString(
            string: check.label, attributes: Theme.Ramp.attributes(.rowTitleStrong, color: Theme.Color.label))
        command.attributedText = NSAttributedString(
            string: check.command, attributes: Theme.Ramp.attributes(.rowDetail, color: Theme.Color.secondaryLabel))
        command.lineBreakMode = .byTruncatingTail
        verdict.attributedText = NSAttributedString(
            string: check.verdictWords, attributes: Theme.Ramp.attributes(.rowMeta, color: tone))
        numbers.attributedText = NSAttributedString(
            string: check.numbers.map { "#\($0)" }.joined(separator: ", "),
            attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel, alignment: .right))
        numbers.lineBreakMode = .byTruncatingHead
        for view in [icon, name, command, verdict, numbers] { addSubview(view) }
        addAction(UIAction { _ in action() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = Localized.text("%1$@, %2$@", check.label, check.verdictWords)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: 28) }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 0, y: 0, width: 18, height: bounds.height)
        let nameSize = name.attributedText?.size() ?? .zero
        name.frame = CGRect(x: 24, y: (bounds.height - nameSize.height) / 2, width: ceil(nameSize.width) + 1, height: ceil(nameSize.height))
        let numberSize = numbers.attributedText?.size() ?? .zero
        let numberWidth = min(ceil(numberSize.width) + 1, bounds.width * 0.2)
        numbers.frame = CGRect(x: bounds.width - numberWidth, y: (bounds.height - numberSize.height) / 2, width: numberWidth, height: ceil(numberSize.height))
        let verdictSize = verdict.attributedText?.size() ?? .zero
        verdict.frame = CGRect(x: numbers.frame.minX - 8 - ceil(verdictSize.width) - 1, y: (bounds.height - verdictSize.height) / 2, width: ceil(verdictSize.width) + 1, height: ceil(verdictSize.height))
        let commandSize = command.attributedText?.size() ?? .zero
        let x = name.frame.maxX + 10
        command.frame = CGRect(x: x, y: (bounds.height - commandSize.height) / 2, width: max(0, verdict.frame.minX - 8 - x), height: ceil(commandSize.height))
    }
}

@MainActor
final class BrainUnfixedRow: UIControl {
    private let line = UILabel()

    init(item: NeuralAccount.Unfixed, action: @escaping () -> Void) {
        super.init(frame: .zero)
        let text = NSMutableAttributedString(
            string: "#\(item.number) ", attributes: Theme.Ramp.attributes(.rowMeta, color: Theme.Color.danger))
        text.append(
            NSAttributedString(
                string: item.title + "  ", attributes: Theme.Ramp.attributes(.rowTitleStrong, color: Theme.Color.label)))
        text.append(
            NSAttributedString(
                string: item.firstLine, attributes: Theme.Ramp.attributes(.rowDetail, color: Theme.Color.secondaryLabel)))
        line.attributedText = text
        line.numberOfLines = 2
        addSubview(line)
        addAction(UIAction { _ in action() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = Localized.text("%1$@, %2$@", item.title, item.firstLine)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: max(28, BrainText.height(line.attributedText, width: size.width, lines: 2)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = bounds
    }
}
