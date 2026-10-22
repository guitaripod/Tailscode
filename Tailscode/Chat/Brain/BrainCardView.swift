import CodingAgentKit
import TailscodeCore
import UIKit

/// A turn collapsed: one card whose picture is the head itself, lit where the turn worked, and
/// whose words are what the turn came to, in the reader's terms. The whole card is one button;
/// Replay and Rows, and the zone chips that open the brain already diving into a zone, are small
/// buttons on it that do not open it.
///
/// A running turn's card keeps the settled card's size and says what is happening now: the verdict
/// with its glyph, the counts ticking, the step in flight and the last line it printed, or the note
/// the agent has just written. When the turn ends the card settles in one 400 ms move, driven by
/// `NeuralCardSettle`, and a card that settles out of sight is simply settled when it arrives.
@MainActor
final class BrainCardView: UIView {
    var onOpen: (() -> Void)?
    var onReplay: (() -> Void)?
    var onRows: (() -> Void)?
    var onShare: (() -> Void)?
    var onDive: ((NeuralZone) -> Void)?
    var onPrefetch: (() -> Void)?

    /// The press and the pointer, which lift the card's lights and take its hairline to its tone.
    private(set) var isHovered = false {
        didSet { applyEmphasis() }
    }
    private var isPressed = false {
        didSet { applyEmphasis() }
    }

    private let surface = UIView()
    private let edge = CAShapeLayer()
    private let moveEdge = CAShapeLayer()
    private let textGroup = UIView()
    private let press = UIControl()
    let picture = BrainCardPicture()
    private let headline = UILabel()
    private let clauses = UILabel()
    private let liveHeadline = UILabel()
    private let liveCounts = UILabel()
    private let nowLabel = UILabel()
    private let nowTrailing = UILabel()
    private let quoteLabel = UILabel()
    private let third = UILabel()
    private let chipHost = UIView()
    private var chips: [BrainZoneChip] = []
    private let replay = CardButton()
    private let rows = CardButton()
    private let open = CardButton()

    private var model: NeuralBrainModel?
    private var row: BrainRow?
    private var card: NeuralBrainCard?
    private var metrics: NeuralStageMetrics?
    private var memory: BrainLiveMemory?
    private var ink: BrainInk?
    private var drawnSignature = ""
    private var layoutMemo: (key: String, layout: Layout)?
    private var settleLink: CADisplayLink?
    private var quoteRelease: DispatchWorkItem?
    private var lastLayout: Layout?
    private var settle = NeuralCardSettle.settled

