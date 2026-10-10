import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A video being asked for, made, and watched — the Studio's video lane, in the window it opens
/// over the work.
///
/// The whole of what this shows is `ForgeBoard`'s, and the room it is shown in is the same one the
/// image lane has: the stage owns the window, the brief is one dock under it, the shelf is the
/// machine's clips as posters, and the machine is a pill. The stage plays the finished clip
/// inline; while one renders it shows the machine's own sketch of the first frame, and the
/// progress line along its bottom edge is one segment per pass of the graph. Nothing here is
/// state — the board, the connection and the render's own task live in ``ForgeRunner`` so that
/// closing the window cannot cancel four minutes of somebody else's card.
final class ForgePane: @unchecked Sendable {
    let chrome: StudioFrame
    var root: UnsafeMutablePointer<GtkWidget> { chrome.root }
    var machine: StudioMachineButton { chrome.machine }
    var shell: StudioStageShell { chrome.shell }
    var shelf: StudioShelfView { chrome.shelf }
    var dock: StudioDock { chrome.dock }

    private var player: OpaquePointer?
    private var surface: UnsafeMutablePointer<GtkWidget>?
    private var callbackBox: UnsafeMutableRawPointer?
    private(set) var playing: ForgeAsset?
    /// Whether the player has said the file is loaded. Until it has, the stage keeps the face it
    /// had — the sketch, usually — so the crossfade goes from a picture to a picture rather than
    /// through a black surface.
    private var loaded = false
    private var muted = false
    /// The clip the pane opened by itself when it landed, so a snapshot that arrives twice does
    /// not open it twice.
    private var autoPlayed: ForgeAsset?

    private let faces = gtk_stack_new()!
    private let emptyOverlay = gtk_overlay_new()!
    private let backdrop = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private var emptyColumn: UnsafeMutablePointer<GtkWidget>!
    private let frame = gtk_aspect_frame_new(0.5, 0.5, 1.5, 0)!
    private let art = gtk_stack_new()!
    private let sketchOverlay = gtk_overlay_new()!
    private let sketchPicture = gtk_picture_new()!
    private let sketchBadge = Gtk.label("", css: "studio-badge", selectable: false)
    private let heldSlot = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private var sketchTexture: UInt = 0
    private var shownSketch: ImageGenPreviewFrame?
    private var backdropKey: String?
    private var heldKey: String?

    private let sizeChip: StudioChip
    private let lengthChip: StudioChip
    private let smoothChip: StudioChip
    private let soundChip: StudioChip
    private let avoidChip: StudioChip
    private let seedChip: StudioChip
    private let avoidEntry = gtk_entry_new()!
    private let soundEntry = gtk_entry_new()!
    private let helperMenu: UnsafeMutablePointer<GtkWidget>
    private let slotView: StudioSlotView
    private let rewrite = StudioRewriteCard()
    private let posters = ForgePosterLibrary()
    private var referenceTexture: (path: String, bits: UInt)?
    /// The sentence typed before the helper's paragraph replaced it, kept so one press puts it
    /// back.
    private var beforeEnhance: String?

    private var parent: UnsafeMutablePointer<GtkWidget>?
    private let runner = ForgeRunner.shared
    private var openTask: Task<Void, Never>?
    private var rewriteObserver: NSObjectProtocol?
    /// Why the last thing somebody pressed did not happen — a machine that would not answer, a
    /// file that is gone, a player that would not decode. Never a render's own failure: that one
    /// is the job's, and the stage says it where it happened.
    private var reason: String?
    /// What the surface itself is waiting on, as opposed to what the renderer is. Only the lookup
    /// before a clip opens lands here, and it says so rather than leaving a pressed row silent.
    private var working: String?
    private var typing = false
    private var fadeEnds: Date?
    private var arrived: ForgeAsset?
    private var entries: [ForgeEntry] = []

    /// Told to the pane's owner whenever what this surface says about itself changes, so the modal's
    /// own footer follows the render rather than lagging a state behind it.
    var onChange: (@Sendable () -> Void)?

    var board: ForgeBoard { runner.board }

    init(parent: UnsafeMutablePointer<GtkWidget>?) {
        self.parent = parent
        let me = Weak<ForgePane>(nil)
        sizeChip = StudioChip.menu { me.value?.choiceRows(.size) ?? [] }
        lengthChip = StudioChip.menu { me.value?.choiceRows(.seconds) ?? [] }
        smoothChip = StudioChip.menu { me.value?.choiceRows(.fps) ?? [] }
        let soundCard = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        soundChip = StudioChip.popover(content: soundCard)
        let avoidCard = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        avoidChip = StudioChip.popover(content: avoidCard)
        seedChip = StudioChip.button { Gtk.onMain { me.value?.runner.pick(.seed, id: "reroll") } }
        let held = ForgeRunner.shared
        helperMenu = Gtk.menuButton("", css: ["draw-chip"]) { HelperMenu.sections(held) }
        slotView = StudioSlotView(
            rows: { me.value?.frameRows() ?? [] },
            onRemove: { Gtk.onMain { me.value?.runner.start(from: nil) } })
        chrome = StudioFrame(helper: helperMenu, window: true)
        me.value = self
        buildEntryCard(soundCard, entry: soundEntry, placeholder: ForgeWords.soundPlaceholder, hint: ForgeWords.soundHint) {
            [weak self] in self?.typedSound()
        }
        buildEntryCard(
            avoidCard, entry: avoidEntry, placeholder: Localized.text("Nothing in particular"),
            hint: ForgeWords.negativeIgnoredHint
        ) { [weak self] in self?.typedAvoid() }
        buildStage()
        buildShelf()
        buildDock()
        runner.watch(self) { [weak self] in
            Gtk.onMain { [weak self] in self?.render() }
        }
        rewriteObserver = NotificationCenter.default.addObserver(
            forName: ForgeRunner.rewriteDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            Gtk.onMain { [weak self] in self?.refreshRewrite() }
        }
        runner.onNotice = { [weak self] line in
            Gtk.onMain { [weak self] in
                self?.working = nil
                self?.reason = line
                self?.render()
            }
        }
        runner.prepare()
        if !(runner.helper?.isChosenByHand ?? false) { runner.surveyHelpers() }
        syncPrompt()
        syncAvoid()
        syncSound()
        chrome.arrange(width: 1080, height: 680)
        render()
    }

