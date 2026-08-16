import TailscodeCore
import UIKit

/// The mark a feature wears while it is still being proven. Small, quiet and never a warning: it
/// is an invitation with its own footing stated, and something wearing it must still work.
@MainActor
final class AlphaBadge: UILabel {
    init() {
        super.init(frame: .zero)
        text = String(localized: "ALPHA")
        font = Theme.Ramp.font(.panelFootnote)
        textColor = Theme.Color.special
        backgroundColor = Theme.Color.special.withAlphaComponent(0.14)
        layer.cornerRadius = 5
        layer.cornerCurve = .continuous
        clipsToBounds = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (badge: AlphaBadge, _) in
            badge.textColor = Theme.Color.special
            badge.backgroundColor = Theme.Color.special.withAlphaComponent(0.14)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 12, height: size.height + 4)
    }
}

/// Where the hand that writes the answers is chosen.
///
/// A reveal cannot be judged from a percentage any more than a haptic can, so this screen does not
/// describe the two hands — it runs both of them, on the same sentence, from the same clock, one
/// above the other. What the previews write is what the transcript will write: the same pacer, the
/// same gate, the same shared arithmetic, the same two renderers. Picking one is touching the one
/// you would rather read.
@MainActor
final class StreamRendererViewController: UIViewController {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var cards: [StreamRendererCard] = []
    private var link: CADisplayLink?
    private var began: CFTimeInterval = 0
    private let footnote = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Streaming")
        view.backgroundColor = Theme.Color.groupedBackground
        build()
        syncSelection()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stop()
    }

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = Theme.Spacing.l
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.l),
            stack.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xxl),
            stack.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
        ])

        stack.addArrangedSubview(hero())
        for choice in StreamRenderer.allCases {
            let card = StreamRendererCard(choice: choice)
            card.onPick = { [weak self] in self?.choose(choice) }
            cards.append(card)
            stack.addArrangedSubview(card)
        }
        stack.addArrangedSubview(footnoteLabel())
    }

    private func hero() -> UIView {
        let title = UILabel()
        title.text = String(localized: "How an answer arrives")
        title.font = Theme.Ramp.font(.cardTitle)
        title.numberOfLines = 0

        let detail = UILabel()
        detail.font = Theme.Ramp.font(.panelDetail)
        detail.textColor = Theme.Color.secondaryLabel
        detail.numberOfLines = 0
        detail.text = String(
            localized:
                "Text does not leave a model the way it is read — it arrives in lumps. Tailscode holds a buffer and plays it out at a speed that changes slowly, so a model that pauses to think reads as a hand slowing rather than a frame dropping. That much is the same either way. What you are choosing is the hand."
        )

        let column = UIStackView(arrangedSubviews: [title, detail])
        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        return card(column)
    }

    /// The screen's one surface idiom: content floating on glass, the same pane the previews are
    /// cut from.
    private func card(_ content: UIView) -> UIView {
        let glass = Theme.Glass.view()
        glass.layer.cornerRadius = Theme.Radius.card
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.isUserInteractionEnabled = false
        glass.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)
        container.addSubview(content)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Spacing.l),
            content.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -Theme.Spacing.l),
            content.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: Theme.Spacing.l),
            content.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        return container
    }

    private func footnoteLabel() -> UILabel {
        footnote.font = Theme.Ramp.font(.panelFootnote)
        footnote.textColor = Theme.Color.secondaryLabel
        footnote.numberOfLines = 0
        footnote.textAlignment = .center
        footnote.text =
            AuroraStreamView.isAvailable
            ? String(
                localized:
                    "Aurora is alpha. It writes prose and code and falls back to Classic for anything it cannot read — a burst of text too large to be a stream, a row it has no geometry for — so nothing is ever left unwritten. Reduce Motion turns both hands off and hands every answer over whole."
            )
            : String(
                localized:
                    "This device has no graphics processor Tailscode can reach, so Aurora cannot run here and every answer is written by Classic."
            )
        return footnote
    }

    private func choose(_ choice: StreamRenderer) {
        guard choice != StreamRendererSetting.choice else { return }
        StreamRendererSetting.set(choice)
        HapticEngine.shared.play(.send, strength: AppPreferences.hapticIntensity)
        syncSelection()
    }

    private func syncSelection() {
        let chosen = StreamRendererSetting.choice
        for card in cards {
            card.setChosen(card.choice == chosen)
            card.setAvailable(card.choice == .classic || AuroraStreamView.isAvailable)
        }
    }

    /// One clock for both previews. Two hands writing the same sentence are only comparable if they
    /// are writing it at the same moment, and two display links drifting a frame apart would put
    /// the difference between them in the wrong place.
    private func start() {
        guard link == nil, !UIAccessibility.isReduceMotionEnabled else { return }
        began = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
        for card in cards { card.rest() }
    }

    @objc private func tick(_ link: CADisplayLink) {
        for card in cards { card.advance(to: link.timestamp, since: began) }
    }
}

