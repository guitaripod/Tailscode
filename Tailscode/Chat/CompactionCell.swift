import CodingAgentKit
import TailscodeCore
import UIKit

/// A compaction as the transcript sees it: the finished boundary, the minutes-long summarize that
/// is still running, or the attempt that was refused.
struct CompactionRow: Hashable {
    enum State: Hashable {
        case done(Compaction)
        /// `waiting` is a prompt this device has handed over while the summarize runs, so the card
        /// can say where it went rather than leave the reader wondering.
        case running(startedAt: Date, waiting: Bool)
        case failed(String)
    }

    let id: String
    let state: State

    var compaction: Compaction? {
        if case .done(let value) = state { return value }
        return nil
    }

    var isReadable: Bool { compaction?.summary?.isEmpty == false }
}

/// The seam a compaction leaves in a conversation. Everything above it still reads normally but is
/// gone from the agent's context, so the row is a full-width divider rather than a bubble: a rule
/// across the transcript, then a card saying what was traded for what.
final class CompactionCell: UICollectionViewCell {
    static let reuseID = "CompactionCell"

    private let rule = UIView()
    private let card = UIControl()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let chevron = UIImageView()
    private let detailLabel = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private let footnote = UILabel()
    private var fillWidth: NSLayoutConstraint!
    private var ticker: Task<Void, Never>?
    private var startedAt: Date?
    private var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(restartSweeping),
            name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(retuneSweep),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)

        rule.backgroundColor = Theme.Color.separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rule)

        card.backgroundColor = Theme.Color.secondaryBackground
        card.layer.cornerRadius = Theme.Radius.card
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addTarget(self, action: #selector(cardTapped), for: .touchUpInside)
        contentView.addSubview(card)

        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [icon, titleLabel, chevron])
        header.axis = .horizontal
        header.alignment = .firstBaseline
        header.spacing = Theme.Spacing.s

        detailLabel.font = Theme.Ramp.font(.panelDetail)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 0

        track.backgroundColor = Theme.Color.separator
        track.layer.cornerRadius = 2
        track.clipsToBounds = true
        track.translatesAutoresizingMaskIntoConstraints = false
        fill.layer.cornerRadius = 2
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        fillWidth = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: 0.05)

        footnote.font = Theme.Ramp.font(.panelFootnote)
        footnote.adjustsFontForContentSizeCategory = true
        footnote.textColor = Theme.Color.tertiaryLabel
        footnote.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [header, detailLabel, track, footnote])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.xs
        stack.setCustomSpacing(Theme.Spacing.s, after: detailLabel)
        stack.setCustomSpacing(Theme.Spacing.s, after: track)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isUserInteractionEnabled = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            rule.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 0.5),

            card.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: Theme.Spacing.m),
            card.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            card.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            card.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Spacing.m),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Spacing.m),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.Spacing.m),

            track.heightAnchor.constraint(equalToConstant: 4),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fillWidth,
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopTicking()
        onTap = nil
        contentView.layer.removeAllAnimations()
        contentView.alpha = 1
        contentView.transform = .identity
    }

    func configure(_ row: CompactionRow, onTap: (() -> Void)?) {
        self.onTap = onTap
        stopTicking()
        card.isUserInteractionEnabled = onTap != nil
        chevron.isHidden = onTap == nil

        switch row.state {
        case .done(let compaction):
            configureDone(compaction)
        case .running(let started, let waiting):
            configureRunning(startedAt: started, waiting: waiting)
        case .failed(let reason):
            configureFailed(reason)
        }
    }

    private func configureDone(_ compaction: Compaction) {
        let story = CompactionStory.done(compaction)
        apply(story, tint: Theme.Color.accent)
        setFill(story.keptFraction)
        track.isHidden = story.keptFraction == nil
    }

    private func configureRunning(startedAt: Date, waiting: Bool) {
        let story = CompactionStory.running(startedAt: startedAt, waiting: waiting)
        apply(story, tint: Theme.Color.accent)
        track.isHidden = false
        self.startedAt = startedAt
        updateElapsed()
        startTicking()
        startSweeping()
    }

    private func configureFailed(_ reason: String) {
        let story = CompactionStory.failed(reason)
        apply(story, tint: Theme.Color.warning)
        track.isHidden = true
    }

    private func apply(_ story: CompactionStory, tint: UIColor) {
        symbol(story.symbol, tint: tint)
        titleLabel.text = story.title
        detailLabel.text = story.detail
        fill.backgroundColor = Theme.Color.accent
        footnote.text = story.footnote
        footnote.isHidden = story.footnote == nil
    }

    private func symbol(_ name: String, tint: UIColor) {
        icon.image = UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        icon.tintColor = tint
    }

    private func setFill(_ fraction: Double?) {
        let clamped = min(max(fraction ?? 0.05, 0.02), 1)
        fillWidth.isActive = false
        fillWidth = fill.widthAnchor.constraint(
            equalTo: track.widthAnchor, multiplier: CGFloat(clamped))
        fillWidth.isActive = true
    }

    private func updateElapsed() {
        guard let startedAt else { return }
        footnote.text = CompactionStory.elapsedLine(startedAt: startedAt)
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.updateElapsed()
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
        startedAt = nil
        fill.layer.removeAllAnimations()
    }

    /// An indeterminate sweep: compaction reports no progress, and a bar that pretended to know
    /// would be lying about a step that can run for two minutes.
    private func startSweeping() {
        setFill(sweepFill)
        layoutIfNeeded()
        fill.layer.removeAllAnimations()
        sweep()
    }

    /// How much of the track the bar holds while it cannot say how far along it is.
    ///
    /// A short stripe is only honest while it travels: parked at 30% by a reader who asked for
    /// less motion it reads as a third done, which is a number nobody measured. Still, it fills
    /// the track — the same thing the sweep bar on the desks does.
    private var sweepFill: Double {
        ActivityMotion.turning.honoring(reduceMotion: UIAccessibility.isReduceMotionEnabled)
            .isAnimated ? 0.3 : 1
    }

    /// The bar's own movement, laid on apart from the shape it moves in, so a reader who changes
    /// their mind while the summarize is still running re-decides the movement and the bar itself
    /// stays exactly where it is. Whether it moves at all is the vocabulary's to say, and a
    /// compaction is the app's one literal case of `ActivityMotion.turning`: something being
    /// turned over, reporting nothing while it is.
    private func sweep() {
        guard track.bounds.width > 0 else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = -track.bounds.width * 0.3
        slide.toValue = track.bounds.width
        slide.duration = 1.4
        slide.repeatCount = .infinity
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fill.layer.setRepeatingMotion(slide, forKey: "sweep", meaning: .turning)
    }

    /// Restarts the sweep once the track has a real width, and after a trip through the background
    /// strips the repeating animation off a cell that never left the window. Only the movement is
    /// re-laid here: the bar's width is the running state's, and setting it from inside a layout
    /// pass would ask for another one.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard startedAt != nil, fill.layer.animation(forKey: "sweep") == nil else { return }
        sweep()
    }

    @objc private func restartSweeping() {
        guard window != nil, startedAt != nil else { return }
        startSweeping()
    }

    /// Reads the reader's mind again when they change it mid-summarize. A compaction runs for
    /// minutes, so a bar that asked only at the moment it appeared would go on sweeping under a
    /// preference already changed; a card with nothing running has no wait to draw.
    @objc private func retuneSweep() {
        guard startedAt != nil else { return }
        setFill(sweepFill)
        layoutIfNeeded()
        sweep()
    }

    @objc private func cardTapped() {
        Theme.Haptics.tap()
        onTap?()
    }
}
