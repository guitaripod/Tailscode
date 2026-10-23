import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    func stopTurn() {
        guard let conversation else { return }
        Task { try? await conversation.cancelCurrentTurn() }
    }

    /// What the call dictated goes where a typed message goes: the pending ink, the queue behind a
    /// running turn, the marks, with the model and effort the composer would use. False only when
    /// there is no conversation to send into, which the call tells the gateway as a refusal.
    func callSend(_ words: String) -> Bool {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let conversation else { return false }
        AppLog.write(.session, "call dictated a message into session \(entry?.session.id ?? "none")")
        enqueueOrRun(
            QueuedSend(
                text: text, model: chosenModel,
                effort: ModelEffort.surviving(chosenEffort, options: effortOptions())),
            through: conversation)
        return true
    }

    func callStopTurn() { stopTurn() }

    func callNotice(_ words: String) { setNotice(words) }

    func callAnnounce(_ words: String) { announce(words) }

    func callChipChanged() { queueLaneFit() }

    /// The prompt just sent rises to the top of the window and the answer streams onto the empty
    /// page under it. The room is made rather than found: the canvas is padded by what the
    /// viewport lacks below the prompt, the scroll rides one eased motion to put the prompt at
    /// `FreshCanvas.headroom`, and following the bottom is off until the answer has filled the room.
    func raiseFreshCanvas(for id: UUID) {
        let key = Self.pendingKey(id)
        canvasPromptKey = key
        canvasPromptTop = nil
        canvasFloor = renderedRows.lastIndex { $0.key == key } ?? renderedRows.count
        canvasPinned = false
        canvasRising = true
        // Following stays on until there is something to rise to. The row this send just appended
        // has no height until the pane has laid it out — on a long conversation, several fills
        // later — and letting go of the bottom first meant the words sat below the fold for every
        // one of those frames: the message you just sent, nowhere on the screen, until the rise
        // either happened or gave up. Now it lands at the bottom the instant it is drawn, and the
        // rise takes the page from there.
        awaitFreshCanvasPrompt(attempts: 0)
    }

    /// The row this frame appended has no height until the next allocation, and the room cannot
    /// be measured against a row that is not there yet: ask again frame by frame, briefly.
    func awaitFreshCanvasPrompt(attempts: Int) {
        guard canvasPromptKey != nil else { return }
        if canvasPrompt() != nil {
            followsBottom = false
            settleFreshCanvas()
            animateFreshCanvas()
            return
        }
        // Patience is about the page, not the clock. A long conversation is filled a chunk of rows
        // at a time with a main-loop hop between chunks, so the row this send just appended has no
        // widget — and no measurable height — until the fill reaches it. A wall-clock second is
        // gone long before that on a transcript of a few thousand rows, and the rise was given up
        // on exactly the conversations it was built for. So the wait runs while the pane is still
        // filling, and the clock only starts once it has stopped.
        guard !fillComplete || isFillingInChunks
            || Double(attempts) * 0.016 < FreshCanvas.patience,
            Double(attempts) * 0.016 < FreshCanvas.ceiling
        else {
            AppLog.write(
                .ui,
                "fresh canvas: prompt row never measured after \(attempts) frames "
                    + "(filled=\(fillComplete))")
            canvasPromptKey = nil
            canvasPinned = false
            canvasRising = false
            if canvasPadding > 0 { setCanvasPadding(0) }
            setFollowing(true)
            return
        }
        Gtk.after(16) { [weak self] in
            Gtk.onMain { [weak self] in self?.awaitFreshCanvasPrompt(attempts: attempts + 1) }
        }
    }

    /// Where the canvas's prompt sits inside the canvas, following the row through the swap from
    /// this device's echo to the server's own account of it.
    ///
    /// The block is the whole send, not the row the key names: the echo is one card, and the
    /// server's account of the same send is a row per picture and one for the words. Every
    /// row of the person's own that touches the keyed one is taken with it, so a picture clipped
    /// to the words rests under the top edge rather than one row above it.
    func canvasPrompt() -> (top: Double, height: Double)? {
        guard let key = canvasPromptKey, let canvas = canvasBox else { return nil }
        var index = renderedRows.lastIndex { $0.key == key }
        if index == nil, key.hasPrefix("pending:"),
            let last = renderedRows.lastIndex(where: {
                if case .userText = $0.kind { return true }
                return false
            }), last >= canvasFloor - 2
        {
            canvasPromptKey = renderedRows[last].key
            index = last
        }
        guard let index, index < rowWidgets.count else { return nil }
        var first = index
        while first > 0, renderedRows[first - 1].isPromptBlock { first -= 1 }
        var last = index
        while last + 1 < renderedRows.count, last + 1 < rowWidgets.count,
            renderedRows[last + 1].isPromptBlock
        { last += 1 }
        var top = Double.infinity
        var bottom = -Double.infinity
        for row in first...last {
            guard let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[row]) else { continue }
            var x = 0.0
            var y = 0.0
            var width = 0.0
            var height = 0.0
            guard tailscode_widget_bounds_in(ptr(raw), canvas, &x, &y, &width, &height) != 0,
                height > 0
            else { continue }
            top = min(top, y)
            bottom = max(bottom, y + height)
        }
        guard top.isFinite, bottom > top else { return nil }
        return (top, bottom - top)
    }

    /// How much of the live row is laid out past its reveal: text the reader has not been shown
    /// yet, drawn clear under the wave. Zero when nothing is being written.
    func unrevealedHeight() -> Double {
        guard let key = cascade.key, !placeholderShown,
            let index = renderedRows.lastIndex(where: { $0.key == key }), index < rowWidgets.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index]),
            let label = Self.streamedLabel(in: ptr(raw), kind: renderedRows[index].kind)
        else { return 0 }
        let written = tailscode_label_revealed_height(label, Int32(cascade.revealed))
        guard written >= 0 else { return 0 }
        return max(0, Double(gtk_widget_get_height(label)) - written)
    }

    /// Re-measures the room on every change of the content's size: the padding shrinks as the
    /// answer grows under the prompt, the prompt is kept where it was through a swap that
    /// changed its height, and once the answer fills the window the canvas lets go.
    func settleFreshCanvas() {
        guard canvasPromptKey != nil, let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        guard let prompt = canvasPrompt() else { return }
        let viewport = gtk_adjustment_get_page_size(adjustment)
        guard viewport > 0 else { return }
        let room = FreshCanvas.room(
            promptTop: prompt.top, viewport: viewport,
            end: canvasContentEnd - unrevealedHeight())
        canvasPromptTop = prompt.top
        if room != canvasPadding {
            AppLog.write(
                .ui,
                "fresh canvas: prompt=\(Int(prompt.height)) viewport=\(Int(viewport)) padding=\(Int(room))")
            setCanvasPadding(room)
        }
        pinFreshCanvas(to: prompt.top, adjustment: adjustment, viewport: viewport)
        guard !canvasRising, !FreshCanvas.holds(room: room) else { return }
        canvasPromptKey = nil
        canvasPromptTop = nil
        canvasPinned = false
        setFollowing(true)
    }

    /// Whether the page stands somewhere other than the end of its own range. The room shrinking
    /// under the prompt drags that range up with it, and GTK reports the clamp as a value nobody
    /// set — while the canvas holds, the pinned value *is* the end of the range, so short of the
    /// end is a hand on the page and at the end is the room being taken back.
    ///
    /// The end that counts is the *visible* one. An answer is laid out in full the moment it
    /// arrives and revealed a glyph at a time, so from the first word of streaming the range runs
    /// past the pin by exactly the text nobody has been shown yet — and a pin measured against the
    /// laid-out end read its own held position as a hand on the page and let go on the first
    /// frame of the answer.
    func scrolledShortOfTheEnd() -> Bool {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return false }
        let ceiling =
            FreshCanvas.visibleEnd(
                contentHeight: gtk_adjustment_get_upper(adjustment),
                unrevealed: unrevealedHeight())
            - gtk_adjustment_get_page_size(adjustment)
        return gtk_adjustment_get_value(adjustment) < ceiling - 1
    }

    /// Keeps the prompt at the headroom rather than trusting the motion that put it there. The
    /// room is asked for in one frame and allocated in the next, a row is measured after it is
    /// drawn, and the server's own rows replace this device's under the whole thing — so where
    /// the prompt actually stands is read again on every one of those and the scroll is moved
    /// back when it has drifted. Nothing happens once the reader's own hand has been on it.
    func pinFreshCanvas(
        to promptTop: Double, adjustment: UnsafeMutablePointer<GtkAdjustment>, viewport: Double
    ) {
        guard canvasPinned, canvasSettle == nil else { return }
        let value = gtk_adjustment_get_value(adjustment)
        guard !FreshCanvas.hasLanded(promptTop: promptTop, offset: value) else { return }
        let offset = FreshCanvas.offset(
            promptTop: promptTop, contentHeight: gtk_adjustment_get_upper(adjustment),
            viewport: viewport)
        guard abs(offset - value) > FreshCanvas.landing else { return }
        isAutoScrolling = true
        gtk_adjustment_set_value(adjustment, offset)
        isAutoScrolling = false
    }

    /// The room is the canvas's own bottom margin rather than a spacer child: a box puts its
    /// spacing at every visible child boundary, so a spacer grew the page by the room asked for
    /// *and one gap*, and the gap came and went with the spacer's visibility. A margin is exactly
    /// what it says, and it reads back exactly, which is what lets the room be measured against a
    /// page that does not already contain it.
    func setCanvasPadding(_ padding: Double) {
        canvasPadding = padding
        guard let canvas = canvasBox else { return }
        gtk_widget_set_margin_bottom(canvas, Int32(padding.rounded()))
    }

    /// Where the conversation itself ends inside the canvas, with the room left out of the
    /// reading rather than subtracted back out of it.
    ///
    /// The scrollable extent contains the margin the canvas is holding, and a margin asked for in
    /// one pass is allocated in the next — so a room measured as *the range less the room* took
    /// the new margin off a range that still held the old one, and the error became the next
    /// pass's room. Nothing damped it: the padding cycled through the same handful of values for
    /// as long as the answer streamed, and the prompt rode the cycle down the page and back.
    /// A box's own allocated height is the content without the room, read from one allocation
    /// pass, and asking for it again cannot change it.
    var canvasContentEnd: Double {
        guard let canvas = canvasBox else { return 0 }
        return Double(gtk_widget_get_height(canvas))
    }

    /// One motion from wherever the reader was to the prompt at the top, on the display's clock.
    /// The target is read again every frame, because the padding the motion rides on lands a
    /// frame or two after it was asked for.
    func animateFreshCanvas() {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        canvasSettle?.cancel()
        let target: () -> Double? = { [weak self] in
            guard let self, let prompt = self.canvasPrompt() else { return nil }
            return FreshCanvas.offset(
                promptTop: prompt.top, contentHeight: gtk_adjustment_get_upper(adjustment),
                viewport: gtk_adjustment_get_page_size(adjustment))
        }
        let settle = FreshCanvasScroll(clock: scroller, adjustment: adjustment, target: target) {
            [weak self] in
            self?.canvasSettle = nil
            self?.canvasRising = false
            self?.settleFreshCanvas()
        }
        canvasSettle = settle
        let set: (Double) -> Void = { [weak self] value in
            self?.isAutoScrolling = true
            gtk_adjustment_set_value(adjustment, value)
            self?.isAutoScrolling = false
        }
        canvasPinned = true
        settle.start(reduceMotion: !RepeatingMotion.allowed, set: set)
    }

    /// Leaving the chat takes the room with it; the next one opens on its own end.
    func leaveFreshCanvas() {
        canvasSettle?.cancel()
        canvasSettle = nil
        canvasPromptKey = nil
        canvasPromptTop = nil
        canvasPinned = false
        canvasRising = false
        if canvasPadding > 0 { setCanvasPadding(0) }
        setFollowing(true)
    }

    /// For the driver: whether the canvas holds, how much room it made, and — the only reading
    /// that says the feature worked — how far the prompt actually is from the headroom.
    var freshCanvasReading: String {
        var drift = "?"
        if let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)),
            let prompt = canvasPrompt()
        {
            drift = String(
                Int(
                    FreshCanvas.drift(
                        promptTop: prompt.top, offset: gtk_adjustment_get_value(adjustment))
                        .rounded()))
        }
        return
            "holding=\(canvasPromptKey != nil) padding=\(Int(canvasPadding)) follows=\(followsBottom) pinned=\(canvasPinned) drift=\(drift)"
    }

    func isNearBottom() -> Bool {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return true }
        let value = gtk_adjustment_get_value(adjustment)
        let ceiling = gtk_adjustment_get_upper(adjustment)
            - gtk_adjustment_get_page_size(adjustment) - unrevealedHeight()
        return value >= ceiling - 8
    }

    /// Following is a decision, not a measurement: the intent is held here and re-applied
    /// whenever the extent actually changes, focused or not.
    func setFollowing(_ following: Bool) {
        followsBottom = following
        if following { pinToBottom() }
    }

    /// The value that puts the last *written* line at the bottom of the window: the end of the
    /// content whenever nothing is being written, and while an answer is, the laid-out remainder
    /// of the live row left below the fold — the page is pushed up by the writing, never by the
    /// layout that ran ahead of it.
    func pinToBottom() {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let target = max(
            gtk_adjustment_get_lower(adjustment),
            gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment)
                - unrevealedHeight())
        guard abs(gtk_adjustment_get_value(adjustment) - target) > 0.5 else { return }
        isAutoScrolling = true
        gtk_adjustment_set_value(adjustment, target)
        isAutoScrolling = false
    }

    func scrollToBottom() {
        setFollowing(true)
        schedulePinCorrector()
    }

    func jumpToBottom() {
        scrollToBottom()
    }

    /// The pill is a way back, not a counter: it shows whenever the reader has left the bottom
    /// of a transcript that has one, and never while a fresh canvas is deliberately holding the
    /// prompt at the top.
    func syncJumpPill() {
        let show = !followsBottom && canvasPromptKey == nil && !renderedRows.isEmpty
        gtk_widget_set_visible(jumpButton, show ? 1 : 0)
        guard show else { return }
        let waiting =
            !(lastState?.pendingPermissions.isEmpty ?? true)
            || !(lastState?.pendingQuestions.isEmpty ?? true)
        let reading = JumpReading.read(
            rowsNow: lastFullRows.count, rowsAtDeparture: rowsAtDeparture, needsYou: waiting)
        if let jumpWord {
            gtk_label_set_text(op(jumpWord), reading.label ?? "")
            gtk_widget_set_visible(jumpWord, reading.label == nil ? 0 : 1)
            if reading.label != nil { Gtk.addClass(jumpWord, "chip-gap") }
        }
        ChatChips.setTone(jumpGlyph, reading.tone)
        tailscode_set_accessible_label(jumpButton, reading.spoken)
    }
}
