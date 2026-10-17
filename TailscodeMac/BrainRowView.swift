import AppKit
import TailscodeCore

/// The one line under an open brain: what the head is doing now, a light in the state's tone, and
/// where the step stands in the turn. It is a label that is restated, never a row that is rebuilt.
@MainActor
final class BrainTickerView: NSView {
    private let dot = NSView()
    private let text = NSTextField(labelWithString: "")
    private let counter = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        dot.layer?.cornerRadius = 3.5
        text.font = MacTheme.Ramp.font(.toolDetail)
        text.lineBreakMode = .byTruncatingTail
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        text.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        counter.font = MacTheme.Ramp.font(.responseStat)
        counter.setContentHuggingPriority(.required, for: .horizontal)
        counter.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = MacTheme.Spacing.s
        stack.setViews([dot, text, counter], in: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ ticker: NeuralTicker, inks: BrainInks) {
        let tone = tone(ticker.status, inks)
        if text.stringValue != ticker.text { text.stringValue = ticker.text }
        if counter.stringValue != ticker.counter { counter.stringValue = ticker.counter }
        text.textColor = inks.text
        counter.textColor = inks.textDim
        dot.layer?.backgroundColor = tone.cgColor
    }

    private func tone(_ status: NeuralStatus, _ inks: BrainInks) -> NSColor {
        switch status {
        case .failed: return NSColor(hex: inks.palette.danger) ?? inks.text
        case .waitingApproval, .waitingAnswer, .stalled:
            return NSColor(hex: inks.palette.warn) ?? inks.text
        case .running, .ok: return NSColor(hex: inks.palette.accent) ?? inks.text
        case .stopped: return inks.textDim
        }
    }

    var line: String { text.stringValue }
}

