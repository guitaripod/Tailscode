import AppKit
import TailscodeCore

/// What the list draws from, taken from the turn's model whenever it changes and read by every
/// part, so no part reaches into the model while a frame is being drawn.
struct BrainListSnapshot {
    var list = NeuralStepList()
    var cursor: String?
    var hovered: String?
    var searchOpen = false
}

/// The step list under the head: a header (search, the failed toggle and the count), the rows in a
/// native scroll view, and the key hint. What a row says comes from Core's `NeuralStepList` and
/// what a key or a click does comes from `NeuralBrowse` through the host, so this draws, scrolls
/// and measures. Only the rows the window shows are drawn, the wheel is the system's own, and
/// nothing here owns a clock while nothing moves.
@MainActor
final class BrainListView: NSView, BrainKeyTaker {
    private(set) weak var host: BrainSurfaceHost?
    private(set) var metrics: NeuralStageMetrics
    let painter: BrainRowPainter
    private(set) var snapshot = BrainListSnapshot()
    private(set) var header: BrainListHeader!
    private(set) var scroll: HandoffScrollView!
    private(set) var rows: BrainListRowsView!
    private(set) var overlay: BrainListOverlay!
    private(set) var hint: BrainListHint!

    private(set) var revealRows: NeuralRowReveal?
    private(set) var headerAlpha = 1.0
    private(set) var arrival: (from: Int, start: Double)?
    let arrivalDuration = 0.12
    private var arrivalClock: BrainClock?
    private var lastTotal = 0
    private(set) var copiedID: String?
    private var copiedTimer: Timer?
    private(set) var pointerRowID: String?
    private(set) var pointerCopy = false
    private var pointerPoint: CGPoint?
    private var pointerIsDriven = false
    private(set) var programmatic = 0
    private(set) var scrollTarget: CGFloat = 0
    private var lastOffset: CGFloat = 0
    private var lastFirstPosition = -1
    private var shownOnce = false
    private(set) var manualScrolls = 0
    static let scrollDuration = 0.16

    init(host: BrainSurfaceHost) {
        self.host = host
        metrics = host.currentMetrics
        painter = BrainRowPainter(inks: host.inks)
        super.init(frame: .zero)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(BrainListWords.stepList)
        header = BrainListHeader(owner: self)
        scroll = HandoffScrollView(frame: .zero)
        rows = BrainListRowsView(owner: self)
        overlay = BrainListOverlay(owner: self)
        hint = BrainListHint(owner: self)
        scroll.documentView = rows
        scroll.onUserScroll = { [weak self] in self?.userScrolled() }
        for view in [header, scroll, overlay, hint] as [NSView] { addSubview(view) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)
        modelChanged()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        copiedTimer?.invalidate()
        arrivalClock?.stop()
    }

    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var searchOpen: Bool { snapshot.searchOpen }
    var isFocused: Bool { window?.firstResponder === self }
    var isWide: Bool { metrics.column.width >= Double(BrainRowPainter.wideColumn) }

    var isAnimating: Bool {
        programmatic > 0 || arrival != nil || copiedID != nil || revealRows != nil
    }

    var viewportHeight: CGFloat { scroll.bounds.height }
    var contentHeight: CGFloat { CGFloat(snapshot.list.contentHeight()) }
    var maxOffset: CGFloat { max(0, contentHeight - viewportHeight) }
    var offset: CGFloat { scroll.contentView.bounds.origin.y }
    var firstVisiblePosition: Int { snapshot.list.position(atOffset: Double(max(offset, 0))) }
    var visibleRowCount: Int { Int(ceil(viewportHeight / CGFloat(metrics.listRowHeight))) + 1 }


