import AppKit
import CodingAgentKit
import TailscodeCore

/// One turn of the transcript drawn as a head. Collapsed it is a card: the head itself lit where the
/// turn worked, the turn's numbers, the agent's first words. Open, the card becomes the stage: the
/// head as a map on the left, the filter chips and the step list under it, the account (the agent
/// talking to you) beside it, and the footer across the bottom. Opening and closing are one move of
/// the same parts, never a rebuild.
///
/// The row is restated in place whenever the store's model for its turn changes, and keeps its
/// views for the life of the turn. Its height is the card's, the open brain's or the move's, and a
/// change of height is the one thing the transcript hears about: every part is placed by frame
/// from Core's `NeuralStageMetrics` for the row's width, at the moment the row is laid out, so a
/// resize between breakpoints rebuilds nothing and no constraint joins one part to another.
/// Opening builds the stage, the list, the account and the footer and closing takes them away,
/// which is also what lets go of the process's textures; a pane that parks, a window that closes
/// and an app that has been away for a while do the same.
@MainActor
final class BrainRowView: NSView, BrainSurfaceHost, RowMotion {
    enum Phase: Equatable {
        case closed
        case open
        case moving
    }

    private(set) var row: BrainRow
    let key: String
    weak var context: TranscriptContext?
    var turnID: String { row.turnID }

    let card = BrainCardView()
    let picture = BrainPictureLayer()
    let carrier = BrainCarrierView()
    let leader = BrainLeaderLayer()
    let wordmark = BrainWordmarkView()
    var wordmarkKey = 0
    var stage: BrainStageView?
    var chips: BrainFilterChips?
    var list: BrainListView?
    var account: BrainAccountView?
    var slide: BrainCarrierView?
    var moveMask: CALayer?
    var footer: BrainFooterView?
    private(set) var phase = Phase.closed
    var mover: BrainMover?
    var schedule: NeuralOpenSchedule?
    var moveContent: BrainCardView.Content?
    var movedFrames = 0
    var parkReasons = Set<String>()
    var startReplayOnOpen = false
    var legend: NSPopover?
    var metricsMemo: (key: MetricsKey, value: NeuralStageMetrics)?
    var lastWidth: CGFloat = 0
    private var pictureRequested = ""
    var hoverApplied: String??
    var pendingHover: (id: String?, delay: Double)?
    var lastHoverApplyTime = 0.0
    var hoverFlush: Timer?
    var graceTimerStore: Timer?
    var announcement: String?
    private var memoStamp = -1
    private var contextObservers: [NSObjectProtocol] = []
    private(set) var tokenComputations = 0
    private var tokenMemo: (answer: String, revision: Int, tokens: [String])?
    var lastIntrinsicHeight: CGFloat = -1
    var focusOnLanding = false
    var maxFrameGap = 0.0
    var movesRun = 0

    var store: BrainStore? { context?.brains }
    private static let rows = NSHashTable<BrainRowView>.weakObjects()
    static var live: [BrainRowView] { rows.allObjects }

