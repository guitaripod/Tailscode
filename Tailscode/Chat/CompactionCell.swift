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
/// gone from the agent's context, so the row is a divider line across the transcript — what was
/// traded for what, in one 32-point row — and the summary, the bar and the explanation live in the
/// reader it opens.
///
/// A summarize that is still running keeps the one thing a line cannot say, that it is moving: a
/// thin sweep under the line, and the elapsed time ticking in it.
final class CompactionCell: UICollectionViewCell {
    static let reuseID = "CompactionCell"

    private let seam = SeamLineView()
    private let track = UIView()
    private let fill = UIView()
    private var fillWidth: NSLayoutConstraint!
    private var topConstraint: NSLayoutConstraint!
    private var trackHeight: NSLayoutConstraint!
    private var ticker: Task<Void, Never>?
    private var startedAt: Date?
    private var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var gapAbove: CGFloat = 0 {
        didSet { topConstraint.constant = gapAbove }
    }

    private func build() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(restartSweeping),
            name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(retuneSweep),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)

        seam.translatesAutoresizingMaskIntoConstraints = false
        seam.addTarget(self, action: #selector(seamTapped), for: .touchUpInside)
        contentView.addSubview(seam)

        track.backgroundColor = Theme.Color.separator
        track.clipsToBounds = true
        track.translatesAutoresizingMaskIntoConstraints = false
        fill.backgroundColor = Theme.Color.accent
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        contentView.addSubview(track)
        fillWidth = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: 0.05)
        trackHeight = track.heightAnchor.constraint(equalToConstant: 0)
        topConstraint = seam.topAnchor.constraint(equalTo: contentView.topAnchor)

        NSLayoutConstraint.activate([
            topConstraint,
            seam.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            seam.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            track.topAnchor.constraint(equalTo: seam.bottomAnchor),
            track.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            track.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            track.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            trackHeight,

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
        setSweep(visible: false)

        switch row.state {
        case .done(let compaction):
            let story = CompactionStory.done(compaction)
            seam.show(
                text: Self.line(for: story, compaction: compaction), symbol: nil,
                tint: Theme.Color.secondaryLabel, tappable: onTap != nil && row.isReadable,
                spoken: Self.spoken(for: story))
        case .running(let started, let waiting):
            let story = CompactionStory.running(startedAt: started, waiting: waiting)
            startedAt = started
            seam.show(
                text: Self.runningLine(story, startedAt: started), symbol: nil,
                tint: Theme.Color.accent, tappable: false, spoken: story.title + ". " + story.detail)
            setSweep(visible: true)
            startTicking()
            startSweeping()
        case .failed(let reason):
            let story = CompactionStory.failed(reason)
            seam.show(
                text: story.title + " · " + story.detail, symbol: story.symbol,
                tint: Theme.Color.warning, tappable: false)
        }
    }

    /// `Context compacted · 311.6k → 16.4k · 1m 54s`: the title, what was traded, how long it took.
    /// What the seam leaves out — the word "tokens", the share freed, the bar — is in the reader it
    /// opens, so the line stays one line.
    private static func line(for story: CompactionStory, compaction: Compaction) -> String {
        var parts = [story.title]
        if let before = compaction.tokensBefore, let after = compaction.tokensAfter {
            parts.append("\(StatusFacts.tokens(before)) → \(StatusFacts.tokens(after))")
        } else if let after = compaction.tokensAfter {
            parts.append(StatusFacts.tokens(after))
        }
        if let duration = compaction.duration, duration >= 1 {
            parts.append(StatusFacts.clock(duration))
        }
        return parts.joined(separator: " · ")
    }

    private static func spoken(for story: CompactionStory) -> String {
        [story.title, story.detail, story.footnote].compactMap { $0 }.joined(separator: ". ")
    }

    private static func runningLine(_ story: CompactionStory, startedAt: Date) -> String {
        story.title + " · " + CompactionStory.elapsedLine(startedAt: startedAt)
    }

    private func setSweep(visible: Bool) {
        trackHeight.constant = visible ? 2 : 0
        track.isHidden = !visible
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, let started = self.startedAt else { return }
                let story = CompactionStory.running(startedAt: started)
                self.seam.show(
                    text: Self.runningLine(story, startedAt: started), symbol: nil,
                    tint: Theme.Color.accent, tappable: false,
                    spoken: story.title + ". " + story.detail)
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
        startedAt = nil
        fill.layer.removeAllAnimations()
    }

    private func setFill(_ fraction: Double) {
        fillWidth.isActive = false
        fillWidth = fill.widthAnchor.constraint(
            equalTo: track.widthAnchor, multiplier: CGFloat(min(max(fraction, 0.02), 1)))
        fillWidth.isActive = true
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

    @objc private func seamTapped() {
        Theme.Haptics.tap()
        onTap?()
    }
}
