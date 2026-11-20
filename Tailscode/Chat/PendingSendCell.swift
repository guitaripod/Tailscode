import TailscodeCore
import UIKit

@MainActor
protocol PendingSendCellDelegate: AnyObject {
    func pendingSend(_ id: UUID, act: PendingSend.Act)
    /// A message being held for a provider's window, acted on: sent into it now anyway, opened
    /// for rewriting, or let out of the wait.
    func pendingSend(_ id: UUID, resume act: ResumeReading.Act)
}

/// What became of a message on its way out, under the bubble that holds its words.
///
/// The words themselves are drawn by the same cell the server's own row uses, at the same size, so
/// the server's account replacing them changes nothing a reader can see. This row is everything
/// else, and it exists only when there is something to say: a send still out past `slowAfter`, a
/// machine that has not started past `quietAfter`, a send held for the connection, one waiting on a
/// provider's window, or one that failed — where it carries the server's own reason and the things
/// worth doing about it. The transcript wakes for exactly the moment it would appear
/// (`nextCaptionChange`) rather than ticking under a bubble that has nothing to say.
@MainActor
final class PendingSendCell: UICollectionViewCell {
    static let reuseID = "PendingSendCell"
    weak var delegate: PendingSendCellDelegate?

    private let badge = ActivityBadgeView(pointSize: 10)
    private let caption = UILabel()
    private let statusStrip = UIStackView()
    private let acts = UIStackView()
    private var send: PendingSend?
    /// The wait this row is under, when it is under one. It replaces the caption, the badge and
    /// the verbs — a message waiting on a window is not a failure to be retried by hand, it is a
    /// message with an appointment.
    private var plan: ResumePlan?
    private var clock: Timer?
    private var stripTop: NSLayoutConstraint!

