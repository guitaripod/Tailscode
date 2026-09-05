import TailscodeCore
import UIKit

/// The mark Delegate wears while it is new, as a control: the capsule is the whole announcement
/// and a tap opens the why. Every word is `DelegateBeta`'s; this draws a capsule and forwards a tap.
@MainActor
final class DelegateBetaBadge: UIControl {
    private let label = UILabel()
    private let symbol = UIImageView(image: UIImage(systemName: "sparkles"))

    var onTap: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityLabel = DelegateBeta.spoken
        accessibilityTraits = .button
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        label.attributedText = NSAttributedString(
            string: DelegateBeta.badge,
            attributes: [.font: Self.font, .kern: 1.1])
        label.adjustsFontForContentSizeCategory = true
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        symbol.contentMode = .center
        let stack = UIStackView(arrangedSubviews: [symbol, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 3
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        addAction(UIAction { [weak self] _ in self?.tapped() }, for: .touchUpInside)
        paint()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (badge: DelegateBetaBadge, _) in badge.paint()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    /// The footnote weight of the ramp, set bold and rounded: a badge is read in one glance.
    private static var font: UIFont {
        let base = Theme.Ramp.font(.panelFootnote)
        var descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor
        descriptor = descriptor.withDesign(.rounded) ?? descriptor
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    private func paint() {
        let tint = Theme.Color.special
        backgroundColor = tint.withAlphaComponent(0.14)
        layer.borderColor = tint.withAlphaComponent(0.45).cgColor
        label.textColor = tint
        symbol.tintColor = tint
    }

    private func tapped() {
        Theme.Haptics.tap()
        onTap?()
    }
}

/// Why Delegate is in beta, as a sheet sized to its words. Every word is `DelegateBeta`'s.
@MainActor
final class DelegateBetaViewController: UIViewController {
    private let scroll = UIScrollView()
    private let column = UIStackView()

    static func present(from presenter: UIViewController) {
        let card = DelegateBetaViewController()
        card.loadViewIfNeeded()
        let width = presenter.view.bounds.width
        let bottom = presenter.view.safeAreaInsets.bottom
        if let sheet = card.sheetPresentationController {
            sheet.prefersGrabberVisible = true
            sheet.detents = [
                .custom(identifier: UISheetPresentationController.Detent.Identifier("delegate.beta")) { context in
                    min(context.maximumDetentValue, card.fittingHeight(width: width, bottomInset: bottom))
                },
                .large(),
            ]
        }
        presenter.present(card, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Theme.Spacing.m
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)

        let mark = DelegateBetaBadge()
        mark.isUserInteractionEnabled = false
        mark.isAccessibilityElement = false
        let title = UILabel()
        title.text = DelegateBeta.title
        title.font = Theme.Ramp.font(.panelTitle)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        let heading = UIStackView(arrangedSubviews: [mark, title])
        heading.axis = .vertical
        heading.alignment = .leading
        heading.spacing = Theme.Spacing.s
        column.addArrangedSubview(heading)
        for paragraph in DelegateBeta.paragraphs {
            let body = UILabel()
            body.text = paragraph
            body.font = Theme.Ramp.font(.cardBody)
            body.adjustsFontForContentSizeCategory = true
            body.textColor = Theme.Color.secondaryLabel
            body.numberOfLines = 0
            column.addArrangedSubview(body)
        }
        var config = UIButton.Configuration.filled()
        config.title = String(localized: "Got it")
        config.baseBackgroundColor = Theme.Color.special
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        let done = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        column.addArrangedSubview(done)
        column.setCustomSpacing(Theme.Spacing.l, after: column.arrangedSubviews[column.arrangedSubviews.count - 2])

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.xl),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.s),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    /// The height the words need at this width, so the sheet is exactly as tall as what it says.
    func fittingHeight(width: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let inner = max(width - 2 * Theme.Spacing.l, 200)
        let content = column.systemLayoutSizeFitting(
            CGSize(width: inner, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return ceil(content.height + Theme.Spacing.xl + Theme.Spacing.s + bottomInset)
    }
}
