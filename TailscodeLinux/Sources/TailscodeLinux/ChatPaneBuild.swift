import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    /// The vadjustment's `changed` signal fires when the content's extent moves — including while
    /// the window is unfocused and doing no other work — which is the only moment at which "stay
    /// at the bottom" can be honoured correctly. The pin must never run inside that signal: it
    /// fires during the viewport's own allocation, and a value written mid-layout is accepted but
    /// never drawn, so the pin runs on the next idle, outside layout.
    func buildRoot() {
        Gtk.addClass(root, "canvas")
        Gtk.addClass(root, "chat-pane")
        gtk_widget_set_size_request(root, 280, -1)
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)

        gtk_widget_set_visible(identityLabel, 0)
        gtk_label_set_ellipsize(op(identityLabel), PANGO_ELLIPSIZE_MIDDLE)
        Gtk.makePaneDragSource(identityLabel, payload: PaneMovePayload(pane: id).encoded)
        gtk_box_append(ptr(root), identityLabel)

        Gtk.addClass(authBanner, "banner-auth")
        gtk_widget_set_visible(authBanner, 0)
        gtk_box_append(ptr(root), authBanner)

        gtk_box_append(ptr(root), makeFindBar())

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        let canvas = Gtk.box(
            GTK_ORIENTATION_VERTICAL, spacing: Int32(TranscriptGaps.metrics.proseToFurnitureGap))
        Gtk.addClass(canvas, "transcript")
        canvasBox = canvas
        gtk_widget_set_visible(earlierButton, 0)
        Gtk.addClass(earlierButton, "flat")
        Gtk.addClass(earlierButton, "dim")
        Gtk.connect(UnsafeMutableRawPointer(earlierButton), "clicked") { [weak self] in
            guard let self, let state = self.lastState else { return }
            self.windowLimit += 400
            self.windowWidened = true
            self.rowTailMessages += 600
            self.apply(state: state, rows: self.lastFullRows)
            self.feed.rebuild(state)
        }
        gtk_box_append(ptr(canvas), earlierButton)
        gtk_box_append(ptr(canvas), transcriptBox)
        Gtk.margins(pendingBox, top: 8)
        gtk_box_append(ptr(canvas), pendingBox)
        gtk_scrolled_window_set_child(op(scroller), makeTranscriptViewport(canvas))
        gtk_widget_set_vexpand(scroller, 1)
        Gtk.onPressHold(
            scroller,
            down: { [weak self] in
                self?.pointerHeld = true
                self?.messageHoverPressed()
            },
            up: { [weak self] in
                Gtk.onMain { [weak self] in
                    Gtk.onMain { [weak self] in self?.releasePointer() }
                }
            })
        transcriptScroller = scroller

        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(op(overlay), scroller)
        gtk_widget_set_vexpand(overlay, 1)
        let jump = ChatChips.content(glyph: "↓", word: "")
        gtk_button_set_child(ptr(jumpButton), jump.box)
        jumpGlyph = jump.glyph
        jumpWord = jump.word
        if let word = jump.word { gtk_widget_set_visible(word, 0) }
        Gtk.addClass(jumpButton, "chip-ctl")
        tailscode_set_accessible_label(jumpButton, JumpReading.read(
            rowsNow: 0, rowsAtDeparture: nil, needsYou: false).spoken)
        gtk_widget_set_halign(jumpButton, GTK_ALIGN_END)
        gtk_widget_set_valign(jumpButton, GTK_ALIGN_END)
        Gtk.margins(jumpButton, bottom: 14, trailing: Int32(MatrixTheme.chatInset()))
        gtk_widget_set_visible(jumpButton, 0)
        Gtk.connect(UnsafeMutableRawPointer(jumpButton), "clicked") { [weak self] in
            self?.jumpToBottom()
        }
        gtk_overlay_add_overlay(op(overlay), jumpButton)
        installMessageHover(on: overlay)
        gtk_box_append(ptr(root), overlay)

        if let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)) {
            Gtk.connect(UnsafeMutableRawPointer(adjustment), "changed") { [weak self] in
                guard let self, self.canvasPromptKey == nil, self.followsBottom else { return }
                self.schedulePinCorrector()
            }
            if let canvas = canvasBox {
                scrollAnchor = ScrollAnchor(
                    adjustment: adjustment, canvas: canvas,
                    rows: { [weak self] in self?.anchorRows() ?? [] },
                    place: { [weak self] value in self?.placeAnchored(value) })
            }
            Gtk.onNotify(UnsafeMutableRawPointer(adjustment), property: "upper") { [weak self] in
                self?.scrollAnchor?.reassert()
                Gtk.onMain { [weak self] in
                    guard let self, self.canvasPromptKey != nil else { return }
                    self.settleFreshCanvas()
                }
            }
            Gtk.connect(UnsafeMutableRawPointer(adjustment), "value-changed") { [weak self] in
                guard let self else { return }
                self.brains.scrolled()
                if self.isAutoScrolling {
                    self.scheduleHoverRefresh()
                    return
                }
                self.messageHoverScrolled()
                guard self.canvasPromptKey == nil else {
                    if self.scrolledShortOfTheEnd() { self.canvasPinned = false }
                    self.followsBottom = false
                    return
                }
                let atBottom = self.isNearBottom()
                self.followsBottom = atBottom
                self.askForRowsAtTheEdge()
            }
        }

        gtk_widget_set_visible(helpOverlay, 0)
        Gtk.addClass(helpOverlay, "canvas")
        Gtk.addClass(helpOverlay, "help-overlay")
        Gtk.margins(helpOverlay, top: 8, bottom: 8)
        gtk_box_append(ptr(root), helpOverlay)

        Gtk.addClass(statusBand, "status-band")
        let bandFrame = gtk_overlay_new()!
        self.bandFrame = bandFrame
        gtk_overlay_set_child(op(bandFrame), Gtk.shrinkable(statusBand))
        let bandGauge = gtk_drawing_area_new()!
        gtk_widget_set_can_target(bandGauge, 0)
        gtk_widget_set_can_focus(bandGauge, 0)
        gtk_overlay_add_overlay(op(bandFrame), bandGauge)
        Gtk.onResize(bandGauge) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                StatusBand.fit(
                    self.statusBand, state: self.bandState,
                    width: self.bandFrame.map { gtk_widget_get_width($0) } ?? 0)
            }
        }
        let bandReveal = gtk_revealer_new()!
        self.bandReveal = bandReveal
        gtk_revealer_set_transition_type(op(bandReveal), GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN)
        gtk_revealer_set_child(op(bandReveal), bandFrame)
        gtk_box_append(ptr(root), bandReveal)
        gtk_widget_set_visible(attachmentsBox, 0)
        Gtk.addClass(attachmentsBox, "attachments-row")
        Gtk.margins(attachmentsBox, top: 4)
        gtk_box_append(ptr(root), attachmentsBox)
        gtk_box_append(ptr(root), call.strip.widget)
        gtk_box_append(ptr(root), makeComposer())
        gtk_box_append(ptr(root), makePillRow())
    }

    /// Dropping files on the prompt box attaches them, which is how a file gets from a file
    /// manager into a conversation without a dialog in between. The box owns the whole width:
    /// its buttons live on the pill strip below, because a column of chrome beside the composer
    /// costs typing room all the time to serve clicks that almost never happen.
    func makeComposer() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.addClass(row, "composer-row")
        Gtk.margins(row, top: 6, bottom: 2)
        tailscode_set_accessible_label(
            entryView, Localized.text("Message… (/ for commands)"))

        editor.onChanged = { [weak self] in
            self?.updateSlashCompletion()
            self?.refreshUltracodeAura()
            self?.recordDraft()
        }
        gtk_box_append(ptr(row), editor.widget)

        Gtk.acceptFileDrops(on: row) { [weak self] paths in
            self?.attach(paths: paths)
        }
        return row
    }

    /// The composer's lanes, worn as buttons because a desk has a pointer rather than a swipe.
    /// The lanes are Core's (`QuickAskLane.offered`), and on a desk each lane is a surface: chat
    /// is this pane, ask is the question window the summon chord opens, and image and video are
    /// modals over the work — so a press is a door, the words in this box stay this
    /// conversation's, and the pill that is already this pane's lane wears the accent and does
    /// nothing but say so.
    ///
    /// Which lanes there are is not a setting. A picture needs a machine with a card, so its pill
    /// is here exactly when one is known and gone when none is — which is why the row is built
    /// again whenever either store says the answer changed rather than once at startup.
    func makeLaneRow() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.addClass(laneRow, "lane-row")
        fillLaneRow()
        observeLaneDoors()
        return laneRow
    }

    func fillLaneRow() {
        Gtk.removeChildren(of: laneRow)
        let door = ImageGenDoor.current()
        for lane in QuickAskLane.offered(imaging: door.isOpen) {
            let button = Gtk.button(lane.word.lowercased(), css: ["chip-ctl"]) {
                [weak self] in
                Gtk.onMain { [weak self] in self?.enterLane(lane) }
            }
            gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
            if lane == .chat { Gtk.addClass(button, "chip-on") }
            tailscode_set_accessible_label(button, lane.word)
            tailscode_set_accessible_pressed(button, lane == .chat ? 1 : 0)
            gtk_widget_set_tooltip_text(
                button, lane == .image ? door.line ?? lane.spoken : lane.spoken)
            gtk_box_append(ptr(laneRow), button)
        }
    }

    /// A renderer this device learned about is a lane this composer grows, in every pane at once
    /// and without anybody restarting anything.
    func observeLaneDoors() {
        for name in [ForgeStore.didChange, ImageGenStore.didChange] {
            let token = ObserverToken(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: nil
                ) { [weak self] _ in
                    Gtk.onMain { [weak self] in self?.fillLaneRow() }
                })
            lifetime.add { NotificationCenter.default.removeObserver(token.observer) }
        }
    }

    func enterLane(_ lane: QuickAskLane) {
        switch lane {
        case .chat:
            focusComposer()
        case .ask:
            host?.summonQuickAsk()
        case .image:
            host?.presentImageStudio()
        case .video:
            _ = host?.presentForge()
        }
    }

    /// The transcript's own search, over what the rows say rather than what the server indexes:
    /// it works offline, on a saved copy, and mid-turn.
    func makeFindBar() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.addClass(findBar, "find-bar")
        gtk_widget_set_visible(findBar, 0)
        Gtk.margins(findBar, top: 4, bottom: 4)

        gtk_search_entry_set_placeholder_text(
            op(findEntry), Localized.text("Find in this conversation"))
        gtk_widget_set_hexpand(findEntry, 1)
        Gtk.connect(UnsafeMutableRawPointer(findEntry), "search-changed") { [weak self] in
            self?.runFind(retarget: true)
        }
        Gtk.connect(UnsafeMutableRawPointer(findEntry), "activate") { [weak self] in
            self?.stepFind(by: 1)
        }
        Gtk.connect(UnsafeMutableRawPointer(findEntry), "stop-search") { [weak self] in
            self?.setFindShown(false)
        }
        gtk_box_append(ptr(findBar), findEntry)
        gtk_box_append(ptr(findBar), findCountLabel)
        gtk_box_append(
            ptr(findBar), Gtk.button("↑", css: ["flat"]) { [weak self] in self?.stepFind(by: -1) })
        gtk_box_append(
            ptr(findBar), Gtk.button("↓", css: ["flat"]) { [weak self] in self?.stepFind(by: 1) })
        gtk_box_append(
            ptr(findBar),
            Gtk.button("✕", css: ["flat"]) { [weak self] in self?.setFindShown(false) })
        return findBar
    }

    /// The one strip under the composer: everything the old side column and button row said, at
    /// pill height — destination, model, effort, the command palette, attachments, send and
    /// stop. The CLI's status line, made clickable; send stays a visible verb, sized for what it
    /// is — a thing the keyboard does and a click may occasionally confirm.
    func makePillRow() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.addClass(row, "pill-row")

        gtk_widget_set_visible(vimBadge, 0)
        gtk_label_set_ellipsize(op(vimBadge), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_valign(vimBadge, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(placeBox), vimBadge)
        gtk_label_set_wrap(op(destinationLabel), 1)
        gtk_label_set_wrap_mode(op(destinationLabel), PANGO_WRAP_WORD)
        gtk_label_set_ellipsize(op(destinationLabel), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_valign(destinationLabel, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(placeBox), destinationLabel)
        gtk_box_append(ptr(row), placeBox)

        let pill = makeDialPill()
        gtk_widget_set_valign(pill, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(row), pill)

        let palette = Gtk.menuButton("/", css: ["chip-ctl"]) { [weak self] in
            self?.commandRows() ?? []
        }
        gtk_widget_set_valign(palette, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(palette, Localized.text("Commands"))
        commandButton = palette
        gtk_box_append(ptr(row), palette)

        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(row), spacer)

        gtk_box_append(ptr(row), makeLaneRow())

        gtk_box_append(ptr(row), call.chip)

        let attach = Gtk.menuButton("📎", css: ["chip-ctl"]) { [weak self] in
            self?.attachRows() ?? []
        }
        gtk_widget_set_valign(attach, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(attach, Localized.text("Attach files"))
        attachButton = attach
        gtk_box_append(ptr(row), attach)

        let sendWords = [Localized.text("Send"), Localized.text("Queue")]
        let send = ChatChips.content(
            glyph: "⏎", word: sendWords[0].lowercased(), tone: .live,
            wordChars: ChatChips.widest(sendWords))
        sendWord = send.word
        gtk_button_set_child(ptr(sendButton), send.box)
        gtk_button_set_can_shrink(ptr(sendButton), 1)
        Gtk.addClass(sendButton, "chip-ctl")
        gtk_widget_set_valign(sendButton, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(sendButton, sendWords[0])
        gtk_widget_set_tooltip_text(sendButton, sendWords[0])
        Gtk.connect(UnsafeMutableRawPointer(sendButton), "clicked") { [weak self] in
            self?.sendFromComposer()
        }
        gtk_box_append(ptr(row), sendButton)

        let stop = ChatChips.content(glyph: "■", word: Localized.text("Stop"), tone: .danger)
        stopWord = stop.word
        gtk_button_set_child(ptr(stopButton), stop.box)
        gtk_widget_set_visible(stopButton, 0)
        Gtk.addClass(stopButton, "chip-ctl")
        gtk_widget_set_valign(stopButton, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(stopButton, Localized.text("Stop the turn"))
        gtk_widget_set_tooltip_text(stopButton, Localized.text("Stop the turn"))
        Gtk.connect(UnsafeMutableRawPointer(stopButton), "clicked") { [weak self] in
            self?.stopTurn()
        }
        gtk_box_append(ptr(row), stopButton)
        return gauged(row)
    }

    /// The strip with a gauge laid over it, so it gives way part by part when it is short. One
    /// line that had to fit everything bought its width from the labels that could shrink, which
    /// were the machine and the model — a split pane drew the pill as a dot and an ellipsis
    /// beside four lane buttons drawn whole. The lanes go first, being the part a narrow pane can
    /// best do without (the keys still reach every lane); then the machine and project move to a
    /// line of their own above the pill, rather than being cut beside it.
    func gauged(_ row: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(placeLine, "pill-row")
        Gtk.addClass(placeLine, "pill-row-place")
        gtk_widget_set_visible(placeLine, 0)
        gtk_box_append(ptr(column), placeLine)
        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(op(overlay), Gtk.shrinkable(row))
        let gauge = gtk_drawing_area_new()!
        gtk_widget_set_can_target(gauge, 0)
        gtk_widget_set_can_focus(gauge, 0)
        gtk_overlay_add_overlay(op(overlay), gauge)
        gtk_box_append(ptr(column), overlay)
        stripRow = row
        stripFrame = overlay
        Gtk.onResize(gauge) { [weak self] in
            Gtk.onMain { [weak self] in self?.fitLanes() }
        }
        return column
    }

    /// The strip's words changed under an unchanged width — another model, Send become Queue —
    /// so the gauge is asked again once the new words have been measured.
    func queueLaneFit() {
        Gtk.onMain { [weak self] in self?.fitLanes() }
    }

    /// What the strip gives up as it narrows, one step at a time and in this order: the lanes,
    /// then the machine's line moving above the pill, then the command palette, then the paperclip.
    /// The model pill, Send and Stop never go. Whatever is still shown is shown whole — a strip that
    /// squeezes every part to an ellipsis says nothing.
    static let fitSteps:
        [(lanes: Bool, command: Bool, attach: Bool, inline: Bool, compact: Bool)] = [
            (true, true, true, true, false),
            (false, true, true, true, false),
            (false, true, true, false, false),
            (false, false, true, false, false),
            (false, false, false, false, false),
            (false, false, false, false, true),
        ]

    func fitLanes() {
        guard let stripRow, let stripFrame else { return }
        let width = gtk_widget_get_width(stripFrame)
        guard width > 0 else { return }
        let lanesShown = gtk_widget_get_visible(laneRow) != 0
        let commandShown = commandButton.map { gtk_widget_get_visible($0) != 0 } ?? false
        let attachShown = attachButton.map { gtk_widget_get_visible($0) != 0 } ?? false
        let placeInline = gtk_widget_get_parent(placeBox) == stripRow
        remeasureHiddenParts()
        if lanesShown { laneWidth = Self.naturalWidth(laneRow) }
        if commandShown, let commandButton { commandWidth = Self.naturalWidth(commandButton) }
        if attachShown, let attachButton { attachWidth = Self.naturalWidth(attachButton) }
        let place = Self.naturalWidth(placeBox) + 8
        let spacing: Int32 = 8
        var core = Self.naturalWidth(stripRow)
        if lanesShown { core -= laneWidth + spacing }
        if commandShown { core -= commandWidth + spacing }
        if attachShown { core -= attachWidth + spacing }
        if placeInline { core -= place }
        if !compactOn { noteWordWidths() }
        let compactSaving = wordWidths
        if compactOn { core += compactSaving }
        let chosen =
            Self.fitSteps.first { step in
                var needed = core
                if step.lanes { needed += laneWidth + spacing }
                if step.command { needed += commandWidth + spacing }
                if step.attach && attachAble { needed += attachWidth + spacing }
                if step.inline { needed += place }
                if step.compact { needed -= compactSaving }
                return needed <= width
            } ?? Self.fitSteps[Self.fitSteps.count - 1]
        if chosen.compact != compactOn {
            compactOn = chosen.compact
            for word in [sendWord, stopWord, call.chipParts.word] {
                if let word { gtk_widget_set_visible(word, compactOn ? 0 : 1) }
            }
        }
        let showAttach = chosen.attach && attachAble
        if chosen.lanes != lanesShown { gtk_widget_set_visible(laneRow, chosen.lanes ? 1 : 0) }
        if let commandButton, chosen.command != commandShown {
            gtk_widget_set_visible(commandButton, chosen.command ? 1 : 0)
        }
        if let attachButton, showAttach != attachShown {
            gtk_widget_set_visible(attachButton, showAttach ? 1 : 0)
        }
        guard chosen.inline != placeInline else { return }
        _ = g_object_ref(UnsafeMutableRawPointer(placeBox))
        if let parent = gtk_widget_get_parent(placeBox) { gtk_box_remove(ptr(parent), placeBox) }
        if chosen.inline {
            gtk_box_prepend(ptr(stripRow), placeBox)
        } else {
            gtk_box_append(ptr(placeLine), placeBox)
        }
        g_object_unref(UnsafeMutableRawPointer(placeBox))
        gtk_widget_set_visible(placeLine, chosen.inline ? 0 : 1)
    }

    /// The widths of the parts the strip has given up are remembered from when they were last on
    /// screen, which is the wrong size once the type has been scaled since. A change of any type
    /// area measures them again, each one shown for the length of the measure and put back.
    func remeasureHiddenParts() {
        let scales = Preferences.Area.allCases.map { Preferences.scale($0) }
        guard scales != measuredScales else { return }
        measuredScales = scales
        laneWidth = Self.naturalWidthWhileHidden(laneRow)
        if let commandButton { commandWidth = Self.naturalWidthWhileHidden(commandButton) }
        if let attachButton { attachWidth = Self.naturalWidthWhileHidden(attachButton) }
        if let sendWord { sendWordWidth = Self.naturalWidthWhileHidden(sendWord) + 5 }
        if let stopWord { stopWordWidth = Self.naturalWidthWhileHidden(stopWord) + 5 }
        if let word = call.chipParts.word { callWordWidth = Self.naturalWidthWhileHidden(word) + 5 }
    }

    static func naturalWidthWhileHidden(_ widget: UnsafeMutablePointer<GtkWidget>) -> Int32 {
        let hidden = gtk_widget_get_visible(widget) == 0
        if hidden { gtk_widget_set_visible(widget, 1) }
        let width = naturalWidth(widget)
        if hidden { gtk_widget_set_visible(widget, 0) }
        return width
    }

    func noteWordWidths() {
        if let sendWord { sendWordWidth = Self.naturalWidth(sendWord) + 5 }
        if let stopWord { stopWordWidth = Self.naturalWidth(stopWord) + 5 }
        if let word = call.chipParts.word, call.chipVisible { callWordWidth = Self.naturalWidth(word) + 5 }
    }

    var wordWidths: Int32 {
        sendWordWidth + (gtk_widget_get_visible(stopButton) != 0 ? stopWordWidth : 0)
            + (call.chipVisible ? callWordWidth : 0)
    }

    static func naturalWidth(_ widget: UnsafeMutablePointer<GtkWidget>) -> Int32 {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, nil, nil)
        return natural
    }

    /// Opening or closing a row is a reading gesture: the person's eyes are on the header they
    /// clicked, so the transcript stops following the bottom — a stream that kept pinning would
    /// scroll the very card they opened out from under them — and the view moves only as far as
    /// ``revealDisclosure`` needs to show the opened body, never past the clicked header. Their
    /// own next prompt, or the jump pill, is what re-engages following.
    func wireContext() {
        context.brains = brains
        brains.changed = { [weak self] in self?.brainSettingsChanged() }
        brains.anchor = { [weak self] in self?.holdScrollAnchor() }
        brains.userToggled = { [weak self] in self?.followsBottom = false }
        brains.policy = { [weak self] in self?.rowBuilder.brainPolicy }
        brains.onScreen = { [weak self] view in self?.brainOnScreen(view) ?? true }
        brains.revealApproval = { [weak self] in self?.scroll(toEnd: true) }
        brains.reply = { [weak self] quote in self?.replyWithQuote(quote) }
        brains.revealAnswer = { [weak self] turnID in self?.revealAnswer(afterBrain: turnID) }
        brains.viewport = { [weak self] in
            guard let scroller = self?.transcriptScroller,
                let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
            else { return nil }
            let page = gtk_adjustment_get_page_size(adjustment)
            return page > 0 ? page : nil
        }
        context.openSubagent = { [weak self] key in
            Gtk.onMain { [weak self] in self?.openSubagentCard(key) }
        }
        context.onToggle = { [weak self] key, open in
            guard let self else { return }
            self.context.expanded.set(key, open: open)
            self.followsBottom = false
        }
        context.revealRow = { [weak self] bits in
            if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_ref(raw) }
            Gtk.onMain { [weak self] in
                self?.revealDisclosure(bits)
                if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
            }
        }
        context.railAct = { [weak self] id, act in
            Gtk.onMain { [weak self] in self?.rails.act(id, act) }
        }
        context.railGone = { [weak self] id in
            Gtk.onMain { [weak self] in self?.rails.gone(id) }
        }
        context.requestImage = { [weak self] reference, key in
            Gtk.onMain { [weak self] in self?.fetchImage(reference, key: key) }
        }
        context.onPictureLanded = { [weak self] key in
            Gtk.onMain { [weak self] in self?.pictureLanded(key) }
        }
        context.requestSubagent = { [weak self] call in
            Gtk.onMain { [weak self] in self?.fetchSubagent(call) }
        }
        context.requestWorkflowAgent = { [weak self] agentID in
            Gtk.onMain { [weak self] in self?.fetchWorkflowAgent(agentID) }
        }
        context.openImage = { [weak self] key, name in
            Gtk.onMain { [weak self] in self?.presentImage(key: key, name: name) }
        }
        context.toast = { [weak self] text in
            Gtk.onMain { [weak self] in self?.host?.toast(text) }
        }
        context.editQueued = { [weak self] id in
            Gtk.onMain { [weak self] in self?.editQueued(id) }
        }
        context.resumeQueue = { [weak self] in
            Gtk.onMain { [weak self] in self?.resumeQueue() }
        }
        context.pendingAct = { [weak self] id, act in
            Gtk.onMain { [weak self] in self?.actOnPending(id, act) }
        }
        context.resumeAct = { [weak self] id, act in
            Gtk.onMain { [weak self] in self?.actOnResume(id, act) }
        }
        context.askAgain = { [weak self] words in
            Gtk.onMain { [weak self] in self?.askAgain(words) }
        }
        context.openDesign = { [weak self] source in
            Gtk.onMain { [weak self] in self?.openDesign(source) }
        }
        context.requestDesignBoard = { [weak self] directory in
            Gtk.onMain { [weak self] in self?.readDesignBoard(directory) }
        }
        context.resumeInterrupted = { [weak self] in
            Gtk.onMain { [weak self] in self?.resumeInterruptedTurn() }
        }
        context.dismissInterrupted = { [weak self] in
            Gtk.onMain { [weak self] in self?.dismissInterruptedTurn() }
        }
        context.presentMessageMenu = { [weak self] messageID, widgetBits, x, y in
            Gtk.onMain { [weak self] in
                self?.presentMessageMenu(messageID: messageID, widgetBits: widgetBits, x: x, y: y)
            }
        }
        context.restoreRevert = { [weak self] in
            Gtk.onMain { [weak self] in self?.pressRestoreRevert() }
        }
        context.presentText = { [weak self] title, subtitle, body, mono in
            Gtk.onMain { [weak self] in
                Dialogs.reader(
                    title: title, subtitle: subtitle, body: body, mono: mono,
                    parent: self?.host?.windowWidget)
            }
        }
    }
}
