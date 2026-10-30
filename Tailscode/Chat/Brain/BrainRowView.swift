import TailscodeCore
import UIKit

/// One turn's brain in the transcript: a card while it is collapsed, the open brain while it is
/// open, and the move that carries one into the other.
///
/// The move is one object. `NeuralTransition` owns every curve and every timing, this view reads its
/// frame off the display's clock for the length of the move and applies the numbers to the card, the
/// head that travels, the nodes, the list, the account, the footer and the row's own height, so
/// Core's arithmetic is the single truth and a press at any moment turns the move round from where
/// it is. A move that is not seen (a row scrolled away, a cell reused) is not run: the row simply
/// stands in the state it was asked to be in.
@MainActor
final class BrainRowView: UIView {
    enum Phase: Equatable {
        case closed
        case open
        case moving
    }

    let card = BrainCardView()
    private(set) var openView: BrainOpenView?
    private(set) var phase = Phase.closed
    private(set) var turnID = ""
    private(set) var row: BrainRow?

    /// The row's height changed: the cell asks its list to measure it again.
    var onHeightChange: (() -> Void)?

    private weak var store: BrainStore?
    private var actions: BrainActions?
    private var viewport: CGFloat = 800
    private var metrics: NeuralStageMetrics?
    private var cardMetrics: NeuralStageMetrics?

    /// How far the card stands in from each side of the row. Zero for an ordinary row; a row
    /// that spans a window wider than the transcript's readable column is as wide as the window,
    /// so its open brain can use the width, and its card stays where every other card is.
    var cardInset: CGFloat = 0 {
        didSet { if cardInset != oldValue { setNeedsLayout() } }
    }

    private var cardWidth: CGFloat { max(bounds.width - 2 * cardInset, 0) }
    private var transition: NeuralTransition?
    private var moveStart: CFTimeInterval = 0
    private var moveProgress = 0.0
    private var link: CADisplayLink?
    private var linkTarget: BrainMoveTarget?
    private var pendingOpen: PendingOpen?
    private var currentHeight: CGFloat = 0
    private var lastTextScale: CGFloat = 1
    private var cardIsStale = false
    private var wasAsking = false
    private var cardRevision = -1
    private var openedByMove = false
    private var wasConfigured = false
    private var liveRegistered = false

    private struct PendingOpen {
        let started: CFTimeInterval
        var ticket: Int
    }

    private var pendingTicket = 0

