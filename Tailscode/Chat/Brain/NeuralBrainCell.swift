import TailscodeCore
import UIKit

/// The collapsed line of a turn's brain: the head glyph, what the turn did in the app's type, a
/// Rows pill that lists the old step rows, and a Replay button. The whole line is one button that
/// opens the brain.
@MainActor
final class BrainLine: UIView {
    var onToggle: (() -> Void)?
    var onRows: (() -> Void)?
    var onReplay: (() -> Void)?
    var onShare: (() -> Void)?
    private var canShare = false
    private var showsRows = false

    private let toggle = UIButton(type: .system)
    private let chevron = UIImageView()
    private let glyph = BrainGlyphView()
    private let label = UILabel()
    private let rowsPill = SlopButton(type: .system)
    private let replay = SlopButton(type: .system)
    private let trailing = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.addTarget(self, action: #selector(toggled), for: .touchUpInside)
        toggle.answersPointer(cornerRadius: Theme.Radius.control)

        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        glyph.translatesAutoresizingMaskIntoConstraints = false
        label.adjustsFontForContentSizeCategory = true
        label.lineBreakMode = .byTruncatingTail
        label.isAccessibilityElement = false
        label.translatesAutoresizingMaskIntoConstraints = false

        var pill = UIButton.Configuration.plain()
        pill.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)
        pill.background.cornerRadius = 12
        rowsPill.configuration = pill
        rowsPill.addTarget(self, action: #selector(rowsPressed), for: .touchUpInside)
        rowsPill.setContentHuggingPriority(.required, for: .horizontal)
        rowsPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        rowsPill.answersPointer(cornerRadius: 12)

        var play = UIButton.Configuration.plain()
        play.image = UIImage(
            systemName: "play.circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        play.baseForegroundColor = Theme.Color.secondaryLabel
        play.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        replay.configuration = play
        replay.addTarget(self, action: #selector(replayPressed), for: .touchUpInside)
        replay.accessibilityLabel = NeuralReading.replayLabel
        replay.setContentHuggingPriority(.required, for: .horizontal)
        replay.setContentCompressionResistancePriority(.required, for: .horizontal)
        replay.answersPointer(cornerRadius: Theme.Radius.control)

        trailing.axis = .horizontal
        trailing.alignment = .center
        trailing.spacing = Theme.Spacing.xs
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.addArrangedSubview(rowsPill)
        trailing.addArrangedSubview(replay)

        toggle.addInteraction(UIContextMenuInteraction(delegate: self))
        addSubview(toggle)
        addSubview(chevron)
        addSubview(glyph)
        addSubview(label)
        addSubview(trailing)
        let rowHeight = CGFloat(Theme.Chat.metrics.activityRowHeight)
        NSLayoutConstraint.activate([
            toggle.topAnchor.constraint(equalTo: topAnchor),
            toggle.bottomAnchor.constraint(equalTo: bottomAnchor),
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(
                greaterThanOrEqualToConstant: max(rowHeight, BrainGlyphView.height + 14)),
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.s),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: Theme.Spacing.xs),
            glyph.widthAnchor.constraint(equalToConstant: BrainGlyphView.width),
            glyph.heightAnchor.constraint(equalToConstant: BrainGlyphView.height),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: Theme.Spacing.s),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: trailing.leadingAnchor, constant: -Theme.Spacing.s),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.xs),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// How much of the line is spoken, richest first. The line gives up its fields from the end
    /// when the width runs short: the thoughts and notes, then the failure's own words, then the
    /// tool mix (first cut to its first three names, then left out), and last the duration. A
    /// field is never shown cut short; it is left out, and the count, the tally, Rows and Replay
    /// stay. A phone keeps the count, the tally and the duration; a wide column keeps the mix too.
    private enum Fullness: Int, CaseIterable {
        case everything, withoutAsides, mixOnly, shortMix, withoutMix, countOnly
    }

    private var reading: NeuralReading.Line?

