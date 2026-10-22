import AppKit
import TailscodeCore

/// The long flipped view the story's items are placed in: it draws nothing, so it owns no backing
/// store whatever its height.
@MainActor
final class AccountDocumentView: NSView {
    nonisolated override var isFlipped: Bool { true }
}

/// The right side of an open brain: the agent talking to you. The entity's header, what the
/// person asked, the agent's plan, a column of what it said, what it thought, the work it did
/// folded to a line and the result that closes the turn, with whatever it is waiting on you for
/// pinned above and the step under the cursor opened inside the story. From an account of 924
/// points the open step's card stands beside the story instead of under its row.
///
/// The column scrolls and never owns more views than the window it shows: items are measured
/// when they are made, estimated while they are not, and only the ones near the viewport exist at
/// all, so a turn of two thousand steps costs what a screenful costs. A height that changes above
/// the reader moves the offset with it; the account follows the newest item while the turn runs
/// until the person scrolls.
@MainActor
final class BrainAccountView: NSView, BrainKeyTaker {
    private(set) weak var host: BrainSurfaceHost?
    private(set) var account: NeuralAccount
    private(set) var entries: [AccountEntry] = []
    var entryIndex: [String: Int] = [:]
    var cells: [String: AccountCell] = [:]
    var heights: [String: CGFloat] = [:]
    var offsets: [CGFloat] = []
    var total: CGFloat = 0

    var unfolded = Set<String>()
    var expandedText = Set<String>()
    var rowCaps: [String: Int] = [:]
    var planStoryOverride: [String: Bool] = [:]
    var planOpenOverride: Bool?
    var pinnedPlanCompact = false

    let header = AccountHeaderView()
    let narrowBar: AccountNarrowBar
    let scroll = HandoffScrollView()
    let document = AccountDocumentView()
    /// The one painter of a step's row, the list's own, so the story's unfolded rows and the list
    /// beside the head draw the same pixels.
    let rowPainter: BrainRowPainter
    let followPill: AccountButton
    let footerStrip: AccountFooterStrip
    var askView: AccountAskView?
    var nowView: AccountNowView?
    var planView: AccountPlanView?
    var askSignature = ""
    var nowSignature = ""
    var planSignature = ""
    var detail: AccountReadoutPage?
    private var hairline = AccountRuleView()

    var viewHeight: CGFloat = 0
    var regionWidth: CGFloat = 0
    var boxWidth: CGFloat = 0
    var padLeft: CGFloat = 20
    var bodyTop: CGFloat = 40
    var pinsBottom: CGFloat = 0
    var headerHeight: CGFloat = 40
    var storyRect = CGRect.zero
    var detailRect: CGRect?
    var isTwoColumns = false
    var holdsBody = false

    var arrivals: [String: Double] = [:]
    var justNow: [String: Double] = [:]
    var knownIDs = Set<String>()
    var seeded = false
    var pendingReveal: (id: String, pad: CGFloat)?
    var lastCursor: String?
    var suppressReveal: String?
    var realizeScheduled = false
    var realizing = false
    var realizeAgain = false
    var lastRefresh = 0.0
    var refreshPending = false
    var workStamps: [String: Int] = [:]
    var readStamp: ReadStamp?
    var holdAnchor: (id: String, delta: CGFloat)?
    var holdTicket = 0
    var copiedFlash: (stepID: String, until: Double)?
    var localHover: String?
    var lastActivityAt: Date?
    var lastActivityMark = ""
    var secondTimer: Timer?
    var filterWord: String?
    var bodyAlpha: CGFloat = 1
    var scrollAnimating = false
    private var scrollObserver: NSObjectProtocol?
    private(set) var hasFocusState = false
    var realizeCount = 0
    var buildCount = 0
    var refreshCount = 0
    var isAnimating = false
    var proseProbe: (line: CGFloat, em: CGFloat) = (20, 13.7)

    /// What the entries were made from: when none of it changed, a new cursor or hover is a change
    /// of what exists and not of what is said.
    struct ReadStamp: Equatable {
        var reads: Int
        var filter: NeuralStepList.Filter
        var total: Int
        var visible: Int
        var following: Bool
        var outcome: NeuralOutcome
        var answer: Int
    }

