import TailscodeCore
import UIKit

/// What a node says when it is pointed at: the tool and how it ended, the command or the words,
/// what it wrote, the first lines it printed, and where it sits in the turn and what it shares
/// with another step. The words are `NeuralReading.Card`'s, written once for every client; this
/// only sets them in the app's type.
@MainActor
final class BrainCardView: UIView {
    private let icon = BrainShapeIcon()
    private let titleLabel = UILabel()
    private let statusLabel = PaddedLabel()
    private let bodyLabel = UILabel()
    private let tallyLabel = UILabel()
    private let outputLabel = UILabel()
    private let outputBar = UIView()
    private let outputRow = UIView()
    private let footerLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.background
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 5)
        isHidden = true
        isUserInteractionEnabled = false

        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.layer.cornerRadius = 9
        statusLabel.layer.masksToBounds = true
        statusLabel.layer.borderWidth = 1
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [icon, titleLabel, UIView(), statusLabel])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Spacing.s

        bodyLabel.numberOfLines = 4
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.adjustsFontForContentSizeCategory = true
        tallyLabel.adjustsFontForContentSizeCategory = true
        outputLabel.numberOfLines = 4
        outputLabel.lineBreakMode = .byTruncatingTail
        outputLabel.adjustsFontForContentSizeCategory = true
        outputLabel.translatesAutoresizingMaskIntoConstraints = false
        outputBar.translatesAutoresizingMaskIntoConstraints = false
        outputRow.addSubview(outputBar)
        outputRow.addSubview(outputLabel)
        NSLayoutConstraint.activate([
            outputBar.leadingAnchor.constraint(equalTo: outputRow.leadingAnchor),
            outputBar.topAnchor.constraint(equalTo: outputRow.topAnchor),
            outputBar.bottomAnchor.constraint(equalTo: outputRow.bottomAnchor),
            outputBar.widthAnchor.constraint(equalToConstant: 2),
            outputLabel.leadingAnchor.constraint(equalTo: outputBar.trailingAnchor, constant: 8),
            outputLabel.trailingAnchor.constraint(equalTo: outputRow.trailingAnchor),
            outputLabel.topAnchor.constraint(equalTo: outputRow.topAnchor),
            outputLabel.bottomAnchor.constraint(equalTo: outputRow.bottomAnchor),
        ])
        footerLabel.numberOfLines = 0
        footerLabel.adjustsFontForContentSizeCategory = true

        stack.axis = .vertical
        stack.spacing = Theme.Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        [header, bodyLabel, tallyLabel, outputRow, footerLabel].forEach(stack.addArrangedSubview)
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.m),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor
    }

    /// Sets the card to a node's words and returns nothing: the stage sizes and places it.
    func show(_ card: NeuralReading.Card, ink: BrainInk) {
        let tone = ink.color(for: NeuralNodes.tone(of: card.status), zone: card.zone)
        let zoneInk = Theme.Color.label.resolvedColor(with: traitCollection)
        icon.set(shape: card.zone.shape, color: tone)
        titleLabel.attributedText = NSAttributedString(
            string: card.title, attributes: Theme.Ramp.attributes(.cardTitle))
        let statusInk = statusColor(card.status)
        statusLabel.attributedText = NSAttributedString(
            string: card.statusWord.uppercased(),
            attributes: Theme.Ramp.attributes(.badge, color: statusInk))
        statusLabel.layer.borderColor = statusInk.cgColor

        let thought = card.zone == .think || card.zone == .say
        if card.body.isEmpty {
            bodyLabel.isHidden = true
        } else {
            bodyLabel.isHidden = false
            bodyLabel.attributedText = NSAttributedString(
                string: card.body,
                attributes: Theme.Ramp.attributes(
                    thought ? .thought : .toolDetail,
                    color: thought ? zoneInk : ink.zone(card.zone).darkenedForText(traitCollection)))
        }
        if let tally = card.tally {
            tallyLabel.isHidden = false
            tallyLabel.attributedText = Self.tally(tally)
        } else {
            tallyLabel.isHidden = true
        }
        if card.output.isEmpty {
            outputRow.isHidden = true
        } else {
            outputRow.isHidden = false
            let bad = card.status == .failed
            let color = bad ? Theme.Color.danger : Theme.Color.secondaryLabel
            outputBar.backgroundColor = bad ? Theme.Color.danger : Theme.Color.separator
            outputLabel.attributedText = NSAttributedString(
                string: card.output.joined(separator: "\n"),
                attributes: Theme.Ramp.attributes(.toolOutput, color: color))
        }
        footerLabel.attributedText = NSAttributedString(
            string: card.footer,
            attributes: Theme.Ramp.attributes(.rowNote, color: Theme.Color.tertiaryLabel))
        accessibilityLabel = [card.title, card.statusWord, card.body, card.footer]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func statusColor(_ status: NeuralStatus) -> UIColor {
        let color: UIColor
        switch status {
        case .ok: color = Theme.Color.success
        case .running: color = Theme.Color.info
        case .failed: color = Theme.Color.danger
        case .stopped: color = Theme.Color.tertiaryLabel
        case .waitingApproval, .waitingAnswer, .stalled: color = Theme.Color.warning
        }
        return color.resolvedColor(with: traitCollection)
    }

    private static func tally(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for word in text.split(separator: " ") {
            let added = word.hasPrefix("+")
            out.append(
                NSAttributedString(
                    string: String(word) + " ",
                    attributes: Theme.Ramp.attributes(
                        .responseStat,
                        color: added ? Theme.Color.success : Theme.Color.danger)))
        }
        return out
    }

    /// Where the card goes in a stage of this size when it points at `anchor`: under the node
    /// when there is room, over it when there is not, never past the stage's edges.
    func place(pointingAt anchor: CGPoint, in bounds: CGRect, nodeRadius: CGFloat) {
        let width = min(310, bounds.width - 12)
        let fitted = systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = min(fitted.height, bounds.height - 12)
        var x = anchor.x - width / 2
        x = min(max(x, bounds.minX + 6), bounds.maxX - width - 6)
        let below = anchor.y + nodeRadius + 8
        var y = below
        if below + height > bounds.maxY - 6 { y = anchor.y - nodeRadius - 8 - height }
        y = min(max(y, bounds.minY + 6), bounds.maxY - height - 6)
        frame = CGRect(x: x, y: y, width: width, height: height)
    }
}

/// A node's shape at icon size, for the head of a card and the rows of a zone list.
@MainActor
final class BrainShapeIcon: UIView {
    private let shape = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        shape.lineWidth = 1.6
        shape.lineJoin = .round
        layer.addSublayer(shape)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var zoneShape = NeuralShape.circle

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = min(bounds.width, bounds.height) / 2 - 2
        shape.path = BrainShapes.path(zoneShape, radius: radius * 0.85)
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func set(shape new: NeuralShape, color: UIColor) {
        zoneShape = new
        shape.strokeColor = color.cgColor
        shape.fillColor = BrainInk.domeColor.mixed(with: color, 0.25).cgColor
        setNeedsLayout()
    }
}

extension UIColor {
    /// A glow colour set as words on the page: a light theme lifts its glow toward white for the
    /// dark dome, and ink on a pale card needs the colour taken back toward the card's own text.
    func darkenedForText(_ traits: UITraitCollection) -> UIColor {
        guard traits.palette?.isDark == false || traits.userInterfaceStyle == .light else {
            return self
        }
        return mixed(with: Theme.Color.label.resolvedColor(with: traits), 0.45)
    }
}