    /// Writes the line from the model: the count and what it was made of, the clock, the tally and
    /// how it ended; the glyph with the zones that did the work; the pills.
    func show(model: NeuralBrainModel, row: BrainRow, now: Date = Date()) {
        let line = model.line(now: now)
        reading = line
        label.numberOfLines =
            traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 1
        let level = fit(line)
        lastDrawn = level
        label.attributedText = text(line, fullness: level)
        glyph.show(model.glyph(dim: false), face: model.face)
        chevron.transform = row.isOpen ? CGAffineTransform(rotationAngle: .pi / 2) : .identity

        var pill = rowsPill.configuration ?? .plain()
        pill.attributedTitle = AttributedString(
            NSAttributedString(
                string: NeuralReading.rowsLabel,
                attributes: Theme.Ramp.attributes(
                    .pill, color: row.showsRows ? Theme.Color.accent : Theme.Color.secondaryLabel)))
        pill.background.backgroundColor =
            row.showsRows ? Theme.Color.accent.withAlphaComponent(0.16) : Theme.Color.groupedSurface
        rowsPill.configuration = pill
        rowsPill.accessibilityLabel = NeuralReading.rowsLabel
        rowsPill.accessibilityTraits = row.showsRows ? [.button, .selected] : .button
        rowsPill.accessibilityHint = Localized.text("Lists every step as a row")
        replay.isHidden = model.turn.outcome == .running
        canShare = model.turn.outcome != .running
        showsRows = row.showsRows

        toggle.accessibilityLabel = model.spoken(now: now)
        toggle.accessibilityValue = row.isOpen ? Localized.text("Expanded") : Localized.text("Collapsed")
        toggle.accessibilityHint =
            row.isOpen ? Localized.text("Double tap to close the head") : Localized.text("Double tap to open the head")
    }

    private func text(_ line: NeuralReading.Line, fullness: Fullness) -> NSAttributedString {
        let failed = line.failure == Localized.text("failed")
        let out = NSMutableAttributedString(
            string: line.count,
            attributes: Theme.Ramp.attributes(
                .toolName, color: failed ? Theme.Color.danger : Theme.Color.label))
        if let tally = line.tally {
            for word in tally.split(separator: " ") {
                out.append(
                    NSAttributedString(
                        string: "  " + String(word),
                        attributes: Theme.Ramp.attributes(
                            .responseStat,
                            color: word.hasPrefix("+") ? Theme.Color.success : Theme.Color.danger)))
            }
        }
        let quiet = Theme.Ramp.attributes(.toolDetail, color: Theme.Color.secondaryLabel)
        if fullness != .countOnly, let duration = line.duration {
            out.append(NSAttributedString(string: "  " + duration, attributes: quiet))
        }
        if fullness.rawValue <= Fullness.shortMix.rawValue, !line.toolMix.isEmpty {
            let names = line.toolMix.split(separator: " ")
            let shown =
                fullness != .shortMix || names.count <= 3
                ? line.toolMix : names.prefix(3).joined(separator: " ") + " \u{2026}"
            out.append(NSAttributedString(string: "  " + shown, attributes: quiet))
        }
        var rest: [String] = []
        if fullness == .everything { rest = [line.thoughts, line.notes].compactMap { $0 } }
        if fullness.rawValue <= Fullness.withoutAsides.rawValue, let failure = line.failure {
            rest.append(failure)
        }
        if !rest.isEmpty {
            out.append(
                NSAttributedString(string: "  " + rest.joined(separator: " · "), attributes: quiet))
        }
        return out
    }

    /// The width the words may take, between the glyph and the pills.
    private var room: CGFloat {
        guard trailing.frame.minX > 0, glyph.frame.maxX > 0 else { return 0 }
        return trailing.frame.minX - Theme.Spacing.s - (glyph.frame.maxX + Theme.Spacing.s)
    }

    /// The richest reading that fits whole in the room there is. Before the first layout there is
    /// no room to measure, and the line is written in full for the layout to settle.
    private func fit(_ line: NeuralReading.Line) -> Fullness {
        if label.numberOfLines == 0 || room <= 0 {
            return .everything
        }
        for level in Fullness.allCases {
            let width = text(line, fullness: level).boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                options: .usesLineFragmentOrigin, context: nil
            ).width.rounded(.up)
            if width <= room { return level }
        }
        return .countOnly
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let reading, label.numberOfLines != 0 else { return }
        let level = fit(reading)
        guard level != lastDrawn else { return }
        lastDrawn = level
        label.attributedText = text(reading, fullness: level)
    }

    private var lastDrawn: Fullness = .everything

    @objc private func toggled() {
        Theme.Haptics.selection()
        onToggle?()
    }

    @objc private func rowsPressed() {
        Theme.Haptics.selection()
        onRows?()
    }

    @objc private func replayPressed() {
        Theme.Haptics.tap()
        onReplay?()
    }
}

