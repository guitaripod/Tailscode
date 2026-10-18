import TailscodeCore
import UIKit

/// The foot of an open brain: Replay, a scrubber across the whole turn with a tick wherever a step
/// fires, the clock of the step the playhead is at, the words of the answer that some step touched
/// (pointing at one lights the steps behind it), and Rows, Share and Close. What it holds at a
/// width is Core's (`footerParts`); a finger always has a way to close, which a pointer has in Esc.
@MainActor
final class BrainFooterView: UIView {
    var onReplay: (() -> Void)?
    var onBegan: (() -> Void)?
    var onMoved: ((Double) -> Void)?
    var onEnded: (() -> Void)?
    var onRows: (() -> Void)?
    var onShare: (() -> Void)?
    var onClose: (() -> Void)?
    var onChip: ((String?) -> Void)?

    private let play = CardButton()
    private let track = BrainScrubTrack()
    private let time = UILabel()
    private let chips = BrainAnswerChips()
    private let rows = CardButton()
    private let share = CardButton()
    private let close = CardButton()
    private let rule = UIView()
    private var parts: [NeuralStageMetrics.FooterPart] = []
    private var compact = false
    private var running = false
    private var showsChips = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [rule, play, track, time, chips, rows, share, close] { addSubview(view) }
        rule.backgroundColor = Theme.Color.separator
        track.onBegan = { [weak self] in self?.onBegan?() }
        track.onMoved = { [weak self] fraction in self?.onMoved?(fraction) }
        track.onEnded = { [weak self] in self?.onEnded?() }
        play.onTap = { [weak self] in self?.onReplay?() }
        rows.onTap = { [weak self] in self?.onRows?() }
        share.onTap = { [weak self] in self?.onShare?() }
        close.onTap = { [weak self] in self?.onClose?() }
        chips.onSelect = { [weak self] token in self?.onChip?(token) }
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(metrics: NeuralStageMetrics, running isRunning: Bool, showsRows: Bool) {
        parts = metrics.footerParts()
        compact = metrics.density == .compact
        running = isRunning
        let iconOnly = parts.first { $0.kind == .replay }?.isIcon ?? false
        play.set(
            title: iconOnly ? "" : NeuralReading.replayLabel, symbol: "play.fill", on: false, compact: compact)
        play.accessibilityLabel = NeuralReading.replayLabel
        rows.set(title: NeuralReading.rowsLabel, symbol: nil, on: showsRows, compact: compact)
        rows.accessibilityLabel = NeuralReading.rowsLabel
        share.set(title: Localized.text("Share"), symbol: nil, on: false, compact: compact)
        close.set(title: Localized.text("Close"), symbol: nil, on: false, compact: compact)
        for button in [play, rows, share, close] { button.isAccessibilityElement = true }
        showsChips = parts.contains { $0.kind == .answerChips }
        setNeedsLayout()
    }