    /// What a card drew, for the debug log and the checks.
    private(set) var drawn = (headline: "", chips: [String](), third: "", live: false)

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self, UITraitPreferredContentSizeCategory.self]) { (view: BrainCardView, _) in view.traitsChanged() }
        surface.layer.cornerRadius = 12
        surface.layer.cornerCurve = .continuous
        surface.layer.borderWidth = 1
        surface.layer.masksToBounds = true
        surface.isUserInteractionEnabled = false
        addSubview(surface)
        edge.lineWidth = 3
        edge.fillColor = nil
        surface.layer.addSublayer(edge)

        moveEdge.lineWidth = 3
        moveEdge.fillColor = nil
        moveEdge.isHidden = true
        layer.addSublayer(moveEdge)
        press.addTarget(self, action: #selector(pressed), for: .touchUpInside)
        press.addTarget(self, action: #selector(touchDown), for: .touchDown)
        press.addTarget(self, action: #selector(touchUp), for: [.touchUpOutside, .touchCancel, .touchUpInside])
        press.accessibilityTraits = .button
        addSubview(press)
        addSubview(picture)
        textGroup.isUserInteractionEnabled = true
        addSubview(textGroup)
        for label in [headline, clauses, liveHeadline, liveCounts, nowLabel, nowTrailing, quoteLabel, third] {
            label.isUserInteractionEnabled = false
            label.adjustsFontForContentSizeCategory = true
            label.lineBreakMode = .byTruncatingTail
            label.numberOfLines = 1
            textGroup.addSubview(label)
        }
        nowTrailing.textAlignment = .right
        chipHost.clipsToBounds = true
        textGroup.addSubview(chipHost)
        for button in [replay, rows, open] { textGroup.addSubview(button) }
        replay.onTap = { [weak self] in
            Theme.Haptics.tap()
            self?.onReplay?()
        }
        rows.onTap = { [weak self] in
            Theme.Haptics.selection()
            self?.onRows?()
        }
        open.onTap = { [weak self] in
            Theme.Haptics.selection()
            self?.onOpen?()
        }
        isAccessibilityElement = false
        installPointer()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        MainActor.assumeIsolated {
            settleLink?.invalidate()
            BrainLiveClock.shared.unregister(self)
        }
    }

    private func installPointer() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        press.addGestureRecognizer(hover)
        press.addInteraction(UIPointerInteraction(delegate: self))
        press.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            if !isHovered { onPrefetch?() }
            isHovered = true
        default: isHovered = false
        }
    }

    @objc private func touchDown() {
        isPressed = true
        onPrefetch?()
    }

    @objc private func touchUp() { isPressed = false }

    @objc private func pressed() {
        Theme.Haptics.selection()
        onOpen?()
    }

    private func applyEmphasis() {
        let lit = isHovered || isPressed
        picture.setHovered(lit)
        guard let card else { return }
        let tone = BrainCanvas.tone(card.edgeTone).resolvedColor(with: traitCollection)
        surface.layer.borderColor =
            (lit ? tone.wash(0.7) : Theme.Color.separator).resolvedColor(with: traitCollection).cgColor
    }

    private var density: ChatDensity { metrics?.density ?? .comfortable }
    private var isCompact: Bool { density == .compact }

    /// Draws the card for a turn at a row width. Nothing is rebuilt when nothing the card says
    /// changed.
    func configure(
        model newModel: NeuralBrainModel, row newRow: BrainRow, memory newMemory: BrainLiveMemory,
        metrics newMetrics: NeuralStageMetrics, now: Date = BrainDebug.now
    ) {
        model = newModel
        row = newRow
        memory = newMemory
        let changedWidth = metrics?.width != newMetrics.width || metrics?.density != newMetrics.density
        metrics = newMetrics
        let made = newModel.brainCard(now: now)
        card = made
        let palette = BrainPalette.palette(for: traitCollection)
        if ink == nil || ink?.palette != palette || ink?.face != newModel.face {
            ink = BrainInk(palette: palette, face: newModel.face)
        }
        if changedWidth { lastLayout = nil }
        rebuild(now: now)
        requestPictures()
        registerClock()
        setNeedsLayout()
    }

    /// The time moved, or the model did: the words that depend on either are written again.
    func refresh(model newModel: NeuralBrainModel, now: Date = BrainDebug.now) {
        guard row != nil, metrics != nil else { return }
        let before = card?.edge
        model = newModel
        card = newModel.brainCard(now: now)
        if let before, before != .waiting, card?.edge == .waiting, window != nil { Theme.Haptics.needsYou() }
        rebuild(now: now)
        registerClock()
    }

    private var isLive: Bool { card?.live != nil }

    private func registerClock() {
        if isLive, window != nil {
            BrainLiveClock.shared.register(self) { [weak self] in self?.clockTick() }
        } else {
            BrainLiveClock.shared.unregister(self)
        }
    }

    private func clockTick() {
        guard let model, isLive else { return }
        refresh(model: model, now: BrainDebug.now)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        registerClock()
        if window == nil {
            settleLink?.invalidate()
            settleLink = nil
        } else {
            requestPictures()
        }
    }

    private func traitsChanged() {
        drawnSignature = ""
        restPicture = nil
        livePictures = nil
        lastLayout = nil
        ink = nil
        if let model, let row, let memory, let metrics {
            configure(model: model, row: row, memory: memory, metrics: metrics)
        }
    }

    /// The settle move, from `NeuralCardSettle`, applied to the card's two sets of words, the
    /// picture and the edge.
    private func apply(settle value: NeuralCardSettle) {
        settle = value
        liveHeadline.alpha = CGFloat(value.liveHeadlineAlpha)
        liveCounts.alpha = CGFloat(value.liveHeadlineAlpha)
        liveHeadline.transform = CGAffineTransform(translationX: 0, y: CGFloat(value.liveHeadlineOffsetY))
        liveCounts.transform = liveHeadline.transform
        headline.alpha = CGFloat(value.settledHeadlineAlpha)
        clauses.alpha = CGFloat(value.settledHeadlineAlpha)
        headline.transform = CGAffineTransform(translationX: 0, y: CGFloat(value.settledHeadlineOffsetY))
        clauses.transform = headline.transform
        for label in [nowLabel, nowTrailing, quoteLabel] { label.alpha = CGFloat(value.nowLineAlpha) }
        third.alpha = CGFloat(value.firstWordsAlpha)
        picture.setLiveShare(CGFloat(1 - value.lights))
        edge.removeAnimation(forKey: "pulse")
    }

    private func rebuild(now: Date) {
        guard let card, let model, let row, let metrics, let memory else { return }
        let line = card.live.map {
            memory.line(for: $0, now: now, compact: isCompact)
        }
        let reading = card.live.map { $0.reading(now: now, lastActivity: memory.lastActivity) }
        var signature = [
            card.headline.pieces.map(\.text).joined(separator: "|"),
            card.chips.map { "\($0.zone)\($0.count)\($0.tone)" }.joined(separator: ","),
            card.digest, card.quote.map { $0.speaker + $0.words } ?? "",
            "\(metrics.width)|\(density)|\(row.showsRows)|\(isHovered)",
        ].joined(separator: "#")
        if let reading, let line {
            signature += "#live#\(reading.word)|\(reading.counts)|\(line.title)|\(line.argument ?? "")|\(line.kind)"
            switch line.trailing {
            case .output(let text, let tone): signature += "|o\(text)\(tone)"
            case .silence(let text): signature += "|s\(text)"
            case .none: break
            }
        }
        let settledNow = memory.settleClock.settleStartedAt != nil
        signature += "#\(settledNow)"
        guard signature != drawnSignature else { return }
        drawnSignature = signature

        let settling = memory.settleClock.isSettling(now: CACurrentMediaTime())
        if settling, !isLive { startSettle() }

        surface.backgroundColor = Theme.Color.secondaryBackground
        applyEdge(card)
        applyEmphasis()
        buildHeadlines(card, reading: reading)
        buildChips(card)
        buildThird(card, line: line)
        buttons(model: model, row: row, live: isLive)
        picture.configure(card: card, ink: ink ?? BrainInk(palette: BrainPalette.palette(for: traitCollection), face: model.face), hovered: isHovered)
        if !settling && !isLive {
            apply(settle: .settled)
        } else if isLive {
            apply(settle: .live)
        }
        drawn = (
            card.headline.pieces.map(\.text).joined(separator: " "),
            card.chips.map { "\($0.label) \($0.count)" },
            third.attributedText?.string ?? nowLabel.attributedText?.string ?? "", isLive)
        isAccessibilityElement = false
        press.isAccessibilityElement = true
        press.accessibilityLabel = Localized.text(
            "%1$@, %2$@", Localized.text("Megatron"),
            isLive ? liveSpoken(card, reading: reading) : card.spoken)
        press.accessibilityValue = row.isOpen ? Localized.text("Expanded") : Localized.text("Collapsed")
        press.accessibilityHint = Localized.text("Double tap to open Megatron")
        press.accessibilityCustomActions = actions(card: card, model: model)
        setNeedsLayout()
    }

    private func liveSpoken(_ card: NeuralBrainCard, reading: NeuralLiveCard.Reading?) -> String {
        guard let reading else { return card.spoken }
        return Localized.text("%1$@, %2$@", reading.word, reading.counts)
    }

    private func actions(card: NeuralBrainCard, model: NeuralBrainModel) -> [UIAccessibilityCustomAction] {
        var out: [UIAccessibilityCustomAction] = []
        if model.turn.outcome != .running {
            out.append(
                UIAccessibilityCustomAction(name: NeuralReading.replayLabel) { [weak self] _ in
                    self?.onReplay?()
                    return true
                })
            out.append(
                UIAccessibilityCustomAction(name: Localized.text("Share this turn")) { [weak self] _ in
                    self?.onShare?()
                    return true
                })
        }
        out.append(
            UIAccessibilityCustomAction(name: NeuralReading.rowsLabel) { [weak self] _ in
                self?.onRows?()
                return true
            })
        for chip in card.chips {
            let zone = chip.zone
            out.append(
                UIAccessibilityCustomAction(
                    name: Localized.text("Dive into %@", chip.label)
                ) { [weak self] _ in
                    self?.onDive?(zone)
                    return true
                })
        }
        return out
    }

    private func applyEdge(_ card: NeuralBrainCard) {
        let tone = BrainCanvas.tone(card.edgeTone).resolvedColor(with: traitCollection)
        edge.strokeColor = tone.cgColor
        edge.lineDashPattern = card.edge == .stopped ? [6, 4] : nil
        edge.removeAnimation(forKey: "pulse")
        guard let live = card.live, live.edgePulses, !UIAccessibility.isReduceMotionEnabled,
            settle.progress < 1 || memory?.settleClock.settleStartedAt == nil,
            let animation = BrainSwell.level(for: live.motion)
        else { return }
        edge.setRepeatingMotion(
            animation, forKey: "pulse", meaning: live.motion == .heartbeat ? .attention : .working)
    }

    private func buildHeadlines(_ card: NeuralBrainCard, reading: NeuralLiveCard.Reading?) {
        let split = Self.countPieces(card)
        let main = NSMutableAttributedString(
            string: split.number,
            attributes: Theme.Ramp.attributes(.metricLarge, color: Theme.Color.label))
        if !split.unit.isEmpty {
            main.append(
                NSAttributedString(
                    string: " " + split.unit,
                    attributes: Theme.Ramp.attributes(.panelLabel, color: Theme.Color.secondaryLabel)))
        }
        if let duration = card.headline.piece(.duration) {
            main.append(
                NSAttributedString(
                    string: "  " + duration.text,
                    attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel)))
        }
        let tail = NSMutableAttributedString()
        if let tally = card.headline.piece(.tally) {
            for word in tally.text.split(separator: " ") {
                if tail.length > 0 { tail.append(NSAttributedString(string: " ")) }
                tail.append(
                    NSAttributedString(
                        string: String(word),
                        attributes: Theme.Ramp.attributes(
                            .rowMeta,
                            color: word.hasPrefix("+") ? Theme.Color.accent : Theme.Color.danger)))
            }
        }
        for kind in [NeuralBrainCard.Piece.Kind.failure, .state] {
            guard let piece = card.headline.piece(kind) else { continue }
            if tail.length > 0 { tail.append(NSAttributedString(string: "  ")) }
            let ink = piece.tone.map { BrainCanvas.tone($0) } ?? Theme.Color.secondaryLabel
            if kind == .failure, let name = Self.clauseSymbol(card.verdict),
                let image = BrainCanvas.image(name, size: 11)
            {
                let attachment = NSTextAttachment()
                attachment.image = image.withTintColor(ink, renderingMode: .alwaysOriginal)
                attachment.bounds = CGRect(x: 0, y: -1.5, width: 11, height: 11)
                tail.append(NSAttributedString(attachment: attachment))
                tail.append(NSAttributedString(string: " "))
            }
            tail.append(
                NSAttributedString(
                    string: piece.text, attributes: Theme.Ramp.attributes(.rowMeta, color: ink)))
        }
        wideHeadline = NSMutableAttributedString(attributedString: main)
        if tail.length > 0 {
            wideHeadline.append(NSAttributedString(string: "   "))
            wideHeadline.append(tail)
        }
        headline.attributedText = wideHeadline
        narrowMain = main
        clauses.attributedText = tail

        if let reading, card.live != nil {
            let verdictInk = BrainCanvas.tone(reading.tone)
            let word = NSMutableAttributedString()
            if let image = BrainCanvas.image(BrainCanvas.symbol(for: reading.glyph), size: reading.glyph == .pulse ? 8 : 12) {
                let attachment = NSTextAttachment()
                attachment.image = image.withTintColor(verdictInk, renderingMode: .alwaysOriginal)
                let size = image.size
                attachment.bounds = CGRect(x: 0, y: reading.glyph == .pulse ? 1 : -1, width: size.width, height: size.height)
                word.append(NSAttributedString(attachment: attachment))
                word.append(NSAttributedString(string: " "))
            }
            word.append(
                NSAttributedString(
                    string: reading.word,
                    attributes: Theme.Ramp.attributes(.cardTitle, color: verdictInk)))
            liveHeadline.attributedText = word
            liveCounts.attributedText = NSAttributedString(
                string: reading.counts,
                attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel))
        } else {
            liveHeadline.attributedText = nil
            liveCounts.attributedText = nil
        }
    }

    private var wideHeadline = NSMutableAttributedString()
    private var narrowMain = NSAttributedString()

    private static func clauseSymbol(_ verdict: NeuralVerdict.Turn) -> String? {
        switch verdict {
        case .doneAfterRetries: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .failed: return "xmark"
        default: return nil
        }
    }

    private static func countPieces(_ card: NeuralBrainCard) -> (number: String, unit: String) {
        let count = card.headline.count
        let number = String(card.headline.number)
        guard count.hasPrefix(number) else { return (count, "") }
        return (number, count.dropFirst(number.count).trimmingCharacters(in: .whitespaces))
    }

    private func buildChips(_ card: NeuralBrainCard) {
        let wanted = card.chips
        while chips.count < wanted.count {
            let chip = BrainZoneChip(height: isCompact ? 24 : 28)
            chipHost.addSubview(chip)
            chips.append(chip)
        }
        for (index, chip) in chips.enumerated() {
            guard index < wanted.count else {
                chip.isHidden = true
                continue
            }
            let item = wanted[index]
            chip.configure(
                BrainZoneChip.Content(
                    zone: item.zone, count: item.count, tone: item.tone, showsWord: true, isOn: false,
                    word: item.label))
            chip.onTap = { [weak self] in self?.onDive?(item.zone) }
            chip.isAccessibilityElement = false
        }
    }

    private func buildThird(_ card: NeuralBrainCard, line: NeuralLiveCard.Line?) {
        if let quote = card.quote {
            third.attributedText = Self.quoteText(
                speaker: quote.speaker, words: quote.words, fit: nil, ink: Theme.Color.label)
            quoteSource = (quote.speaker, quote.words)
        } else {
            third.attributedText = NSAttributedString(
                string: card.digest,
                attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.secondaryLabel))
            quoteSource = nil
        }
        guard let line else {
            nowLabel.attributedText = nil
            nowTrailing.attributedText = nil
            quoteLabel.attributedText = nil
            return
        }
        switch line.kind {
        case .quote:
            let quote = line.quote
            quoteLabel.attributedText = Self.quoteText(
                speaker: quote?.speaker ?? "", words: quote?.words ?? "", fit: nil, ink: Theme.Color.label)
            nowLabel.attributedText = nil
            nowTrailing.attributedText = nil
        case .step:
            quoteLabel.attributedText = nil
            let text = NSMutableAttributedString(
                string: line.title,
                attributes: Theme.Ramp.attributes(.rowTitleStrong, color: Theme.Color.label))
            if let argument = line.argument, !argument.isEmpty {
                text.append(
                    NSAttributedString(
                        string: "  " + argument,
                        attributes: Theme.Ramp.attributes(.rowDetail, color: Theme.Color.secondaryLabel)))
            }
            nowLabel.attributedText = text
            switch line.trailing {
            case .output(let output, let tone):
                nowTrailing.attributedText = NSAttributedString(
                    string: output,
                    attributes: Theme.Ramp.attributes(
                        .rowDetail,
                        color: tone == .attention ? Theme.Color.warning : Theme.Color.secondaryLabel,
                        alignment: .right))
            case .silence(let words):
                let silent = NSMutableAttributedString()
                if let image = BrainCanvas.image("clock.badge.exclamationmark", size: 11) {
                    let attachment = NSTextAttachment()
                    attachment.image = image.withTintColor(Theme.Color.warning.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
                    attachment.bounds = CGRect(x: 0, y: -1.5, width: 12, height: 11)
                    silent.append(NSAttributedString(attachment: attachment))
                    silent.append(NSAttributedString(string: " "))
                }
                silent.append(
                    NSAttributedString(
                        string: words,
                        attributes: Theme.Ramp.attributes(
                            .rowDetail, color: Theme.Color.warning, alignment: .right)))
                nowTrailing.attributedText = silent
            case .none:
                nowTrailing.attributedText = nil
            }
        }
        if line.kind == .quote, let memory, let arrived = memory.quoteArrivals[line.quote?.stepID ?? ""] {
            scheduleQuoteRelease(after: NeuralLiveCard.quoteHold - BrainDebug.now.timeIntervalSince(arrived))
        }
    }

    private var quoteSource: (speaker: String, words: String)?

    private func scheduleQuoteRelease(after seconds: TimeInterval) {
        quoteRelease?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.clockTick() }
        }
        quoteRelease = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, seconds + 0.05), execute: item)
    }

    /// The agent's own words as a line: the quote mark and its name in the accent, the words in
    /// italic ink. `fit` cuts the words at a whole word to what a width can say.
    private static func quoteText(
        speaker: String, words: String, fit width: CGFloat?, ink: UIColor
    ) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: "\u{201C} ",
            attributes: Theme.Ramp.attributes(.cardTitle, color: Theme.Color.accent))
        out.append(
            NSAttributedString(
                string: speaker + "  ",
                attributes: Theme.Ramp.attributes(.rowTitleStrong, color: Theme.Color.accent)))
        out.append(
            NSAttributedString(
                string: words, attributes: Theme.Ramp.attributes(.thought, color: ink)))
        return out
    }

    /// The quote cut at a whole word to the room the line has.
    private func fittedQuote(width: CGFloat) -> NSAttributedString? {
        guard let source = quoteSource else { return nil }
        var best = Self.quoteText(
            speaker: source.speaker,
            words: NeuralAccount.quote(of: source.words, maxChars: 8), fit: nil, ink: Theme.Color.label)
        var characters = 12
        let limit = source.words.count + 8
        while characters <= limit + 12 {
            let words = NeuralAccount.quote(of: source.words, maxChars: characters)
            let candidate = Self.quoteText(
                speaker: source.speaker, words: words, fit: nil, ink: Theme.Color.label)
            guard candidate.size().width.rounded(.up) <= width else { break }
            best = candidate
            if words == NeuralAccount.quote(of: source.words, maxChars: Int.max / 4) { break }
            characters += 4
        }
        return best
    }

    private func fittedDigest(width: CGFloat, card: NeuralBrainCard) -> NSAttributedString {
        var best = card.digest(fitting: 0)
        var characters = 24
        let limit = card.digest.count
        let attributes = Theme.Ramp.attributes(.cardBody, color: Theme.Color.secondaryLabel)
        while characters <= limit + 24 {
            let candidate = card.digest(fitting: characters)
            guard NSAttributedString(string: candidate, attributes: attributes).size().width.rounded(.up) <= width
            else { break }
            best = candidate
            if candidate == card.digest { break }
            characters += 6
        }
        return NSAttributedString(string: best, attributes: attributes)
    }

    private func buttons(model: NeuralBrainModel, row: BrainRow, live: Bool) {
        replay.set(
            title: NeuralReading.replayLabel, symbol: "play.fill", on: false, compact: isCompact)
        rows.set(title: NeuralReading.rowsLabel, symbol: nil, on: row.showsRows, compact: isCompact)
        open.set(title: Localized.text("Open"), symbol: nil, on: false, compact: isCompact)
        replay.isHidden = false
        replay.isEnabled = !(live || model.steps.count <= 1)
        replay.accessibilityLabel = NeuralReading.replayLabel
        rows.accessibilityLabel = NeuralReading.rowsLabel
        rows.accessibilityTraits = row.showsRows ? [.button, .selected] : .button
        open.isHidden = !live
        rows.isHidden = live
        for button in [replay, rows, open] { button.isAccessibilityElement = false }
    }

    private struct PictureKey: Equatable {
        var frame: NeuralFrame
        var palette: Palette
        var face: NeuralFace
        var width: Int
    }

    private var restPicture: PictureKey?
    private var livePictures: (floor: PictureKey, peak: PictureKey)?

    private func requestPictures() {
        guard let model, let metrics, let card, window != nil else { return }
        let scale = max(1, picture.pixelScale)
        let palette = BrainPalette.palette(for: traitCollection)
        let wholeWidth =
            CGFloat(metrics.card.picture.width * NeuralDesign.width / NeuralStageMetrics.designWidth)
        let restFrame = model.frame(time: 0, reduceMotion: true)
        let pixels = Int(wholeWidth * scale)
        let restKey = PictureKey(frame: restFrame, palette: palette, face: model.face, width: pixels)
        if restPicture != restKey || !picture.hasRest {
            restPicture = restKey
            BrainPictures.picture(
                frame: restFrame, palette: palette, face: model.face, width: wholeWidth, scale: scale
            ) { [weak self] made in
                guard let self, self.restPicture == restKey else { return }
                self.picture.setRest(made, animated: true)
            }
        }
        if let live = card.live {
            let times = BrainSwellTimes.floorAndPeak(live.motion)
            let floorFrame = model.frame(time: times.floor, reduceMotion: false)
            let peakFrame = model.frame(time: times.peak, reduceMotion: false)
            let floorKey = PictureKey(frame: floorFrame, palette: palette, face: model.face, width: pixels)
            let peakKey = PictureKey(frame: peakFrame, palette: palette, face: model.face, width: pixels)
            if livePictures?.floor != floorKey || livePictures?.peak != peakKey {
                livePictures = (floorKey, peakKey)
                var pair: [BrainPicture?] = [nil, nil]
                var arrived = 0
                for (index, frame) in [floorFrame, peakFrame].enumerated() {
                    BrainPictures.picture(
                        frame: frame, palette: palette, face: model.face, width: wholeWidth,
                        scale: scale
                    ) { [weak self] made in
                        pair[index] = made
                        arrived += 1
                        guard arrived == 2, let self, self.livePictures?.floor == floorKey,
                            self.livePictures?.peak == peakKey
                        else { return }
                        self.picture.setLive(floor: pair[0], peak: pair[1])
                        self.picture.setSwell(live.motion)
                        if self.isLive { self.picture.setLiveShare(1) }
                    }
                }
            }
        } else if livePictures != nil, !settleRunning {
            livePictures = nil
            picture.setLive(floor: nil, peak: nil)
        }
    }

    private var hapticSettle: TimeInterval?

    private var settleRunning: Bool { settleLink != nil }

    private func startSettle() {
        guard window != nil else { return }
        if let started = memory?.settleClock.settleStartedAt, started != hapticSettle {
            hapticSettle = started
            Theme.Haptics.received()
        }
        guard !UIAccessibility.isReduceMotionEnabled, settleLink == nil else { return }
        let link = CADisplayLink(target: BrainSettleTarget(self), selector: #selector(BrainSettleTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        settleLink = link
    }

    fileprivate func settleStep() {
        guard let memory else {
            settleLink?.invalidate()
            settleLink = nil
            return
        }
        let value = memory.settleClock.settle(now: CACurrentMediaTime())
        apply(settle: value)
        layoutTexts(animated: false)
        if value.isDone {
            settleLink?.invalidate()
            settleLink = nil
            livePictures = nil
            picture.setLive(floor: nil, peak: nil)
            drawnSignature = ""
            if let model { refresh(model: model) }
        }
    }

    private var moveOffsetX: CGFloat = 0

    /// What the move between this card and the open brain does to the card, from a frame: the text
    /// fades and slides, the surface fades, the picture is the traveller's and goes, the lights stay
    /// where they are or return, and the tone edge rides the picture's left edge for a moment.
    func applyMove(frame: NeuralTransitionFrame, opening: Bool, originX: CGFloat = 0) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        textGroup.alpha = CGFloat(frame.cardTextAlpha)
        moveOffsetX = CGFloat(frame.cardTextOffsetX)
        textGroup.center = CGPoint(x: bounds.midX + moveOffsetX, y: bounds.midY)
        surface.backgroundColor = Theme.Color.secondaryBackground.withAlphaComponent(CGFloat(frame.cardSurfaceAlpha))
        surface.layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection)
            .withAlphaComponent(CGFloat(frame.cardSurfaceAlpha)).cgColor
        picture.setMoving(
            imageAlpha: CGFloat(frame.cardPictureAlpha), lightsAlpha: CGFloat(frame.cardLightsAlpha))
        edge.isHidden = true
        moveEdge.isHidden = false
        moveEdge.strokeColor = edge.strokeColor
        let path = CGMutablePath()
        path.move(to: CGPoint(x: frame.edge.x - originX + 1.5, y: 0))
        path.addLine(to: CGPoint(x: frame.edge.x - originX + 1.5, y: bounds.height))
        moveEdge.path = path
        moveEdge.frame = bounds
        moveEdge.opacity = Float(frame.edge.alpha)
    }

    /// The card as it stands when no move is running.
    func clearMove() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        textGroup.alpha = 1
        moveOffsetX = 0
        textGroup.center = CGPoint(x: bounds.midX, y: bounds.midY)
        surface.backgroundColor = Theme.Color.secondaryBackground
        applyEmphasis()
        picture.setMoving(imageAlpha: 1, lightsAlpha: 1)
        edge.isHidden = false
        moveEdge.isHidden = true
    }

    private struct Layout {
        var height: CGFloat
        var headline: CGRect
        var clauses: CGRect
        var liveHeadline: CGRect
        var liveCounts: CGRect
        var chips: [CGRect]
        var third: CGRect
        var now: CGRect
        var trailing: CGRect
        var quote: CGRect
        var replay: CGRect
        var rows: CGRect
        var open: CGRect
        var narrow: Bool
    }

    /// What the card needs in height at this width: the metrics' height, or more when the reader's
    /// type is large enough that the lines would not fit in it.
    func requiredHeight(width: CGFloat) -> CGFloat {
        guard let metrics else { return 0 }
        return max(CGFloat(metrics.card.height), fittedLayout(width: width).height)
    }

    /// The card's layout at a width. Measuring its lines is what a card costs the main thread
    /// most, and every state a conversation emits asks the transcript to size every card again, so
    /// a layout is kept for what it was made from: the words drawn (`drawnSignature` changes with
    /// any of them), the width, the metrics' height and the reader's type size.
    private func fittedLayout(width: CGFloat) -> Layout {
        guard !drawnSignature.isEmpty, let metrics else { return computeLayout(width: width) }
        let key =
            "\(drawnSignature)|\(Int(width * 4))|\(metrics.card.height)|\(traitCollection.preferredContentSizeCategory.rawValue)"
        if let memo = layoutMemo, memo.key == key { return memo.layout }
        let made = computeLayout(width: width)
        layoutMemo = (key, made)
        return made
    }

    private func computeLayout(width: CGFloat) -> Layout {
        guard let metrics, let card else {
            return Layout(
                height: 0, headline: .zero, clauses: .zero, liveHeadline: .zero, liveCounts: .zero,
                chips: [], third: .zero, now: .zero, trailing: .zero, quote: .zero, replay: .zero,
                rows: .zero, open: .zero, narrow: false)
        }
        let geometry = metrics.card
        let narrow = geometry.layout == .narrow
        let textX = CGFloat(geometry.text.x)
        let trailingInset: CGFloat = 12
        let textWidth = max(0, width - textX - trailingInset)
        let live = card.live != nil
        let buttonHeight: CGFloat = isCompact ? 26 : 28
        let buttonSet: [CardButton] = live ? [replay, open] : [replay, rows]
        let sizes = buttonSet.map { $0.fitted(height: buttonHeight) }
        let buttonsWidth = sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * 6
        let gap: CGFloat = isCompact ? 4 : 6
        func lineSize(_ label: UILabel, width limit: CGFloat) -> CGSize {
            guard let text = label.attributedText, text.length > 0 else { return .zero }
            return CGSize(
                width: ceil(text.size().width),
                height: BrainText.height(text, width: max(limit, 1), lines: label.numberOfLines))
        }
        func buttonFrames(origin: CGPoint) -> (replay: CGRect, second: CGRect) {
            let first = CGRect(origin: origin, size: sizes[0])
            let second = CGRect(
                x: first.maxX + 6, y: origin.y, width: sizes[1].width, height: sizes[1].height)
            return (first, second)
        }
        var layout = Layout(
            height: CGFloat(geometry.height), headline: .zero, clauses: .zero, liveHeadline: .zero,
            liveCounts: .zero, chips: [], third: .zero, now: .zero, trailing: .zero, quote: .zero,
            replay: .zero, rows: .zero, open: .zero, narrow: narrow)
        let rest: CGFloat = isCompact ? 6 : 8
        if !narrow {
            let headlineWidth = max(0, textWidth - buttonsWidth - 10)
            let settledHeight = lineSize(headline, width: headlineWidth).height
            let liveHeight = max(
                lineSize(liveHeadline, width: headlineWidth).height,
                lineSize(liveCounts, width: headlineWidth).height)
            let headlineHeight = max(settledHeight, liveHeight, isCompact ? 22 : 28)
            let chipHeight: CGFloat = isCompact ? 24 : 28
            let thirdHeight = max(
                lineSize(third, width: textWidth).height,
                lineSize(nowLabel, width: textWidth).height, 18)
            let parts = card.fit(width: width)
            let hasChips = parts.contains(.zoneStrip)
            let hasThird = parts.contains(.digest) || live
            var total = headlineHeight
            if hasChips { total += gap + chipHeight }
            if hasThird { total += gap + thirdHeight }
            let height = max(CGFloat(geometry.height), total + rest * 2)
            var y = max(rest, ((height - total) / 2).rounded(.down))
            layout.height = height
            layout.headline = CGRect(x: textX, y: y, width: headlineWidth, height: headlineHeight)
            let countsX = textX
            layout.liveHeadline = CGRect(x: countsX, y: y, width: 0, height: headlineHeight)
            y += headlineHeight
            if hasChips {
                y += gap
                var x = textX
                var frames: [CGRect] = []
                for chip in chips where !chip.isHidden {
                    let size = chip.intrinsicContentSize
                    guard x + size.width <= textX + textWidth + 1 else {
                        frames.append(.zero)
                        continue
                    }
                    frames.append(CGRect(x: x, y: y, width: size.width, height: chipHeight))
                    x += size.width + 6
                }
                layout.chips = frames
                y += chipHeight
            }
            if hasThird {
                y += gap
                layout.third = CGRect(x: textX, y: y, width: textWidth, height: thirdHeight)
                layout.quote = layout.third
                let trailingWidth = min(
                    lineSize(nowTrailing, width: textWidth).width, (textWidth * 0.42).rounded())
                layout.trailing = CGRect(
                    x: textX + textWidth - trailingWidth, y: y, width: trailingWidth, height: thirdHeight)
                layout.now = CGRect(
                    x: textX, y: y, width: max(0, textWidth - trailingWidth - 8), height: thirdHeight)
            }
            let origin = CGPoint(x: width - 12 - buttonsWidth, y: 8)
            let frames = buttonFrames(origin: origin)
            layout.replay = frames.replay
            if live { layout.open = frames.second } else { layout.rows = frames.second }
        } else {
            let mainHeight = max(lineSize(headline, width: textWidth).height, isCompact ? 20 : 26)
            let mainWidth = textWidth
            let clauseHeight = max(lineSize(clauses, width: textWidth).height, 0)
            let liveVerdict = lineSize(liveHeadline, width: textWidth).height
            let liveCountHeight = lineSize(liveCounts, width: textWidth).height
            let nowHeight = max(
                lineSize(nowLabel, width: textWidth).height, lineSize(quoteLabel, width: textWidth).height)
            var total: CGFloat
            if live {
                total = max(liveVerdict, 20)
                if !isCompact { total += 2 + liveCountHeight }
                total += gap + max(nowHeight, 16)
            } else {
                total = max(mainHeight, 20)
                if clauseHeight > 0 { total += 2 + clauseHeight }
            }
            total += gap + buttonHeight
            let height = max(CGFloat(geometry.height), total + rest * 2)
            var y = max(rest - 2, ((height - total) / 2).rounded(.down))
            layout.height = height
            if live {
                layout.liveHeadline = CGRect(x: textX, y: y, width: textWidth, height: max(liveVerdict, 20))
                y += max(liveVerdict, 20)
                if !isCompact {
                    y += 2
                    layout.liveCounts = CGRect(x: textX, y: y, width: textWidth, height: liveCountHeight)
                    y += liveCountHeight
                } else {
                    let verdictWidth = ceil(liveHeadline.attributedText?.size().width ?? 0) + 8
                    layout.liveHeadline.size.width = verdictWidth
                    layout.liveCounts = CGRect(
                        x: textX + verdictWidth, y: layout.liveHeadline.minY,
                        width: max(0, textWidth - verdictWidth), height: max(liveVerdict, 20))
                }
                y += gap
                layout.now = CGRect(x: textX, y: y, width: textWidth, height: max(nowHeight, 16))
                layout.quote = layout.now
                layout.trailing = .zero
                y += max(nowHeight, 16)
            } else {
                layout.headline = CGRect(x: textX, y: y, width: mainWidth, height: max(mainHeight, 20))
                layout.liveHeadline = layout.headline
                y += max(mainHeight, 20)
                if clauseHeight > 0 {
                    y += 2
                    layout.clauses = CGRect(x: textX, y: y, width: textWidth, height: clauseHeight)
                    y += clauseHeight
                }
            }
            y += gap
            let frames = buttonFrames(origin: CGPoint(x: textX, y: y))
            layout.replay = frames.replay
            if live { layout.open = frames.second } else { layout.rows = frames.second }
        }
        return layout
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutTexts(animated: false)
    }

    private func layoutTexts(animated: Bool) {
        guard let metrics, let card, bounds.width > 0 else { return }
        surface.frame = bounds
        press.frame = bounds
        textGroup.bounds = CGRect(origin: .zero, size: bounds.size)
        textGroup.center = CGPoint(x: bounds.midX + moveOffsetX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.path = {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 1.5, y: 0))
            path.addLine(to: CGPoint(x: 1.5, y: bounds.height))
            return path
        }()
        edge.frame = bounds
        CATransaction.commit()
        picture.frame = CGRect(
            x: metrics.card.picture.x, y: metrics.card.picture.y, width: metrics.card.picture.width,
            height: metrics.card.picture.height)
        let layout = fittedLayout(width: bounds.width)
        let live = card.live != nil || settle.progress < 1 && memory?.settleClock.settleStartedAt != nil
        lastLayout = layout
        let wide = !layout.narrow
        let showsLiveGroup = live
        headline.isHidden = false
        headline.attributedText = wide ? wideHeadline : narrowMain
        headline.frame = layout.headline
        clauses.isHidden = wide
        clauses.frame = layout.clauses
        liveHeadline.isHidden = !showsLiveGroup
        liveCounts.isHidden = !showsLiveGroup
        if wide {
            let headlineWidth = layout.headline.width
            let verdict = liveHeadline.attributedText?.size().width.rounded(.up) ?? 0
            let counts = liveCounts.attributedText?.size().width.rounded(.up) ?? 0
            let verdictFrame = CGRect(
                x: layout.headline.minX, y: layout.headline.minY,
                width: min(verdict + 2, headlineWidth), height: layout.headline.height)
            liveHeadline.frame = verdictFrame
            liveCounts.frame = CGRect(
                x: verdictFrame.maxX + 10, y: layout.headline.minY,
                width: max(0, min(counts + 2, headlineWidth - verdictFrame.width - 10)),
                height: layout.headline.height)
            liveHeadline.textAlignment = .natural
        } else {
            liveHeadline.frame = layout.liveHeadline
            liveCounts.frame = layout.liveCounts
        }
        liveCounts.isHidden = liveCounts.isHidden || (layout.liveCounts == .zero && layout.narrow)
        chipHost.frame = bounds
        var visible = 0
        var index = 0
        for chip in chips {
            if chip.isHidden && index >= card.chips.count { continue }
            defer { index += 1 }
            guard visible < layout.chips.count else {
                chip.isHidden = true
                continue
            }
            let frame = layout.chips[visible]
            visible += 1
            chip.isHidden = frame == .zero
            chip.frame = frame
        }
        for hidden in chips.dropFirst(card.chips.count) { hidden.isHidden = true }
        let hasThird = layout.third != .zero
        third.isHidden = !hasThird || !wide && true
        third.frame = layout.third
        if hasThird, !third.isHidden {
            if quoteSource != nil {
                third.attributedText = fittedQuote(width: layout.third.width) ?? third.attributedText
            } else {
                third.attributedText = fittedDigest(width: layout.third.width, card: card)
            }
        }
        nowLabel.frame = layout.now
        nowLabel.isHidden = card.live == nil && settle.nowLineAlpha <= 0
        nowTrailing.frame = layout.trailing
        nowTrailing.isHidden = nowLabel.isHidden || layout.trailing == .zero
        quoteLabel.frame = layout.quote
        quoteLabel.isHidden = nowLabel.isHidden || quoteLabel.attributedText == nil
        if quoteLabel.attributedText != nil { nowLabel.isHidden = true; nowTrailing.isHidden = true }
        replay.frame = layout.replay
        rows.frame = layout.rows
        open.frame = layout.open
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: requiredHeight(width: size.width))
    }
}