extension BrainLine: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var items: [UIMenuElement] = []
            if self.canShare {
                items.append(
                    UIAction(
                        title: Localized.text("Share this turn"),
                        image: UIImage(systemName: "square.and.arrow.up")
                    ) { _ in self.onShare?() })
                items.append(
                    UIAction(
                        title: NeuralReading.replayLabel, image: UIImage(systemName: "play.circle")
                    ) { _ in self.onReplay?() })
            }
            items.append(
                UIAction(
                    title: NeuralReading.rowsLabel, image: UIImage(systemName: "list.bullet"),
                    state: self.showsRows ? .on : .off
                ) { _ in self.onRows?() })
            return UIMenu(children: items)
        }
    }
}

/// What the cell asks the chat to do, so it owns no state about the conversation.
struct BrainActions {
    var toggle: (String) -> Void
    var rows: (String) -> Void
    var replay: (String) -> Void
    var share: (String) -> Void
    var revealAgent: (String, String) -> Void
}

/// One turn's brain in the transcript: a collapsed line, and when open the stage under it, the
/// ticker, the scrubber once the turn has ended and the chips that point from the answer back to
/// the steps. The stage, and the textures it holds, exist only while the brain is open and the
/// cell is in use; closing it, scrolling it away and reusing the cell all let them go.
@MainActor
final class NeuralBrainCell: UICollectionViewCell, RowGapCell {
    static let reuseID = "NeuralBrainCell"

    private let container = UIView()
    private let line = BrainLine()
    private let body = UIStackView()
    private let holder = UIView()
    private let ticker = BrainTicker()
    private let scrubber = BrainScrubber()
    private let chips = BrainChips()
    private var stage: BrainStageView?
    private var stageWidth: NSLayoutConstraint?
    private var topConstraint: NSLayoutConstraint!
    private var foldedBottom: NSLayoutConstraint!
    private var openBottom: NSLayoutConstraint!
    private var bodyTop: NSLayoutConstraint!
    private var row: BrainRow?
    private weak var store: BrainStore?
    private var actions: BrainActions?
    private var inkCache: BrainInk?

    var brainStage: BrainStageView? { stage }

