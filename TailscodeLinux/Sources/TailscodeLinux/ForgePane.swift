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

    var player: OpaquePointer?
    var surface: UnsafeMutablePointer<GtkWidget>?
    var callbackBox: UnsafeMutableRawPointer?
    var playing: ForgeAsset?
    /// Whether the player has said the file is loaded. Until it has, the stage keeps the face it
    /// had — the sketch, usually — so the crossfade goes from a picture to a picture rather than
    /// through a black surface.
    var loaded = false
    var muted = false
    /// The clip the person asked for last, from the moment they asked. `playing` only becomes it
    /// once the machine has confirmed the file is there, and the shelf, the stage and the verbs
    /// answer the press at once rather than after a round trip.
    var chosen: ForgeAsset?
    /// Bumped by everything that decides what the stage is on. An answer to an earlier question —
    /// the machine confirming a file two clicks ago — arrives after the person has moved on, and
    /// is only believed while its number is still the latest.
    var playTicket = 0
    var saving = false

    let faces = gtk_stack_new()!
    let emptyOverlay = gtk_overlay_new()!
    let backdrop = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    var emptyColumn: UnsafeMutablePointer<GtkWidget>!
    let frame = gtk_aspect_frame_new(0.5, 0.5, 1.5, 0)!
    let art = gtk_stack_new()!
    let sketchOverlay = gtk_overlay_new()!
    let sketchPicture = gtk_picture_new()!
    let sketchBadge = Gtk.label("", css: "studio-badge", selectable: false)
    let heldSlot = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    var sketchTexture: UInt = 0
    var shownSketch: ImageGenPreviewFrame?
    var backdropKey: String?
    var heldKey: String?

    let sizeChip: StudioChip
    let lengthChip: StudioChip
    let smoothChip: StudioChip
    let soundChip: StudioChip
    let avoidChip: StudioChip
    let seedChip: StudioChip
    let avoidEntry = gtk_entry_new()!
    let soundEntry = gtk_entry_new()!
    let helperMenu: UnsafeMutablePointer<GtkWidget>
    let slotView: StudioSlotView
    let rewrite = StudioRewriteCard()
    let posters = ForgePosterLibrary()
    var referenceTexture: (path: String, bits: UInt)?
    /// The sentence typed before the helper's paragraph replaced it, kept so one press puts it
    /// back.
    var beforeEnhance: String?

    let runner = ForgeRunner.shared
    var openTask: Task<Void, Never>?
    var rewriteObserver: NSObjectProtocol?
    /// Why the last thing somebody pressed did not happen — a machine that would not answer, a
    /// file that is gone, a player that would not decode. Never a render's own failure: that one
    /// is the job's, and the stage says it where it happened.
    var reason: String?
    /// What the surface itself is waiting on, as opposed to what the renderer is. Only the lookup
    /// before a clip opens lands here, and it says so rather than leaving a pressed row silent.
    var working: String?
    var typing = false
    var fadeEnds: Date?
    var entries: [ForgeEntry] = []

    /// Told to the pane's owner whenever what this surface says about itself changes, so the modal's
    /// own footer follows the render rather than lagging a state behind it.
    var onChange: (@Sendable () -> Void)?

    var board: ForgeBoard { runner.board }

    init() {
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

    func buildEntryCard(
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
    func buildStage() {
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

    func buildShelf() {
        let pane = Weak(self)
        shelf.thumbnail = { id in pane.value?.posterBits(for: id) ?? 0 }
        shelf.onChoose = { id in
            Gtk.onMain {
                guard let pane = pane.value, let entry = pane.entries.first(where: { $0.id == id })
                else { return }
                if entry.asset != nil { pane.play(entry) } else { pane.runner.reuse(entry) }
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

    func buildDock() {
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
        machine.onPress = { [weak self] in self?.openChecklist() }
    }

    func choiceRows(_ field: ForgeField)
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

    /// The one main window this surface sits in, which every dialog it opens is a transient of.
    var hostWindow: UnsafeMutablePointer<GtkWidget>? {
        guard let root = gtk_widget_get_root(ptr(root)) else { return nil }
        return UnsafeMutablePointer(root)
    }

    var isPlaying: Bool { playing != nil }

    /// How many renders are ahead of or at this one on the machine: the board's own count while a
    /// render is out, nothing otherwise.
    var queueCount: Int {
        if case .queued(let ahead) = board.job.phase { return ahead + 1 }
        return board.isBusy ? 1 : 0
    }

    /// Stops the render that is out, by the same road the stop chord takes.
    func stopRender() {
        let (handled, action) = runner.handle(.cancel)
        guard handled else { return }
        guard let action else {
            render()
            return
        }
        perform(action)
    }

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

    var visibleArt: String {
        gtk_stack_get_visible_child_name(op(art)).map { String(cString: $0) } ?? "-"
    }

    var visibleFace: String {
        gtk_stack_get_visible_child_name(op(faces)).map { String(cString: $0) } ?? "-"
    }

    var jobWord: String {
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

    var reachWord: String {
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

    var promptText: String { dock.words }

    /// Puts the prompt box back in step with the recipe the board holds — after an old clip's
    /// settings are put back in the draft, or after the driver has stood the board in a state. The
    /// write is not an edit, so it must not be read back as one.
    func syncPrompt() {
        let words = board.recipe.prompt
        guard promptText != words else { return }
        typing = true
        dock.words = words
        typing = false
    }

    func syncAvoid() {
        let words = board.recipe.negative
        guard Dialogs.entryText(avoidEntry) != words else { return }
        typing = true
        gtk_editable_set_text(op(avoidEntry), words)
        typing = false
    }

    func syncSound() {
        let words = board.recipe.sound
        guard Dialogs.entryText(soundEntry) != words else { return }
        typing = true
        gtk_editable_set_text(op(soundEntry), words)
        typing = false
    }
}

extension ForgePane {
    /// Every state the surface has, put on screen without a renderer to make one happen. The board
    /// is stood up by the runner, which owns it; this only puts the prompt box back in step with
    /// the recipe that came with the state. `done` is staged at rest, with the clip's poster and
    /// verbs on the stage and the player left unopened, because a headless harness has no
    /// output for the player to draw on.
    func demonstrate(_ name: String) {
        releaseStage()
        dropSketch()
        runner.demonstrate(name)
        if name == "done", let asset = board.job.asset { runner.present(asset) }
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
    func drivePlay(_ index: String) {
        let place = Int(index) ?? 0
        guard entries.indices.contains(place) else { return }
        play(entries[place])
    }
    func driveVerb(_ id: String) { shell.press(id) }
    func driveSound(_ words: String) {
        typing = true
        gtk_editable_set_text(op(soundEntry), words)
        typing = false
        runner.hear(words)
    }
}