    init(row: BrainRow, key: String, context: TranscriptContext) {
        self.row = row
        self.key = key
        self.context = context
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        build()
        context.brains?.views.add(self)
        Self.rows.add(self)
        MacBrainIdle.shared.install()
        apply(row, initial: true)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    isolated deinit {
        hoverFlush?.invalidate()
        graceTimerStore?.invalidate()
        for token in contextObservers { NotificationCenter.default.removeObserver(token) }
    }

    private func build() {
        carrier.frame = bounds
        carrier.autoresizingMask = [.width, .height]
        addSubview(card)
        addSubview(carrier)
        carrier.layer?.addSublayer(picture.container)
        layer?.addSublayer(leader.layer)
        addSubview(wordmark)
        card.onOpen = { [weak self] in self?.store?.toggleOpen(self?.turnID ?? "") }
        card.onReplay = { [weak self] in self?.toggleReplay() }
        card.onRows = { [weak self] in self?.toggleRows() }
        card.onZone = { [weak self] zone in self?.openDiving(into: zone) }
        card.onHover = { [weak self] _ in self?.cardHoverChanged() }
        setAccessibilityElement(false)
        let center = NotificationCenter.default
        contextObservers.append(
            center.addObserver(forName: MacTheme.Chrome.didRepaint, object: nil, queue: .main) {
                [weak self] _ in MainThread.call { self?.rethemed() }
            })
        contextObservers.append(
            center.addObserver(forName: ChatDensitySetting.didChange, object: nil, queue: .main) {
                [weak self] _ in MainThread.call { self?.densityChanged() }
            })
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }


    var model: NeuralBrainModel {
        store?.model(turnID) ?? NeuralBrainModel(turn: placeholderTurn)
    }

    private var placeholderTurn: NeuralTurn {
        store?.entry(turnID)?.turn ?? NeuralTurn(id: turnID)
    }

    @discardableResult
    func updateModel<Value>(_ body: (inout NeuralBrainModel) -> Value) -> Value {
        if let result = store?.withModel(turnID, body) { return result }
        var scratch = NeuralBrainModel(turn: placeholderTurn)
        return body(&scratch)
    }

    var inks: BrainInks { BrainInks.current(for: effectiveAppearance) }
    var density: ChatDensity { ChatDensitySetting.current }
    var reduceMotion: Bool { !ActivityPulse.motionAllowed }
    var answerText: String { store?.entry(turnID)?.answer ?? "" }
    var isShowingRows: Bool { row.showsRows }

    var isVisible: Bool {
        guard window != nil, DisplayGate.allows(self) else { return false }
        return !visibleRect.isEmpty
    }

    var accessibleLabel: String { NeuralReading.named(announcement ?? model.spoken) }

    func relayout() {
        needsLayout = true
        let height = restingHeight
        if height != lastIntrinsicHeight {
            lastIntrinsicHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    func animationChanged() {}

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        announce(Localized.text("Copied"))
    }

    func announce(_ words: String) {
        announcement = words
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func goToApproval() { store?.revealApproval?() }

    func replyWithQuote(_ quote: String) { store?.replyQuote?(quote) }

    func revealAnswer() {
        guard let target = store?.answerTarget(turnID: turnID) else { return }
        store?.revealAnswerPart?(target.messageID, target.part)
    }

    func focusList() {
        guard let window else { return }
        if let list, !list.isHidden {
            window.makeFirstResponder(list)
        } else {
            account?.focus()
        }
    }

    func focusSearchField() {
        if let list, !list.isHidden { list.focusSearch() } else { account?.focusSearch() }
    }

    func collapseBrain() { store?.setOpen(false, turnID: turnID) }

    var promptText: String? { store?.entry(turnID)?.prompt }

    func relationHover(_ ids: [String]?) {
        updateModel { $0.setHover(ids?.first) }
        stage?.refresh(force: true)
    }

    func dive(into zone: NeuralZone) { stage?.dive(into: zone) }

    func showInRows(_ stepID: String) {
        if !row.showsRows { store?.toggleRows(turnID) }
        store?.revealStepRow?(stepID)
    }

    func openSubagent(_ stepID: String) { context?.revealSubagent?(stepID) }

    func stageFocusChanged(_ focused: Bool) {
        if focused, model.browseFocus != .list { updateModel { $0.setBrowseFocus(.list) } }
        stage?.refresh(force: true)
    }

    func stagePressed() { dismissLegend() }

    var zonesMemo: (revision: Int, count: Int)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: restingHeight)
    }


    override func layout() {
        super.layout()
        let width = bounds.width
        if width != lastWidth {
            lastWidth = width
            widthChanged()
        }
        place()
    }

    var cardInput: BrainCardView.Content?


    func restate(_ next: BrainRow) { apply(next, initial: false) }

    /// What the row last restated itself from: the entry and model it held and the machine's
    /// context. The clock is the second's own tick, which forces a restatement.
    private struct RestateStamp: Equatable {
        let entry: Int
        let model: Int
        let context: NeuralBrainContext
    }

    private var restateStamp: RestateStamp?

    /// Notes that every part was brought to the model as it stands, so the end of a move, which
    /// would bring them all to it again, finds nothing to do unless the model moved meanwhile.
    func markRestated() {
        guard let entry = store?.entry(turnID) else { return }
        restateStamp = RestateStamp(
            entry: entry.revision, model: entry.model.revision, context: entry.context)
    }

    /// The account of the turn read on another thread while the press is still being answered: the
    /// model keeps what it reads, so the frame that makes the account finds it ready.
    private func prefetchAccount() {
        let model = model
        let answer = answerText
        let prompt = promptText
        Task.detached(priority: .userInitiated) {
            _ = model.account(answer: answer.isEmpty ? nil : answer, prompt: prompt)
        }
    }

    /// Brings every part to the model when anything it says changed. A token that lengthens a note
    /// the brain has not read again changes nothing the card or the open parts say, so it costs the
    /// comparison; the second's tick restates with `force`.
    @discardableResult
    func refresh(force: Bool = false) -> Bool {
        guard let store, let entry = store.entry(turnID) else {
            restateStamp = nil
            refreshAll()
            return true
        }
        let stamp = RestateStamp(
            entry: entry.revision, model: entry.model.revision, context: entry.context)
        guard force || stamp != restateStamp else { return false }
        restateStamp = stamp
        refreshAll()
        return true
    }

    private func apply(_ next: BrainRow, initial: Bool) {
        let old = row
        row = next
        if initial {
            syncCard()
            requestPicture()
            return
        }
        if old.isOpen != next.isOpen {
            if next.isOpen { open(animated: true) } else { close(animated: true) }
        } else if old.showsRows != next.showsRows {
            footer?.sync(now: BrainClock.now)
            syncCard()
        }
        refresh()
    }

    func refreshAll() {
        let begun = CACurrentMediaTime()
        defer { store?.noteSpent(CACurrentMediaTime() - begun) }
        syncBrowse()
        syncCard()
        requestPicture()
        stage?.refresh()
        footer?.sync(now: BrainClock.now)
        updateLeader()
        relayout()
    }

    /// The steps moved under the list: it redraws, follows a running turn, and the head dims what
    /// the filters hide.
    func syncBrowse() {
        guard phase != .closed || mover != nil else { return }
        let effects = updateModel { $0.drainBrowseEffects() }
        list?.modelChanged()
        chips?.invalidate()
        account?.refresh()
        if !effects.isEmpty { applyBrowse(effects, grabFocus: false) }
        drainAccountEffects()
    }

    @objc private func motionChanged() {
        stage?.refresh(force: true)
        syncCard()
    }

    private func rethemed() {
        wordmarkKey = 0
        BrainPictures.forgetAll()
        pictureRequested = ""
        syncCard()
        requestPicture()
        chips?.retheme()
        list?.retheme()
        account?.retheme()
        stage?.refresh(force: true)
        footer?.sync(now: BrainClock.now)
    }

    private func densityChanged() {
        metricsMemo = nil
        syncCard()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncCard()
        requestPicture()
    }


    var liveZone: NeuralZone? { cardInput?.card.live?.activeZone }
    var liveMotion: NeuralMotion { cardInput?.card.live?.motion ?? .still }

    /// Brings the card to the model.
    func syncCard() {
        guard let store, let entry = store.entry(turnID) else { return }
        let model = entry.model
        let m = currentMetrics
        let brainCard = model.brainCard(now: Date())
        let content = BrainCardView.Content(
            card: brainCard, showsRows: row.showsRows, isReplaying: model.isReplaying,
            canReplay: model.turn.outcome != .running && model.steps.count > 1, inks: inks,
            density: density, width: m.width, geometry: m.card, face: model.face,
            reduceMotion: reduceMotion)
        cardInput = content
        card.show(content, revision: entry.revision)
        if phase == .closed {
            picture.show(
                card: brainCard, inks: inks, hovered: card.hovered, lift: 1, liveZone: liveZone,
                liveMotion: liveMotion)
        }
        setAccessibilityLabel(NeuralReading.named(brainCard.spoken))
        if phase == .closed { toolTip = nil }
    }

    private func cardHoverChanged() {
        guard phase == .closed, let content = cardInput else { return }
        picture.show(
            card: content.card, inks: inks, hovered: card.hovered, lift: 1, liveZone: liveZone,
            liveMotion: liveMotion)
        if card.hovered { prefetchStage() }
    }

    /// The head's picture for this look and this turn's eye, asked for as soon as the row is
    /// built: it is shared, so the second card of a look costs nothing.
    private func requestPicture() {
        guard NeuralHeadView.isSupported else { return }
        let model = model
        let palette = inks.palette
        let frame = BrainPictures.restFrame(of: model)
        let wanted = BrainPictures.key(palette: palette, frame: frame, face: model.face)
        if wanted == pictureRequested, picture.hasImage { return }
        pictureRequested = wanted
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if let held = BrainPictures.cached(palette: palette, frame: frame, face: model.face) {
            picture.setImage(held, scale: scale, fading: card.isSettling)
            return
        }
        BrainPictures.picture(palette: palette, frame: frame, face: model.face) { [weak self] image in
            guard let self, self.pictureRequested == wanted else { return }
            self.picture.setImage(image, scale: scale, fading: true)
            self.needsLayout = true
        }
    }

    private func prefetchStage() {}


    var isOpenShown: Bool { phase != .closed && stage != nil }
    var hasStage: Bool { stage != nil }

    /// Whether this brain may build its stage: the person asked, and a Metal head can be drawn.
    private var stageMayOpen: Bool { MacBrain.isAvailable }

    func open(animated: Bool) {
        focusOnLanding = NSApp.currentEvent?.type == .keyDown
        if let mover {
            if !mover.isOpening { reverseMove() }
            return
        }
        guard phase == .closed, stageMayOpen else { return }
        let swapped = store?.consumeSwap(turnID) ?? false
        if animated && canMove {
            schedule = NeuralOpenSchedule()
            prefetchAccount()
            startMove(opening: true, swapped: swapped)
        } else {
            showStage()
        }
    }

    func close(animated: Bool) {
        if let mover {
            if mover.isOpening { reverseMove() }
            return
        }
        guard phase == .open else { return }
        let swapped = store?.consumeSwap(turnID) ?? false
        if animated && canMove { startMove(opening: false, swapped: swapped) } else { hideStage() }
    }

    private var canMove: Bool {
        parkReasons.isEmpty && MotionBudget.level < .critical && window != nil && bounds.width > 8
            && isVisible
    }

    var graveyard: [NSView] = []
    var burialScheduled = false

    /// The stage, list, account and footer in place with no move.
    func showStage() {
        guard stageMayOpen else {
            setPhase(.closed)
            return
        }
        makeParts()
        setPhase(.open)
        if startReplayOnOpen {
            startReplayOnOpen = false
            updateModel { $0.startReplay(now: BrainClock.now) }
        }
        applyPendingDive()
        refreshAll()
        let fromFind = store?.pendingFind[turnID] != nil
        applyPendingFind()
        if !fromFind, focusOnLanding { window?.makeFirstResponder(list ?? stage) }
        focusOnLanding = false
        relayout()
    }

    func hideStage() {
        guard phase != .closed || stage != nil else { return }
        mover = nil
        carrier.setTravel(.identity)
        dropParts()
        setPhase(.closed)
        syncCard()
        requestPicture()
        relayout()
    }

    func setPhase(_ next: Phase) {
        phase = next
        setAccessibilityExpanded(next != .closed)
        card.isHidden = next != .closed && next != .moving
        relayout()
    }

    func returnFocusFromBrain() {
        guard let window, let responder = window.firstResponder as? NSView,
            responder !== self, responder.isDescendant(of: self)
        else { return }
        window.makeFirstResponder(card.isHidden ? self : card)
    }


    func toggleRows() { store?.toggleRows(turnID) }

    func openDiving(into zone: NeuralZone) {
        store?.pendingDive[turnID] = zone
        store?.toggleOpen(turnID)
    }

    func applyPendingFind() {
        guard let needle = store?.pendingFind.removeValue(forKey: turnID), phase == .open,
            let id = store?.stepHolding(needle, turnID: turnID)
        else { return }
        browse(.click(id, double: false), grabFocus: false)
    }

    func applyPendingDive() {
        guard let zone = store?.pendingDive.removeValue(forKey: turnID) else { return }
        stage?.dive(into: zone)
    }

    func diveChanged(_ zone: NeuralZone?) {
        if let zone {
            browse(.zoneChip(zone, solo: true), grabFocus: false)
        } else {
            browse(.key(.character("0")), grabFocus: false)
        }
        relayout()
    }

    func stageActivity() {
        footer?.sync(now: BrainClock.now)
        updateLeader()
    }

    func toggleReplay() {
        if model.isReplaying {
            updateModel { $0.stopReplay() }
            afterReplayChange()
            return
        }
        guard model.turn.outcome != .running else { return }
        if phase == .closed {
            startReplayOnOpen = true
            store?.toggleOpen(turnID)
            return
        }
        updateModel { $0.startReplay(now: BrainClock.now) }
        afterReplayChange()
    }

    func scrub(to fraction: Double) {
        updateModel { $0.scrub(to: fraction) }
        afterReplayChange()
    }

    func endScrub() {
        updateModel { $0.endScrub() }
        afterReplayChange()
    }

    private func afterReplayChange() {
        stage?.refresh(force: true)
        stage?.head.setNeedsRender()
        syncCard()
        footer?.sync(now: BrainClock.now)
        account?.refresh()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func presentShare() {
        guard let store, let context, let window, model.turn.outcome != .running else { return }
        BrainSharePanel.present(turnID: turnID, store: store, context: context, on: window)
    }

    /// The answer's literal path-like words that a step carries: worked out once for an answer and
    /// a revision of the turn, not once a hover.
    var answerChips: [String] {
        let answer = answerText
        let revision = model.revision
        if let memo = tokenMemo, memo.answer == answer, memo.revision == revision { return memo.tokens }
        tokenComputations += 1
        let words = answer.isEmpty ? [] : model.answerTokens(in: answer).map(\.text)
        var seen = Set<String>()
        let unique = words.filter { seen.insert($0).inserted }
        tokenMemo = (answer, revision, unique)
        return unique
    }

    func pointAt(token: String?, hold: Bool) {
        let active = model.provenanceToken == token
        let next = hold ? (active ? nil : token) : token
        if !hold, model.provenanceToken != nil, !active, next == nil { /* released */ }
        stage?.setProvenance(next)
        footer?.sync(now: BrainClock.now)
    }


    /// A pane that parks, a window that closes or an app that has been away takes the head out of
    /// the row, which lets go of the textures; each gives its reason and takes it back, and the
    /// head is back only when nobody still wants it gone.
    func setParked(_ parked: Bool, reason: String = "pane") {
        if parked { parkReasons.insert(reason) } else { parkReasons.remove(reason) }
        if parkReasons.isEmpty { stage?.unpark() } else { stage?.park() }
        if parked, let mover { finishMove(snapOpen: mover.isOpening) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        syncCard()
        requestPicture()
    }


    override var acceptsFirstResponder: Bool { false }

    override func accessibilityPerformPress() -> Bool {
        store?.toggleOpen(turnID)
        return true
    }

    func pressLine() { store?.toggleOpen(turnID) }

    /// The reader scrolled: the head may have come into view or left it.
    func viewportMoved() {
        stage?.visibilityChanged()
        list?.viewportMoved()
    }
}