    static let footerHeight: CGFloat = 32
    static let padRight: CGFloat = 12
    static let saidGap: CGFloat = 12
    static let gap: CGFloat = 20
    static let arrivalDuration = 0.12
    static let justNowDuration = 6.0
    static let initialRows = 40
    static let rowStride = 40
    static let rowMax = 400

    init(host: BrainSurfaceHost) {
        self.host = host
        let paint = AccountPaint(host.inks)
        narrowBar = AccountNarrowBar(paint: paint)
        footerStrip = AccountFooterStrip(paint: paint)
        followPill = AccountButton(title: AccountWords.followingPaused, style: .pill, paint: paint)
        rowPainter = BrainRowPainter(inks: host.inks)
        let prompt = host.promptText
        let answer = host.answerText
        account = host.model.account(answer: answer.isEmpty ? nil : answer, prompt: prompt)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(header)
        addSubview(narrowBar)
        scroll.documentView = document
        scroll.acceptsFocus = false
        scroll.contentView.drawsBackground = false
        addSubview(scroll)
        addSubview(footerStrip)
        followPill.emphasis = "End"
        followPill.host = host
        followPill.isHidden = true
        followPill.wantsLayer = true
        followPill.layer?.shadowColor = NSColor.black.cgColor
        followPill.layer?.shadowOpacity = 0.3
        followPill.layer?.shadowRadius = 8
        followPill.layer?.shadowOffset = CGSize(width: 0, height: -3)
        followPill.layer?.masksToBounds = false
        followPill.onTap = { [weak self] in self?.jumpToLatest() }
        addSubview(followPill)
        scroll.onUserScroll = { [weak self] in self?.userScrolled() }
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
        narrowBar.host = host
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(AccountWords.accountLabel)
        proseProbe = Self.probe()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        secondTimer?.invalidate()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The items are made here, in the layout pass that gives the story its size, and never from
    /// a block deferred to a later turn: items made after the row had been laid out are not put
    /// in the layer tree until something else makes the window redraw, and the story stays blank.
    override func layout() {
        super.layout()
        layoutAccount()
        if needsRealizeNow() { realize() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSecondTimer()
        if window != nil { needsLayout = true }
    }


    var paint: AccountPaint { AccountPaint(host?.inks ?? BrainInks.current(for: effectiveAppearance)) }
    var model: NeuralBrainModel { host?.model ?? NeuralBrainModel(turn: NeuralTurn(id: "")) }
    var metrics: NeuralStageMetrics { host?.currentMetrics ?? NeuralStageMetrics.make(width: 600, density: .comfortable, zonesWithSteps: 1, viewportHeight: nil) }
    var reduceMotion: Bool { host?.reduceMotion ?? false }

    var promptText: String? {
        host?.promptText
    }

    var answerOrNil: String? {
        let text = host?.answerText ?? ""
        return text.isEmpty ? nil : text
    }

    /// When the turn began, in the machine's clock, for the footer.
    var beganClock: String? {
        let model = model
        guard let at = model.turn.startedAt ?? model.steps.compactMap(\.at).min() else { return nil }
        return NeuralReading.clock(at)
    }

    /// The prose role's line height and size.
    static func probe() -> (line: CGFloat, em: CGFloat) {
        (AccountType.lineHeight(.answer), AccountType.font(.answer).pointSize)
    }

    var isAccordion: Bool { metrics.arrangement == .accordion }

    /// A dive or a replay that takes the whole body of a layout with one column: the detail
    /// stands where the story was, because a zone's steps and a replay's log are not a story.
    var readoutHoldsBody: Bool {
        let m = metrics
        guard m.accountLayout != .split || m.arrangement == .accordion else { return false }
        return model.isReplaying || model.divedZone != nil
    }

    /// Whether the detail is drawn at all: beside the story when the account has two columns,
    /// over the body for a dive or a replay, and nowhere otherwise.
    var readoutIsShown: Bool {
        let m = metrics
        return (m.arrangement == .split && m.accountLayout == .split) || readoutHoldsBody
    }

    var scrollY: CGFloat { scroll.contentView.bounds.origin.y }
    var maxScroll: CGFloat { max(0, total - viewHeight) }


    /// The model changed: a step arrived, a status moved, a filter was set, the cursor or the
    /// hover went elsewhere. The account is read again, and what is on screen is brought to it.
    func refresh(immediate: Bool = false) {
        guard let host else { return }
        let now = CACurrentMediaTime()
        if !immediate, now - lastRefresh < 0.06 {
            guard !refreshPending else { return }
            refreshPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self else { return }
                self.refreshPending = false
                self.refresh(immediate: true)
            }
            return
        }
        lastRefresh = now
        refreshCount += 1
        let model = host.model
        let list = model.browseState.list
        let next = model.account(answer: answerOrNil, prompt: promptText)
        let stamp = ReadStamp(
            reads: model.accountReads, filter: list.filter, total: list.total, visible: list.visibleCount,
            following: list.isFollowing, outcome: model.turn.outcome, answer: host.answerText.utf8.count)
        guard stamp != readStamp || entries.isEmpty else {
            followCursor()
            refreshChrome()
            clampScroll()
            scheduleRealize()
            refreshDetail(animate: true)
            return
        }
        readStamp = stamp
        account = next
        let made = AccountEntries.make(model: model, account: next, list: list)
        let live = model.turn.outcome == .running
        let fresh = made.filter { !knownIDs.contains($0.id) }
        if seeded, live, list.isFollowing, !reduceMotion {
            for entry in fresh {
                arrivals[entry.id] = now
                if entry.isSaid { scheduleJustNow(entry.id) }
            }
        }
        knownIDs.formUnion(made.map(\.id))
        seeded = true
        entries = made
        entryIndex = Dictionary(uniqueKeysWithValues: made.enumerated().map { ($1.id, $0) })
        heights = heights.filter { entryIndex[$0.key] != nil }
        workStamps = [:]
        for entry in made {
            guard case .work(let work) = entry.kind else { continue }
            var hasher = Hasher()
            for id in work.stepIDs {
                guard let step = model.step(id: id) else { continue }
                hasher.combine(id)
                hasher.combine(step.status)
                hasher.combine(step.outputLines.count)
                hasher.combine(step.call?.call.output?.utf8.count ?? 0)
            }
            workStamps[entry.id] = hasher.finalize()
        }
        recomputeOffsets()
        refreshChrome()
        followCursor()
        followNewest()
        clampScroll()
        scheduleRealize()
        refreshDetail(animate: true)
        needsLayout = true
    }

    func retheme() {
        if let host { rowPainter.reset(inks: host.inks) }
        header.show(headerContent())
        footerStrip.paint = paint
        followPill.paint = paint
        dropPins()
        readStamp = nil
        proseProbe = Self.probe()
        for cell in cells.values { cell.stale = true }
        heights = [:]
        detail?.retheme()
        refresh(immediate: true)
        needsDisplay = true
    }

    func geometryChanged() {
        holdAnchorHere()
        holdFor(0.45)
        heights = [:]
        for cell in cells.values { cell.stale = true }
        needsLayout = true
        scheduleRealize()
    }

    func setBodyAlpha(_ alpha: Double) {
        bodyAlpha = CGFloat(alpha)
        if alpha >= 1 {
            alphaValue = 1
        }
        for view in [scroll, footerStrip, followPill] as [NSView] { view.alphaValue = bodyAlpha }
        for view in [askView, nowView, planView] as [NSView?] { view?.alphaValue = bodyAlpha }
        detail?.alphaValue = bodyAlpha
        narrowBar.alphaValue = bodyAlpha
    }

    /// Scrolls so the item holding the step is visible. A press inside the account does not
    /// scroll it: the item is under the pointer already.
    func revealStep(_ id: String) {
        if suppressReveal == id { return }
        guard let item = account.item(containing: id), var at = entryIndex[item.id] else { return }
        var pad: CGFloat = 8
        if case .work(let work) = entries[at].kind, isOpen(entries[at], work: work),
            let row = work.stepIDs.firstIndex(of: id)
        {
            let inside = 36 + 4 + CGFloat(row) * 28
            if inside > viewHeight * 0.6 { pad = viewHeight * 0.35 - inside }
        }
        if pad == 8, entries[at].isWork, at > 0, entries[at - 1].isSaid { at -= 1 }
        pendingReveal = (entries[at].id, pad)
        scheduleRealize()
        let target = min(max(offsets[at] - pad, 0), maxScroll)
        scrollTo(target, animated: true)
        verifyReveal()
    }

    /// Space or `o` on a card: unfolds the long output or the diff of the card under the cursor,
    /// or of the detail column's step.
    func toggleCardOutput() -> Bool {
        for cell in cells.values {
            if let work = cell as? AccountWorkCell, work.toggleCursorCardOutput() { return true }
        }
        if let detail, detail.toggleOutput() { return true }
        return false
    }

    func flashCopied(_ stepID: String) {
        copiedFlash = (stepID, CACurrentMediaTime() + 1.4)
        setCopyLabel(for: stepID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.45) { [weak self] in
            guard let self, let flash = self.copiedFlash, flash.stepID == stepID,
                CACurrentMediaTime() >= flash.until
            else { return }
            self.copiedFlash = nil
            self.setCopyLabel(for: stepID)
        }
    }

    func copyWord(for stepID: String) -> String {
        if let flash = copiedFlash, flash.stepID == stepID, CACurrentMediaTime() < flash.until { return AccountWords.copied }
        return NeuralReading.copyLabel
    }

    private func setCopyLabel(for stepID: String) {
        guard let item = account.item(containing: stepID), let cell = cells[item.id] as? AccountSaidCell else { return }
        cell.setCopyTitle(copyWord(for: stepID))
    }

    func focus() {
        window?.makeFirstResponder(self)
    }

    var hasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    func takesBrainKey(_ event: NSEvent) -> Bool { host?.brainKeyApplies(event) ?? false }

    func focusSearch() {
        guard isAccordion else { return }
        narrowBar.focusField()
    }


    override func becomeFirstResponder() -> Bool {
        host?.updateModel { $0.setBrowseFocus(.readout) }
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        let result = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in
            guard let self, let host = self.host, host.model.browseFocus == .readout, !self.hasFocus else { return }
            host.updateModel { $0.setBrowseFocus(.list) }
        }
        return result
    }

