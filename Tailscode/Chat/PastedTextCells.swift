import TailscodeCore
import UIKit

/// A long paste in a message the person sent, folded to a card on their side of the transcript:
/// what it is and how long, the first line that says anything, and a chevron that says a tap opens
/// the whole of it. It wears the prompt's own accent at a whisper, so it reads as part of what was
/// sent rather than something the agent wrote.
final class PastedTextCell: UICollectionViewCell {
    static let reuseID = "PastedTextCell"

    private let control = UIControl()
    private let glyph = UIImageView()
    private let title = UILabel()
    private let glimpse = UILabel()
    private let chevron = UIImageView()
    private var topConstraint: NSLayoutConstraint!
    private var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        control.backgroundColor = Theme.Color.userBubble.withAlphaComponent(0.14)
        control.layer.cornerRadius = Theme.Radius.bubble
        control.layer.cornerCurve = .continuous
        control.layer.borderWidth = 1
        control.layer.borderColor = Theme.Color.userBubble.withAlphaComponent(0.35).cgColor
        control.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        control.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(control)

        glyph.image = UIImage(
            systemName: "text.alignleft",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        glyph.tintColor = Theme.Color.accent
        glyph.contentMode = .center
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)

        title.font = Theme.Ramp.font(.panelDetail).withTraits(.traitBold)
        title.textColor = Theme.Color.label
        title.adjustsFontForContentSizeCategory = true
        title.setContentCompressionResistancePriority(.required, for: .horizontal)

        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        glimpse.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: 12, weight: .regular))
        glimpse.adjustsFontForContentSizeCategory = true
        glimpse.textColor = Theme.Color.secondaryLabel
        glimpse.lineBreakMode = .byTruncatingTail
        glimpse.numberOfLines = 1

        let head = UIStackView(arrangedSubviews: [glyph, title, UIView(), chevron])
        head.axis = .horizontal
        head.alignment = .center
        head.spacing = Theme.Spacing.s
        let column = UIStackView(arrangedSubviews: [head, glimpse])
        column.axis = .vertical
        column.spacing = 2
        column.isUserInteractionEnabled = false
        column.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(column)

        topConstraint = control.topAnchor.constraint(equalTo: contentView.topAnchor)
        NSLayoutConstraint.activate([
            topConstraint,
            control.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            control.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            control.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            control.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.82),
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            column.topAnchor.constraint(equalTo: control.topAnchor, constant: Theme.Spacing.s),
            column.bottomAnchor.constraint(equalTo: control.bottomAnchor, constant: -Theme.Spacing.s),
            column.leadingAnchor.constraint(equalTo: control.leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: control.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        let wide = control.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.82)
        wide.priority = .defaultLow
        wide.isActive = true

        isAccessibilityElement = false
        control.isAccessibilityElement = true
        control.accessibilityTraits = .button
        control.accessibilityHint = Localized.text("Opens the pasted text")
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (cell: PastedTextCell, _) in
            cell.control.layer.borderColor = Theme.Color.userBubble.withAlphaComponent(0.35).cgColor
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var gapAbove: CGFloat = 0 {
        didSet { topConstraint.constant = gapAbove }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
    }

    func configure(_ paste: FoldedPaste, onTap: @escaping () -> Void) {
        self.onTap = onTap
        title.text = paste.label
        glimpse.text = paste.glimpse
        glimpse.isHidden = paste.glimpse.isEmpty
        control.accessibilityLabel = paste.spoken
    }

    @objc private func tapped() {
        Theme.Haptics.tap()
        onTap?()
    }
}

extension PastedTextCell: RowGapCell {}

/// A paste read whole: its size and weight above it, the text monospaced and selectable, Copy, and
/// — for one still waiting in the composer — Edit as text, which puts it back in the box as words.
@MainActor
final class PastedTextViewController: UIViewController {
    private let paste: FoldedPaste
    private let onEdit: (() -> Void)?
    private let textView = UITextView()
    private let header = UILabel()