    private func buildEntryCard(
        _ card: UnsafeMutablePointer<GtkWidget>, entry: UnsafeMutablePointer<GtkWidget>,
        placeholder: String, hint: String, changed: @escaping @Sendable () -> Void
    ) {
        Gtk.margins(card, 12)
        gtk_widget_set_size_request(card, 360, -1)
        let words = Gtk.label(hint, css: "draw-toggle-detail", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(words), 48)
        gtk_entry_set_placeholder_text(ptr(entry), placeholder)
        Gtk.addClass(entry, "draw-avoid")
        gtk_widget_set_hexpand(entry, 1)
        gtk_box_append(ptr(card), words)
        gtk_box_append(ptr(card), entry)
        Gtk.connect(UnsafeMutableRawPointer(entry), "changed", changed)
    }

    // MARK: building

    /// The stage: one canvas, two faces. Empty is the newest clip's poster held dimmed behind what
    /// to do next; the other is a frame of exactly the clip's shape holding a stack of three
    /// things — the machine's sketch, the player, and a held placeholder — of which only the
    /// visible one changes while a render runs, so nothing moves when a clip lands.
    private func buildStage() {
        Gtk.addClass(emptyOverlay, "studio-drop")
        gtk_widget_set_overflow(emptyOverlay, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_hexpand(backdrop, 1)
        gtk_widget_set_vexpand(backdrop, 1)
        gtk_overlay_set_child(op(emptyOverlay), backdrop)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        gtk_widget_set_valign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(column, GTK_ALIGN_CENTER)
        let title = Gtk.label(ForgeBoard().prompt, css: "draw-empty-title", selectable: false)
        gtk_label_set_xalign(op(title), 0.5)
        let body = Gtk.label(ForgeWords.frameHint, css: "dim", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(body), 48)
        gtk_label_set_justify(op(body), GTK_JUSTIFY_CENTER)
        gtk_label_set_xalign(op(body), 0.5)
        gtk_box_append(ptr(column), title)
        gtk_box_append(ptr(column), body)
        gtk_overlay_add_overlay(op(emptyOverlay), column)
        emptyColumn = column

        gtk_aspect_frame_set_child(op(frame), art)
        gtk_widget_set_hexpand(frame, 1)
        gtk_widget_set_vexpand(frame, 1)
        gtk_widget_set_hexpand(art, 1)
        gtk_widget_set_vexpand(art, 1)
        gtk_widget_set_overflow(art, GTK_OVERFLOW_HIDDEN)
        Gtk.addClass(art, "studio-art")
        gtk_stack_set_transition_type(op(art), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_hhomogeneous(op(art), 1)
        gtk_stack_set_vhomogeneous(op(art), 1)

        gtk_picture_set_content_fit(op(sketchPicture), GTK_CONTENT_FIT_FILL)
        gtk_widget_set_hexpand(sketchPicture, 1)
        gtk_widget_set_vexpand(sketchPicture, 1)
        Gtk.setHidden(sketchPicture, true)
        gtk_overlay_set_child(op(sketchOverlay), sketchPicture)
        gtk_widget_set_halign(sketchBadge, GTK_ALIGN_START)
        gtk_widget_set_valign(sketchBadge, GTK_ALIGN_START)
        Gtk.margins(sketchBadge, top: 10, leading: 10)
        gtk_widget_set_can_target(sketchBadge, 0)
        gtk_label_set_ellipsize(op(sketchBadge), PANGO_ELLIPSIZE_NONE)
        gtk_overlay_add_overlay(op(sketchOverlay), sketchBadge)
        gtk_widget_set_tooltip_text(sketchOverlay, ForgeWords.sketchNote)
        gtk_widget_set_hexpand(heldSlot, 1)
        gtk_widget_set_vexpand(heldSlot, 1)
        gtk_stack_add_named(op(art), sketchOverlay, "sketch")
        gtk_stack_add_named(op(art), heldSlot, "held")

        gtk_stack_add_named(op(faces), emptyOverlay, "empty")
        gtk_stack_add_named(op(faces), frame, "picture")
        gtk_widget_set_hexpand(faces, 1)
        gtk_widget_set_vexpand(faces, 1)
        gtk_box_append(ptr(shell.content), faces)

        Gtk.acceptFileDrops(on: shell.root) { [weak self] paths in
            Gtk.onMain { [weak self] in
                guard let path = paths.first(where: { ImageGenFileKind.of($0) != nil }) else { return }
                self?.runner.start(from: .file(path))
            }
        }
    }

    private func buildShelf() {
        let pane = Weak(self)
        shelf.thumbnail = { id in pane.value?.posterBits(for: id) ?? 0 }
        shelf.onChoose = { id in
            Gtk.onMain {
                guard let pane = pane.value, let entry = pane.entries.first(where: { $0.id == id })
                else { return }
                if let asset = entry.asset { pane.play(asset) } else { pane.runner.reuse(entry) }
            }
        }
        shelf.onMenu = { id, widget, x, y in
            guard let pane = pane.value, let entry = pane.entries.first(where: { $0.id == id }) else { return }
            pane.presentClipMenu(entry, on: widget, x: x, y: y)
        }
        shelf.onWant = { ids in Gtk.onMain { pane.value?.wantPosters(ids) } }
        shelf.onRefresh = { Gtk.onMain { pane.value?.runner.prepare() } }
        posters.onChange = { Gtk.onMain { pane.value?.shelf.refreshPictures() } }
    }

    private func buildDock() {
        dock.tray.fill([sizeChip, lengthChip, smoothChip, soundChip, avoidChip, seedChip])
        gtk_box_append(ptr(dock.slotHolder), slotView.widget)
        slotView.acceptDrops { [weak self] paths in
            Gtk.onMain { [weak self] in
                guard let path = paths.first(where: { ImageGenFileKind.of($0) != nil }) else { return }
                self?.runner.start(from: .file(path))
            }
        }
        dock.onChange = { [weak self] in self?.typed() }
        dock.onSubmit = { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.board.isBusy else { return }
                self.callPressed()
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(dock.go), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.callPressed() }
        }
        Gtk.connect(UnsafeMutableRawPointer(dock.enhance), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.enhancePressed() }
        }
        shell.setLowerCard(rewrite.root)
        shell.showLowerCard(false)
        rewrite.onUse = { [weak self] in self?.useRewrite() }
        rewrite.onKeep = { [weak self] in self?.runner.dismissRewrite() }
        rewrite.onAgain = { [weak self] in
            guard let self, let draft = self.runner.draft else { return }
            self.runner.rewrite(draft.original)
        }
        rewrite.onStop = { [weak self] in self?.runner.stopRewrite() }
        rewrite.onRevise = { [weak self] words in
            guard let self, let draft = self.runner.draft, draft.isUsable else { return }
            self.runner.rewrite(draft.original, instruction: words)
        }
        machine.details = { [weak self] in
            guard let self else { return Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0) }
            return StudioMachineDetails.forge(
                board: self.board,
                onCheck: { [weak self] in Gtk.onMain { [weak self] in self?.runner.probe() } },
                onChange: { [weak self] in Gtk.onMain { [weak self] in self?.openSetup() } })
        }
    }

    private func choiceRows(_ field: ForgeField)
        -> [(title: String, detail: String?, action: @Sendable () -> Void)]
    {
        board.choices(of: field).map { choice in
            (
                title: choice.menuTitle, detail: choice.detail.isEmpty ? nil : choice.detail,
                action: { @Sendable in
                    Gtk.onMain { [weak self] in self?.runner.pick(field, id: choice.id) }
                }
            )
        }
    }

    // MARK: the driver and the keys

    var isPlaying: Bool { playing != nil }

    var isBusy: Bool { board.isBusy }

    /// One line for the headless driver: where the renderer is, where the render is, what the
    /// button under it would do, how the board is grouped, and what is playing.
    var summary: String {
        let sections = board.sections.map {
            "\($0.id):\($0.rows.count)\($0.hidden > 0 ? "+\($0.hidden)" : "")"
        }
        let bar = board.job.percent.map { "\($0)%" } ?? "-"
        let draft: String
        if let held = runner.draft {
            switch held.phase {
            case .writing: draft = "writing(\(held.words))"
            case .landed: draft = "landed(\(held.words))"
            case .failed: draft = "failed"
            }
        } else {
            draft = "-"
        }
        let stackFace = visibleArt == "player" ? "player" : "face"
        return
            "\(jobWord) renderer=\(board.value(of: .endpoint))/\(reachWord) [\(board.job.title)] \(board.job.subtitle) badge=\(board.job.badge ?? "-") bar=\(bar) call=\(board.renderCall) [\(sections.joined(separator: " "))] cursor=\(board.focused?.title ?? "-") history=\(board.history.count) playing=\(playing?.filename ?? "-") aside=\(reason ?? working ?? "-") sketch=\(board.sketch != nil) shown=\(sketchTexture != 0) stack=\(stackFace) loaded=\(loaded) muted=\(muted) draft=\(draft) helper=\(runner.helper?.name ?? "-") expect=\(board.expectation ?? "-") frame=\(board.recipe.frame?.label ?? "-") sound=\(board.recipe.sound.isEmpty ? "-" : "set") size=\(board.recipe.size.id)\(board.sizeChosen ? "*" : "") studio=[\(chrome.summary) \(shell.progressSummary) posters=\(posters.textures.count) art=\(visibleArt) face=\(visibleFace)]"
    }

    private var visibleArt: String {
        gtk_stack_get_visible_child_name(op(art)).map { String(cString: $0) } ?? "-"
    }

    private var visibleFace: String {
        gtk_stack_get_visible_child_name(op(faces)).map { String(cString: $0) } ?? "-"
    }

    private var jobWord: String {
        switch board.job.phase {
        case .drafting: return "drafting"
        case .submitting: return "submitting"
        case .queued(let ahead): return "queued(\(ahead))"
        case .running(let fraction): return fraction >= 1 ? "collecting" : "running"
        case .done: return "done"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    private var reachWord: String {
        guard let section = board.sections.first(where: { $0.id == ForgeBoard.rendererID })
        else { return "-" }
        switch section.phase {
        case .idle: return board.endpoint == nil ? "unset" : "unchecked"
        case .checking: return "checking"
        case .ready: return "up"
        case .failed: return "down"
        }
    }

    func focusPrompt() {
        dock.focus()
    }

    /// Types into the prompt as a person would, so the driver exercises the same path a keystroke
    /// does rather than a private one that could drift from it.
    func describe(_ text: String) {
        typing = true
        dock.words = text
        typing = false
        typed()
    }

    private var promptText: String { dock.words }

    /// Puts the prompt box back in step with the recipe the board holds — after an old clip's
    /// settings are put back in the draft, or after the driver has stood the board in a state. The
    /// write is not an edit, so it must not be read back as one.
    private func syncPrompt() {
        let words = board.recipe.prompt
        guard promptText != words else { return }
        typing = true
        dock.words = words
        typing = false
    }

    private func syncAvoid() {
        let words = board.recipe.negative
        guard Dialogs.entryText(avoidEntry) != words else { return }
        typing = true
        gtk_editable_set_text(op(avoidEntry), words)
        typing = false
    }

    private func syncSound() {
        let words = board.recipe.sound
        guard Dialogs.entryText(soundEntry) != words else { return }
        typing = true
        gtk_editable_set_text(op(soundEntry), words)
        typing = false
    }

    /// The board's own keys, offered before the box they are typed into gets them. Only chords a
    /// text field cannot want are claimed, so every letter and digit still types into the prompt —
    /// except while a clip is playing and the prompt does not have the keyboard, when the surface
    /// is a player and answers a player's keys.
    func handleChord(_ chord: KeyChord) -> Bool {
        if isPlaying {
            if chord.keyval == Keymap.escape {
                showBoard()
                return true
            }
            if !fieldHasFocus, let command = VideoCommand.command(for: chord) {
                guard command != .change else {
                    showBoard()
                    return true
                }
                drive(command)
                return true
            }
        }
        guard let command = ForgeBoard.command(for: chord) else { return false }
        if fieldHasFocus {
            switch command {
            case .up, .down, .activate, .expand: return false
            case .render, .cancel, .reroll, .back: break
            }
        }
        let (handled, action) = runner.handle(command)
        guard handled else { return false }
        guard let action else {
            render()
            return true
        }
        perform(action)
        return true
    }

    /// Stops this pane being drawn, and nothing else. It has to happen the instant the window is
    /// destroyed rather than a turn of the main loop later: the runner keeps yielding snapshots for
    /// as long as the render runs, and one that lands after the widgets are gone writes text into
    /// labels GTK has already freed.
    func stopDrawing() {
        runner.unwatch(self)
        runner.onNotice = nil
        if let rewriteObserver { NotificationCenter.default.removeObserver(rewriteObserver) }
        rewriteObserver = nil
        posters.onChange = nil
        openTask?.cancel()
        openTask = nil
    }

    /// The window is closing. The render is deliberately not touched — it lives in the runner, and
    /// a person who closed a window asked for the window to go, never for the other machine to stop
    /// — so what is let go of here is exactly what belongs to this view: the player, the sketch's
    /// texture, the posters and the lookup that would have fed the player.
    func shutdown() {
        stopDrawing()
        dropSketch()
        posters.release()
        if let held = referenceTexture, let raw = UnsafeMutableRawPointer(bitPattern: held.bits) {
            g_object_unref(raw)
        }
        referenceTexture = nil
        dock.tray.release()
        if let player {
            tailscode_mpv_free(player)
            self.player = nil
            surface = nil
        }
        if let callbackBox {
            Unmanaged<Box>.fromOpaque(callbackBox).release()
            self.callbackBox = nil
        }
    }

    private var promptHasFocus: Bool { dock.hasFocus }
    private var fieldHasFocus: Bool {
        promptHasFocus || gtk_widget_has_focus(avoidEntry) != 0
            || gtk_widget_has_focus(soundEntry) != 0 || rewrite.hasFocus
    }

    private func typed() {
        guard !typing else { return }
        if beforeEnhance != nil { beforeEnhance = nil }
        runner.describe(promptText)
    }

    private func typedAvoid() {
        guard !typing else { return }
        guard let raw = gtk_editable_get_text(op(avoidEntry)) else { return }
        runner.avoid(String(cString: raw))
    }

    private func typedSound() {
        guard !typing else { return }
        guard let raw = gtk_editable_get_text(op(soundEntry)) else { return }
        runner.hear(String(cString: raw))
    }

    /// What activating a row means here. Everything the board can do on its own — walking a
    /// setting, expanding a section, putting an old recipe back in the draft — never reaches this.
    private func perform(_ action: ForgeAction) {
        switch action {
        case .render(let recipe):
            reason = nil
            autoPlayed = nil
            runner.start(recipe)
        case .cancel:
            runner.stop()
        case .play(let asset):
            play(asset)
        case .edit(let field):
            edit(field)
        case .choose(let field):
            choose(field)
        case .configure:
            openSetup()
        }
    }

    private func edit(_ field: ForgeField) {
        switch field {
        case .endpoint:
            openSetup()
        case .prompt:
            focusPrompt()
        case .negative:
            avoidChip.open()
        case .sound:
            soundChip.open()
        case .frame:
            offerFrame()
        case .size, .seconds, .fps, .seed:
            return
        }
    }

    /// Where the renderer lives, asked for the way a server is asked for: a surface that states
    /// this machine's own address, sweeps the tailnet for the box with the card, checks what it is
    /// given and explains what it finds. Every word of it is Core's.
    ///
    /// The renderer somebody picked is taken up by the runner rather than by this pane, because the
    /// setup window outlives the surface that opened it: closing the forge modal while the setup is
    /// still up must not be what decides whether the address they chose is ever pointed at.
    private func openSetup() {
        ForgeSetupWindow.present(parent: parent) { [weak self] in
            Gtk.onMain { [weak self] in
                ForgeRunner.shared.pointAtStoredRenderer()
                self?.reason = nil
            }
        }
    }

    /// Where the clip starts: a file chosen here, the end of a clip already made, or nothing. The
    /// same rows the start-from slot's own menu offers, so a keyboard and a pointer reach the same
    /// doors.
    private func offerFrame() {
        slotView.open()
    }

    private func frameRows() -> [(title: String, detail: String?, action: @Sendable () -> Void)] {
        var rows: [(title: String, detail: String?, action: @Sendable () -> Void)] = []
        rows.append(
            (ForgeWords.pickFileTitle, ForgeWords.pickFileHint,
             { [weak self] in Gtk.onMain { [weak self] in self?.pickFrameFile() } }))
        rows.append(
            (ImageGenReferenceSource.clipboard.title, nil,
             { [weak self] in Gtk.onMain { [weak self] in self?.pasteFrame() } }))
        for entry in board.history.filter(\.isPlayable).prefix(3) {
            rows.append(
                (ForgeWords.continueTitle(entry), ForgeWords.continueHint,
                 { [weak self] in
                     Gtk.onMain { [weak self] in
                         guard let self, let asset = entry.asset else { return }
                         self.runner.start(from: .clipEnd(asset))
                     }
                 }))
        }
        if board.recipe.frame != nil {
            rows.append(
                (ForgeWords.noFrameTitle, nil,
                 { [weak self] in Gtk.onMain { [weak self] in self?.runner.start(from: nil) } }))
        }
        return rows
    }

    private func pickFrameFile() {
        Gtk.openFiles(parent: parent) { [weak self] paths in
            guard let self, let path = paths.first else { return }
            Gtk.onMain { [weak self] in
                self?.runner.start(from: .file(path))
                self?.focusPrompt()
            }
        }
    }

    /// A picture on the clipboard is a start: files first, then a picture written once to a file the
    /// render can send.
    private func pasteFrame() {
        Gtk.readClipboard { [weak self] offer in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                if let path = offer.paths.first(where: { ImageGenFileKind.of($0) != nil }) {
                    self.runner.start(from: .file(path))
                    return
                }
                guard let data = offer.image else {
                    self.reason = Localized.text("The clipboard holds no picture")
                    self.render()
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tailscode-start-\(UUID().uuidString).png")
                guard (try? data.write(to: url)) != nil else { return }
                self.runner.start(from: .file(url.path))
            }
        }
    }

    /// A clip, asked for before it is opened. The file is on the other machine and `/view` answers
    /// one that has been cleaned up with a 404 — which a player reports in its own words, none of
    /// them about this machine — so Core is asked where the file is first and its sentence is what
    /// a clip that is gone says.
    private func play(_ asset: ForgeAsset) {
        guard let client = runner.renderer(for: asset) else { return }
        guard tailscode_mpv_available() != 0 else {
            return refuse(Localized.text("This build has no libmpv, so a slot cannot play"))
        }
        reason = nil
        working = Localized.text("Checking…")
        render()
        openTask?.cancel()
        openTask = Task { [weak self] in
            do {
                let url = try await client.locate(asset)
                Gtk.onMain { [weak self] in self?.open(asset, at: url) }
            } catch {
                let sentence = ForgeClient.reason(error, host: client.endpoint.host)
                Gtk.onMain { [weak self] in self?.refuse(sentence) }
            }
        }
    }

    /// The player, pointed at a file the machine has just confirmed it still has. The stage keeps
    /// the face it had until the player says the file is loaded, and only then crosses over.
    private func open(_ asset: ForgeAsset, at url: URL) {
        working = nil
        guard ensurePlayer() else {
            return refuse(String(cString: tailscode_mpv_last_error()))
        }
        reason = nil
        playing = asset
        loaded = false
        tailscode_mpv_play(player, url.absoluteString)
        render()
        if let surface { gtk_widget_grab_focus(surface) }
    }

    /// Why a clip is not playing, in the sentence whoever refused it wrote — Core's for a file the
    /// machine no longer has, mpv's for one it will not decode. The stage stays up underneath it,
    /// because a reason with nothing to press is a dead end.
    private func refuse(_ sentence: String) {
        working = nil
        playing = nil
        loaded = false
        reason = sentence
        render()
    }

    /// Back to the stage with the clip stopped and the recipe that made it still in the boxes — the
    /// point of keeping a seed is that the next one is one edit away rather than a retype.
    private func showBoard() {
        guard isPlaying else { return }
        playing = nil
        loaded = false
        if player != nil { drive(["stop"]) }
        dropSketch()
        render()
        focusPrompt()
    }

    private func drive(_ command: VideoCommand) {
        let arguments = command.mpvCommand
        guard !arguments.isEmpty else { return }
        drive(arguments)
    }

    private func drive(_ arguments: [String]) {
        guard let player else { return }
        withCommand(arguments) { tailscode_mpv_command(player, $0) }
    }

    // MARK: drawing

    private func render() {
        entries = board.history
        openOnArrival()
        refreshStage()
        refreshChips()
        refreshDock()
        refreshShelf()
        refreshMachine()
        onChange?()
    }

    /// A clip that just landed is opened by the pane itself, once: the stage is the room the
    /// person was watching, and the last sketch crossing into the moving picture is the arrival.
    private func openOnArrival() {
        guard let asset = board.job.asset, asset != autoPlayed, !isPlaying, working == nil else {
            return
        }
        autoPlayed = asset
        play(asset)
    }

    /// The shape of the clip, decided before it renders: the recipe's own frame, so the sketch, the
    /// player and the held placeholder all sit in one rectangle.
    private var ratio: Double {
        let size = board.isBusy || board.job.isFinished ? board.job.recipe : board.recipe
        return Double(size.width) / Double(max(size.height, 1))
    }

    /// Everything the stage says, from what the board and the player hold right now.
    private func refreshStage() {
        let job = board.job
        gtk_aspect_frame_set_ratio(op(frame), Float(ratio))
        if let frame = job.sketch, frame != shownSketch { adoptSketch(frame) }
        switch job.phase {
        case .drafting, .failed, .cancelled: if !isPlaying { dropSketch() }
        default: break
        }

        var sentence: String?
        var detail: String?
        var tone: ActivityTone?
        var breathing = false
        var card: UnsafeMutablePointer<GtkWidget>?
        var verbs: [StudioVerb] = []
        var showVerbs = false
        var spoken = ForgeBoard().prompt

        if let aside = reason {
            sentence = aside
            tone = .danger
        } else if let waiting = working {
            sentence = waiting
            tone = .live
            breathing = true
        }

        if board.isBusy {
            showFace("picture")
            if sentence == nil {
                sentence = busyLine(job)
                tone = .live
                breathing = true
            }
            spoken = busyLine(job)
            if sketchTexture != 0 {
                gtk_stack_set_visible_child_name(op(art), "sketch")
            } else {
                showHeld(key: "working", bits: 0, opacity: 1)
            }
            verbs = clipVerbs(reserved: true)
        } else if case .failed(let why) = job.phase, !isPlaying {
            showFace("empty")
            gtk_widget_set_visible(emptyColumn, 0)
            refreshBackdrop(dim: 0.3)
            card = failureCard(why)
            tone = tone ?? .danger
            spoken = why
        } else if isPlaying {
            showFace("picture")
            if loaded { showPlayer() }
            if sentence == nil, let entry = entries.first(where: { $0.asset == playing }) {
                sentence = entry.title
                detail = entry.detail
            }
            if let entry = entries.first(where: { $0.asset == playing }) {
                verbs = clipVerbs(for: entry)
                showVerbs = loaded
                spoken = entry.title
            }
        } else if let asset = job.asset, let entry = entries.first(where: { $0.asset == asset }) {
            showFace("picture")
            let key = ForgePosters.key(for: asset)
            showHeld(key: key, bits: posters.textures[key] ?? 0, opacity: 1)
            if sentence == nil {
                sentence = entry.title
                detail = entry.detail
            }
            verbs = clipVerbs(for: entry)
            showVerbs = true
            spoken = entry.title
        } else {
            showFace("empty")
            gtk_widget_set_visible(emptyColumn, 1)
            refreshBackdrop(dim: 0.16)
            if sentence == nil, case .cancelled = job.phase {
                sentence = ImageGenWords.stoppedNotice
                tone = .attention
            }
            if sentence == nil, backdropKey != nil, let name = board.endpoint?.shortName {
                sentence = StudioWords.heldFromShelf(machine: name)
            }
        }
        shell.setState(sentence, detail: detail, tone: tone, breathing: breathing)
        shell.setProgress(progressSegments(job))
        shell.setVerbs(verbs, visible: showVerbs)
        shell.setCard(card)
        shell.describe(spoken)
        refreshSketchBadge()
    }

    /// A picture held in the frame while nothing is playing and nothing is painting: a landed
    /// clip's poster, or an empty placeholder in the clip's own shape until there is one.
    private func showHeld(key: String, bits: UInt, opacity: Double) {
        showFace("picture")
        if heldKey != key {
            Gtk.removeChildren(of: heldSlot)
            if bits != 0, let picture = Gtk.studioPicture(bits: bits) {
                Gtk.setHidden(picture, true)
                gtk_box_append(ptr(heldSlot), picture)
            } else {
                let placeholder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
                Gtk.addClass(placeholder, "draw-working")
                gtk_widget_set_hexpand(placeholder, 1)
                gtk_widget_set_vexpand(placeholder, 1)
                gtk_box_append(ptr(heldSlot), placeholder)
            }
            heldKey = key
        }
        gtk_widget_set_opacity(heldSlot, opacity)
        gtk_stack_set_transition_type(op(art), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_visible_child_name(op(art), "held")
    }

    private func showFace(_ name: String) {
        gtk_stack_set_visible_child_name(op(faces), name)
    }

    /// The sentence for a render in flight, in the order a person watches it: which pass, which
    /// step, how long it has been going — or, before the machine is painting, what it is waiting on.
    private func busyLine(_ job: ForgeJob) -> String {
        let clock = job.spent() ?? ""
        if job.samplerSteps > 0 {
            let base = job.detail
            return clock.isEmpty ? base : "\(base) · \(clock)"
        }
        let base = job.stageName ?? job.subtitle
        return clock.isEmpty ? base : "\(base) · \(clock)"
    }

    /// The progress line, one segment per pass when the machine says which node is working and the
    /// one bar it has otherwise — and nothing at all until there is a count to draw it from.
    private func progressSegments(_ job: ForgeJob) -> [Double]? {
        guard job.isBusy, let fraction = job.fraction else { return nil }
        if let passes = StudioProgress.passes(
            running: job.census?.running, step: job.samplerStep, steps: job.samplerSteps)
        {
            return passes
        }
        return [fraction]
    }

    private func refreshSketchBadge() {
        let sketching = board.isBusy && visibleArt == "sketch"
        gtk_widget_set_visible(sketchBadge, sketching ? 1 : 0)
        if sketching { gtk_label_set_text(op(sketchBadge), ForgeWords.sketchCaption(board.job)) }
    }

    /// The newest clip's poster, held dimmed behind everything the empty stage says.
    private func refreshBackdrop(dim: Double) {
        let key = entries.first(where: \.isPlayable)?.asset.map(ForgePosters.key(for:))
        let bits = key.flatMap { posters.textures[$0] } ?? 0
        guard bits != 0, let key else {
            if backdropKey != nil {
                Gtk.removeChildren(of: backdrop)
                backdropKey = nil
            }
            return
        }
        if backdropKey != key {
            Gtk.removeChildren(of: backdrop)
            if let picture = Gtk.studioPicture(bits: bits, fit: GTK_CONTENT_FIT_COVER) {
                Gtk.setHidden(picture, true)
                gtk_box_append(ptr(backdrop), picture)
            }
            backdropKey = key
        }
        gtk_widget_set_opacity(backdrop, dim)
    }

    /// The finished clip's verbs: a copy somewhere of the person's own, and the next clip from
    /// where this one ended. They hold their room while a render is out.
    private func clipVerbs(for entry: ForgeEntry) -> [StudioVerb] {
        guard let asset = entry.asset else { return [] }
        let pane = Weak(self)
        return [
            StudioVerb(
                id: "save", glyph: "↓", title: ImageGenAction.save.title,
                hint: Localized.text("Write the clip somewhere of your own"),
                perform: { pane.value?.save(asset) }),
            StudioVerb(
                id: "extend", glyph: "⏭", title: ForgeWords.extendTitle, hint: ForgeWords.extendHint,
                isPrimary: true,
                perform: {
                    guard let pane = pane.value else { return }
                    pane.showBoard()
                    pane.runner.extend(entry)
                    pane.focusPrompt()
                }),
        ]
    }

    private func clipVerbs(reserved: Bool) -> [StudioVerb] {
        [
            StudioVerb(id: "save", glyph: "↓", title: ImageGenAction.save.title, hint: "", perform: {}),
            StudioVerb(id: "extend", glyph: "⏭", title: ForgeWords.extendTitle, hint: "", perform: {}),
        ]
    }

    /// The clip's bytes, fetched from the machine that wrote them, into a file of the person's
    /// choosing — never a re-encode of what the player showed.
    private func save(_ asset: ForgeAsset) {
        guard let client = runner.renderer(for: asset) else { return }
        working = Localized.text("Fetching…")
        render()
        Task { [weak self] in
            do {
                let data = try await client.fetch(asset)
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.working = nil
                    self.render()
                    Gtk.saveFile(parent: self.parent, suggestedName: asset.filename, data: data) { [weak self] path in
                        guard let path else { return }
                        Gtk.onMain { [weak self] in
                            self?.reason = nil
                            self?.working = nil
                            self?.flash(ImageGenWords.savedNotice(path: path))
                        }
                    }
                }
            } catch {
                let sentence = ForgeClient.reason(error, host: client.endpoint.host)
                Gtk.onMain { [weak self] in
                    self?.working = nil
                    self?.reason = sentence
                    self?.render()
                }
            }
        }
    }

    /// One line on the stage's own state row for a few seconds — a file written — and then the
    /// stage says what it was saying.
    private func flash(_ line: String) {
        shell.setState(line, tone: .live, breathing: false)
        Gtk.after(4000) { [weak self] in Gtk.onMain { [weak self] in self?.render() } }
    }

    /// The failure's one honest sentence and the remedies that follow from it: the same words
    /// again, the machine's own account, and another look.
    private func failureCard(_ why: String) -> UnsafeMutablePointer<GtkWidget> {
        let pane = Weak(self)
        return StudioFailureCard.make(
            sentence: why, note: nil,
            remedies: [
                (title: Localized.text("Try again"), primary: true,
                 perform: { pane.value?.callPressed() }),
                (title: ImageGenMachineWords.title + "…", primary: false,
                 perform: { pane.value?.machine.open() }),
                (title: ImageGenMachineWords.checkAgain, primary: false,
                 perform: { pane.value?.runner.probe() }),
            ])
    }

    // MARK: the dock

    private func refreshChips() {
        let readings = StudioChips.forge(for: board)
        for reading in readings {
            switch reading.id {
            case .size: sizeChip.apply(reading, tooltip: nil)
            case .length: lengthChip.apply(reading, tooltip: nil)
            case .smoothness: smoothChip.apply(reading, tooltip: nil)
            case .sound: soundChip.apply(reading, tooltip: ForgeWords.soundHint)
            case .avoid: avoidChip.apply(reading, tooltip: ForgeWords.negativeIgnoredHint)
            case .seed:
                seedChip.apply(
                    reading, tooltip: Localized.text("The same seed and prompt make the same clip"))
            case .engine, .aspect, .detail, .cutout, .reference, .craft: break
            }
        }
        dock.tray.relayout(force: false)
    }

    private func refreshDock() {
        syncPrompt()
        syncAvoid()
        syncSound()
        dock.setPlaceholder(board.prompt)
        dock.setGo(title: board.renderCall, stopping: board.isBusy)
        dock.setLocked(board.isBusy)
        gtk_widget_set_tooltip_text(dock.go, board.expectation ?? board.job.hint)
        let about = board.expectation.map { line -> String in
            guard let name = board.endpoint?.shortName else { return line }
            return Localized.text("%@ on %@", line, name)
        }
        let words = ImageGenBrief.words(in: promptText.trimmingCharacters(in: .whitespacesAndNewlines))
        dock.setFoot(
            about,
            tooltip: words == 1 ? Localized.text("1 word") : Localized.text("%@ words", "\(words)"))
        refreshEnhance()
        refreshSlot()
    }

    /// The start-from slot wears the picture the clip opens on, or a glyph for the end of a clip.
    private func refreshSlot() {
        guard let frame = board.recipe.frame else {
            slotView.apply(count: 0, bits: 0, tooltip: ForgeWords.frameHint)
            releaseReferenceTexture()
            return
        }
        var bits: UInt = 0
        var glyph: String? = "▤"
        switch frame {
        case .file(let path):
            if referenceTexture?.path != path {
                releaseReferenceTexture()
                if let data = FileManager.default.contents(atPath: path) {
                    let made: UInt = data.withUnsafeBytes { buffer in
                        guard let base = buffer.baseAddress else { return 0 }
                        var width: Int32 = 0
                        var height: Int32 = 0
                        guard
                            let texture = tailscode_texture_scaled(
                                base, gsize(data.count), 256, &width, &height)
                        else { return 0 }
                        return UInt(bitPattern: UnsafeMutableRawPointer(texture))
                    }
                    if made != 0 { referenceTexture = (path, made) }
                }
            }
            bits = referenceTexture?.bits ?? 0
            glyph = nil
        case .kept: glyph = "▤"
        case .clipEnd: glyph = "⏭"
        }
        slotView.apply(
            count: 1, bits: bits, glyph: glyph, tooltip: "\(frame.label) — \(frame.detail)")
    }

    private func releaseReferenceTexture() {
        if let held = referenceTexture, let raw = UnsafeMutableRawPointer(bitPattern: held.bits) {
            g_object_unref(raw)
        }
        referenceTexture = nil
    }

    private func refreshMachine() {
        let section = board.sections.first(where: { $0.id == ForgeBoard.rendererID })
        let row = board.rows.first(where: { $0.kind == .field(.endpoint) })
        let name = board.endpoint.map { board.rendererName ?? $0.shortName } ?? ""
        let state: String?
        var tone: StudioMachinePill.Tone
        switch section?.phase ?? .idle {
        case .ready:
            state = row?.badge
            tone = .ready
        case .failed(let why):
            state = why
            tone = .danger
        case .checking:
            state = row?.badge
            tone = .unknown
        case .idle:
            state = board.endpoint == nil ? ForgeSetup.title : row?.badge
            tone = .unknown
        }
        if board.isBusy { tone = .working }
        machine.apply(StudioMachinePill(machine: name, state: state, version: nil, tone: tone))
    }

    // MARK: the shelf

    private func refreshShelf() {
        var tiles: [StudioTile] = []
        if board.isBusy {
            tiles.append(
                StudioTile(
                    id: StudioShelf.inFlightID, inFlight: true, badge: board.job.badge,
                    progress: board.job.fraction, glyph: "…", words: busyLine(board.job),
                    tooltip: busyLine(board.job)))
        }
        for entry in entries {
            let ago = ImageGenLibraryWords.ago(entry.finishedAt)
            tiles.append(
                StudioTile(
                    id: entry.id,
                    badge: entry.asset == nil
                        ? entry.badge : StudioWords.duration(entry.recipe.seconds),
                    glyph: entry.isPlayable ? "▶" : "✕",
                    words: StudioWords.shelfTileLabel(words: entry.title, facts: entry.detail),
                    tooltip: "\(ago) · \(entry.detail)"))
        }
        let selected = playing.flatMap { asset in entries.first(where: { $0.asset == asset })?.id }
            ?? board.job.asset.flatMap { asset in entries.first(where: { $0.asset == asset })?.id }
        shelf.describe(
            heading: ForgeWords.recentTitle,
            count: entries.isEmpty ? nil : Localized.text("%@ kept", "\(entries.count)"),
            note: entries.isEmpty ? Localized.text("Nothing rendered yet") : nil)
        shelf.update(tiles: tiles, selection: selected)
    }

    /// The decoded poster a tile draws: the sketch for the render in flight, the clip's filed poster
    /// for one that is made, and nothing for a clip with no poster, which wears its glyph.
    private func posterBits(for id: String) -> UInt {
        if id == StudioShelf.inFlightID { return sketchTexture }
        guard let asset = entries.first(where: { $0.id == id })?.asset else { return 0 }
        return posters.textures[ForgePosters.key(for: asset)] ?? 0
    }

    private func wantPosters(_ ids: [String]) {
        var keys = ids.compactMap { id in
            entries.first(where: { $0.id == id })?.asset.map(ForgePosters.key(for:))
        }
        if let newest = entries.first(where: \.isPlayable)?.asset { keys.append(ForgePosters.key(for: newest)) }
        if let landed = board.job.asset { keys.append(ForgePosters.key(for: landed)) }
        posters.want(keys)
    }

    /// What a kept clip offers besides being played: the next clip from where it ended, its
    /// settings back in the draft, and the way to let it go. A receipt for a file that is no longer
    /// on the other machine is exactly the kind of row a history has to be able to lose.
    private func presentClipMenu(
        _ entry: ForgeEntry, on widget: UnsafeMutablePointer<GtkWidget>, x: Double, y: Double
    ) {
        var rows: [(String, String?, @Sendable () -> Void)] = []
        if let asset = entry.asset {
            rows.append(
                (Localized.text("Play"), entry.detail,
                 { [weak self] in Gtk.onMain { [weak self] in self?.play(asset) } }))
            rows.append(
                (ForgeWords.extendTitle, ForgeWords.extendHint,
                 { [weak self] in
                     Gtk.onMain { [weak self] in
                         guard let self else { return }
                         self.showBoard()
                         self.runner.extend(entry)
                         self.focusPrompt()
                     }
                 }))
        }
        rows.append(
            (Localized.text("Use it"), entry.recipe.summary,
             { [weak self] in
                 Gtk.onMain { [weak self] in self?.runner.reuse(entry) }
             }))
        rows.append(
            (Localized.text("Forget it"), nil,
             { [weak self] in
                 Gtk.onMain { [weak self] in self?.runner.forget(entry) }
             }))
        Gtk.contextMenu(on: widget, x: x, y: y, rows: rows)
    }

    // MARK: sketch and player

    private func adoptSketch(_ frame: ImageGenPreviewFrame) {
        let bits: UInt = frame.bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress,
                let texture = tailscode_texture_from_bytes(base, gsize(frame.bytes.count))
            else { return 0 }
            return UInt(bitPattern: UnsafeMutableRawPointer(texture))
        }
        guard bits != 0 else { return }
        Gtk.replacePicture(of: sketchPicture, bits: bits)
        if sketchTexture != 0, let raw = UnsafeMutableRawPointer(bitPattern: sketchTexture) {
            g_object_unref(raw)
        }
        sketchTexture = bits
        shownSketch = frame
        shelf.refreshPicture(StudioShelf.inFlightID)
    }

    private func dropSketch() {
        guard sketchTexture != 0 else { return }
        gtk_picture_set_paintable(op(sketchPicture), nil)
        if let raw = UnsafeMutableRawPointer(bitPattern: sketchTexture) { g_object_unref(raw) }
        sketchTexture = 0
        shownSketch = nil
    }

    static let arrivalFade: UInt32 = 240

    /// The player takes the stage. A clip that just landed crossfades from its last sketch once,
    /// 240 milliseconds, ease-out; a clip chosen from the shelf is simply there.
    private func showPlayer() {
        guard surface != nil else { return }
        let landing = visibleArt != "player" && sketchTexture != 0 && Gtk.animationsAllowed
        if landing {
            gtk_stack_set_transition_duration(op(art), Self.arrivalFade)
            gtk_stack_set_transition_type(op(art), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
            gtk_stack_set_visible_child_name(op(art), "player")
            fadeEnds = Date().addingTimeInterval(Double(Self.arrivalFade + 200) / 1000)
            Gtk.after(Self.arrivalFade + 200) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.fadeEnds = nil
                    gtk_stack_set_transition_type(op(self.art), GTK_STACK_TRANSITION_TYPE_NONE)
                    if self.loaded { self.dropSketch() }
                }
            }
            return
        }
        if let fadeEnds, fadeEnds > Date(), visibleArt == "player" { return }
        gtk_stack_set_transition_type(op(art), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_visible_child_name(op(art), "player")
        if loaded { dropSketch() }
    }

    private func ensurePlayer() -> Bool {
        if player != nil { return true }
        guard tailscode_mpv_available() != 0 else { return false }
        let box = Box(pane: self)
        let raw = Unmanaged.passRetained(box).toOpaque()
        guard
            let created = tailscode_mpv_new(
                { user, kind, text in
                    guard let user, let kind else { return }
                    let event = String(cString: kind)
                    let payload = text.map { String(cString: $0) } ?? ""
                    let box = Unmanaged<Box>.fromOpaque(user).takeUnretainedValue()
                    box.pane?.received(event: event, payload: payload)
                }, raw)
        else {
            Unmanaged<Box>.fromOpaque(raw).release()
            return false
        }
        player = created
        callbackBox = raw
        guard let area = tailscode_mpv_area(created) else { return false }
        surface = area
        gtk_widget_set_hexpand(area, 1)
        gtk_widget_set_vexpand(area, 1)
        gtk_stack_add_named(op(art), area, "player")
        return true
    }

    /// mpv's own words about the file. A clip that will not play says why and hands the board
    /// back, because a black surface with nothing in it is indistinguishable from one still
    /// loading; a clip that loaded is what the stage crosses over to, and the sketch it crossed
    /// from is let go once the fade is done.
    private func received(event: String, payload: String) {
        switch event {
        case "error":
            refuse(payload.isEmpty ? Localized.text("That would not play") : payload)
        case "loaded":
            loaded = true
            render()
        case "mute":
            muted = payload == "1"
            render()
        default:
            return
        }
    }

    private func withCommand(
        _ arguments: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> Void
    ) {
        var pointers: [UnsafePointer<CChar>?] = arguments.map { argument in
            UnsafePointer(strdup(argument))
        }
        pointers.append(nil)
        pointers.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { body(base) }
        }
        for pointer in pointers where pointer != nil {
            free(UnsafeMutableRawPointer(mutating: pointer))
        }
    }

    /// The C callback carries a raw pointer, so the pane reaches it through a box it owns and
    /// releases at shutdown — an event arriving after the pane is gone finds nothing rather than a
    /// dangling object.
    private final class Box {
        weak var pane: ForgePane?
        init(pane: ForgePane) { self.pane = pane }
    }

    // MARK: enhance and the rewrite card

    /// The Enhance control and the link beside it that names who would write: the helper, or where
    /// the survey stands. Press once to have the caption written, press again while it writes to
    /// stop it, and once more after taking it to get your own sentence back.
    private func refreshEnhance() {
        dock.showEnhance(
            host: runner, enhancing: runner.enhancing, canUndo: beforeEnhance != nil,
            locked: board.isBusy)
        refreshRewrite()
    }

    /// The card follows the draft, risen over the stage's lower third.
    private func refreshRewrite() {
        shell.showLowerCard(rewrite.refresh(runner.draft, canUse: !board.isBusy))
    }

    /// Takes the caption: into the box, where it can still be edited, with the typed sentence one
    /// press away. The shape the helper chose is followed only where nobody chose one by hand and
    /// the clip does not continue another, which takes its shape from that clip.
    private func useRewrite() {
        guard let draft = runner.draft, draft.isUsable else { return }
        beforeEnhance = promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? draft.original : promptText
        if let aspect = draft.aspect, board.recipe.frame?.isClipEnd != true {
            runner.follow(size: ForgeSize.following(aspect))
        }
        describe(draft.written)
        runner.dismissRewrite()
        reason = ImageGenWords.enhancedNotice(draft.helper)
        render()
    }

    private func enhancePressed() {
        if let original = beforeEnhance {
            beforeEnhance = nil
            describe(original)
            refreshEnhance()
            return
        }
        if runner.enhancing {
            runner.stopRewrite()
            return
        }
        let brief = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else {
            focusPrompt()
            return
        }
        reason = nil
        runner.rewrite(brief)
    }

    private func choose(_ field: ForgeField) {
        switch field {
        case .size: sizeChip.open()
        case .seconds: lengthChip.open()
        case .fps: smoothChip.open()
        default: break
        }
    }

    private func callPressed() {
        guard let action = runner.begin() else { return }
        perform(action)
    }
}

extension ForgePane {
    /// Every state the surface has, put on screen without a renderer to make one happen. The board
    /// is stood up by the runner, which owns it; this only puts the prompt box back in step with
    /// the recipe that came with the state. `done` is staged at rest, with the clip's poster and
    /// verbs on the stage and the player left unopened, because a headless harness has no
    /// output for the player to draw on.
    func demonstrate(_ name: String) {
        showBoard()
        autoPlayed = nil
        runner.demonstrate(name)
        if name == "done" { autoPlayed = board.job.asset }
        syncPrompt()
        syncAvoid()
        syncSound()
        reason = nil
        working = nil
        render()
    }

    /// The driver's doors into the helper and the start picture, through the same paths a press
    /// takes.
    func driveEnhance() { enhancePressed() }
    func driveUseRewrite() { useRewrite() }
    func driveFrame(_ path: String) { runner.start(from: .file(path)) }
    func driveExtendNewest() {
        guard let entry = board.history.first(where: \.isPlayable) else { return }
        runner.extend(entry)
    }
    func driveSound(_ words: String) {
        typing = true
        gtk_editable_set_text(op(soundEntry), words)
        typing = false
        runner.hear(words)
    }
}
