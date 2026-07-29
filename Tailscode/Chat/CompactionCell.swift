import CodingAgentKit
import UIKit

/// A compaction as the transcript sees it: the finished boundary, the minutes-long summarize that
/// is still running, or the attempt that was refused.
struct CompactionRow: Hashable {
    enum State: Hashable {
        case done(Compaction)
        case running(startedAt: Date)
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
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
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

        detailLabel.font = .preferredFont(forTextStyle: .caption1)
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

        footnote.font = .preferredFont(forTextStyle: .caption2)
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
        case .running(let started):
            configureRunning(startedAt: started)
        case .failed(let reason):
            configureFailed(reason)
        }
    }

    private func configureDone(_ compaction: Compaction) {
        symbol("arrow.down.right.and.arrow.up.left", tint: Theme.Color.accent)
        titleLabel.text = Self.title(for: compaction.trigger)
        detailLabel.text = Self.detail(for: compaction)
        fill.backgroundColor = Theme.Color.accent
        setFill(Self.keptFraction(compaction))
        track.isHidden = compaction.tokensBefore == nil || compaction.tokensAfter == nil
        footnote.text = Self.footnote(for: compaction)
        footnote.isHidden = false
    }

    private func configureRunning(startedAt: Date) {
        symbol("arrow.down.right.and.arrow.up.left", tint: Theme.Color.accent)
        titleLabel.text = String(localized: "Compacting…")
        detailLabel.text =
            String(
                localized:
                    "Re-reading the conversation to summarize it. This can take a minute or two.")
        track.isHidden = false
        fill.backgroundColor = Theme.Color.accent
        footnote.isHidden = false
        self.startedAt = startedAt
        updateElapsed()
        startTicking()
        startSweeping()
    }

    private func configureFailed(_ reason: String) {
        symbol("exclamationmark.triangle.fill", tint: Theme.Color.warning)
        titleLabel.text = String(localized: "Couldn't compact")
        detailLabel.text = reason
        track.isHidden = true
        footnote.text = String(localized: "The conversation is unchanged.")
        footnote.isHidden = false
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

    /// The sliver of context the summary now occupies. Rendering what is *kept* rather than what
    /// was freed is the honest read: a nearly empty bar is the point of compacting.
    private static func keptFraction(_ compaction: Compaction) -> Double? {
        guard let before = compaction.tokensBefore, before > 0, let after = compaction.tokensAfter
        else { return nil }
        return Double(after) / Double(before)
    }

    private static func title(for trigger: Compaction.Trigger?) -> String {
        trigger == .auto
            ? String(localized: "Context compacted automatically")
            : String(localized: "Context compacted")
    }

    private static func detail(for compaction: Compaction) -> String {
        var parts: [String] = []
        if let before = compaction.tokensBefore, let after = compaction.tokensAfter {
            parts.append(String(localized: "\(tokens(before)) → \(tokens(after)) tokens"))
        } else if let after = compaction.tokensAfter {
            parts.append(String(localized: "\(tokens(after)) tokens in context"))
        }
        if let duration = compaction.duration, duration >= 1 {
            parts.append(elapsed(duration))
        }
        guard !parts.isEmpty else {
            return String(localized: "The conversation so far was replaced by a summary of it.")
        }
        return parts.joined(separator: " · ")
    }

    private static func footnote(for compaction: Compaction) -> String {
        var sentence =
            compaction.reduction.map {
                String(
                    localized: "\(Int(($0 * 100).rounded()))% of the context was replaced by a summary"
                )
            } ?? String(localized: "Earlier messages were replaced by a summary")
        if let preserved = compaction.preservedMessageCount, preserved > 0 {
            sentence += "; " + String(localized: "the last \(preserved) messages carried over")
        }
        return sentence + "."
    }

    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)k" }
        return "\(value)"
    }

    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(Int(interval.rounded()), 0)
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func updateElapsed() {
        guard let startedAt else { return }
        footnote.text = String(
            localized: "Running for \(Self.elapsed(Date().timeIntervalSince(startedAt)))")
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
        setFill(0.3)
        layoutIfNeeded()
        guard track.bounds.width > 0 else { return }
        fill.layer.removeAllAnimations()
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = -track.bounds.width * 0.3
        slide.toValue = track.bounds.width
        slide.duration = 1.4
        slide.repeatCount = .infinity
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fill.layer.add(slide, forKey: "sweep")
    }

    /// Restarts the sweep once the track has a real width, and after a trip through the background
    /// strips the repeating animation off a cell that never left the window.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard startedAt != nil, track.bounds.width > 0,
            fill.layer.animation(forKey: "sweep") == nil
        else { return }
        startSweeping()
    }

    @objc private func restartSweeping() {
        guard window != nil, startedAt != nil else { return }
        startSweeping()
    }

    @objc private func cardTapped() {
        Theme.Haptics.tap()
        onTap?()
    }
}