    init(paste: FoldedPaste, onEdit: (() -> Void)? = nil) {
        self.paste = paste
        self.onEdit = onEdit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func sheet(_ paste: FoldedPaste, onEdit: (() -> Void)? = nil) -> UINavigationController {
        let nav = UINavigationController(
            rootViewController: PastedTextViewController(paste: paste, onEdit: onEdit))
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        return nav
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        title = FoldedPaste.title
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        var items = [
            UIBarButtonItem(
                image: UIImage(systemName: "doc.on.doc"),
                primaryAction: UIAction { [weak self] _ in
                    UIPasteboard.general.string = self?.paste.text
                    Theme.Haptics.success()
                })
        ]
        items[0].accessibilityLabel = Localized.text("Copy")
        if onEdit != nil {
            let edit = UIBarButtonItem(
                title: Localized.text("Edit as text"),
                primaryAction: UIAction { [weak self] _ in
                    let edit = self?.onEdit
                    self?.dismiss(animated: true) { edit?() }
                })
            items.append(edit)
        }
        navigationItem.rightBarButtonItems = items
        build()
    }

    private func build() {
        header.text = paste.summary
        header.font = Theme.Ramp.font(.panelDetail)
        header.adjustsFontForContentSizeCategory = true
        header.textColor = Theme.Color.secondaryLabel
        header.numberOfLines = 0
        header.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.adjustsFontForContentSizeCategory = true
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        textView.textColor = Theme.Color.label
        textView.text = paste.text
        textView.textContainerInset = UIEdgeInsets(
            top: Theme.Spacing.m, left: Theme.Spacing.l, bottom: Theme.Spacing.xl,
            right: Theme.Spacing.l)
        textView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(textView)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: Theme.Spacing.m),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.Spacing.l),
            header.trailingAnchor.constraint(
                equalTo: guide.trailingAnchor, constant: -Theme.Spacing.l),
            textView.topAnchor.constraint(equalTo: header.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

/// A paste waiting beside the composer: the glyph, its label and the first line, a tap that opens
/// it, and an x that takes it away.
final class PasteChip: UIView {
    init(paste: FoldedPaste, onOpen: @escaping () -> Void, onRemove: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Theme.Color.secondaryBackground
        layer.cornerRadius = Theme.Radius.control
        layer.cornerCurve = .continuous

        let open = UIControl()
        open.translatesAutoresizingMaskIntoConstraints = false
        open.addAction(UIAction { _ in onOpen() }, for: .touchUpInside)
        open.isAccessibilityElement = true
        open.accessibilityTraits = .button
        open.accessibilityLabel = paste.spoken
        open.accessibilityHint = Localized.text("Opens the pasted text")

        let glyph = UIImageView(
            image: UIImage(
                systemName: "text.alignleft",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)))
        glyph.tintColor = Theme.Color.accent
        glyph.contentMode = .scaleAspectFit
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        let label = UILabel()
        label.font = Theme.Ramp.font(.panelFootnote).withTraits(.traitBold)
        label.textColor = Theme.Color.label
        label.text = paste.label
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let glimpse = UILabel()
        glimpse.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        glimpse.textColor = Theme.Color.secondaryLabel
        glimpse.text = paste.glimpse
        glimpse.lineBreakMode = .byTruncatingTail
        glimpse.isHidden = paste.glimpse.isEmpty
        glimpse.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [glyph, label, glimpse])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        open.addSubview(row)

        let remove = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        config.baseForegroundColor = Theme.Color.tertiaryLabel
        config.contentInsets = .zero
        remove.configuration = config
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.accessibilityLabel = Localized.text("Remove %@", FoldedPaste.title)
        remove.addAction(UIAction { _ in onRemove() }, for: .touchUpInside)

        addSubview(open)
        addSubview(remove)
        NSLayoutConstraint.activate([
            open.leadingAnchor.constraint(equalTo: leadingAnchor),
            open.topAnchor.constraint(equalTo: topAnchor),
            open.bottomAnchor.constraint(equalTo: bottomAnchor),
            open.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -Theme.Spacing.xs),
            row.leadingAnchor.constraint(equalTo: open.leadingAnchor, constant: Theme.Spacing.s),
            row.trailingAnchor.constraint(equalTo: open.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: open.centerYAnchor),
            glimpse.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.s),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 28),
            remove.heightAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
