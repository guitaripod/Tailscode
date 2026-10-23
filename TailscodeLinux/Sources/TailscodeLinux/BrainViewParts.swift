import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension BrainView {
    func setPhase(_ next: Phase) {
        phase = next
        gtk_widget_set_focusable(widget, next == .closed ? 1 : 0)
        gtk_widget_set_cursor_from_name(widget, next == .closed ? "pointer" : nil)
        gtk_widget_set_tooltip_text(widget, next == .closed ? card.card.spoken : nil)
        tailscode_set_accessible_expanded(widget, next == .closed ? 0 : 1)
        if next == .closed {
            gtk_widget_add_css_class(widget, "bn-closed")
        } else {
            gtk_widget_remove_css_class(widget, "bn-closed")
        }
        relayout()
    }

    // MARK: restating

    /// Brings the view to a new row value; the widget stays.
    func restate(_ next: BrainRow) {
        let old = row
        row = next
        refreshContextInto()
        if old.look != next.look || old.slot.outline.modelID != next.slot.outline.modelID {
            inks = BrainInks(palette: MatrixTheme.palette, face: model.face)
            stage?.retheme()
            card.retheme()
            readout?.retheme()
            list?.retheme()
            filters?.retheme()
            account?.retheme()
        }
        card.refresh()
        if old.open != next.open {
            host?.anchor?()
            if next.open { open(animated: true) } else { close(animated: true) }
        } else if old.showRows != next.showRows {
            footer?.sync(BrainClock.now)
        }
        stage?.modelChanged()
        footer?.rebuildChips(width: currentMetrics.width)
        footer?.configure(width: currentMetrics.width, running: model.turn.outcome == .running)
        refreshReadout(animate: false)
        redrawNow()
        updateClock()
    }

    func refreshContextInto() {
        let brainContext = host?.context(for: turnID) ?? .none
        model.update(turn: row.turn, context: brainContext)
        syncBrowse()
    }

    /// The steps moved under the list: it redraws, follows a running turn, and the head dims what
    /// the filters hide.
    func syncBrowse() {
        let effects = model.drainBrowseEffects()
        list?.modelChanged()
        filters?.invalidate()
        account?.refresh()
        if model.stepList.isFiltered { refreshDimming() }
        if !effects.isEmpty { applyBrowse(effects, grabFocus: false) }
    }

    /// The conversation's account of the live turn changed.
    func refreshContext() {
        let brainContext = host?.context(for: turnID) ?? .none
        model.update(turn: row.turn, context: brainContext)
        syncBrowse()
        stage?.modelChanged()
        card.refresh()
        refreshReadout(animate: false)
        redrawNow()
        updateClock()
    }

    /// The palette or the face changed: the colours are made again and the head is drawn afresh.
    func rethemed() {
        metricsMemo = nil
        inks = BrainInks(palette: MatrixTheme.palette, face: model.face)
        stage?.retheme()
        card.retheme()
        readout?.retheme()
        list?.retheme()
        filters?.retheme()
        account?.retheme()
        refreshReadout(animate: false)
        redrawNow()
    }

    func handleKey(keyval: UInt32, state: UInt32) -> Bool {
        guard hasBrainFocus else { return false }
        return brainKey(keyval: keyval, state: state)
    }

    /// The governor's debounced verdict moved. The stage's widgets stay as they are: a head that
    /// may not be drawn keeps its last picture and stops asking for frames, and takes them again
    /// when it may, so a window at the edge of the threshold cannot make anything flap.
    func budgetChanged() {
        let allowed = BrainBudget.stageAllowed
        stage?.drawing = allowed
        if allowed {
            stage?.invalidate()
            needsDraw = true
        }
        if row.open, stage == nil, phase == .closed, allowed, !isSuspended, moveState == nil {
            showStage()
        }
        motionChanged()
    }

    func motionChanged() {
        stage?.invalidate()
        redrawNow()
        updateClock()
    }

    /// Whether the brain is in the part of the transcript the reader can see, which decides
    /// whether it owns a clock at all. Asked at most four times a second.
    var isVisible: Bool {
        guard gtk_widget_get_mapped(widget) != 0, !isSuspended else { return false }
        let now = BrainClock.now
        if let cached = visibleCache, now - cached.time < 0.25 { return cached.value }
        let value = host?.isOnScreen(self) ?? true
        visibleCache = (now, value)
        return value
    }

    /// The reader scrolled: the brain may have come into view or left it.
    func viewportMoved() {
        visibleCache = nil
        let nowVisible = isVisible
        if nowVisible, stage != nil { needsDraw = true }
        if nowVisible { card.ensureContent() }
        updateClock()
    }

    /// The answer's literal path-like words that a step carries, which the footer's chips and the
    /// harness read: worked out once for an answer and a revision of the turn, not once a hover.
    var answerChips: [String] {
        if let memo = tokenMemo, memo.answer == row.answer, memo.revision == model.revision {
            return memo.tokens
        }
        tokenComputations += 1
        let words = row.answer.isEmpty ? [] : model.answerTokens(in: row.answer).map(\.text)
        var seen = Set<String>()
        let unique = words.filter { seen.insert($0).inserted }
        tokenMemo = (row.answer, model.revision, unique)
        return unique
    }

    // MARK: opening and closing

    var canMove: Bool {
        !isSuspended && BrainBudget.stageAllowed && NeuralAssetFiles.isAvailable
            && gtk_widget_get_mapped(widget) != 0 && gtk_widget_get_width(widget) > 8
            && (host?.isOnScreen(self) ?? true)
    }

    func open(animated: Bool) {
        if let move = moveState {
            if !move.opening { reverseMove() }
            return
        }
        guard phase == .closed else { return }
        guard stageMayOpen, NeuralAssetFiles.isAvailable else { return }
        let swapped = host?.consumeSwap(turnID) ?? false
        guard animated, canMove else {
            showStage()
            return
        }
        makeHead()
        openSchedule = NeuralOpenSchedule()
        movedFrames = 0
        prefetchAccount()
        pendingOpen = PendingOpen(started: BrainClock.now, swapped: swapped)
        stage?.ensureRenderer()
        startOpeningIfReady()
        if pendingOpen != nil {
            Gtk.after(Self.openFallbackMilliseconds) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, !self.disposed, let pending = self.pendingOpen else { return }
                    _ = pending
                    self.pendingOpen = nil
                    self.showStage()
                }
            }
        }
    }

    func close(animated: Bool) {
        if pendingOpen != nil {
            pendingOpen = nil
            dropParts()
            return
        }
        if let move = moveState {
            if move.opening { reverseMove() }
            return
        }
        guard phase == .open else { return }
        let swapped = host?.consumeSwap(turnID) ?? false
        guard animated, canMove, stage?.hasPicture == true else {
            hideStage()
            return
        }
        startClosing(swapped: swapped)
    }

    /// Builds the stage, readout and footer without showing them: what a move needs in hand.
    func makeParts() {
        guard stage == nil else { return }
        makeHead()
        makeList()
        makeAccount()
        fillAccount()
    }

    /// What the card turns into first: the head, the chips, the readout and the footer. The list
    /// and the account are made on the frames of the move that follows, one to a frame, because
    /// building them with the rest was one turn of ten to twenty-five milliseconds before the
    /// first picture moved.
    func makeHead() {
        guard stage == nil else { return }
        let filterPart = BrainFilters(owner: self)
        filters = filterPart
        tailscode_brain_row_add(widget, filterPart.canvas)
        let made = BrainStage(owner: self)
        made.drawing = BrainBudget.stageAllowed
        stage = made
        for part in made.widgets { tailscode_brain_row_add(widget, part) }
        let readout = BrainReadout(owner: self)
        self.readout = readout
        let clip = gtk_fixed_new()!
        gtk_widget_set_overflow(clip, GTK_OVERFLOW_HIDDEN)
        gtk_fixed_put(ptr(clip), readout.widget, 0, 0)
        readoutClip = clip
        tailscode_brain_row_add(widget, clip)
        let footer = BrainFooter(owner: self)
        self.footer = footer
        tailscode_brain_row_add(widget, footer.widget)
        let mark = BrainUI.label(NeuralReading.wordmark, "bn-label")
        tailscode_set_accessible_hidden(mark, 1)
        gtk_widget_set_can_target(mark, 0)
        wordmark = mark
        tailscode_brain_row_add(widget, mark)
        installMoveCanvas()
        let m = currentMetrics
        made.configure(
            width: Int(m.stage.width.rounded()), height: Int(m.stage.height.rounded()),
            scaleFactor: max(1, Int(gtk_widget_get_scale_factor(widget))))
        footer.configure(width: m.width, running: model.turn.outcome == .running)
        footer.rebuildChips(width: m.width)
        if isSuspended { made.suspend() }
    }

    func makeList() {
        guard list == nil, stage != nil else { return }
        let listPart = BrainList(owner: self)
        list = listPart
        for part in listPart.widgets { tailscode_brain_row_add(widget, part) }
        raiseOverlays()
    }

    func makeAccount(paced: Bool = false) {
        guard account == nil, stage != nil else { return }
        let accountPart = BrainAccount(owner: self)
        if paced { accountPart.makeCap = 3 }
        account = accountPart
        tailscode_brain_row_add(widget, accountPart.root)
        raiseOverlays()
    }

    func fillAccount() {
        guard let accountPart = account else { return }
        accountPart.proseProbe = BrainAccount.probe()
        accountPart.refresh(immediate: true)
    }

    /// The readout's clip, the footer and the move's canvases stand over the account and the list
    /// whichever of them was made last.
    func raiseOverlays() {
        for part in [readoutClip, footer?.widget, wordmark, moveCanvas, edgeCanvas] {
            if let part { tailscode_brain_row_raise(widget, part) }
        }
    }

    /// The account of the turn read on another thread while the press is still being answered:
    /// the model keeps what it reads, so the frame that makes the account finds it ready.
    func prefetchAccount() {
        let held = model
        let answer = row.answer
        let prompt = row.prompt
        DispatchQueue.global(qos: .userInitiated).async {
            _ = held.account(answer: answer.isEmpty ? nil : answer, prompt: prompt)
        }
    }

    /// The parts the schedule says are due on this frame of the opening move.
    func buildDueParts(at time: Double) {
        guard var held = openSchedule, let move = moveState, move.opening else { return }
        movedFrames += 1
        let duration = max(move.transition.duration * BrainMove.timeScale, 0.001)
        let due = held.due(frame: movedFrames, progress: (time - move.start) / duration)
        openSchedule = held.isComplete ? nil : held
        build(due, paced: true)
        account?.continueRealize()
    }

    /// Whatever the move did not reach before it ended.
    func completeParts() {
        if var held = openSchedule {
            openSchedule = nil
            build(held.remaining())
        }
        account?.finishRealize()
    }

    func build(_ parts: [NeuralOpenPart], paced: Bool = false) {
        for part in parts {
            switch part {
            case .steps: makeList()
            case .account: makeAccount(paced: paced)
            case .story: fillAccount()
            case .head, .nodes, .footer: break
            }
        }
    }

    func dropParts() {
        openSchedule = nil
        guard let held = stage else { return }
        stage = nil
        held.releaseSurfaces()
        held.teardown()
        returnFocusFromBrain()
        dropPopovers()
        for part in held.widgets { tailscode_brain_row_remove(widget, part) }
        if let list { for part in list.widgets { tailscode_brain_row_remove(widget, part) } }
        if let filters { tailscode_brain_row_remove(widget, filters.canvas) }
        if let readoutClip { tailscode_brain_row_remove(widget, readoutClip) }
        if let account {
            account.teardown()
            tailscode_brain_row_remove(widget, account.root)
        }
        if let footer { tailscode_brain_row_remove(widget, footer.widget) }
        if let wordmark { tailscode_brain_row_remove(widget, wordmark) }
        if let moveCanvas { tailscode_brain_row_remove(widget, moveCanvas) }
        if let edgeCanvas { tailscode_brain_row_remove(widget, edgeCanvas) }
        account = nil
        readout = nil
        list = nil
        filters = nil
        readoutClip = nil
        dimmedNodes = []
        hoverApplied = nil
        pendingHover = nil
        footer = nil
        wordmark = nil
        moveCanvas = nil
        edgeCanvas = nil
        model.clearSelection()
        model.browse(.hoverLeft)
        model.setBrowseFocus(.list)
        model.setProvenance(token: nil)
        model.setDiving(false)
        model.setDive(zone: nil)
        leaderState = BrainLeaderState()
        if model.isReplaying { model.stopReplay() }
        announcement = nil
        updateClock()
        relayout()
    }

    /// The stage, readout and footer, in place with no move.
    func showStage() {
        guard stage == nil || phase != .open else { return }
        guard stageMayOpen, NeuralAssetFiles.isAvailable else {
            setPhase(.closed)
            return
        }
        makeParts()
        guard let made = stage else { return }
        pendingOpen = nil
        host?.anchor?()
        setPhase(.open)
        if isSuspended { made.suspend() } else { made.ensureRenderer() }
        footer?.rebuildChips(width: currentMetrics.width)
        footer?.configure(width: currentMetrics.width, running: model.turn.outcome == .running)
        if replayWhenOpen {
            replayWhenOpen = false
            model.startReplay(now: BrainClock.now)
        }
        made.render(BrainClock.now)
        refreshReadout(animate: false)
        footer?.sync(BrainClock.now)
        refitFooterSoon()
        applyPendingDive()
        relayout()
        updateClock()
    }

    /// The footer's chips are fitted again once the row has been laid out and styled, because
    /// their widths are not true before the first frame.
    func refitFooterSoon() {
        Gtk.after(160) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.disposed, let footer = self.footer,
                    self.isLive(footer.widget)
                else { return }
                let width = self.currentMetrics.width
                footer.rebuildChips(width: width)
                footer.configure(width: width, running: self.model.turn.outcome == .running)
            }
        }
    }

    func hideStage() {
        guard stage != nil || phase != .closed else { return }
        host?.anchor?()
        moveState = nil
        revealOverride = nil
        dropParts()
        setPhase(.closed)
        card.refresh()
        card.redraw()
    }

    func stageRendererReady() {
        stage?.render(BrainClock.now)
        redrawNow()
    }

    /// The compositor finished the first picture: a move that was waiting for it begins.
    func stagePictureReady() {
        startOpeningIfReady()
        footer?.sync(BrainClock.now)
        updateClock()
    }

    /// Builds the parts of the stage and draws the head once, for a frozen move a screenshot
    /// is taken of: the move cannot be drawn without the stage's own two pictures.
    func makeFrozenParts() {
        makeParts()
        stage?.ensureRenderer()
    }

    func cardPictureReady() {
        if let move = moveState, !move.opening { gtk_widget_queue_draw(moveCanvas ?? widget) }
    }

    // MARK: the card as a button

    func cardPressed() {
        guard phase == .closed else { return }
        toggleOpen()
    }

    func cardKey(keyval: UInt32, state: UInt32) -> Bool {
        guard phase == .closed, gtk_widget_has_focus(widget) != 0 else { return false }
        let modifiers = state & (GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue)
        guard modifiers == 0 else { return false }
        switch Int32(keyval) {
        case GDK_KEY_Return, GDK_KEY_KP_Enter, GDK_KEY_space:
            toggleOpen()
            return true
        default:
            return false
        }
    }

    func pointerOverRow(_ over: Bool) {
        guard phase == .closed else {
            card.setHovered(false)
            return
        }
        card.setHovered(over)
        if over { prefetchStage() }
    }

    func frameFocus(_ entered: Bool) {
        guard phase == .closed else { return }
        if entered { prefetchStage() }
        card.redraw()
    }

    /// The compositor the stage will want, started while the pointer is on the card, so the move
    /// begins on the press rather than after a build.
    func prefetchStage() {
        guard prefetched == nil, canMove, NeuralAssetFiles.isAvailable else {
            prefetchTicket += 1
            scheduleRelease()
            return
        }
        let m = currentMetrics
        let scale = max(1, Int(gtk_widget_get_scale_factor(widget)))
        let width = Int(
            (m.stage.width * NeuralDesign.width / NeuralStageMetrics.designWidth).rounded())
        let cap = max(1, NeuralAssetName.fullWidth / max(1, width))
        let used = min(scale, cap)
        let table = NeuralToneTable(palette: MatrixTheme.palette, face: model.face)
        BrainCompositors.acquire(
            width: width * used, height: Int(m.stage.height.rounded()) * used, table: table
        ) { [weak self] built in
            guard let self else {
                if let built { BrainCompositors.release(built) }
                return
            }
            guard let built else { return }
            if self.prefetched != nil || self.phase != .closed {
                BrainCompositors.release(built)
                return
            }
            self.prefetched = built
            self.scheduleRelease()
        }
    }

    func scheduleRelease() {
        prefetchTicket += 1
        let ticket = prefetchTicket
        Gtk.after(5000) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.prefetchTicket == ticket, let held = self.prefetched else { return }
                BrainCompositors.release(held)
                self.prefetched = nil
            }
        }
    }

    // MARK: pointer and keyboard on the stage
}