    var gapAbove: CGFloat = 0 {
        didSet { stripTop.constant = gapAbove }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        caption.numberOfLines = 1
        caption.adjustsFontForContentSizeCategory = true
        caption.textAlignment = .right
        badge.setContentHuggingPriority(.required, for: .horizontal)

        statusStrip.axis = .horizontal
        statusStrip.alignment = .center
        statusStrip.spacing = Theme.Spacing.xs
        statusStrip.translatesAutoresizingMaskIntoConstraints = false
        statusStrip.addArrangedSubview(badge)
        statusStrip.addArrangedSubview(caption)

        acts.axis = .horizontal
        acts.alignment = .center
        acts.spacing = Theme.Spacing.s
        acts.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(statusStrip)
        contentView.addSubview(acts)

        stripTop = statusStrip.topAnchor.constraint(equalTo: contentView.topAnchor)
        let maxWidth = statusStrip.widthAnchor.constraint(
            lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.82)
        NSLayoutConstraint.activate([
            stripTop,
            maxWidth,
            statusStrip.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.stripHeight),
            statusStrip.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            statusStrip.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentView.leadingAnchor, constant: Theme.Spacing.l),

            acts.topAnchor.constraint(equalTo: statusStrip.bottomAnchor),
            acts.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            acts.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            acts.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The strip's height whatever the words; only a failure is allowed past it — that caption
    /// carries the server's own reason, and a reason cut off at "check your connec…" is the one
    /// thing on this row worth reading in full.
    private static let stripHeight: CGFloat = 18

    /// Whether a send has anything for this row to say right now. The transcript asks it to
    /// decide whether the row exists at all.
    static func speaks(_ send: PendingSend, plan: ResumePlan?, now: Date) -> Bool {
        plan != nil || !send.acts.isEmpty || PendingSendReading.caption(send, now: now) != nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.layer.removeAllAnimations()
        contentView.alpha = 1
        contentView.transform = .identity
        badge.prepareForReuse()
        stopClock()
        send = nil
        plan = nil
        accessibilityCustomActions = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stopClock() : startClockIfNeeded()
    }

    func configure(
        _ sent: PendingSend, plan: ResumePlan? = nil, delegate: PendingSendCellDelegate?
    ) {
        var send = sent
        send.text = PasteFold.glance(CarriedText.typed(sent.text))
        self.send = send
        self.plan = plan
        self.delegate = delegate
        let wraps = send.isUnsent
        caption.numberOfLines = wraps ? 0 : 1
        caption.textAlignment = wraps ? .natural : .right
        let icon = plan == nil ? PendingSendReading.icon(send) : ResumeReading.icon
        badge.show(icon, spoken: nil)
        rebuildActs(for: send, plan: plan)
        paintCaption()
        isAccessibilityElement = true
        accessibilityTraits = send.isFailed && plan == nil ? .staticText : .updatesFrequently
        accessibilityCustomActions = recoveryActions(for: send, plan: plan)
        startClockIfNeeded()
    }

    /// The row's buttons as VoiceOver actions. The row reads as one element so its state is heard
    /// whole, which hides the buttons inside it, so what can be done about a send that did not go
    /// is handed to the rotor.
    private func recoveryActions(
        for send: PendingSend, plan: ResumePlan?
    ) -> [UIAccessibilityCustomAction] {
        let id = send.id
        guard plan == nil else {
            return ResumeReading.acts.map { act in
                UIAccessibilityCustomAction(name: ResumeReading.title(act)) { [weak self] _ in
                    self?.delegate?.pendingSend(id, resume: act)
                    return true
                }
            }
        }
        return send.acts.map { act in
            UIAccessibilityCustomAction(name: PendingSendReading.title(act, for: send)) {
                [weak self] _ in
                self?.delegate?.pendingSend(id, act: act)
                return true
            }
        }
    }

    private func rebuildActs(for send: PendingSend, plan: ResumePlan?) {
        for view in acts.arrangedSubviews { view.removeFromSuperview() }
        guard plan == nil else {
            acts.isHidden = false
            let id = send.id
            for act in ResumeReading.acts {
                let quiet = act == .stopWaiting
                var configuration = UIButton.Configuration.plain()
                configuration.image = UIImage(systemName: ResumeReading.symbol(act))
                configuration.imagePadding = Theme.Spacing.xs
                configuration.contentInsets = NSDirectionalEdgeInsets(
                    top: 4, leading: Theme.Spacing.xs, bottom: 4, trailing: Theme.Spacing.xs)
                configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                    pointSize: 11, weight: .semibold)
                let ink = quiet ? Theme.Color.tertiaryLabel : Theme.Color.accent
                configuration.baseForegroundColor = ink
                configuration.attributedTitle = AttributedString(
                    NSAttributedString(
                        string: ResumeReading.title(act),
                        attributes: Theme.Ramp.attributes(.control, color: ink)))
                let button = UIButton(
                    configuration: configuration,
                    primaryAction: UIAction { [weak self] _ in
                        self?.delegate?.pendingSend(id, resume: act)
                    })
                button.accessibilityLabel = ResumeReading.title(act)
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: TouchSlop.hit)
                    .isActive = true
                acts.addArrangedSubview(button)
            }
            return
        }
        acts.isHidden = send.acts.isEmpty
        for act in send.acts {
            let title = PendingSendReading.title(act, for: send)
            var configuration = UIButton.Configuration.plain()
            configuration.title = title
            configuration.image = UIImage(systemName: PendingSendReading.symbol(act))
            configuration.imagePadding = Theme.Spacing.xs
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: 4, leading: Theme.Spacing.xs, bottom: 4, trailing: Theme.Spacing.xs)
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                pointSize: 11, weight: .semibold)
            configuration.baseForegroundColor =
                act == .discard ? Theme.Color.tertiaryLabel : Theme.Color.accent
            configuration.attributedTitle = AttributedString(
                NSAttributedString(
                    string: title,
                    attributes: Theme.Ramp.attributes(
                        .control,
                        color: act == .discard ? Theme.Color.tertiaryLabel : Theme.Color.accent)))
            let id = send.id
            let button = UIButton(
                configuration: configuration,
                primaryAction: UIAction { [weak self] _ in
                    self?.delegate?.pendingSend(id, act: act)
                })
            button.accessibilityLabel = title
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: TouchSlop.hit)
                .isActive = true
            acts.addArrangedSubview(button)
        }
    }

    private func paintCaption() {
        guard let send else { return }
        let now = Date()
        let icon = plan == nil ? PendingSendReading.icon(send) : ResumeReading.icon
        let words =
            plan.map { ResumeReading.caption($0, now: now) }
            ?? PendingSendReading.caption(send, now: now)
        caption.attributedText = words.map {
            NSAttributedString(
                string: $0, attributes: Theme.Ramp.attributes(.rowStamp, color: icon.tone.color))
        }
        badge.isHidden = words == nil
        accessibilityLabel = plan.map { ResumeReading.spoken($0, words: send.text, now: now) }
            ?? PendingSendReading.state(send, now: now)
    }

    /// A message held for a provider's window keeps a countdown, so it keeps a beat. Every other
    /// change to what this row says arrives as a reconfigure from the transcript, which owns the
    /// clock that decides whether the row exists.
    private func startClockIfNeeded() {
        guard clock == nil, window != nil, plan != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.paintCaption() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }
}