    /// What a move cost, for the debug log and the checks: how many frames it drew and the longest
    /// gap between two of them.
    private(set) var lastMove: (frames: Int, maxGap: Double, duration: Double, direction: String)?
    private var lastStamp: CFTimeInterval = 0
    private var frames = 0
    private var maxGap = 0.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(card)
        card.onOpen = { [weak self] in self?.toggleFromCard() }
        card.onReplay = { [weak self] in
            guard let self else { return }
            self.actions?.replay(self.turnID)
        }
        card.onRows = { [weak self] in
            guard let self else { return }
            self.actions?.rows(self.turnID)
        }
        card.onShare = { [weak self] in
            guard let self else { return }
            self.actions?.share(self.turnID)
        }
        card.onDive = { [weak self] zone in
            guard let self else { return }
            self.actions?.openDiving(self.turnID, zone)
        }
        card.onPrefetch = { [weak self] in self?.prefetch() }
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        MainActor.assumeIsolated {
            link?.invalidate()
            BrainLiveClock.shared.unregister(self)
        }
    }

    /// Draws a brain row. The model is read from the store, never copied here, so a cursor or a
    /// replay the person started survives the cell being configured again.
    func configure(
        row new: BrainRow, store newStore: BrainStore, actions newActions: BrainActions,
        viewport newViewport: CGFloat
    ) {
        let previous = row
        let sameTurn = previous?.turnID == new.turnID
        row = new
        store = newStore
        actions = newActions
        viewport = newViewport
        turnID = new.turnID
        guard let model = newStore.model(for: new.turnID) else { return }
        let width = bounds.width > 0 ? bounds.width : 360
        metrics = makeMetrics(width: width, model: model)
        cardMetrics = makeCardMetrics(model: model)
        if !sameTurn { resetState() }
        card.configure(model: model, row: new, memory: newStore.memory(for: new.turnID), metrics: cardMetrics!)
        cardRevision = model.revision
        let wantsOpen = new.isOpen
        switch (phase, wantsOpen) {
        case (.closed, true):
            if wasConfigured, sameTurn, canMove { startOpening() } else { showOpen() }
        case (.open, false):
            if wasConfigured, sameTurn, canMove { startClosing() } else { showClosed() }
        case (.moving, _):
            let opening = transition?.direction.isOpening ?? false
            if opening != wantsOpen { reverse() }
        case (.open, true):
            openView?.apply(metrics: metrics!)
            openView?.refreshAll()
        case (.closed, false):
            break
        }
        wasConfigured = true
        updateClock()
        setNeedsLayout()
    }

    /// The conversation moved without this row changing: the brain reads the model again.
    func refreshLive() {
        guard let store, let row, let model = store.model(for: row.turnID) else { return }
        switch phase {
        case .closed:
            guard model.turn.outcome == .running || model.revision != cardRevision else { return }
            cardRevision = model.revision
            card.refresh(model: model)
        case .open:
            let asking = model.stepList.pendingAskID != nil
            if asking != wasAsking {
                wasAsking = asking
                card.refresh(model: model)
            } else {
                cardIsStale = true
            }
            openView?.conversationChanged()
        case .moving:
            card.refresh(model: model)
        }
        updateClock()
    }

    private func makeCardMetrics(model: NeuralBrainModel) -> NeuralStageMetrics {
        cardInset > 0 ? makeMetrics(width: cardWidth, model: model) : (metrics ?? makeMetrics(width: bounds.width, model: model))
    }

    private func makeMetrics(width: CGFloat, model: NeuralBrainModel) -> NeuralStageMetrics {
        let expanded = store?.interaction(for: model.turn.id).listExpanded ?? false
        return NeuralStageMetrics.make(
            width: Double(width), density: ChatDensitySetting.current, input: .touch,
            zonesWithSteps: max(model.stepList.zoneChips.count, 1), rows: BrainOpenView.compactSlots(model: model, expanded: expanded),
            viewportHeight: Double(viewport), phone: true, textScale: Double(Self.textScale(for: traitCollection)))
    }

    /// How much larger than the design's the reader's type is, for a phone's rows and bar.
    private static func textScale(for traits: UITraitCollection) -> CGFloat {
        min(
            max(UIFontMetrics(forTextStyle: .body).scaledValue(for: 1, compatibleWith: traits), 1),
            CGFloat(NeuralStageMetrics.phoneMaxTextScale))
    }

    /// The open stage's list wants another number of rows than it was laid out for: lay it out
    /// again, move the transcript's row to its new height, and draw the rows.
    private func slotsChanged() {
        guard phase == .open, let store, let model = store.model(for: turnID) else { return }
        metrics = makeMetrics(width: bounds.width, model: model)
        cardMetrics = makeCardMetrics(model: model)
        openView?.apply(metrics: metrics!)
        currentHeight = openView?.openHeight ?? currentHeight
        onHeightChange?()
        setNeedsLayout()
        openView?.refreshAll()
    }

    private func resetState() {
        finishNow(open: false)
        openView?.dismissReader()
        openView?.removeFromSuperview()
        openView = nil
        phase = .closed
        card.isHidden = false
        card.clearMove()
        wasConfigured = false
        pendingOpen = nil
        pendingTicket += 1
    }

    func prepareForReuse() {
        link?.invalidate()
        link = nil
        transition = nil
        pendingOpen = nil
        pendingTicket += 1
        openView?.dismissReader()
        openView?.removeFromSuperview()
        openView = nil
        phase = .closed
        card.isHidden = false
        card.clearMove()
        store = nil
        actions = nil
        row = nil
        wasConfigured = false
        BrainLiveClock.shared.unregister(self)
        liveRegistered = false
    }

    /// What a row is estimated at before its model is made: the card's height on a phone's narrow
    /// row, a wide card's everywhere else.
    private static func unmadeHeight(forWidth width: CGFloat) -> CGFloat {
        guard NeuralStageMetrics.cardLayout(width: Double(width)) == .narrow else { return 112 }
        let compact = ChatDensitySetting.current == .compact
        return CGFloat(
            compact ? NeuralStageMetrics.phoneCardHeightCompact : NeuralStageMetrics.phoneCardHeightComfortable)
    }

    /// The row's height for a width: the card's, the open brain's, or the move's own at this
    /// instant.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let store, let row, let model = store.model(for: row.turnID) else {
            return Self.unmadeHeight(forWidth: width)
        }
        let m = (metrics?.width == Double(width)) ? metrics! : makeMetrics(width: width, model: model)
        switch phase {
        case .closed:
            return card.requiredHeight(width: max(width - 2 * cardInset, 0))
        case .open:
            return CGFloat(m.openHeight)
        case .moving:
            return currentHeight
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, let store, let row, let model = store.model(for: row.turnID) else { return }
        let scale = Self.textScale(for: traitCollection)
        if metrics?.width != Double(bounds.width) || cardMetrics?.width != Double(cardWidth)
            || scale != lastTextScale
        {
            lastTextScale = scale
            metrics = makeMetrics(width: bounds.width, model: model)
            cardMetrics = makeCardMetrics(model: model)
            card.configure(model: model, row: row, memory: store.memory(for: row.turnID), metrics: cardMetrics!)
            if phase == .open || phase == .moving {
                openView?.apply(metrics: metrics!)
                openView?.refreshAll()
            }
            if phase == .moving { finishNow(open: transition?.direction.isOpening ?? false) }
        }
        let cardHeight = card.requiredHeight(width: cardWidth)
        card.frame = CGRect(x: cardInset, y: 0, width: cardWidth, height: cardHeight)
        if let openView {
            openView.frame = CGRect(
                x: 0, y: 0, width: bounds.width, height: openView.openHeight)
        }
    }

    private func toggleFromCard() {
        guard let actions else { return }
        actions.toggle(turnID)
    }

    private var canMove: Bool {
        window != nil && bounds.width > 8 && !isHiddenInHierarchyForMove && NeuralMetalContext.shared?.isSupported == true
    }

    private var isHiddenInHierarchyForMove: Bool {
        guard let collection = superview(of: UICollectionView.self) else { return false }
        let visible = collection.bounds.insetBy(dx: 0, dy: -40)
        let frame = convert(bounds, to: collection)
        return !visible.intersects(frame)
    }

    private func superview<T: UIView>(of type: T.Type) -> T? {
        var view = superview
        while let current = view {
            if let match = current as? T { return match }
            view = current.superview
        }
        return nil
    }

    /// Starts the textures loading and the picture being made while the finger is still on the card,
    /// so the move begins on the lift rather than after a build.
    private func prefetch() {
        guard let model = store?.model(for: turnID) else { return }
        let ink = BrainPalette.palette(for: traitCollection)
        let scale = max(1, window?.windowScene?.screen.scale ?? 2)
        let width = CGFloat(NeuralStageMetrics.headWidth(rowWidth: Double(bounds.width)))
            * CGFloat(NeuralDesign.width / NeuralStageMetrics.designWidth)
        BrainPictures.picture(
            frame: model.frame(time: 0, reduceMotion: true), palette: ink, face: model.face,
            width: width, scale: scale
        ) { _ in }
    }

    private func makeOpen() -> BrainOpenView? {
        guard let store, let metrics, let model = store.model(for: turnID) else { return nil }
        if let openView { return openView }
        let made = BrainOpenView(metrics: metrics)
        made.attach(store: store, turnID: turnID, actions: actions!)
        made.onSlotsChange = { [weak self] in self?.slotsChanged() }
        made.apply(metrics: metrics)
        insertSubview(made, belowSubview: card)
        made.frame = CGRect(x: 0, y: 0, width: bounds.width, height: made.openHeight)
        made.refreshAll()
        let palette = BrainPalette.palette(for: traitCollection)
        let ink = BrainInk(palette: palette, face: model.face)
        made.configureLights(card: model.brainCard(now: BrainDebug.now), ink: ink)
        openView = made
        return made
    }

    /// Takes the open brain with no move.
    private func showOpen() {
        guard makeOpen() != nil else { return }
        phase = .open
        card.isHidden = true
        openView?.finishMove()
        currentHeight = openView?.openHeight ?? 0
        applyPendingDive()
        if store?.interaction(for: turnID).replayOnOpen == true {
            store?.interaction(for: turnID).replayOnOpen = false
            openView?.startReplay()
        }
        onHeightChange?()
        setNeedsLayout()
    }

    /// Takes the card with no move and lets the open parts go.
    private func showClosed() {
        refreshStaleCard()
        openView?.dismissReader()
        openView?.removeFromSuperview()
        openView = nil
        phase = .closed
        card.isHidden = false
        card.clearMove()
        currentHeight = card.requiredHeight(width: cardWidth)
        onHeightChange?()
        setNeedsLayout()
    }

    private func geometries(metrics m: NeuralStageMetrics, extra: CGFloat) -> (NeuralTransition.Geometry, NeuralTransition.Geometry) {
        var cardGeometry = (cardMetrics ?? m).cardGeometry
        cardGeometry.rowHeight = max(cardGeometry.rowHeight, Double(card.requiredHeight(width: cardWidth)))
        if cardInset > 0 { cardGeometry = Self.shifted(cardGeometry, dx: Double(cardInset)) }
        var stage = m.stageGeometry
        stage.rowHeight += Double(extra)
        stage.footer = stage.footer.offsetBy(dy: Double(extra))
        return (cardGeometry, stage)
    }

    private static func shifted(_ g: NeuralTransition.Geometry, dx: Double) -> NeuralTransition.Geometry {
        var out = g
        out.picture = g.picture.offsetBy(dx: dx)
        out.readout = g.readout.offsetBy(dx: dx)
        out.footer = g.footer.offsetBy(dx: dx)
        out.list = g.list.offsetBy(dx: dx)
        out.panel = g.panel.offsetBy(dx: dx)
        return out
    }

    private func makeTransition(direction: NeuralTransition.Direction) -> NeuralTransition? {
        guard let metrics, let model = store?.model(for: turnID) else { return nil }
        let extra = CGFloat(metrics.narrowExtra)
        let (cardGeometry, stageGeometry) = geometries(metrics: metrics, extra: extra)
        let opening = direction.isOpening
        return NeuralTransition(
            direction: direction, from: opening ? cardGeometry : stageGeometry,
            to: opening ? stageGeometry : cardGeometry, nodeCount: model.nodeCount,
            rowCount: metrics.rowsShown, reduceMotion: UIAccessibility.isReduceMotionEnabled,
            level: ProcessInfo.processInfo.isLowPowerModeEnabled ? .strained : .calm,
            live: model.turn.outcome == .running)
    }

    private func startOpening() {
        guard let move = makeTransition(direction: .open), makeOpen() != nil else {
            showOpen()
            return
        }
        transition = move
        openView?.stage.setSuspended(false)
        pendingTicket += 1
        let ticket = pendingTicket
        pendingOpen = PendingOpen(started: CACurrentMediaTime(), ticket: ticket)
        applyFrame(move.frame(at: 0, clock: CACurrentMediaTime()), opening: true)
        if let stage = openView?.stage, stage.head.isReady {
            beginMove()
        } else {
            openView?.stage.onReady = { [weak self] in
                guard let self, self.pendingOpen?.ticket == ticket else { return }
                self.beginMove()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.pendingOpen?.ticket == ticket else { return }
                    self.pendingOpen = nil
                    self.showOpen()
                    self.actions?.landed(self.turnID)
                }
            }
        }
    }

    private func beginMove() {
        guard pendingOpen != nil, let move = transition else { return }
        pendingOpen = nil
        openView?.stage.onReady = nil
        phase = .moving
        currentHeight = CGFloat(move.from.rowHeight)
        startClock()
    }

    /// The card is not drawn while the brain is open, so it is not kept current for every token
    /// either: it reads the model again as it comes back.
    private func refreshStaleCard() {
        guard cardIsStale, let model = store?.model(for: turnID) else { return }
        cardIsStale = false
        card.refresh(model: model)
    }

    private func startClosing() {
        refreshStaleCard()
        guard openView != nil, let move = makeTransition(direction: .close) else {
            showClosed()
            return
        }
        pendingOpen = nil
        transition = move
        phase = .moving
        card.isHidden = false
        currentHeight = CGFloat(move.from.rowHeight)
        applyFrame(move.frame(at: 0, clock: CACurrentMediaTime()), opening: false)
        startClock()
    }

    /// A press during the move turns it round where it is.
    private func reverse() {
        guard let move = transition else { return }
        let now = CACurrentMediaTime()
        let progress = min(max((now - moveStart) / max(move.duration * BrainDebug.slowMotion, 0.001), 0), 1)
        transition = move.reversed(from: progress)
        moveStart = now
    }

    private func startClock() {
        moveStart = CACurrentMediaTime()
        frames = 0
        maxGap = 0
        lastStamp = 0
        link?.invalidate()
        let target = BrainMoveTarget(self)
        linkTarget = target
        let display = CADisplayLink(target: target, selector: #selector(BrainMoveTarget.step(_:)))
        display.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        display.add(to: .main, forMode: .common)
        link = display
    }

    fileprivate func moveStep(_ display: CADisplayLink) {
        guard let move = transition else {
            link?.invalidate()
            link = nil
            return
        }
        let now = CACurrentMediaTime()
        if lastStamp > 0 { maxGap = max(maxGap, now - lastStamp) }
        lastStamp = now
        frames += 1
        let progress = min(max((now - moveStart) / max(move.duration * BrainDebug.slowMotion, 0.001), 0), 1)
        moveProgress = progress
        let frame = move.frame(at: progress, clock: now)
        applyFrame(frame, opening: move.direction.isOpening)
        if progress >= 1 { finishMoveLanded(move) }
    }

    /// Dives into the zone a card's chip asked for, now that the head is there to dive.
    private func applyPendingDive() {
        guard let zone = store?.interaction(for: turnID).pendingDive else { return }
        store?.interaction(for: turnID).pendingDive = nil
        openView?.stage.dive(to: zone)
    }

    private func finishMoveLanded(_ move: NeuralTransition) {
        link?.invalidate()
        link = nil
        let opening = move.direction.isOpening
        lastMove = (frames, maxGap, move.duration, opening ? "open" : "close")
        BrainDebug.logMove(
            turn: turnID, direction: opening ? "open" : "close", frames: frames, maxGap: maxGap,
            duration: move.duration)
        transition = nil
        if opening {
            phase = .open
            card.isHidden = true
            card.clearMove()
            openView?.finishMove()
            currentHeight = openView?.openHeight ?? 0
            openView?.fadeInContent()
            applyPendingDive()
            if store?.interaction(for: turnID).replayOnOpen == true {
                store?.interaction(for: turnID).replayOnOpen = false
                openView?.startReplay()
            }
        } else {
            showClosed()
        }
        onHeightChange?()
        setNeedsLayout()
        if opening { actions?.landed(turnID) }
    }

    /// Lands a move at once, for a width that changed under it or a cell that was reused.
    private func finishNow(open: Bool) {
        link?.invalidate()
        link = nil
        transition = nil
        pendingOpen = nil
        if open { showOpen() } else if phase != .closed || openView != nil { showClosed() }
    }

    private func applyFrame(_ frame: NeuralTransitionFrame, opening: Bool) {
        currentHeight = CGFloat(frame.rowHeight)
        card.applyMove(frame: frame, opening: opening, originX: cardInset)
        if let metrics { openView?.apply(frame: frame, from: metrics, opening: opening, live: transition?.live ?? false) }
        onHeightChange?()
    }

    private func updateClock() {
        let live = phase == .open && store?.model(for: turnID)?.turn.outcome == .running && window != nil
        if live, !liveRegistered {
            liveRegistered = true
            BrainLiveClock.shared.register(self) { [weak self] in self?.openView?.tick() }
        } else if !live, liveRegistered {
            liveRegistered = false
            BrainLiveClock.shared.unregister(self)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            link?.invalidate()
            link = nil
            if phase == .moving { finishNow(open: transition?.direction.isOpening ?? false) }
            openView?.stage.setSuspended(true)
            updateClock()
        } else {
            openView?.stage.setSuspended(false)
            updateClock()
        }
    }

    /// Whether any display link exists for this row: a settled row owns none.
    var ownsDisplayLink: Bool { link != nil }

    var openHeight: CGFloat? { openView?.openHeight }
}

private final class BrainMoveTarget {
    weak var row: BrainRowView?
    init(_ row: BrainRowView) { self.row = row }

    @objc @MainActor func step(_ link: CADisplayLink) {
        guard let row else {
            link.invalidate()
            return
        }
        row.moveStep(link)
    }
}