    func configure(metrics next: NeuralStageMetrics) {
        guard next != metrics else { return }
        metrics = next
        needsLayout = true
        rows.needsDisplay = true
        hint.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let rowsHeight = CGFloat(metrics.listRows.height)
        header.frame = CGRect(x: 0, y: 0, width: width, height: BrainListHeader.height)
        scroll.frame = CGRect(x: 0, y: BrainListHeader.height, width: width, height: rowsHeight)
        overlay.frame = scroll.frame
        let showsHint = metrics.listHint != nil
        hint.isHidden = !showsHint
        hint.frame = CGRect(
            x: 0, y: BrainListHeader.height + rowsHeight + CGFloat(NeuralStageMetrics.listFootPadding),
            width: width, height: CGFloat(NeuralStageMetrics.listHintHeight))
        syncDocument()
        if !shownOnce, viewportHeight > 0 {
            shownOnce = true
            if let cursor = snapshot.cursor {
                reveal(cursor, animated: false)
            } else if snapshot.list.isFollowing, let newest = snapshot.list.lastVisibleID {
                reveal(newest, animated: false)
            }
        }
    }

    /// The document is as tall as the whole turn, and the offset is kept inside it.
    private func syncDocument() {
        let size = CGSize(
            width: scroll.contentSize.width, height: max(contentHeight, viewportHeight))
        if rows.frame.size != size { rows.setFrameSize(size) }
        let clamped = min(max(offset, 0), maxOffset)
        if clamped != offset { jump(to: clamped) }
        scrollTarget = min(max(scrollTarget, 0), maxOffset)
        rows.syncPulses()
    }


    /// The steps, the filters, the cursor or the hover changed under the list.
    func modelChanged() {
        guard let host else { return }
        let model = host.model
        let list = model.browseState.list
        snapshot = BrainListSnapshot(
            list: list, cursor: model.pinnedStep, hovered: model.browseState.hovered,
            searchOpen: model.browseState.searchOpen)
        let firstFill = lastTotal == 0 && list.total > 0
        noteArrival(list)
        syncDocument()
        if firstFill, list.isFollowing, let newest = list.lastVisibleID { reveal(newest, animated: false) }
        syncSearch()
        refreshLabel()
        header.needsLayout = true
        header.needsDisplay = true
        overlay.needsDisplay = true
        rows.needsDisplay = true
        if pointerPoint != nil { refreshPointer() }
    }

    private func noteArrival(_ list: NeuralStepList) {
        defer { lastTotal = list.total }
        guard list.total > lastTotal, lastTotal > 0, list.isLive, let host, !host.reduceMotion,
            window != nil
        else { return }
        arrival = (lastTotal, BrainClock.now)
        let clock = arrivalClock ?? BrainClock(view: self) { [weak self] time in self?.arrivalTick(time) }
        arrivalClock = clock
        clock.run()
        if !clock.isRunning { arrival = nil }
        host.animationChanged()
    }

    private func arrivalTick(_ time: Double) {
        rows.needsDisplay = true
        guard let arrival, time - arrival.start >= arrivalDuration else { return }
        self.arrival = nil
        arrivalClock?.stop()
        rows.needsDisplay = true
        host?.animationChanged()
    }

    /// The accessible name: the row the cursor is on, said the way a step is announced.
    private func refreshLabel() {
        let list = snapshot.list
        if let row = list.cursorRow {
            setAccessibilityLabel(
                BrainListWords.stepList + ": "
                    + BrainListWords.stepRowLabel(
                        number: row.number, total: list.total, title: row.title,
                        argument: row.argument, status: row.verdict.word))
        } else {
            setAccessibilityLabel(BrainListWords.stepList + ": " + list.countLabel)
        }
    }

    func retheme() {
        guard let host else { return }
        painter.reset(inks: host.inks)
        header.box.retheme()
        header.needsDisplay = true
        rows.needsDisplay = true
        rows.syncPulses()
        overlay.needsDisplay = true
        hint.needsDisplay = true
    }

    func setReveal(rows reveal: NeuralRowReveal?, headerAlpha alpha: Double) {
        let changed = reveal != revealRows || alpha != headerAlpha
        revealRows = reveal
        headerAlpha = alpha
        header.alphaValue = CGFloat(alpha)
        guard changed else { return }
        rows.needsDisplay = true
    }


    private func userScrolled() {
        if programmatic > 0 { cancelAnimation() }
    }

