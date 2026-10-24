import TailscodeCore
import UIKit

/// Chips that wrap onto as many lines as they need: the files an agent has touched, set so a long
/// name never gets cut and a long list never runs off the edge.
@MainActor
final class AgentsFlowView: UIView {
    private var chips: [UIView] = []
    private var measuredHeight: CGFloat = 0
    private var measuredWidth: CGFloat = 0

    func setChips(_ names: [String]) {
        chips.forEach { $0.removeFromSuperview() }
        chips = names.map(Self.chip)
        chips.forEach(addSubview)
        measuredWidth = 0
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        let gap = Theme.Spacing.s
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var lineHeight: CGFloat = 0
        for chip in chips {
            var size = chip.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .fittingSizeLevel,
                verticalFittingPriority: .fittingSizeLevel)
            if size.width > width {
                size = chip.systemLayoutSizeFitting(
                    CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel)
            }
            if cursorX > 0, cursorX + size.width > width {
                cursorX = 0
                cursorY += lineHeight + gap
                lineHeight = 0
            }
            chip.frame = CGRect(origin: CGPoint(x: leadingX(cursorX, size.width, width), y: cursorY), size: size)
            cursorX += size.width + gap
            lineHeight = max(lineHeight, size.height)
        }
        let height = chips.isEmpty ? 0 : cursorY + lineHeight
        if abs(height - measuredHeight) > 0.5 || width != measuredWidth {
            measuredHeight = height
            measuredWidth = width
            invalidateIntrinsicContentSize()
        }
    }

    private func leadingX(_ x: CGFloat, _ itemWidth: CGFloat, _ width: CGFloat) -> CGFloat {
        UIView.userInterfaceLayoutDirection(for: semanticContentAttribute) == .rightToLeft
            ? width - x - itemWidth : x
    }

    private static func chip(_ name: String) -> UIView {
        let label = UILabel()
        label.font = Theme.Ramp.font(.code).withSize(Theme.Ramp.font(.panelFootnote).pointSize)
        label.textColor = Theme.Color.label
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.adjustsFontForContentSizeCategory = true
        label.text = name
        label.translatesAutoresizingMaskIntoConstraints = false
        let box = UIView()
        box.backgroundColor = Theme.Color.groupedSurface
        box.layer.cornerRadius = 8
        box.layer.cornerCurve = .continuous
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -5),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Theme.Spacing.m),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        box.isAccessibilityElement = true
        box.accessibilityLabel = name
        return box
    }
}

/// One of the three figures under a peek: a value in large type with the word for what it is.
@MainActor
final class AgentsMeterTile: UIView {
    init(value: String, caption: String, ring: (fraction: Double, tint: UIColor)? = nil, spoken: String) {
        super.init(frame: .zero)
        backgroundColor = Theme.Color.groupedSurface
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous

        let valueLabel = UILabel()
        valueLabel.font = Theme.Ramp.font(.metricLarge)
        valueLabel.textColor = Theme.Color.label
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.7
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.text = value

        let captionLabel = UILabel()
        captionLabel.font = Theme.Ramp.font(.panelFootnote)
        captionLabel.textColor = Theme.Color.secondaryLabel
        captionLabel.numberOfLines = 0
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.text = caption

        let texts = UIStackView(arrangedSubviews: [valueLabel, captionLabel])
        texts.axis = .vertical
        texts.spacing = 2
        let column = UIStackView()
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = Theme.Spacing.s
        if let ring {
            let mini = MiniRingView()
            mini.fraction = ring.fraction
            mini.tint = ring.tint
            mini.translatesAutoresizingMaskIntoConstraints = false
            mini.widthAnchor.constraint(equalToConstant: 28).isActive = true
            mini.heightAnchor.constraint(equalToConstant: 28).isActive = true
            column.addArrangedSubview(mini)
        }
        column.addArrangedSubview(texts)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.m),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
        ])
        isAccessibilityElement = true
        accessibilityLabel = spoken
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// One step an agent took, in words, with when this device first saw it. The age is a sighting,
/// never a duration: a tool call carries no time of its own.
@MainActor
final class AgentsStepRow: UIView {
    private let badge = ActivityBadgeView(pointSize: 14)
    private let wordsLabel = UILabel()
    private let seenLabel = UILabel()
    private let step: AgentStep

    init(_ step: AgentStep, isNewest: Bool) {
        self.step = step
        super.init(frame: .zero)
        let box = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(badge)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 22),
            badge.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            badge.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
        ])
        badge.show(AgentGlyph.icon(for: step.outcome), spoken: nil)

        wordsLabel.font = Theme.Ramp.font(.rowDetail)
        wordsLabel.textColor = isNewest ? Theme.Color.label : Theme.Color.secondaryLabel
        wordsLabel.numberOfLines = 0
        wordsLabel.adjustsFontForContentSizeCategory = true
        wordsLabel.text = step.words

        seenLabel.font = Theme.Ramp.font(.rowStamp)
        seenLabel.textColor = Theme.Color.tertiaryLabel
        seenLabel.adjustsFontForContentSizeCategory = true
        seenLabel.setContentHuggingPriority(.required, for: .horizontal)
        seenLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [box, wordsLabel, seenLabel])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Theme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
        tick(now: Date())
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func tick(now: Date) {
        var said = [step.words, AgentGlyph.spoken(for: step.outcome)]
        if let seen = step.seen {
            seenLabel.text = AgentsWords.ago(seen, now: now)
            said.append(String(localized: "first seen \(AgentsWords.spokenAge(seen, now: now)) ago"))
        } else {
            seenLabel.text = nil
        }
        accessibilityLabel = said.joined(separator: ", ")
    }
}

@MainActor
enum AgentsPeekStyle {
    static func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        let font = Theme.Ramp.font(.sectionLabel)
        label.attributedText = NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: font, .foregroundColor: Theme.Color.secondaryLabel,
                .kern: Typography.spec(.sectionLabel).tracking * font.pointSize,
            ])
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityTraits = .header
        return label
    }

    static func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = Theme.Ramp.font(.panelFootnote)
        label.textColor = Theme.Color.tertiaryLabel
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.text = text
        return label
    }

    static func section(_ title: String, _ body: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [sectionLabel(title)] + body)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        return stack
    }

    static func button(_ title: String, symbol: String? = nil, prominent: Bool = false) -> UIButton {
        var configuration = prominent ? UIButton.Configuration.filled() : .gray()
        configuration.title = title
        configuration.cornerStyle = .large
        if prominent {
            configuration.baseBackgroundColor = Theme.Color.accent
            configuration.baseForegroundColor = Theme.Color.onAccent
        } else {
            configuration.baseForegroundColor = Theme.Color.label
        }
        if let symbol {
            configuration.image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
            configuration.imagePadding = Theme.Spacing.s
        }
        configuration.titleLineBreakMode = .byWordWrapping
        configuration.titleTextAttributesTransformer = controlText
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 14, leading: Theme.Spacing.m, bottom: 14, trailing: Theme.Spacing.m)
        let button = UIButton(configuration: configuration)
        button.titleLabel?.numberOfLines = 0
        return button
    }

    static let controlText = UIConfigurationTextAttributesTransformer {
        var attributes = $0
        attributes.font = Theme.Ramp.font(.control)
        return attributes
    }
}
