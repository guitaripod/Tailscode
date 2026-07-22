import UIKit

/// One enhanced-prompt page inside the enhance bubble: an angle label and the
/// rewritten text, which scrolls when long. No card chrome — the bubble is the
/// surface and the collection view holding these pages carries zero padding.
@MainActor
final class EnhancedPromptCell: UICollectionViewCell {
    static let reuseID = "EnhancedPromptCell"

    private let icon = UIImageView()
    private let badge = UILabel()
    private let textView = UITextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The prompt text's scroll view, so the bubble's pull-to-dismiss can defer
    /// to inner scrolling until the text is at its top.
    var promptScrollView: UIScrollView { textView }

    private func build() {
        icon.image = UIImage(
            systemName: "sparkles",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        icon.tintColor = Theme.Color.accent
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false

        badge.font = .preferredFont(forTextStyle: .caption1)
        badge.adjustsFontForContentSizeCategory = true
        badge.textColor = Theme.Color.accent
        badge.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = false
        textView.backgroundColor = .clear
        textView.textColor = Theme.Color.label
        textView.font = Theme.Font.body()
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.showsHorizontalScrollIndicator = false
        textView.translatesAutoresizingMaskIntoConstraints = false

        [icon, badge, textView].forEach(contentView.addSubview)
        let h = Theme.Spacing.l
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: h),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            badge.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Spacing.xs),
            badge.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor, constant: -44),

            textView.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: Theme.Spacing.s),
            textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: h),
            textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -h),
            textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.s),
        ])
    }

    func configure(_ prompt: EnhancedPrompt) {
        badge.text = prompt.label.localizedUppercase
        textView.text = prompt.text
        textView.setContentOffset(.zero, animated: false)
        accessibilityLabel = "Enhanced prompt, \(prompt.label): \(prompt.text)"
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        textView.setContentOffset(.zero, animated: false)
    }
}

/// The shimmering placeholder page shown while the model is still generating.
@MainActor
final class EnhanceSkeletonCell: UICollectionViewCell {
    static let reuseID = "EnhanceSkeletonCell"

    private var bars: [ShimmerView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        isUserInteractionEnabled = false
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let widths: [CGFloat] = [0.4, 0.92, 0.86, 0.7, 0.5]
        for (index, fraction) in widths.enumerated() {
            let bar = ShimmerView()
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.layer.cornerRadius = index == 0 ? 6 : 5
            stack.addArrangedSubview(bar)
            NSLayoutConstraint.activate([
                bar.heightAnchor.constraint(equalToConstant: index == 0 ? 12 : 14),
                bar.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: fraction),
            ])
            bars.append(bar)
        }

        let h = Theme.Spacing.l
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.l),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: h),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -h),
        ])
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { bars.forEach { $0.startAnimating() } }
    }
}

/// A centered message page for the unavailable / needs-more / failed states.
@MainActor
final class EnhanceMessageCell: UICollectionViewCell {
    static let reuseID = "EnhanceMessageCell"

    var onRetry: (() -> Void)?

    private let icon = UIImageView()
    private let message = UILabel()
    private let retry = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        icon.tintColor = Theme.Color.secondaryLabel
        icon.contentMode = .scaleAspectFit
        message.font = Theme.Font.subheadline()
        message.adjustsFontForContentSizeCategory = true
        message.textColor = Theme.Color.secondaryLabel
        message.textAlignment = .center
        message.numberOfLines = 0

        var retryConfig = Theme.Glass.buttonConfiguration()
        retryConfig.cornerStyle = .capsule
        retryConfig.title = "Try again"
        retry.configuration = retryConfig
        retry.isHidden = true
        retry.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, message, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Theme.Spacing.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            icon.heightAnchor.constraint(equalToConstant: 30),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.xl),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.xl),
        ])
    }

    func configure(symbol: String, text: String, showsRetry: Bool) {
        icon.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        message.text = text
        retry.isHidden = !showsRetry
        accessibilityLabel = text
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onRetry = nil
    }
}

/// A lightweight left-to-right shimmer, static under Reduce Motion.
@MainActor
final class ShimmerView: UIView {
    private let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.reasoningBackground
        clipsToBounds = true
        gradient.colors = [
            UIColor.clear.cgColor,
            UIColor.label.withAlphaComponent(0.10).cgColor,
            UIColor.clear.cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0, 0.25, 0.5]
        layer.addSublayer(gradient)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func startAnimating() {
        guard !UIAccessibility.isReduceMotionEnabled,
            gradient.animation(forKey: "shimmer") == nil
        else { return }
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.5, -0.25, 0]
        animation.toValue = [1.0, 1.25, 1.5]
        animation.duration = 1.25
        animation.repeatCount = .infinity
        gradient.add(animation, forKey: "shimmer")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        startAnimating()
    }
}
