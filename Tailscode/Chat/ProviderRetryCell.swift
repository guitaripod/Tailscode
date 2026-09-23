import CodingAgentKit
import TailscodeCore
import UIKit

/// The face of a turn waiting on its provider between attempts. A card at the end of the
/// transcript, in the same family as the interrupted-turn card: from the outside the wait looks
/// like a model thinking very hard, and the provider's own reason is the whole explanation.
///
/// It asks nothing of the person, so it carries no button of its own beyond the remedy the
/// provider named, and it wakes its own clock for the exact moment its words next change rather
/// than ticking under a card that has nothing new to say.
final class ProviderRetryCell: UICollectionViewCell {
    static let reuseID = "ProviderRetryCell"

    private let card = UIView()
    private let badge = ActivityBadgeView(pointSize: 15)
    private let titleLabel = UILabel()
    private let reasonLabel = UILabel()
    private let attemptLabel = UILabel()
    private let remedyTitleLabel = UILabel()
    private let remedyMessageLabel = UILabel()
    private let remedyButton = UIButton(type: .system)
    private let remedyStack = UIStackView()
    private var retry: TurnRetry?
    private var onOpenRemedy: ((URL) -> Void)?
    private var clock: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        card.backgroundColor = Theme.Color.secondaryBackground
        card.layer.cornerRadius = Theme.Radius.card
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = ProviderRetryCard.tone.color.withAlphaComponent(0.35).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        badge.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0

        let header = UIStackView(arrangedSubviews: [badge, titleLabel])
        header.axis = .horizontal
        header.alignment = .firstBaseline
        header.spacing = Theme.Spacing.s

        reasonLabel.font = Theme.Ramp.font(.panelDetail)
        reasonLabel.adjustsFontForContentSizeCategory = true
        reasonLabel.textColor = Theme.Color.secondaryLabel
        reasonLabel.numberOfLines = 0

        attemptLabel.font = Theme.Ramp.font(.rowStamp)
        attemptLabel.adjustsFontForContentSizeCategory = true
        attemptLabel.textColor = ProviderRetryCard.tone.color
        attemptLabel.numberOfLines = 0

        remedyTitleLabel.font = Theme.Ramp.font(.rowTitleStrong)
        remedyTitleLabel.adjustsFontForContentSizeCategory = true
        remedyTitleLabel.textColor = Theme.Color.label
        remedyTitleLabel.numberOfLines = 0

        remedyMessageLabel.font = Theme.Ramp.font(.panelDetail)
        remedyMessageLabel.adjustsFontForContentSizeCategory = true
        remedyMessageLabel.textColor = Theme.Color.secondaryLabel
        remedyMessageLabel.numberOfLines = 0

        var remedyConfig = Theme.Glass.buttonConfiguration()
        remedyConfig.cornerStyle = .capsule
        remedyConfig.buttonSize = .small
        remedyButton.configuration = remedyConfig
        remedyButton.addAction(UIAction { [weak self] _ in self?.openRemedy() }, for: .touchUpInside)

        [remedyTitleLabel, remedyMessageLabel, remedyButton].forEach(remedyStack.addArrangedSubview)
        remedyStack.axis = .vertical
        remedyStack.alignment = .leading
        remedyStack.spacing = Theme.Spacing.xs
        remedyStack.setCustomSpacing(Theme.Spacing.s, after: remedyMessageLabel)

        let stack = UIStackView(arrangedSubviews: [
            header, reasonLabel, attemptLabel, remedyStack,
        ])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.xs
        stack.setCustomSpacing(Theme.Spacing.s, after: attemptLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            card.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            card.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            card.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Spacing.m),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Spacing.m),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(
                equalTo: card.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopClock()
        retry = nil
        onOpenRemedy = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stopClock() : startClockIfNeeded()
    }

    func configure(_ retry: TurnRetry, onOpenRemedy: @escaping (URL) -> Void) {
        self.retry = retry
        self.onOpenRemedy = onOpenRemedy
        paint()
        startClockIfNeeded()
    }

    private func paint() {
        guard let retry, let reading = ProviderRetryReading.read(retry, now: Date()) else { return }
        badge.show(ActivityKind.retrying(attempt: retry.attempt).icon, spoken: nil)
        titleLabel.text = reading.title
        reasonLabel.text = reading.reason
        attemptLabel.text = reading.attemptLine
        if let remedy = reading.remedy {
            remedyTitleLabel.text = remedy.title
            remedyMessageLabel.text = remedy.message
            remedyButton.configuration?.title = remedy.label
        }
        remedyStack.isHidden = reading.remedy == nil
        remedyTitleLabel.isHidden = reading.remedy == nil
        remedyMessageLabel.isHidden = reading.remedy == nil
        remedyButton.isHidden = reading.remedy?.link == nil
        isAccessibilityElement = true
        accessibilityLabel = reading.spoken
        accessibilityTraits = .staticText
        accessibilityCustomActions = remedyAction(reading.remedy)
    }

    /// The remedy's button as a VoiceOver action. The card reads as one element so its words are
    /// heard in order, which hides the button inside it, so the one press it offers is handed to
    /// the rotor instead.
    private func remedyAction(_ remedy: ProviderRetryCard.Remedy?) -> [UIAccessibilityCustomAction] {
        guard let remedy, remedy.link != nil else { return [] }
        return [
            UIAccessibilityCustomAction(name: remedy.label) { [weak self] _ in
                self?.openRemedy()
                return true
            }
        ]
    }

    private func openRemedy() {
        guard let retry, let remedy = ProviderRetryReading.read(retry)?.remedy, let link = remedy.link
        else { return }
        onOpenRemedy?(link)
    }

    /// The clock fires once, at the exact moment `ProviderRetryReading` says the words would next
    /// change on their own, and never under a card that has nothing left to say: a wait counted in
    /// minutes does not need a per-second wake, and a wait that has already resolved needs none.
    private func startClockIfNeeded() {
        guard clock == nil, window != nil, let retry else { return }
        guard let at = ProviderRetryReading.nextChange(retry, now: Date()) else { return }
        let timer = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clock = nil
                self.paint()
                self.startClockIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }
}
