import TailscodeCore
import UIKit

/// The five bars of a level, drawn the way the pill's meter draws them: the first `lit` in the
/// model's hue, the rest in a quiet ink.
@MainActor
final class PartyBarsView: UIView {
    private static let heights: [CGFloat] = [5, 7, 9, 11, 13]
    private static let width: CGFloat = 3
    private static let gap: CGFloat = 2

    var lit = 0 {
        didSet { setNeedsDisplay() }
    }

    var hue: UIColor? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isOpaque = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: PartyBarsView, _) in view.setNeedsDisplay()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let count = CGFloat(Self.heights.count)
        return CGSize(
            width: count * Self.width + (count - 1) * Self.gap, height: Self.heights.last ?? 13)
    }

    override func draw(_ rect: CGRect) {
        let traits = traitCollection
        let unlit = UIColor.label.withAlphaComponent(0.17).resolvedColor(with: traits)
        let on = (hue ?? Theme.Color.tertiaryLabel).resolvedColor(with: traits)
        for (index, height) in Self.heights.enumerated() {
            let bar = CGRect(
                x: CGFloat(index) * (Self.width + Self.gap), y: bounds.maxY - height,
                width: Self.width, height: height)
            (index < lit ? on : unlit).setFill()
            UIBezierPath(roundedRect: bar, cornerRadius: Self.width / 2).fill()
        }
    }
}

/// A small capsule on a quiet fill: the machine a slot lives on, or a recent model to take.
@MainActor
final class PartyPillView: UIControl {
    private let dot = UIImageView()
    private let label = UILabel()

    init(font: UIFont, insets: UIEdgeInsets) {
        super.init(frame: .zero)
        backgroundColor = Theme.Color.tertiaryLabel.withAlphaComponent(0.2)
        label.font = font
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.label
        label.numberOfLines = 0
        label.isUserInteractionEnabled = false
        dot.isHidden = true
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.isUserInteractionEnabled = false
        let row = UIStackView(arrangedSubviews: [dot, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
        ])
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    var dotColor: UIColor? {
        didSet {
            dot.isHidden = dotColor == nil
            dot.image = dotColor.map { EffortMeterView.dotImage($0) }
        }
    }

    /// The pill of the server the surface is aimed at wears a wash of the accent; the others a
    /// quiet grey, which is what tells a take that stays from one that moves the work.
    var isHere = false {
        didSet { paintFill() }
    }

    private func paintFill() {
        backgroundColor =
            isHere
            ? Theme.Color.accent.withAlphaComponent(0.2)
            : Theme.Color.tertiaryLabel.withAlphaComponent(0.2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.height / 2, 18)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}

/// A model used lately that no slot holds: its dot, its name and the server that runs it, and a
/// plus that puts it in the party. A tap on the row takes it, a drag lifts it onto a slot.
///
/// Like a card, the row is the one thing a touch lands on; only the plus is a control of its own.
@MainActor
final class PartyRecentRow: UIControl {
    let recent: PartyRecent
    private let words = UIStackView()
    private let plus = SlopButton(type: .custom)

    init(recent: PartyRecent, take: @escaping () -> Void, add: @escaping () -> Void) {
        self.recent = recent
        super.init(frame: .zero)
        let dot = UIImageView(
            image: EffortMeterView.dotImage(
                recent.chip.map { Theme.Color.modelIdentity($0) } ?? Theme.Color.tertiaryLabel))
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.isUserInteractionEnabled = false
        let name = UILabel()
        name.text = recent.word
        name.font = PartyCardView.font(17, .regular)
        name.adjustsFontForContentSizeCategory = true
        name.textColor = Theme.Color.label
        name.numberOfLines = 0
        name.isUserInteractionEnabled = false
        let place = UILabel()
        place.text = Self.place(of: recent)
        place.font = PartyCardView.font(12.5, .regular)
        place.adjustsFontForContentSizeCategory = true
        place.textColor = recent.serverAnswers == false ? Theme.Color.danger : Theme.Color.secondaryLabel
        place.numberOfLines = 0
        place.isUserInteractionEnabled = false
        words.axis = .vertical
        words.spacing = 1
        words.isUserInteractionEnabled = false
        [name, place].forEach(words.addArrangedSubview)

        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "plus.circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
        config.baseForegroundColor = Theme.Color.accent
        plus.configuration = config
        plus.accessibilityLabel = String(localized: "Add to party")
        plus.setContentHuggingPriority(.required, for: .horizontal)
        plus.addAction(UIAction { _ in add() }, for: .touchUpInside)
        plus.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [dot, words, plus])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.m
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        let rule = UIView()
        rule.backgroundColor = Theme.Color.separator
        rule.isUserInteractionEnabled = false
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(rule)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            plus.widthAnchor.constraint(equalToConstant: 44),
            plus.heightAnchor.constraint(equalToConstant: 44),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 10),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        isAccessibilityElement = true
        accessibilityLabel = Self.spoken(recent)
        accessibilityTraits = .button
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Add to party")) { _ in
                add()
                return true
            }
        ]
        addAction(UIAction { _ in take() }, for: .touchUpInside)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func place(of recent: PartyRecent) -> String {
        recent.serverAnswers == false
            ? String(localized: "on \(recent.server) · not answering")
            : String(localized: "on \(recent.server)")
    }

    private static func spoken(_ recent: PartyRecent) -> String {
        recent.word + ", " + place(of: recent)
    }

    /// The name and the server, lifted off the row for a drag.
    var dragPreview: UIDragPreview { UIDragPreview(view: words) }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === plus ? hit : self
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}

/// The lift a pointer gives a card or a row it rests on, on an iPad with a trackpad or a mouse.
@MainActor
final class PartyPointer: NSObject, UIPointerInteractionDelegate {
    func pointerInteraction(
        _ interaction: UIPointerInteraction, styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        guard let view = interaction.view else { return nil }
        let target = (view as? PartyCardView)?.previewTarget ?? UITargetedPreview(view: view)
        return UIPointerStyle(effect: .lift(target))
    }
}