    var gapAbove: CGFloat = 0 {
        didSet { topConstraint.constant = gapAbove }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.layer.cornerRadius = Theme.Radius.card
        container.layer.cornerCurve = .continuous
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)

        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)

        body.axis = .vertical
        body.spacing = Theme.Spacing.xs
        body.translatesAutoresizingMaskIntoConstraints = false
        holder.translatesAutoresizingMaskIntoConstraints = false
        [holder, ticker, scrubber, chips].forEach(body.addArrangedSubview)
        ticker.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        body.isHidden = true
        container.addSubview(body)

        topConstraint = container.topAnchor.constraint(equalTo: contentView.topAnchor)
        foldedBottom = line.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        openBottom = body.bottomAnchor.constraint(
            equalTo: container.bottomAnchor, constant: -Theme.Spacing.m)
        bodyTop = body.topAnchor.constraint(equalTo: line.bottomAnchor)
        NSLayoutConstraint.activate([
            topConstraint,
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            container.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.s),
            container.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.s),
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            foldedBottom,
            bodyTop,
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),
        ])

        line.onToggle = { [weak self] in self?.send { $0.toggle } }
        line.onRows = { [weak self] in self?.send { $0.rows } }
        line.onReplay = { [weak self] in self?.send { $0.replay } }
        line.onShare = { [weak self] in self?.send { $0.share } }
        scrubber.onShare = { [weak self] in self?.send { $0.share } }
        scrubber.onPlayPause = { [weak self] in self?.playPause() }
        scrubber.onBegan = { [weak self] in self?.scrubBegan() }
        scrubber.onMoved = { [weak self] fraction in self?.scrubbed(to: fraction) }
        scrubber.onEnded = { [weak self] in self?.scrubEnded() }
        chips.onSelect = { [weak self] token in self?.pointAt(token) }
        scrubber.isHidden = true
        chips.isHidden = true
        ticker.isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        tearDownStage()
        row = nil
        store = nil
        actions = nil
    }

    /// Draws a brain row. The model is read from the store, never copied here, so a pin or a
    /// replay the person started survives the cell being configured again.
    func configure(_ new: BrainRow, store newStore: BrainStore, actions newActions: BrainActions) {
        row = new
        store = newStore
        actions = newActions
        guard let model = newStore.model(for: new.turnID) else { return }
        container.backgroundColor = new.isOpen ? Theme.Color.secondaryBackground : .clear
        line.show(model: model, row: new)
        setOpen(new.isOpen, model: model)
        if new.isOpen { stage?.configure(store: newStore, turnID: new.turnID) }
    }

    /// The conversation moved without this row changing: the line's clock, the ticker's step and
    /// the chips are read again, and nothing is rebuilt.
    func refreshLive() {
        guard let row, let store, let model = store.model(for: row.turnID) else { return }
        line.show(model: model, row: row)
        guard row.isOpen else { return }
        footer(model, time: CACurrentMediaTime())
    }

    private func send(_ pick: (BrainActions) -> ((String) -> Void)) {
        guard let row, let actions else { return }
        pick(actions)(row.turnID)
    }

    private func setOpen(_ open: Bool, model: NeuralBrainModel) {
        foldedBottom.isActive = !open
        openBottom.isActive = open
        bodyTop.constant = open ? Theme.Spacing.xs : 0
        body.isHidden = !open
        guard open else {
            tearDownStage()
            return
        }
        if stage == nil { buildStage() }
        footer(model, time: CACurrentMediaTime())
    }

    private func buildStage() {
        let view = BrainStageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(view)
        let width = view.widthAnchor.constraint(equalTo: holder.widthAnchor)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: holder.topAnchor),
            view.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            view.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            view.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            width,
            view.heightAnchor.constraint(
                equalTo: view.widthAnchor, multiplier: NeuralDesign.height / NeuralDesign.width),
        ])
        view.onChange = { [weak self] model, time in self?.footer(model, time: time) }
        view.onRevealAgent = { [weak self] id in
            guard let self, let row = self.row else { return }
            self.actions?.revealAgent(row.turnID, id)
        }
        stage = view
        stageWidth = width
    }

    private func tearDownStage() {
        stage?.removeFromSuperview()
        stage = nil
        stageWidth = nil
    }

    /// The ticker, the scrubber and the chips, from the model at `time`.
    private func footer(_ model: NeuralBrainModel, time: Double) {
        guard let store, let row else { return }
        let ink = ink(for: model)
        let live = model.turn.outcome == .running
        ticker.show(model.ticker(now: time), ink: ink)
        scrubber.isHidden = live
        if !live {
            let replaying: Bool
            if case .replaying = model.mode { replaying = true } else { replaying = false }
            let fraction = model.replayFraction(now: time) ?? 1
            let clock = model.replayTime(now: time).flatMap { model.timeline.clockLabel(at: $0) }
            let timeline = model.timeline
            let ticks = timeline.fireTimes.map { timeline.fraction(forTime: $0) }
            let total = model.steps.count
            scrubber.show(
                fraction: fraction, playing: replaying, clock: clock, ticks: ticks,
                spoken: { position in
                    let lit = timeline.litCount(at: timeline.time(forFraction: position))
                    return Localized.text("step %1$lld of %2$lld", max(lit, 1), total)
                })
        }
        if live || model.isReplaying {
            chips.isHidden = true
        } else {
            let answer = store.answerText(for: row.turnID)
            let tokens = answer.isEmpty ? [] : model.answerTokens(in: answer).map(\.text)
            var unique: [String] = []
            for token in tokens where !unique.contains(token) { unique.append(token) }
            chips.show(tokens: Array(unique.prefix(12)), selected: model.provenanceToken)
        }
    }

    private func ink(for model: NeuralBrainModel) -> BrainInk {
        let palette = BrainPalette.palette(for: traitCollection)
        if let held = inkCache, held.palette == palette, held.face == model.face { return held }
        let made = BrainInk(palette: palette, face: model.face)
        inkCache = made
        return made
    }


    private func change(_ body: (inout NeuralBrainModel) -> Void) {
        guard let row, let store else { return }
        store.mutate(row.turnID, body)
        stage?.refresh()
    }

    private func playPause() {
        guard let row, let model = store?.model(for: row.turnID) else { return }
        Theme.Haptics.tap()
        let now = CACurrentMediaTime()
        switch model.mode {
        case .live:
            change { $0.startReplay(now: now) }
        case .replaying:
            let fraction = model.replayFraction(now: now) ?? 0
            change { $0.scrub(to: fraction) }
        case .scrubbing(let fraction):
            let elapsed = model.timeline.time(forFraction: fraction)
            change { $0.startReplay(now: now - elapsed) }
        }
    }

    private func scrubBegan() {
        guard let row, let model = store?.model(for: row.turnID) else { return }
        let fraction = model.replayFraction(now: CACurrentMediaTime()) ?? 1
        change { $0.scrub(to: fraction) }
    }

    private func scrubbed(to fraction: Double) {
        change { $0.scrub(to: fraction) }
    }

    private func scrubEnded() {
        change { $0.endScrub() }
    }

    private func pointAt(_ token: String?) {
        change { $0.setProvenance(token: token) }
    }
}
