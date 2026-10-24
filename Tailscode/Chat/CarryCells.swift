import TailscodeCore
import UIKit

/// The words a carried conversation keeps for the person: what they typed, without the brief that
/// rode behind it.
enum CarriedText {
    static func typed(_ text: String) -> String {
        CarryMark.split(text)?.rest ?? text
    }
}

/// The one flat line where the answering model changed: the new model's dot and word, and the old
/// one after it. It holds perfectly still, wraps rather than truncates, and is never a card.
final class ModelSeamCell: UICollectionViewCell {
    static let reuseID = "ModelSeamCell"

    private static let dotSize: CGFloat = 8

    private let dot = UIView()
    private let label = UILabel()
    private var topConstraint: NSLayoutConstraint!
    private var dotCenter: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        dot.layer.cornerRadius = Self.dotSize / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dot)
        contentView.addSubview(label)
        topConstraint = label.topAnchor.constraint(equalTo: contentView.topAnchor)
        dotCenter = dot.centerYAnchor.constraint(equalTo: label.topAnchor)
        NSLayoutConstraint.activate([
            topConstraint,
            dotCenter,
            dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSize),
            dot.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            label.leadingAnchor.constraint(
                equalTo: dot.trailingAnchor, constant: Theme.Spacing.s),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var gapAbove: CGFloat = 0 {
        didSet { topConstraint.constant = gapAbove }
    }

    func configure(_ seam: ModelSwitch, chip: ModelChip?) {
        dot.backgroundColor = chip.map { Theme.Color.modelIdentity($0) } ?? Theme.Color.tertiaryLabel
        let line = NSMutableAttributedString(
            string: seam.to,
            attributes: Theme.Ramp.attributes(.rowTitleStrong, color: Theme.Color.label))
        line.append(
            NSAttributedString(
                string: " " + seam.fromText,
                attributes: Theme.Ramp.attributes(.panelDetail, color: Theme.Color.secondaryLabel)))
        label.attributedText = line
        dotCenter.constant = Theme.Ramp.font(.rowTitleStrong).lineHeight / 2
        accessibilityLabel = Localized.text("Model changed to %@ from %@", seam.to, seam.from)
    }
}

/// The first row of a carried chat: where the conversation came from, as one tappable line that
/// opens the brief it rode in on. The bubble under it shows only what the person typed.
final class CarriedLineCell: UICollectionViewCell {
    static let reuseID = "CarriedLineCell"

    private let control = UIControl()
    private let glyph = UIImageView()
    private let label = UILabel()
    private let chevron = UIImageView()
    private var topConstraint: NSLayoutConstraint!
    private var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        glyph.image = UIImage(
            systemName: "arrow.turn.up.left",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        glyph.tintColor = Theme.Color.tertiaryLabel
        glyph.contentMode = .center
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [glyph, label, chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(row)
        control.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        control.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(control)

        topConstraint = control.topAnchor.constraint(equalTo: contentView.topAnchor)
        NSLayoutConstraint.activate([
            topConstraint,
            control.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            control.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            control.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            row.topAnchor.constraint(equalTo: control.topAnchor, constant: Theme.Spacing.xs),
            row.bottomAnchor.constraint(equalTo: control.bottomAnchor, constant: -Theme.Spacing.xs),
            row.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: control.trailingAnchor),
        ])
        isAccessibilityElement = false
        control.isAccessibilityElement = true
        control.accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var gapAbove: CGFloat = 0 {
        didSet { topConstraint.constant = gapAbove }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
    }

    func configure(_ reading: CarryReading, onTap: @escaping () -> Void) {
        self.onTap = onTap
        let line = reading.line
        let text = NSMutableAttributedString(
            string: line,
            attributes: Theme.Ramp.attributes(.panelDetail, color: Theme.Color.secondaryLabel))
        if let range = line.range(of: reading.source) {
            text.addAttributes(
                [
                    .font: Theme.Ramp.font(.panelDetail).withTraits(.traitBold),
                    .foregroundColor: Theme.Color.label,
                ], range: NSRange(range, in: line))
        }
        label.attributedText = text
        control.accessibilityLabel = line
    }

    @objc private func tapped() {
        Theme.Haptics.tap()
        onTap?()
    }
}

/// The brief a carried chat began with, as text. It is machine-facing prose the model read and the
/// person never wrote, so it opens on demand in the same reader a compaction summary does.
@MainActor
final class CarrySummaryViewController: UIViewController {
    private let reading: CarryReading
    private let textView = UITextView()
    private let header = UILabel()

    init(reading: CarryReading) {
        self.reading = reading
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        title = Localized.text("Carried conversation")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            primaryAction: UIAction { [weak self] _ in
                UIPasteboard.general.string = self?.reading.brief
                Theme.Haptics.success()
            })
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        build()
    }

    private func build() {
        header.text = reading.summary
        header.font = Theme.Ramp.font(.panelDetail)
        header.adjustsFontForContentSizeCategory = true
        header.textColor = Theme.Color.secondaryLabel
        header.numberOfLines = 0
        header.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(
            top: Theme.Spacing.m, left: Theme.Spacing.l, bottom: Theme.Spacing.xl,
            right: Theme.Spacing.l)
        textView.attributedText = NSAttributedString(
            string: reading.brief,
            attributes: Theme.Ramp.attributes(.answer, color: Theme.Color.label))
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
