import TailscodeCore
import UIKit

@MainActor
protocol PendingSendCellDelegate: AnyObject {
    func pendingSend(_ id: UUID, act: PendingSend.Act)
    /// A message being held for a provider's window, acted on: sent into it now anyway, opened
    /// for rewriting, or let out of the wait.
    func pendingSend(_ id: UUID, resume act: ResumeReading.Act)
}

/// A message on its way out: the words in the bubble they will keep, with a line under them
/// saying whether they went.
///
/// The line is the point. A prompt that merely appears is a claim that it was sent, and until
/// this row existed that claim was the only thing the app ever made — a send that died on the
/// tunnel took its words out of the transcript and left them in the composer or, worse, the
/// pasteboard, for the reader to notice. Here they stay exactly where they were written, and the
/// row says what happened to them and offers the three things worth doing about it.
///
/// The caption ages on the cell's own clock rather than through the transcript. Whether a send has
/// been out for one second or six is the difference between a formality and the only useful thing
/// on screen, but redrawing a whole conversation once a second to say so would cost more than the
/// wait it describes. Nothing it changes moves any layout: the strip is a fixed height and the
/// words inside it are free to be longer.
@MainActor
final class PendingSendCell: UICollectionViewCell {
    static let reuseID = "PendingSendCell"
    weak var delegate: PendingSendCellDelegate?

    private let bubble = UIView()
    private let label = UILabel()
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
    private var bubbleTop: NSLayoutConstraint!

    /// Extra gap above the bubble when this row opens a new turn, set by the transcript exactly
    /// as it is on every other bubble — a prompt that has not arrived anywhere yet still opens a
    /// turn.
    var turnInset: CGFloat = 0 {
        didSet { bubbleTop.constant = Theme.Spacing.xs + turnInset }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.layer.cornerRadius = Theme.Radius.bubble
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
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

        contentView.addSubview(bubble)
        bubble.addSubview(label)
        contentView.addSubview(statusStrip)
        contentView.addSubview(acts)

        bubbleTop = bubble.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: Theme.Spacing.xs)
        NSLayoutConstraint.activate([
            bubbleTop,
            bubble.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            bubble.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            bubble.widthAnchor.constraint(
                lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.82),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: Theme.Spacing.s),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -Theme.Spacing.s),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: Theme.Spacing.m),
            label.trailingAnchor.constraint(
                equalTo: bubble.trailingAnchor, constant: -Theme.Spacing.m),

            statusStrip.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 2),
            statusStrip.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            statusStrip.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            statusStrip.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.stripHeight),

            acts.topAnchor.constraint(equalTo: statusStrip.bottomAnchor),
            acts.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            acts.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            acts.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The strip holds this height whatever the caption says, so a wait that grows a word does
    /// not move the transcript under the reader. Only a failure is allowed past it — that caption
    /// carries the server's own reason, and a reason cut off at "check your connec…" is the one
    /// thing on this row worth reading in full.
    private static let stripHeight: CGFloat = 18

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.layer.removeAllAnimations()
        contentView.alpha = 1
        contentView.transform = .identity
        badge.prepareForReuse()
        stopClock()
        send = nil
        plan = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stopClock() : startClockIfNeeded()
    }

    func configure(
        _ send: PendingSend, plan: ResumePlan? = nil, delegate: PendingSendCellDelegate?
    ) {
        self.send = send
        self.plan = plan
        self.delegate = delegate
        let failed = send.isFailed
        caption.numberOfLines = failed ? 0 : 1
        caption.textAlignment = failed ? .natural : .right
        bubble.backgroundColor = Theme.Color.userBubble.withAlphaComponent(failed ? 0.45 : 1)
        label.attributedText = NSAttributedString(
            string: send.text,
            attributes: Theme.Ramp.attributes(.prompt, color: Theme.Color.onAccent))
        let icon = plan == nil ? PendingSendReading.icon(send) : ResumeReading.icon
        badge.show(icon, spoken: nil)
        rebuildActs(for: send, plan: plan)
        paintCaption()
        isAccessibilityElement = true
        accessibilityTraits = failed && plan == nil ? .staticText : .updatesFrequently
        startClockIfNeeded()
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
                acts.addArrangedSubview(button)
            }
            return
        }
        acts.isHidden = send.acts.isEmpty
        for act in send.acts {
            var configuration = UIButton.Configuration.plain()
            configuration.title = PendingSendReading.title(act)
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
                    string: PendingSendReading.title(act),
                    attributes: Theme.Ramp.attributes(
                        .control,
                        color: act == .discard ? Theme.Color.tertiaryLabel : Theme.Color.accent)))
            let id = send.id
            let button = UIButton(
                configuration: configuration,
                primaryAction: UIAction { [weak self] _ in
                    self?.delegate?.pendingSend(id, act: act)
                })
            button.accessibilityLabel = PendingSendReading.title(act)
            acts.addArrangedSubview(button)
        }
    }

    private func paintCaption() {
        guard let send else { return }
        let now = Date()
        let icon = plan == nil ? PendingSendReading.icon(send) : ResumeReading.icon
        caption.attributedText = NSAttributedString(
            string: plan.map { ResumeReading.caption($0, now: now) }
                ?? PendingSendReading.caption(send, now: now),
            attributes: Theme.Ramp.attributes(.rowStamp, color: icon.tone.color))
        accessibilityLabel = plan.map { ResumeReading.spoken($0, words: send.text, now: now) }
            ?? PendingSendReading.spoken(send, now: now)
    }

    /// A caption that ages needs a clock, and only while it is still ageing: a failure says the
    /// same thing forever, so it keeps none.
    private func startClockIfNeeded() {
        guard clock == nil, window != nil, let send else { return }
        guard plan != nil || !send.isFailed else { return }
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