/// One hand, running.
@MainActor
final class StreamRendererCard: UIControl {
    let choice: StreamRenderer

    private let glass = Theme.Glass.view()
    private let preview: StreamRendererPreview
    private let name = UILabel()
    private let summary = UILabel()
    private let mark = UIImageView()
    private let badge = AlphaBadge()
    private var chosen = false

    var onPick: (() -> Void)?

    init(choice: StreamRenderer) {
        self.choice = choice
        preview = StreamRendererPreview(choice: choice)
        super.init(frame: .zero)
        build()
        addTarget(self, action: #selector(picked), for: .touchUpInside)
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        glass.layer.cornerRadius = Theme.Radius.card
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.isUserInteractionEnabled = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        name.text = choice.title
        name.font = Theme.Ramp.font(.cardTitle)
        name.setContentHuggingPriority(.required, for: .horizontal)

        summary.text = choice.summary
        summary.font = Theme.Ramp.font(.panelDetail)
        summary.textColor = Theme.Color.secondaryLabel
        summary.numberOfLines = 0

        mark.contentMode = .scaleAspectFit
        mark.setContentHuggingPriority(.required, for: .horizontal)
        mark.tintColor = Theme.Color.accent

        badge.isHidden = !choice.isAlpha

        let heading = UIStackView(arrangedSubviews: [name, badge, spacer(), mark])
        heading.axis = .horizontal
        heading.alignment = .center
        heading.spacing = Theme.Spacing.s

        let column = UIStackView(arrangedSubviews: [preview, heading, summary])
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        column.isUserInteractionEnabled = false
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.l),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.l),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    private func spacer() -> UIView {
        let view = UIView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func setChosen(_ value: Bool) {
        chosen = value
        mark.image = UIImage(
            systemName: value ? "checkmark.circle.fill" : "circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
        mark.tintColor = value ? Theme.Color.accent : Theme.Color.tertiaryLabel
        layer.borderWidth = value ? 1.5 : 0
        layer.borderColor = value ? Theme.Color.accent.cgColor : nil
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous
        accessibilityLabel = "\(choice.title). \(choice.spoken)"
        accessibilityValue =
            value ? String(localized: "Selected") : String(localized: "Not selected")
    }

    /// A hand this device cannot run is shown and refused rather than hidden: a preview nobody can
    /// pick still says what the choice would have been, and a row that vanished would read as a
    /// version of the app missing a feature rather than as a device without the hardware.
    func setAvailable(_ value: Bool) {
        isEnabled = value
        alpha = value ? 1 : 0.45
        if !value {
            accessibilityValue = String(localized: "Unavailable on this device")
        }
    }

    func advance(to time: CFTimeInterval, since began: CFTimeInterval) {
        preview.advance(to: time, since: began)
    }

    func rest() { preview.rest() }

    @objc private func picked() { onPick?() }
}