    override func mouseDown(with event: NSEvent) {
        if !hasFocus { focus() }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleKey(event) { return }
        super.keyDown(with: event)
    }


    override func draw(_ dirtyRect: NSRect) {
        let paint = paint
        if metrics.arrangement == .split {
            paint.rule2.setFill()
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        }
        if window?.firstResponder === self, !storyRect.isEmpty {
            paint.accent.withAlphaComponent(0.55).setStroke()
            let path = NSBezierPath(roundedRect: storyRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
            path.lineWidth = 1
            path.stroke()
        }
    }

    override var focusRingMaskBounds: NSRect { .zero }

    /// What the harness reads: how many items exist, how long the story is, where it is scrolled.
    var reading: String {
        let held = cells.keys.compactMap { entryIndex[$0] }.sorted()
        let range = held.isEmpty ? "-" : "\(held.first!)...\(held.last!)"
        var views = 0
        func count(_ view: NSView) {
            views += 1
            for child in view.subviews { count(child) }
        }
        count(self)
        return String(
            format: "items=%d realized=%d range=%@ views=%d total=%.0f scroll=%.0f view=%.0f box=%.0f refreshes=%d realizes=%d builds=%d",
            entries.count, cells.count, range, views, total, scrollY, viewHeight, boxWidth, refreshCount,
            realizeCount, buildCount)
    }

    /// The text of every label and word of the items that exist, in story order.
    var visibleText: String {
        var words: [String] = []
        func walk(_ view: NSView) {
            if view.isHidden { return }
            if let text = view as? AccountTextView { words.append(text.string) }
            if let button = view as? AccountButton { words.append(button.title) }
            if let pill = view as? AccountPill { words.append(pill.word) }
            if let label = view as? AccountLabelRow { words.append(label.label) }
            if let page = view as? AccountReadoutPage { words.append(page.visibleText) }
            if let cell = view as? AccountCell { words.append(contentsOf: cell.drawnWords) }
            if view is AccountBlock, let label = view.accessibilityLabel(), !label.isEmpty { words.append(label) }
            for child in view.subviews { walk(child) }
        }
        words.append(header.accessibilityLabel() ?? "")
        for pin in [askView, nowView, planView] as [NSView?] {
            if let pin { walk(pin) }
        }
        for entry in entries { if let cell = cells[entry.id] { walk(cell) } }
        if let detail { walk(detail) }
        return words.joined(separator: "\n")
    }
}