    /// Stops an eased scroll where it stands, because a hand took over.
    private func cancelAnimation() {
        let clip = scroll.contentView
        let here = clip.bounds.origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            clip.animator().setBoundsOrigin(here)
        }
    }

    @objc private func clipBoundsChanged() { offsetChanged() }

    private func offsetChanged() {
        let y = offset
        guard abs(y - lastOffset) > 0.01 else { return }
        lastOffset = y
        if scroll.isUserScrolling {
            scrollTarget = y
            if snapshot.list.following {
                manualScrolls += 1
                host?.browse(.scrolled(manual: true), grabFocus: false)
            }
        }
        let first = firstVisiblePosition
        if first != lastFirstPosition {
            lastFirstPosition = first
            rows.syncPulses()
        }
        if pointerPoint != nil { refreshPointer() }
    }

    /// Scrolls so the row is in view: the least that shows it, or the middle when it is far.
    func scrollTo(_ id: String) {
        modelChanged()
        reveal(id, animated: true)
    }

    func reveal(_ id: String, animated: Bool) {
        let list = snapshot.list
        guard let position = list.visibleIndex(of: id) else { return }
        let rowTop = CGFloat(list.offset(ofVisible: position))
        let rowTall = CGFloat(list.row(atVisible: position)?.height() ?? 28)
        let rowBottom = rowTop + rowTall
        let view = viewportHeight
        var wanted = scrollTarget
        if rowTop < offset - view || rowBottom > offset + 2 * view {
            let step = CGFloat(metrics.listRowHeight)
            wanted = ((rowTop - (view - rowTall) / 2) / step).rounded() * step
        } else if rowTop < scrollTarget {
            wanted = rowTop
        } else if rowBottom > scrollTarget + view {
            wanted = rowBottom - view
        }
        setOffset(wanted, animated: animated)
    }

    func setOffset(_ y: CGFloat, animated: Bool) {
        let clamped = min(max(y, 0), maxOffset)
        scrollTarget = clamped
        guard abs(clamped - offset) > 0.01 else { return }
        let motion = animated && host?.reduceMotion == false && window?.isVisible == true
        guard motion else {
            jump(to: clamped)
            return
        }
        let clip = scroll.contentView
        programmatic += 1
        host?.animationChanged()
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = Self.scrollDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: clamped))
            },
            completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.programmatic = max(0, self.programmatic - 1)
                    self.scroll.reflectScrolledClipView(self.scroll.contentView)
                    self.host?.animationChanged()
                }
            })
    }

    private func jump(to y: CGFloat) {
        let clip = scroll.contentView
        programmatic += 1
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        programmatic -= 1
    }


    private struct Hit {
        let id: String
        let copy: Bool
    }

    private func hit(at point: CGPoint) -> Hit? {
        let list = snapshot.list
        guard list.visibleCount > 0, point.y >= 0, point.y < CGFloat(list.contentHeight()) else {
            return nil
        }
        let position = list.position(atOffset: Double(point.y))
        guard let row = list.row(atVisible: position) else { return nil }
        let local = CGPoint(x: point.x, y: point.y - CGFloat(list.offset(ofVisible: position)))
        let rect = painter.copyRect(for: row, width: rows.bounds.width, copied: copiedID == row.id)
        return Hit(id: row.id, copy: rect.contains(local))
    }

    /// The pointer is over a point of the rows, or left them: the row under it takes the wash and
    /// the Copy button, and the readout previews it.
    func pointerMoved(to point: CGPoint?) {
        pointerIsDriven = false
        place(pointer: point)
    }

    private func place(pointer point: CGPoint?) {
        pointerPoint = point
        var id: String?
        var copy = false
        if let point, let found = hit(at: point) {
            id = found.id
            copy = found.copy
        }
        let rowChanged = id != pointerRowID
        guard rowChanged || copy != pointerCopy else { return }
        pointerRowID = id
        pointerCopy = copy
        rows.pulsesHideRow(id)
        rows.needsDisplay = true
        if copy { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        if rowChanged { host?.hoverStep(id) }
    }

    /// The page scrolled under a resting pointer: the row it was on is not the row it is on.
    func viewportMoved() { if pointerPoint != nil { refreshPointer() } }

    /// The pointer has not moved but what is under it has, because the list scrolled or changed.
    private func refreshPointer() {
        guard !pointerIsDriven, let window, window.isVisible else {
            return
        }
        let local = rows.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard rows.visibleRect.contains(local) else {
            pointerMoved(to: nil)
            return
        }
        pointerMoved(to: local)
    }

    func pressed(at point: CGPoint, clicks: Int) {
        guard let host else { return }
        guard let found = hit(at: point) else {
            host.focusList()
            return
        }
        if found.copy, pointerRowID == found.id {
            host.browse(.copyItem(found.id), grabFocus: false)
            host.focusList()
            return
        }
        host.browse(.click(found.id, double: clicks >= 2), grabFocus: true)
    }

    func contextPressed(at point: CGPoint, event: NSEvent) {
        guard let found = hit(at: point) else { return }
        host?.presentMenu(forStep: found.id, event: event, in: rows)
    }

    func flashCopied(_ id: String, seconds: Double = 1.0) {
        copiedID = id
        copiedTimer?.invalidate()
        copiedTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.copiedID = nil
                self?.rows.needsDisplay = true
                self?.host?.animationChanged()
            }
        }
        rows.needsDisplay = true
        host?.animationChanged()
    }


    func openSearch() {
        guard let host else { return }
        host.updateModel { $0.setBrowseFocus(.list) }
        host.browse(.key(.character("/")), grabFocus: true)
    }

    func focusSearch() {
        modelChanged()
        guard snapshot.searchOpen else { return }
        header.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(header.box.field)
    }

    /// The field shows while the browse state says the search is open, with the query it holds.
    private func syncSearch() {
        let open = snapshot.searchOpen
        if header.box.isHidden == open { header.box.isHidden = !open }
        let query = snapshot.list.filter.search
        let field = header.box.field
        if field.stringValue != query { field.stringValue = query }
    }

    func searchFocusChanged(_ entered: Bool) {
        guard let host else { return }
        if entered {
            host.updateModel {
                $0.setBrowseFocus(.search)
                $0.setBrowseSearchOpen(true)
            }
        } else {
            host.updateModel {
                if $0.browseFocus == .search { $0.setBrowseFocus(.list) }
                if $0.browseState.list.filter.query.isEmpty { $0.setBrowseSearchOpen(false) }
            }
        }
        modelChanged()
        header.box.needsDisplay = true
    }

    func searchTextChanged(_ text: String) {
        host?.browse(.searchText(text), grabFocus: false)
    }

    /// A key that leaves the search or walks its matches: it goes through the same reducer every
    /// other key does, so the focus rules of the search live in Core.
    func searchKey(_ key: NeuralBrowse.Key, event: NSEvent?) {
        guard let host else { return }
        let keyed = event.flatMap { $0.type == .keyDown ? $0 : nil }
        let handled = keyed.map { host.handleBrainKey($0, from: self) } ?? false
        if !handled { host.browse(.key(key), grabFocus: true) }
        if key == .enter { host.focusList() }
    }

    func toggleFailed() {
        host?.browse(.failedToggle, grabFocus: false)
        host?.focusList()
    }

    func jumpToLatest() {
        host?.browse(.jumpToLatest, grabFocus: true)
        host?.focusList()
    }

    func toggleLegend() {
        guard let host else { return }
        host.updateModel { $0.setBrowseFocus(.list) }
        host.browse(.key(.character("?")), grabFocus: false)
    }

    /// Lets go of every filter the way Esc does, one layer at a time, so the search field, the
    /// chips and the cursor's own rules stay Core's.
    func clearAllFilters() {
        guard let host else { return }
        var guardCount = 0
        while host.model.browseState.list.filter.isActive, guardCount < 4 {
            host.browse(.key(.escape), grabFocus: false)
            guardCount += 1
        }
        host.focusList()
    }


    func takesBrainKey(_ event: NSEvent) -> Bool { host?.brainKeyApplies(event) ?? false }

    override func keyDown(with event: NSEvent) {
        if host?.handleBrainKey(event, from: self) == true { return }
        super.keyDown(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        retheme()
    }

    override func becomeFirstResponder() -> Bool {
        host?.stageFocusChanged(true)
        overlay.needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        overlay.needsDisplay = true
        host?.stageFocusChanged(false)
        return true
    }


    func accessibilityRowElements(in view: BrainListRowsView) -> [Any] {
        let list = snapshot.list
        let range = list.visibleRange(offset: Double(offset), height: Double(viewportHeight))
        return range.compactMap { position -> Any? in
            guard let row = list.row(atVisible: position) else { return nil }
            let element = BrainRowElement(stepID: row.id)
            element.setAccessibilityRole(.row)
            element.setAccessibilityParent(view)
            element.setAccessibilityLabel(
                BrainListWords.stepRowLabel(
                    number: row.number, total: list.total, title: row.title, argument: row.argument,
                    status: row.verdict.word))
            element.setAccessibilityFrameInParentSpace(
                CGRect(
                    x: 0, y: CGFloat(list.offset(ofVisible: position)), width: view.bounds.width,
                    height: CGFloat(row.height())))
            element.isSelected = snapshot.cursor == row.id
            let id = row.id
            element.onPress = { [weak self] in self?.host?.browse(.click(id, double: false), grabFocus: true) }
            return element
        }
    }


    var ownsClock: Bool { arrivalClock?.isRunning == true }
    var pulseCountForChecks: Int { rows.pulseCount }
    var pulseHasAnimationForChecks: Bool { rows.pulsesBreathe }

    /// The ids of the rows in view, top to bottom.
    var visibleIDs: [String] {
        let list = snapshot.list
        return list.rows(atOffset: Double(offset), height: Double(viewportHeight)).map(\.id)
    }

    /// Where a row stands in the list's own coordinates, for the checks to point at.
    func rowFrame(of id: String) -> CGRect? {
        let list = snapshot.list
        guard let position = list.visibleIndex(of: id), let row = list.row(atVisible: position) else {
            return nil
        }
        return CGRect(
            x: 0, y: BrainListHeader.height + CGFloat(list.offset(ofVisible: position)) - offset,
            width: bounds.width, height: CGFloat(row.height()))
    }

    /// Puts the pointer on a row (or on its Copy button) as if it had moved there, for the drive
    /// verbs and the checks: the row is brought into view first.
    func driveHover(_ id: String?, copy: Bool = false) {
        guard let id else {
            pointerIsDriven = false
            place(pointer: nil)
            return
        }
        modelChanged()
        reveal(id, animated: false)
        let list = snapshot.list
        guard let position = list.visibleIndex(of: id), let row = list.row(atVisible: position) else { return }
        let top = CGFloat(list.offset(ofVisible: position))
        let x = copy ? rows.bounds.width - 30 : min(rows.bounds.width - 40, 160)
        pointerIsDriven = true
        place(pointer: CGPoint(x: x, y: top + CGFloat(row.height()) / 2))
    }

    /// What the list holds, for the drive's report.
    var reading: String {
        "rows=\(rows.rowsDrawn) offset=\(Int(offset))/\(Int(maxOffset)) pointer=\(pointerRowID ?? "-")"
            + " copy=\(pointerCopy) copied=\(copiedID ?? "-") pulses=\(rows.pulseCount)"
            + " following=\(snapshot.list.following) pill=\(snapshot.list.showsFollowPill)"
            + " search=\(searchOpen) focus=\(isFocused) wide=\(isWide)"
    }

    /// Scrolls the way a hand does: the offset moves and the list is told a person did it.
    func driveScroll(to y: CGFloat) {
        jump(to: min(max(y, 0), maxOffset))
        scrollTarget = offset
        host?.browse(.scrolled(manual: true), grabFocus: false)
    }
}
