import TailscodeCore
import UIKit

@MainActor
protocol PendingSendCellDelegate: AnyObject {
    func pendingSend(_ id: UUID, act: PendingSend.Act)
    /// A message being held for a provider's window, acted on: sent into it now anyway, opened
    /// for rewriting, or let out of the wait.
    func pendingSend(_ id: UUID, resume act: ResumeReading.Act)
}

/// A message on its way out: the words in the bubble they will keep, drawn in the ink that says
/// whether they went.
///
/// The ink is the point. A message on the wire is faint and fills in when the server has it; no
/// word is drawn under it for that. The strip under the bubble exists only when the wait has
/// become news — a send still out past `slowAfter`, a machine that has not started past
/// `quietAfter` — or when the send failed, where it carries the server's own reason and the
/// three things worth doing about it. The cell wakes itself for exactly the moment the strip
/// would change (`nextCaptionChange`) rather than ticking every second under a row that has
/// nothing to say.
@MainActor
final class PendingSendCell: UICollectionViewCell {
    static let reuseID = "PendingSendCell"
    weak var delegate: PendingSendCellDelegate?
    /// The strip appearing or going changes the row's height, which a self-sizing list only
    /// re-measures when asked; the transcript answers by reconfiguring this row.
    var onResize: (() -> Void)?

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
    private var stripShown: NSLayoutConstraint!
    private var stripHidden: NSLayoutConstraint!
    private var shownPhase: PendingSend.Phase?

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
        stripShown = statusStrip.heightAnchor.constraint(
            greaterThanOrEqualToConstant: Self.stripHeight)
        stripHidden = statusStrip.heightAnchor.constraint(equalToConstant: 0)
        stripHidden.isActive = true
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

            acts.topAnchor.constraint(equalTo: statusStrip.bottomAnchor),
            acts.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            acts.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            acts.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The strip's height once it has something to say, whatever the words; only a failure is
    /// allowed past it — that caption carries the server's own reason, and a reason cut off at
    /// "check your connec…" is the one thing on this row worth reading in full.
    private static let stripHeight: CGFloat = 18

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.layer.removeAllAnimations()
        contentView.alpha = 1
        contentView.transform = .identity
        badge.prepareForReuse()
        bubble.layer.removeAllAnimations()
        bubble.layer.borderWidth = 0
        stopClock()
        send = nil
        plan = nil
        shownPhase = nil
        onResize = nil
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
        label.attributedText = NSAttributedString(
            string: send.text,
            attributes: Theme.Ramp.attributes(.prompt, color: Theme.Color.onAccent))
        let icon = plan == nil ? PendingSendReading.icon(send) : ResumeReading.icon
        badge.show(icon, spoken: nil)
        paintInk(send, plan: plan)
        rebuildActs(for: send, plan: plan)
        paintCaption()
        isAccessibilityElement = true
        accessibilityTraits = failed && plan == nil ? .staticText : .updatesFrequently
        startClockIfNeeded()
    }

    /// The bubble's alpha is the state. Faint on the wire, full when the server has it — and the
    /// change from one to the other is the one thing this row animates, because it is the thing a
    /// person is waiting to see. A failure keeps the words at full strength and takes the danger
    /// tone on the bubble's edge.
    private func paintInk(_ send: PendingSend, plan: ResumePlan?) {
        let ink = plan == nil ? PendingSendReading.ink(send) : .full
        let previous = shownPhase
        shownPhase = send.phase
        bubble.backgroundColor = Theme.Color.userBubble
        let target = CGFloat(ink.opacity)
        if ink == .failed {
            bubble.layer.borderWidth = 1.5
            bubble.layer.borderColor = Theme.Color.danger.cgColor
            bubble.backgroundColor = Theme.Color.userBubble.withAlphaComponent(0.45)
        } else {
            bubble.layer.borderWidth = 0
        }
        let fills = previous == .sending && send.phase == .accepted
        guard fills, !UIAccessibility.isReduceMotionEnabled, window != nil else {
            bubble.layer.removeAllAnimations()
            bubble.alpha = target
            return
        }
        UIView.animate(
            withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]
        ) { self.bubble.alpha = target }
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

    private func paintCaption(announcing: Bool = false) {
        guard let send else { return }
        let now = Date()
        let icon = plan == nil ? PendingSendReading.icon(send) : ResumeReading.icon
        let words =
            plan.map { ResumeReading.caption($0, now: now) }
            ?? PendingSendReading.caption(send, now: now)
        let shown = words != nil
        caption.attributedText = words.map {
            NSAttributedString(
                string: $0, attributes: Theme.Ramp.attributes(.rowStamp, color: icon.tone.color))
        }
        if statusStrip.isHidden == shown {
            statusStrip.isHidden = !shown
            stripHidden.isActive = !shown
            stripShown.isActive = shown
            if announcing, window != nil { onResize?() }
        }
        accessibilityLabel = plan.map { ResumeReading.spoken($0, words: send.text, now: now) }
            ?? PendingSendReading.spoken(send, now: now)
    }

    /// The clock fires once, at the moment the strip would next change on its own, and never
    /// under a row that has nothing left to say. A held message keeps a countdown, so it keeps
    /// a beat.
    private func startClockIfNeeded() {
        guard clock == nil, window != nil, let send else { return }
        if plan != nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.paintCaption(announcing: true) }
            }
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
            return
        }
        guard let at = PendingSendReading.nextCaptionChange(send, now: Date()) else { return }
        let timer = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clock = nil
                self.paintCaption(announcing: true)
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