    /// The scrubber's playhead, the clock and the chips from the model at `time`.
    func show(
        model: NeuralBrainModel, answer: String, now: Double, replaying: Bool
    ) {
        let live = model.turn.outcome == .running
        track.isHidden = live
        time.isHidden = live
        play.isHidden = live && !replaying
        play.isEnabled = !live
        if !live {
            let fraction = model.replayFraction(now: now) ?? 1
            let timeline = model.timeline
            let ticks = timeline.fireTimes.map { timeline.fraction(forTime: $0) }
            let total = model.steps.count
            track.configure(ticks: ticks) { position in
                let lit = timeline.litCount(at: timeline.time(forFraction: position))
                return Localized.text("step %1$lld of %2$lld", max(lit, 1), total)
            }
            track.set(value: fraction)
            let clock = model.replayTime(now: now).flatMap { timeline.clockLabel(at: $0) }
                ?? model.steps.last?.at.map { NeuralReading.clock($0) }
            time.attributedText = NSAttributedString(
                string: clock ?? "",
                attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel, alignment: .right))
            let icon = replaying ? "pause.fill" : "play.fill"
            let iconOnly = parts.first { $0.kind == .replay }?.isIcon ?? false
            play.set(
                title: iconOnly ? "" : (replaying ? Localized.text("Stop") : NeuralReading.replayLabel),
                symbol: icon, on: replaying, compact: compact)
            play.accessibilityLabel = replaying ? Localized.text("Pause") : NeuralReading.replayLabel
        }
        if live || model.isReplaying || !showsChips {
            chips.isHidden = true
        } else {
            let tokens = answer.isEmpty ? [] : model.answerTokens(in: answer).map(\.text)
            var unique: [String] = []
            for token in tokens where !unique.contains(token) { unique.append(token) }
            chips.show(tokens: Array(unique.prefix(12)), selected: model.provenanceToken)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rule.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1 / max(UIScreen.main.scale, 1))
        let height: CGFloat = compact ? 26 : 28
        let midY = bounds.height / 2
        var left: CGFloat = 0
        var right = bounds.width
        let iconOnly = parts.first { $0.kind == .replay }?.isIcon ?? false
        if !play.isHidden {
            let size = play.fitted(height: height)
            let width = iconOnly ? max(34, size.width - 4) : size.width
            play.frame = CGRect(x: left, y: midY - height / 2, width: width, height: height)
            left = play.frame.maxX + 8
        }
        func placeRight(_ button: CardButton, show: Bool) {
            button.isHidden = !show
            guard show else { return }
            let size = button.fitted(height: height)
            button.frame = CGRect(x: right - size.width, y: midY - height / 2, width: size.width, height: height)
            right = button.frame.minX - 6
        }
        placeRight(close, show: true)
        placeRight(share, show: parts.contains { $0.kind == .share } && !running)
        placeRight(rows, show: parts.contains { $0.kind == .rows })
        right -= 4
        if !time.isHidden {
            let size = time.attributedText?.size() ?? .zero
            let width = ceil(size.width) + 2
            time.frame = CGRect(x: right - width, y: midY - size.height / 2, width: width, height: ceil(size.height))
            right = time.frame.minX - 8
        }
        if !chips.isHidden {
            let width = min(max(0, (right - left) * 0.42), chips.contentWidth)
            chips.frame = CGRect(x: right - width, y: midY - 18, width: width, height: 36)
            right = chips.frame.minX - 8
        }
        if !track.isHidden {
            track.frame = CGRect(x: left, y: midY - BrainScrubTrack.touchHeight / 2, width: max(0, right - left), height: BrainScrubTrack.touchHeight)
        }
    }
}

/// The path words in an answer that some step touched literally, as a row of chips. Pointing at
/// one lights the steps behind it and dims the rest; nothing that is not a literal match is offered.
@MainActor
final class BrainAnswerChips: UIView {
    var onSelect: ((String?) -> Void)?

    private let scroll = UIScrollView()
    private var buttons: [BrainTextButton] = []
    private var tokens: [String] = []
    private var selected: String?
    private(set) var contentWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.clipsToBounds = true
        addSubview(scroll)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(tokens new: [String], selected newSelected: String?) {
        isHidden = new.isEmpty
        guard new != tokens || newSelected != selected else { return }
        tokens = new
        selected = newSelected
        for button in buttons { button.removeFromSuperview() }
        buttons = []
        for token in new {
            let on = token == newSelected
            let text = NSAttributedString(
                string: token,
                attributes: Theme.Ramp.attributes(.rowStamp, color: on ? Theme.Color.onAccent : Theme.Color.info))
            let button = BrainTextButton(attributed: text, bordered: true) { [weak self] in
                Theme.Haptics.selection()
                self?.onSelect?(on ? nil : token)
            }
            if on { button.backgroundColor = Theme.Color.info }
            button.accessibilityLabel = Localized.text("Show the steps behind %@", token)
            button.accessibilityTraits = on ? [.button, .selected] : .button
            scroll.addSubview(button)
            buttons.append(button)
        }
        var x: CGFloat = 0
        for button in buttons {
            let size = button.intrinsicContentSize
            x += size.width + 6
        }
        contentWidth = max(0, x - 6)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        var x: CGFloat = 0
        for button in buttons {
            let size = button.intrinsicContentSize
            button.frame = CGRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x += size.width + 6
        }
        scroll.contentSize = CGSize(width: max(0, x - 6), height: bounds.height)
    }
}