private final class BrainSettleTarget {
    weak var card: BrainCardView?
    init(_ card: BrainCardView) { self.card = card }

    @objc @MainActor func step(_ link: CADisplayLink) {
        guard let card else {
            link.invalidate()
            return
        }
        card.settleStep()
    }
}

extension BrainCardView: UIPointerInteractionDelegate {
    func pointerInteraction(
        _ interaction: UIPointerInteraction, styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        guard let view = interaction.view else { return nil }
        let preview = UITargetedPreview(view: view)
        return UIPointerStyle(effect: .hover(preview, preferredTintMode: .none, prefersShadow: false, prefersScaledContent: false))
    }
}

extension BrainCardView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self, let model = self.model else { return nil }
            var items: [UIMenuElement] = []
            if model.turn.outcome != .running {
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
                    state: self.row?.showsRows == true ? .on : .off
                ) { _ in self.onRows?() })
            return UIMenu(children: items)
        }
    }
}

/// A small pill on the card: Replay, Rows or Open. A finger is given a 44 point target however
/// small it is drawn.
@MainActor
final class CardButton: UIControl {
    var onTap: (() -> Void)?
    private let label = UILabel()
    private let icon = UIImageView()
    private var title = ""
    private var hasIcon = false
    private var compact = false
    private var isOn = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) { (view: CardButton, _) in view.traitsChanged() }
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        label.isUserInteractionEnabled = false
        label.adjustsFontForContentSizeCategory = true
        icon.contentMode = .center
        addSubview(icon)
        addSubview(label)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }

    func set(title new: String, symbol: String?, on: Bool, compact isCompact: Bool) {
        title = new
        hasIcon = symbol != nil
        isOn = on
        compact = isCompact
        let ink = on ? Theme.Color.accent : Theme.Color.label
        label.attributedText = NSAttributedString(
            string: new, attributes: Theme.Ramp.attributes(.control, color: ink))
        icon.image = symbol.flatMap { BrainCanvas.image($0, size: 9)?.withTintColor(ink, renderingMode: .alwaysOriginal) }
        icon.isHidden = symbol == nil
        layer.borderColor = (on ? Theme.Color.accent : Theme.Color.separator).resolvedColor(with: traitCollection).cgColor
        backgroundColor = on ? Theme.Color.accent.wash(0.14) : Theme.Color.background.wash(0.5)
        setNeedsLayout()
    }

    private func traitsChanged() {
        set(title: title, symbol: hasIcon ? "play.fill" : nil, on: isOn, compact: compact)
    }

    func fitted(height: CGFloat) -> CGSize {
        let text = label.attributedText?.size().width.rounded(.up) ?? 0
        return CGSize(width: 12 + (hasIcon ? 13 : 0) + text + 12, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let text = label.attributedText?.size() ?? .zero
        var x: CGFloat = 12
        if hasIcon {
            icon.frame = CGRect(x: 8, y: 0, width: 12, height: bounds.height)
            x = 21
        }
        label.frame = CGRect(
            x: x, y: (bounds.height - text.height) / 2, width: ceil(text.width) + 2,
            height: ceil(text.height))
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        TouchSlop.area(of: bounds).contains(point)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isEnabled ? (isHighlighted ? 0.55 : 1) : 0.4 }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }
}