/// A drawn slider for a replay: a track, what has played, and a knob. Dragging it scrubs the
/// brain through the turn and letting go leaves the playhead where it was; the end of the track is
/// the turn as it stands.
@MainActor
final class BrainScrubber: NSView {
    var fraction: Double = 1 {
        didSet {
            guard fraction != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(Int((fraction * 100).rounded()))
        }
    }
    var onScrub: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    var inks: BrainInks? {
        didSet { needsDisplay = true }
    }
    private var dragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(NeuralReading.scrubLabel)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var track: NSRect {
        NSRect(x: 7, y: bounds.midY - 2, width: max(0, bounds.width - 14), height: 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let inks else { return }
        let rail = track
        let base = NSBezierPath(roundedRect: rail, xRadius: 2, yRadius: 2)
        inks.rule.setFill()
        base.fill()
        let played = NSRect(
            x: rail.minX, y: rail.minY, width: rail.width * CGFloat(fraction), height: rail.height)
        let accent = NSColor(hex: inks.palette.accent) ?? inks.text
        accent.setFill()
        NSBezierPath(roundedRect: played, xRadius: 2, yRadius: 2).fill()
        let knob = NSRect(x: played.maxX - 6, y: bounds.midY - 6, width: 12, height: 12)
        accent.setFill()
        NSBezierPath(ovalIn: knob).fill()
        inks.canvas.setStroke()
        let ring = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        scrub(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        scrub(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        scrub(event)
        onEnd?()
    }

    private func scrub(_ event: NSEvent) {
        let rail = track
        guard rail.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let next = min(1, max(0, Double((point.x - rail.minX) / rail.width)))
        fraction = next
        onScrub?(next)
    }

    override func accessibilityPerformIncrement() -> Bool {
        step(by: 0.05)
    }

    override func accessibilityPerformDecrement() -> Bool {
        step(by: -0.05)
    }

    private func step(by delta: Double) -> Bool {
        let next = min(1, max(0, fraction + delta))
        fraction = next
        onScrub?(next)
        onEnd?()
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: _ = step(by: -0.05)
        case 124: _ = step(by: 0.05)
        default: super.keyDown(with: event)
        }
    }
}

/// The scrubber's row: a play or stop button, the track, and how long the turn took or where the
/// playhead is. It is there once the turn is over; a turn still being written has nothing to play.
@MainActor
final class BrainScrubRow: NSView {
    let play = SymbolChip(kind: .control)
    let share = SymbolChip(kind: .fact)
    let scrubber = BrainScrubber()
    private let clock = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        play.symbol = "play.fill"
        play.setAccessibilityLabel(NeuralReading.replayLabel)
        clock.font = MacTheme.Ramp.font(.responseStat)
        clock.textColor = MacTheme.Color.secondaryLabel
        clock.setContentHuggingPriority(.required, for: .horizontal)
        clock.setContentCompressionResistancePriority(.required, for: .horizontal)
        clock.alignment = .right
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = MacTheme.Spacing.s
        share.text = Localized.text("Share")
        share.symbol = "square.and.arrow.up"
        stack.setViews([play, scrubber, clock, share], in: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(playing: Bool, fraction: Double, clock text: String, inks: BrainInks) {
        let symbol = playing ? "stop.fill" : "play.fill"
        if play.symbol != symbol { play.symbol = symbol }
        play.setAccessibilityLabel(playing ? Localized.text("Stop the replay") : NeuralReading.replayLabel)
        scrubber.fraction = fraction
        scrubber.inks = inks
        if clock.stringValue != text { clock.stringValue = text }
        clock.textColor = inks.textDim
    }

    var clockText: String { clock.stringValue }
}

/// An answer word that a step carries literally: the path or command the answer quotes. Hovering it
/// lights the steps that touched it and dims the rest; pressing it holds the light.
@MainActor
final class BrainTokenChip: SymbolChip {
    var onHover: ((Bool) -> Void)?
    private(set) var token = ""

    convenience init(token: String) {
        self.init(kind: .fact)
        self.token = token
        text = token
        symbol = "link"
        lineLimit()
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
    }

    private func lineLimit() {
        widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}

/// The paths and commands the answer quotes, as chips under the scrubber. Only a word some step
/// carries literally is offered, so the row never claims a link the transcript cannot show.
@MainActor
final class BrainChipsRow: NSView {
    private let stack = NSStackView()
    private let caption = NSTextField(labelWithString: "")
    private(set) var tokens: [String] = []
    var onHover: ((String?) -> Void)?
    var onPress: ((String) -> Void)?
    static let limit = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        caption.font = MacTheme.Ramp.font(.hint)
        caption.textColor = MacTheme.Color.secondaryLabel
        caption.setContentHuggingPriority(.required, for: .horizontal)
        caption.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = MacTheme.Spacing.xs
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.group)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ next: [String]) {
        guard next != tokens else { return }
        tokens = next
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !next.isEmpty else { return }
        caption.stringValue = Localized.text("In the answer")
        stack.addArrangedSubview(caption)
        for (index, token) in next.prefix(Self.limit).enumerated() {
            let chip = BrainTokenChip(token: token)
            chip.onHover = { [weak self] entered in self?.onHover?(entered ? token : nil) }
            chip.onTap = { [weak self] in self?.onPress?(token) }
            chip.setAccessibilityLabel(Localized.text("Answer word %@", token))
            stack.addArrangedSubview(chip)
            stack.setVisibilityPriority(
                .init(Float(NSStackView.VisibilityPriority.mustHold.rawValue) - Float(index + 1)),
                for: chip)
        }
        stack.setVisibilityPriority(.mustHold, for: caption)
    }

    var chips: [BrainTokenChip] { stack.arrangedSubviews.compactMap { $0 as? BrainTokenChip } }
}

/// One turn of the transcript drawn as a head. Collapsed it is a line: a chevron, the glyph, how
/// many tools, how long, what changed, a Rows button and a Replay button. Open, the line becomes
/// the top of a card holding the stage (the head with its nodes), the one line of what is
/// happening, and once the turn is over the scrubber and the words of the answer that a step
/// carries.
///
/// The row is restated in place whenever the store's model for its turn changes. Opening builds the
/// stage and closing takes it away, which is also what lets go of the process's textures; a pane
/// that parks, a window that closes and an app that has been away for a while do the same. The
/// row's height is the line, or the line and the stage, which is a fixed shape, so opening and
/// closing change one row's height and never re-solve the page.
@MainActor
final class BrainRowView: NSView, KeyboardPressable {
    private(set) var row: BrainRow
    let key: String
    private weak var context: TranscriptContext?
    private let ground = RowKit.Ground(frame: .zero)
    private let stack = FillingStack(topDown: true)
    private let header: NSStackView
    private let press: PressSurface
    private let mark = ToolRowView.disclosureMark(false)
    private let glyph = BrainGlyphView()
    private let count = RowKit.label("", font: MacTheme.Ramp.font(.toolName), color: MacTheme.Color.label)
    private let detail = ToolRowView.detailLabel("")
    private let added = RowKit.label("", font: MacTheme.Ramp.font(.diff), color: MacTheme.Color.success)
    private let removed = RowKit.label("", font: MacTheme.Ramp.font(.diff), color: MacTheme.Color.danger)
    private let rowsChip = SymbolChip(kind: .fact)
    private let replayChip = SymbolChip(kind: .fact)
    private let ticker = BrainTickerView()
    private let scrubRow = BrainScrubRow()
    private let chips = BrainChipsRow()
    private var holder: NSView?
    private(set) var stage: BrainStageView?
    private var parkReasons = Set<String>()
    private var startReplayOnOpen = false

    private var store: BrainStore? { context?.brains }
    private static let rows = NSHashTable<BrainRowView>.weakObjects()

    init(row: BrainRow, key: String, context: TranscriptContext) {
        self.row = row
        self.key = key
        self.context = context
        let header = NSStackView()
        self.header = header
        press = PressSurface(content: header, minHeight: ToolRowView.lineHeight)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        context.brains?.views.add(self)
        Self.rows.add(self)
        MacBrainIdle.shared.install()
        apply(row)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        ground.stroke = MacTheme.Color.separator
        ground.radius = MacTheme.Radius.card
        ground.isHidden = true
        addSubview(ground)
        addSubview(stack)
        NSLayoutConstraint.activate([
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            ground.topAnchor.constraint(equalTo: topAnchor),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        stack.spacing = MacTheme.Spacing.xs

        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = MacTheme.Spacing.s
        added.isHidden = true
        removed.isHidden = true
        rowsChip.text = NeuralReading.rowsLabel
        rowsChip.onTap = { [weak self] in self.map { $0.store?.toggleRows($0.row.turnID) } }
        replayChip.text = NeuralReading.replayLabel
        replayChip.symbol = "arrow.counterclockwise"
        replayChip.onTap = { [weak self] in self?.replayPressed() }
        let spacer = RowKit.spacer()
        for view in [mark, glyph, count, detail, added, removed, spacer, rowsChip, replayChip] {
            header.addArrangedSubview(view)
        }
        header.setCustomSpacing(MacTheme.Spacing.xs, after: removed)
        header.detachesHiddenViews = true
        header.setClippingResistancePriority(MacTheme.Layout.belowWindowSize, for: .horizontal)
        header.setVisibilityPriority(.init(300), for: rowsChip)
        header.setVisibilityPriority(.init(500), for: replayChip)
        press.onPress = { [weak self] in self.map { $0.store?.toggleOpen($0.row.turnID) } }
        stack.addArrangedSubview(press)
        ticker.isHidden = true
        scrubRow.isHidden = true
        chips.isHidden = true
        stack.addArrangedSubview(ticker)
        stack.addArrangedSubview(scrubRow)
        stack.addArrangedSubview(chips)

        scrubRow.play.onTap = { [weak self] in self?.playPressed() }
        scrubRow.share.onTap = { [weak self] in self?.sharePressed() }
        scrubRow.scrubber.onScrub = { [weak self] fraction in self?.scrubbed(fraction) }
        scrubRow.scrubber.onEnd = { [weak self] in self?.scrubEnded() }
        chips.onHover = { [weak self] token in self?.stage?.setProvenance(token) }
        chips.onPress = { [weak self] token in self?.pinProvenance(token) }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(budgetChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override func keyDown(with event: NSEvent) {
        guard [49, 36, 76].contains(event.keyCode) else { return super.keyDown(with: event) }
        store?.toggleOpen(row.turnID)
    }

    override func accessibilityPerformPress() -> Bool {
        store?.toggleOpen(row.turnID)
        return true
    }

    @objc private func themeChanged() {
        ground.stroke = MacTheme.Color.separator
        ground.needsDisplay = true
        syncLine()
        refreshAux()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncLine()
        refreshAux()
    }

    func restate(_ next: BrainRow) {
        apply(next)
    }

    func refresh() {
        syncLine()
        stage?.refresh()
        refreshAux()
    }

    /// A window shed to its last level keeps the glyph and nothing more: the head is not drawn there
    /// whatever the person chose, and comes back when the window has room again.
    private static var isShed: Bool { MotionBudget.level >= .critical }

    private func apply(_ next: BrainRow) {
        row = next
        let wanted = next.isOpen && !Self.isShed
        let opening = wanted != (stage != nil)
        if opening { setOpen(wanted) }
        syncLine()
        stage?.refresh()
        refreshAux()
    }

    @objc private func budgetChanged() {
        apply(row)
    }

    private func setOpen(_ open: Bool) {
        mark.stringValue = ToolRowView.disclosureGlyph(open)
        ground.isHidden = !open
        stack.edgeInsets =
            open
            ? NSEdgeInsets(top: 4, left: 10, bottom: 10, right: 10)
            : NSEdgeInsets()
        setAccessibilityExpanded(open)
        guard open else {
            closeStage()
            return
        }
        guard stage == nil, let context, let store else { return }
        let made = BrainStageView(turnID: row.turnID, store: store, context: context)
        made.onActivity = { [weak self] in self?.refreshAux() }
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(made)
        let wide = made.widthAnchor.constraint(equalTo: holder.widthAnchor)
        wide.priority = .init(750)
        NSLayoutConstraint.activate([
            made.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            made.topAnchor.constraint(equalTo: holder.topAnchor),
            made.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            made.widthAnchor.constraint(lessThanOrEqualToConstant: BrainStageView.maximumWidth),
            wide,
            made.heightAnchor.constraint(
                equalTo: made.widthAnchor, multiplier: NeuralDesign.height / NeuralDesign.width),
        ])
        stack.insertArrangedSubview(holder, at: 1)
        self.holder = holder
        stage = made
        if !parkReasons.isEmpty { made.park() }
        if startReplayOnOpen {
            startReplayOnOpen = false
            begin(replayAt: CACurrentMediaTime())
        }
    }

    private func closeStage() {
        stage?.removeFromSuperview()
        holder?.removeFromSuperview()
        stage = nil
        holder = nil
        ticker.isHidden = true
        scrubRow.isHidden = true
        chips.isHidden = true
        store?.withModel(row.turnID) {
            $0.stopReplay()
            $0.clearSelection()
            $0.setProvenance(token: nil)
        }
    }

    private func syncLine() {
        guard let store, let model = store.model(row.turnID) else { return }
        let inks = BrainInks.current(for: effectiveAppearance)
        let line = model.line
        glyph.show(model.glyph, face: model.face, motion: model.state.motion)
        if count.stringValue != line.count { count.stringValue = line.count }
        let words = line.detail
        if detail.stringValue != words { detail.stringValue = words }
        detail.isHidden = words.isEmpty
        added.stringValue = line.added > 0 ? "+\(line.added)" : ""
        added.isHidden = line.added == 0
        removed.stringValue = line.removed > 0 ? "−\(line.removed)" : ""
        removed.isHidden = line.removed == 0
        mark.stringValue = ToolRowView.disclosureGlyph(stage != nil)
        let settled = model.turn.outcome != .running
        replayChip.isHidden = !settled || model.steps.isEmpty
        replayChip.text = model.isReplaying ? Localized.text("Stop") : NeuralReading.replayLabel
        replayChip.symbol = model.isReplaying ? "stop.fill" : "arrow.counterclockwise"
        rowsChip.glyphTone = row.showsRows ? .live : nil
        rowsChip.symbol = row.showsRows ? "checkmark" : nil
        press.toolTip = line.toolMix.isEmpty ? nil : line.toolMix
        setAccessibilityLabel(model.spoken)
        _ = inks
    }

    /// The ticker, the scrubber and the chips under the stage: restated from the model, shown only
    /// when there is something to say.
    private func refreshAux() {
        guard let store, let model = store.model(row.turnID), let entry = store.entry(row.turnID)
        else { return }
        guard stage != nil else {
            ticker.isHidden = true
            scrubRow.isHidden = true
            chips.isHidden = true
            return
        }
        let inks = BrainInks.current(for: effectiveAppearance)
        let now = CACurrentMediaTime()
        if let live = model.ticker(now: now) {
            ticker.show(live, inks: inks)
            ticker.isHidden = false
        } else {
            ticker.isHidden = true
        }
        let settled = model.turn.outcome != .running
        scrubRow.isHidden = !settled
        if settled {
            let playing = model.isReplaying
            let fraction = model.replayFraction(now: now) ?? 1
            let clock =
                playing
                ? (model.replayTime(now: now).map { NeuralReading.duration($0) } ?? "")
                : (model.line.duration ?? NeuralReading.duration(model.timeline.duration))
            scrubRow.show(playing: playing, fraction: fraction, clock: clock, inks: inks)
        }
        let words =
            settled
            ? model.answerTokens(in: entry.answer).map(\.text).uniqued()
            : []
        chips.show(words)
        chips.isHidden = words.isEmpty
    }

    private func replayPressed() {
        guard let store else { return }
        if store.model(row.turnID)?.isReplaying == true {
            stopReplay()
            return
        }
        if stage != nil {
            begin(replayAt: CACurrentMediaTime())
        } else {
            startReplayOnOpen = true
            store.toggleOpen(row.turnID)
        }
    }

    private func playPressed() {
        if store?.model(row.turnID)?.isReplaying == true {
            stopReplay()
        } else {
            begin(replayAt: CACurrentMediaTime())
        }
    }

    private func begin(replayAt time: Double) {
        store?.withModel(row.turnID) { $0.startReplay(now: time) }
        stage?.refresh(force: true)
        syncLine()
        refreshAux()
    }

    private func stopReplay() {
        store?.withModel(row.turnID) { $0.stopReplay() }
        stage?.refresh(force: true)
        syncLine()
        refreshAux()
    }

    private func scrubbed(_ fraction: Double) {
        scrubRow.scrubber.fraction = fraction
        store?.withModel(row.turnID) { $0.scrub(to: fraction) }
        stage?.refresh()
        syncLine()
        refreshAux()
    }

    private func scrubEnded() {
        store?.withModel(row.turnID) { $0.endScrub() }
        stage?.refresh(force: true)
        syncLine()
        refreshAux()
    }

    private func sharePressed() {
        guard let store, let context, let window else { return }
        BrainSharePanel.present(turnID: row.turnID, store: store, context: context, on: window)
    }

    private func pinProvenance(_ token: String) {
        let active = store?.model(row.turnID)?.provenanceToken == token
        stage?.setProvenance(active ? nil : token)
    }

    /// A pane that parks, a window that closes or an app that has been away takes the head out of
    /// the row, which lets go of the textures; each gives its reason and takes it back, and the
    /// head is back only when nobody still wants it gone.
    func setParked(_ parked: Bool, reason: String = "pane") {
        if parked { parkReasons.insert(reason) } else { parkReasons.remove(reason) }
        if parkReasons.isEmpty { stage?.unpark() } else { stage?.park() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        syncLine()
    }

    static var live: [BrainRowView] { rows.allObjects }

    var isOpenShown: Bool { stage != nil }
    var hasReplayChip: Bool { !replayChip.isHidden }
    var linePieces: (count: String, detail: String, added: String, removed: String) {
        (count.stringValue, detail.stringValue, added.stringValue, removed.stringValue)
    }
    var tickerText: String? { ticker.isHidden ? nil : ticker.line }
    var scrubberShown: Bool { !scrubRow.isHidden }
    var scrubFraction: Double { scrubRow.scrubber.fraction }
    var tokenChips: [String] { chips.isHidden ? [] : chips.tokens }
    var glyphView: BrainGlyphView { glyph }
    var rowsButton: SymbolChip { rowsChip }
    var replayButton: SymbolChip { replayChip }
    var playButton: SymbolChip { scrubRow.play }
    var shareButton: SymbolChip { scrubRow.share }
    var chipViews: [BrainTokenChip] { chips.chips }
    var scrubberView: BrainScrubber { scrubRow.scrubber }
    var tokenCount: Int { chips.tokens.count }

    func pressLine() { store?.toggleOpen(row.turnID) }
}

extension Array where Element: Hashable {
    fileprivate func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// The brain's one standing clock: none. What it does is notice that nobody is looking. A head
/// holds the process's textures while it is open, so an app that has been in the background, hidden
/// or behind another window for a minute and a half lets go of them, and takes them back the moment
/// it is looked at; a window that closes lets go at once.
@MainActor
final class MacBrainIdle {
    static let shared = MacBrainIdle()
    static let delay: TimeInterval = 90

    private var installed = false
    private var timer: Timer?
    private(set) var isIdle = false

    func install() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.away() }
            }
        }
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.back() }
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
            note in
            guard let closing = (note.object as? NSWindow).map({ ObjectIdentifier($0) }) else {
                return
            }
            MainActor.assumeIsolated {
                for row in BrainRowView.live where row.window.map({ ObjectIdentifier($0) }) == closing {
                    row.setParked(true, reason: "window")
                }
            }
        }
    }

    func away() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fallIdle() }
        }
    }

    func fallIdle() {
        timer = nil
        isIdle = true
        for row in BrainRowView.live { row.setParked(true, reason: "idle") }
    }

    func back() {
        timer?.invalidate()
        timer = nil
        guard isIdle else { return }
        isIdle = false
        for row in BrainRowView.live { row.setParked(false, reason: "idle") }
    }
}
