import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A video being asked for, made, and watched — the body of the forge modal.
///
/// The whole of what this shows is `ForgeBoard`'s. The composition is `ForgeStudio`'s: the stage
/// is the room, the words are typed once, the settings walk as chips, and what was made is a strip
/// of clips. Nothing here is state — the board, the connection and the render's own task live in
/// ``ForgeRunner`` so that closing the window cannot cancel four minutes of somebody else's card.
///
/// The stage is one stack of two faces — the board's own (a glyph, or the machine's sketch of the
/// clip while it renders) and the player — and a finished clip crossfades from the last sketch
/// into the player as the file loads, rather than replacing it. The prompt and the chips stay
/// put, so the next one is one edit away.
final class ForgePane: @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private var player: OpaquePointer?
    private var surface: UnsafeMutablePointer<GtkWidget>?
    private var callbackBox: UnsafeMutableRawPointer?
    private(set) var playing: ForgeAsset?
    /// Whether the player has said the file is loaded. Until it has, the stage keeps the face
    /// it had — the sketch, usually — so the crossfade goes from a picture to a picture rather
    /// than through a black surface.
    private var loaded = false
    private var muted = false
    /// The clip the pane opened by itself when it landed, so a snapshot that arrives twice does
    /// not open it twice.
    private var autoPlayed: ForgeAsset?

    private let split = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
    private let stage = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let stageFrame = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let stageStack = gtk_stack_new()!
    private let stageFace = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let sketchFace = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private let sketchPicture = gtk_picture_new()!
    private let sketchCaption: UnsafeMutablePointer<GtkWidget>
    private let sketchBar = gtk_progress_bar_new()!
    private var sketchTexture: UInt = 0
    private var shownSketch: ImageGenPreviewFrame?
    private let statusLine = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    private let filmHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let rendererHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let frameHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let chipsHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let promptView = gtk_text_view_new()!
    private let avoidEntry = gtk_entry_new()!
    private let soundEntry = gtk_entry_new()!
    private let enhanceButton: UnsafeMutablePointer<GtkWidget>
    private let helperMenu: UnsafeMutablePointer<GtkWidget>
    private let rewriteBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let rewriteHead: UnsafeMutablePointer<GtkWidget>
    private let rewriteBody = gtk_text_view_new()!
    private let rewriteInstruction = gtk_entry_new()!
    private let rewriteVerbs = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let rewriteUse: UnsafeMutablePointer<GtkWidget>
    private let rewriteKeep: UnsafeMutablePointer<GtkWidget>
    private let rewriteAgain: UnsafeMutablePointer<GtkWidget>
    private let rewriteStop: UnsafeMutablePointer<GtkWidget>
    private var rewriteShown = ""
    private var rewriteWasWriting = false
    private var surveyShown: Date?
    /// The sentence typed before the helper's paragraph replaced it, kept so one press puts it
    /// back.
    private var beforeEnhance: String?
    private let call = gtk_button_new_with_label(ForgeBoard().renderCall)!
    private let reasonLabel: UnsafeMutablePointer<GtkWidget>

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

    /// Told to the pane's owner whenever what this surface says about itself changes, so the modal's
    /// own footer follows the render rather than lagging a state behind it.
    var onChange: (@Sendable () -> Void)?

    var board: ForgeBoard { runner.board }

    init(parent: UnsafeMutablePointer<GtkWidget>?) {
        self.parent = parent
        reasonLabel = Gtk.label("", css: "forge-reason", wrap: true, selectable: false)
        sketchCaption = Gtk.label("", css: "forge-stage-caption", selectable: false)
        enhanceButton = Gtk.button(ImageGenWords.enhanceTitle, css: ["flat", "forge-enhance"], onClick: {})
        let held = ForgeRunner.shared
        helperMenu = Gtk.menuButton("", css: ["draw-link", "draw-helper-link"]) {
            HelperMenu.sections(held)
        }
        rewriteHead = Gtk.label("", css: "draw-rewrite-head", wrap: true, selectable: false)
        rewriteUse = Gtk.button(ImageGenRewriteWords.useTitle, css: ["draw-action", "draw-action-lead"], onClick: {})
        rewriteKeep = Gtk.button(ImageGenRewriteWords.keepTitle, css: ["draw-action"], onClick: {})
        rewriteAgain = Gtk.button(ImageGenRewriteWords.againTitle, css: ["draw-action"], onClick: {})
        rewriteStop = Gtk.button(ImageGenRewriteWords.stopTitle, css: ["draw-action", "danger"], onClick: {})
        buildRewriteCard()
        buildRoot()
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
        render()
    }

    private func buildRoot() {
        Gtk.addClass(root, "canvas")
        Gtk.addClass(root, "forge-pane")
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)

        gtk_paned_set_wide_handle(op(split), 1)
        gtk_paned_set_resize_start_child(op(split), 1)
        gtk_paned_set_resize_end_child(op(split), 0)
        gtk_paned_set_shrink_start_child(op(split), 1)
        gtk_paned_set_shrink_end_child(op(split), 0)
        gtk_widget_set_hexpand(split, 1)
        gtk_widget_set_vexpand(split, 1)
        Gtk.margins(split, top: 10, bottom: 8, leading: 12, trailing: 12)

        gtk_paned_set_start_child(op(split), makeStage())
        gtk_paned_set_end_child(op(split), makeControls())
        gtk_box_append(ptr(root), split)
        Gtk.after(0) { [weak self] in
            guard let self else { return }
            let width = gtk_widget_get_width(self.split)
            guard width > 0 else { return }
            gtk_paned_set_position(op(self.split), Int32(Double(width) * ForgeStudio.stageShare))
        }
    }

    private func makeStage() -> UnsafeMutablePointer<GtkWidget> {
        gtk_widget_set_hexpand(stage, 1)
        gtk_widget_set_vexpand(stage, 1)
        Gtk.addClass(stageFrame, "forge-stage")
        gtk_widget_set_hexpand(stageFrame, 1)
        gtk_widget_set_vexpand(stageFrame, 1)
        gtk_stack_set_transition_type(
            op(stageStack),
            RepeatingMotion.allowed ? GTK_STACK_TRANSITION_TYPE_CROSSFADE : GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_transition_duration(op(stageStack), Self.arrivalFade)
        gtk_stack_set_hhomogeneous(op(stageStack), 1)
        gtk_stack_set_vhomogeneous(op(stageStack), 1)
        gtk_widget_set_hexpand(stageStack, 1)
        gtk_widget_set_vexpand(stageStack, 1)
        gtk_widget_set_hexpand(stageFace, 1)
        gtk_widget_set_vexpand(stageFace, 1)
        gtk_stack_add_child(op(stageStack), stageFace)
        gtk_box_append(ptr(stageFrame), stageStack)
        gtk_box_append(ptr(stage), statusLine)
        gtk_box_append(ptr(stage), stageFrame)
        gtk_box_append(ptr(stage), filmHolder)
        gtk_widget_set_hexpand(filmHolder, 1)

        g_object_ref_sink(sketchFace)
        gtk_widget_set_hexpand(sketchFace, 1)
        gtk_widget_set_vexpand(sketchFace, 1)
        gtk_picture_set_content_fit(op(sketchPicture), GTK_CONTENT_FIT_CONTAIN)
        gtk_widget_set_hexpand(sketchPicture, 1)
        gtk_widget_set_vexpand(sketchPicture, 1)
        Gtk.addClass(sketchPicture, "forge-sketch")
        gtk_box_append(ptr(sketchFace), sketchPicture)
        gtk_label_set_xalign(op(sketchCaption), 0.5)
        gtk_box_append(ptr(sketchFace), sketchCaption)
        Gtk.addClass(sketchBar, "forge-bar")
        gtk_widget_set_size_request(sketchBar, 180, -1)
        gtk_widget_set_halign(sketchBar, GTK_ALIGN_CENTER)
        Gtk.margins(sketchBar, bottom: 6)
        gtk_box_append(ptr(sketchFace), sketchBar)
        return stage
    }

    private func makeControls() -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        gtk_widget_set_size_request(column, Int32(ForgeStudio.controlWidth), -1)
        gtk_widget_set_hexpand(column, 0)
        gtk_widget_set_vexpand(column, 1)
        Gtk.margins(column, leading: 8)

        gtk_widget_set_hexpand(rendererHolder, 1)
        gtk_box_append(ptr(column), rendererHolder)

        let promptFrame = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(promptFrame, "forge-prompt")
        gtk_text_view_set_wrap_mode(ptr(promptView), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_accepts_tab(ptr(promptView), 0)
        gtk_text_view_set_top_margin(ptr(promptView), 8)
        gtk_text_view_set_bottom_margin(ptr(promptView), 8)
        gtk_text_view_set_left_margin(ptr(promptView), 10)
        gtk_text_view_set_right_margin(ptr(promptView), 10)
        Gtk.connect(
            UnsafeMutableRawPointer(gtk_text_view_get_buffer(ptr(promptView))), "changed"
        ) { [weak self] in
            self?.typed()
        }
        gtk_box_append(ptr(promptFrame), Gtk.boundedScroller(promptView, minimum: 120, maximum: 260))
        gtk_box_append(ptr(column), promptFrame)

        let helperRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_hexpand(helperRow, 1)
        Gtk.connect(UnsafeMutableRawPointer(enhanceButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.enhancePressed() }
        }
        gtk_box_append(ptr(helperRow), enhanceButton)
        gtk_menu_button_set_can_shrink(op(helperMenu), 0)
        gtk_menu_button_set_always_show_arrow(op(helperMenu), 1)
        gtk_widget_set_halign(helperMenu, GTK_ALIGN_END)
        gtk_widget_set_hexpand(helperMenu, 1)
        gtk_box_append(ptr(helperRow), helperMenu)
        gtk_box_append(ptr(column), helperRow)
        gtk_box_append(ptr(column), rewriteBox)

        gtk_entry_set_placeholder_text(ptr(avoidEntry), Localized.text("Nothing in particular"))
        gtk_widget_set_hexpand(avoidEntry, 1)
        gtk_widget_set_tooltip_text(avoidEntry, ForgeField.negative.label)
        Gtk.connect(UnsafeMutableRawPointer(avoidEntry), "changed") { [weak self] in
            self?.typedAvoid()
        }
        gtk_box_append(ptr(column), avoidEntry)

        gtk_entry_set_placeholder_text(ptr(soundEntry), ForgeWords.soundPlaceholder)
        gtk_widget_set_hexpand(soundEntry, 1)
        gtk_widget_set_tooltip_text(soundEntry, "\(ForgeField.sound.label) · \(ForgeWords.soundHint)")
        Gtk.connect(UnsafeMutableRawPointer(soundEntry), "changed") { [weak self] in
            self?.typedSound()
        }
        gtk_box_append(ptr(column), soundEntry)

        gtk_widget_set_hexpand(frameHolder, 1)
        gtk_box_append(ptr(column), frameHolder)
        gtk_widget_set_hexpand(chipsHolder, 1)
        gtk_box_append(ptr(column), chipsHolder)
        gtk_box_append(ptr(column), reasonLabel)

        Gtk.addClass(call, "forge-call")
        gtk_widget_set_hexpand(call, 1)
        Gtk.connect(UnsafeMutableRawPointer(call), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.callPressed() }
        }
        gtk_box_append(ptr(column), call)
        return column
    }

    /// The card under the words. Built once; ``refreshRewrite()`` tells it what changed. The
    /// same card the image studio draws, because it is the same draft.
    private func buildRewriteCard() {
        Gtk.addClass(rewriteBox, "draw-rewrite")
        gtk_widget_set_visible(rewriteBox, 0)
        gtk_label_set_xalign(op(rewriteHead), 0)
        gtk_label_set_max_width_chars(op(rewriteHead), 48)
        gtk_box_append(ptr(rewriteBox), rewriteHead)
        gtk_text_view_set_editable(ptr(rewriteBody), 0)
        gtk_text_view_set_cursor_visible(ptr(rewriteBody), 0)
        gtk_text_view_set_wrap_mode(ptr(rewriteBody), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_left_margin(ptr(rewriteBody), 10)
        gtk_text_view_set_right_margin(ptr(rewriteBody), 10)
        gtk_text_view_set_top_margin(ptr(rewriteBody), 8)
        gtk_text_view_set_bottom_margin(ptr(rewriteBody), 8)
        Gtk.addClass(rewriteBody, "draw-rewrite-body")
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_min_content_height(op(scroller), 120)
        gtk_scrolled_window_set_max_content_height(op(scroller), 220)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_child(op(scroller), rewriteBody)
        Gtk.addClass(scroller, "draw-rewrite-scroller")
        gtk_box_append(ptr(rewriteBox), scroller)
        gtk_entry_set_placeholder_text(ptr(rewriteInstruction), ImageGenRewriteWords.instructionPlaceholder)
        gtk_widget_set_hexpand(rewriteInstruction, 1)
        gtk_widget_set_tooltip_text(rewriteInstruction, ImageGenRewriteWords.reviseTitle)
        gtk_box_append(ptr(rewriteBox), rewriteInstruction)
        gtk_widget_set_tooltip_text(rewriteUse, ImageGenRewriteWords.useHint)
        gtk_widget_set_tooltip_text(rewriteKeep, ImageGenRewriteWords.keepHint)
        gtk_widget_set_tooltip_text(rewriteAgain, ImageGenRewriteWords.againHint)
        for verb in [rewriteUse, rewriteAgain, rewriteKeep, rewriteStop] {
            gtk_box_append(ptr(rewriteVerbs), verb)
        }
        gtk_widget_set_halign(rewriteVerbs, GTK_ALIGN_START)
        gtk_box_append(ptr(rewriteBox), rewriteVerbs)
        Gtk.connect(UnsafeMutableRawPointer(rewriteUse), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.useRewrite() }
        }
        Gtk.connect(UnsafeMutableRawPointer(rewriteKeep), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.runner.dismissRewrite() }
        }
        Gtk.connect(UnsafeMutableRawPointer(rewriteAgain), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, let draft = self.runner.draft else { return }
                self.runner.rewrite(draft.original)
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(rewriteStop), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.runner.stopRewrite() }
        }
        Gtk.connect(UnsafeMutableRawPointer(rewriteInstruction), "activate") { [weak self] in
            Gtk.onMain { [weak self] in self?.revisePressed() }
        }
    }

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
        let stackFace = gtk_stack_get_visible_child(op(stageStack)) == surface ? "player" : "face"
        return
            "\(jobWord) renderer=\(board.value(of: .endpoint))/\(reachWord) [\(board.job.title)] \(board.job.subtitle) badge=\(board.job.badge ?? "-") bar=\(bar) call=\(board.renderCall) [\(sections.joined(separator: " "))] cursor=\(board.focused?.title ?? "-") history=\(board.history.count) playing=\(playing?.filename ?? "-") aside=\(reason ?? working ?? "-") sketch=\(board.sketch != nil) shown=\(sketchTexture != 0) stack=\(stackFace) loaded=\(loaded) muted=\(muted) draft=\(draft) helper=\(runner.helper?.name ?? "-") expect=\(board.expectation ?? "-") frame=\(board.recipe.frame?.label ?? "-") sound=\(board.recipe.sound.isEmpty ? "-" : "set") size=\(board.recipe.size.id)\(board.sizeChosen ? "*" : "")"
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
        gtk_widget_grab_focus(promptView)
    }

    /// Types into the prompt as a person would, so the driver exercises the same path a keystroke
    /// does rather than a private one that could drift from it.
    func describe(_ text: String) {
        typing = true
        setPrompt(text)
        typing = false
        typed()
    }

    private var promptText: String {
        let buffer = gtk_text_view_get_buffer(ptr(promptView))
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    private func setPrompt(_ text: String) {
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(promptView)), text, -1)
    }

    /// Puts the prompt box back in step with the recipe the board holds — after an old clip's
    /// settings are put back in the draft, or after the driver has stood the board in a state. The
    /// write is not an edit, so it must not be read back as one.
    private func syncPrompt() {
        let words = board.recipe.prompt
        guard promptText != words else { return }
        typing = true
        setPrompt(words)
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
        openTask?.cancel()
        openTask = nil
    }

    /// The window is closing. The render is deliberately not touched — it lives in the runner, and
    /// a person who closed a window asked for the window to go, never for the other machine to stop
    /// — so what is let go of here is exactly what belongs to this view: the player, the sketch's
    /// texture and the lookup that would have fed the player.
    func shutdown() {
        stopDrawing()
        dropSketch()
        g_object_unref(sketchFace)
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

    private var promptHasFocus: Bool { gtk_widget_has_focus(promptView) != 0 }
    private var fieldHasFocus: Bool {
        promptHasFocus || gtk_widget_has_focus(avoidEntry) != 0
            || gtk_widget_has_focus(soundEntry) != 0 || gtk_widget_has_focus(rewriteInstruction) != 0
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
            gtk_widget_grab_focus(avoidEntry)
        case .sound:
            gtk_widget_grab_focus(soundEntry)
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

    /// Where the clip starts: a file chosen here, the end of a clip already made, or nothing.
    /// The same rows the Start from row's own menu offers, so a keyboard and a pointer reach the
    /// same three doors.
    private func offerFrame() {
        Gtk.contextMenu(on: frameHolder, x: 8, y: 8, rows: frameRows())
    }

    private func frameRows() -> [(title: String, detail: String?, action: @Sendable () -> Void)] {
        var rows: [(title: String, detail: String?, action: @Sendable () -> Void)] = []
        rows.append(
            (ForgeWords.pickFileTitle, ForgeWords.pickFileHint,
             { [weak self] in Gtk.onMain { [weak self] in self?.pickFrameFile() } }))
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
    /// machine no longer has, mpv's for one it will not decode. The board stays up underneath it,
    /// because a reason with nothing to press is a dead end.
    private func refuse(_ sentence: String) {
        working = nil
        playing = nil
        loaded = false
        reason = sentence
        render()
    }

    /// Back to the stage with the clip stopped and the recipe that made it still in the boxes —
    /// the point of keeping a seed is that the next one is one edit away rather than a retype.
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

    private func render() {
        drawAside()
        openOnArrival()
        drawStage()
        drawControls()
        refreshEnhance()
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

    /// The one line the surface says on its own behalf, under the chips: what it is waiting on, or
    /// why the last press did nothing. They share a line because they are the same slot in the
    /// reading — the answer to "what happened when I pressed that" — and wear different tones so
    /// a wait is never mistaken for a refusal.
    private func drawAside() {
        let line = reason ?? working
        gtk_widget_remove_css_class(reasonLabel, "forge-working")
        gtk_widget_remove_css_class(reasonLabel, "forge-refusal")
        guard let line else {
            gtk_widget_set_visible(reasonLabel, 0)
            return
        }
        Gtk.addClass(reasonLabel, reason == nil ? "forge-working" : "forge-refusal")
        gtk_label_set_text(op(reasonLabel), line)
        gtk_widget_set_visible(reasonLabel, 1)
    }

    private func drawStage() {
        Gtk.removeChildren(of: statusLine)
        gtk_box_append(ptr(statusLine), ForgeBoardView.status(board.job))
        if isPlaying {
            let mark = Gtk.label(muted ? ForgeWords.soundOffMark : ForgeWords.soundOnMark, css: "pill", selectable: false)
            Gtk.addClass(mark, muted ? "pill-offline" : "pill-source")
            gtk_label_set_ellipsize(op(mark), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_hexpand(mark, 0)
            gtk_widget_set_tooltip_text(mark, ForgeWords.soundToggleHint)
            Gtk.margins(mark, leading: 6)
            gtk_box_append(ptr(statusLine), mark)
        }
        drawFace()
        let showPlayer = isPlaying && loaded
        if let surface, gtk_widget_get_parent(surface) == stageStack {
            gtk_stack_set_visible_child(op(stageStack), showPlayer ? surface : stageFace)
        }
        Gtk.removeChildren(of: filmHolder)
        gtk_box_append(
            ptr(filmHolder),
            ForgeBoardView.filmstrip(
                board,
                onActivate: { [weak self] offset in
                    Gtk.onMain { [weak self] in
                        self?.activate(section: ForgeBoard.historyID, offset: offset)
                    }
                },
                onClipMenu: { [weak self] entry, x, y in
                    Gtk.onMain { [weak self] in self?.presentClipMenu(entry, x: x, y: y) }
                }))
    }

    /// What the stage shows while nothing plays: the machine's sketch while one is coming and
    /// until the player has taken over, else the phase's own glyph. The sketch's picture is swapped
    /// in place, never rebuilt, so a frame changes pixels and nothing else.
    private func drawFace() {
        let job = board.job
        if let frame = job.sketch, frame != shownSketch {
            adoptSketch(frame)
        }
        if case .drafting = job.phase { dropSketch() }
        if case .failed = job.phase { dropSketch() }
        if case .cancelled = job.phase { dropSketch() }
        if sketchTexture != 0 {
            if gtk_widget_get_parent(sketchFace) != stageFace {
                Gtk.removeChildren(of: stageFace)
                gtk_box_append(ptr(stageFace), sketchFace)
            }
            let caption: String
            if job.isBusy {
                let left = job.remaining().map { " · " + $0 } ?? ""
                caption = ForgeWords.sketchCaption(job) + left
            } else {
                caption = job.subtitle
            }
            gtk_label_set_text(op(sketchCaption), caption)
            tailscode_set_accessible_label(sketchPicture, ForgeWords.sketchNote)
            if let fraction = job.fraction {
                gtk_progress_bar_set_fraction(op(sketchBar), min(max(fraction, 0), 1))
                gtk_widget_set_visible(sketchBar, 1)
            } else {
                gtk_widget_set_visible(sketchBar, 0)
            }
            return
        }
        Gtk.removeChildren(of: stageFace)
        gtk_box_append(ptr(stageFace), ForgeBoardView.stageFace(job))
    }

    private func adoptSketch(_ frame: ImageGenPreviewFrame) {
        let bits: UInt = frame.bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress,
                let texture = tailscode_texture_from_bytes(base, gsize(frame.bytes.count))
            else { return 0 }
            return UInt(bitPattern: UnsafeMutableRawPointer(texture))
        }
        guard bits != 0 else { return }
        dropSketch()
        sketchTexture = bits
        shownSketch = frame
        gtk_picture_set_paintable(op(sketchPicture), OpaquePointer(UnsafeMutableRawPointer(bitPattern: bits)!))
    }

    private func dropSketch() {
        guard sketchTexture != 0 else { return }
        gtk_picture_set_paintable(op(sketchPicture), nil)
        if let raw = UnsafeMutableRawPointer(bitPattern: sketchTexture) { g_object_unref(raw) }
        sketchTexture = 0
        shownSketch = nil
        if gtk_widget_get_parent(sketchFace) == stageFace { gtk_box_remove(ptr(stageFace), sketchFace) }
    }

    private static let arrivalFade: UInt32 = 700

    private func drawControls() {
        Gtk.removeChildren(of: rendererHolder)
        gtk_box_append(
            ptr(rendererHolder),
            ForgeBoardView.renderer(board) { [weak self] in
                Gtk.onMain { [weak self] in self?.openSetup() }
            })
        Gtk.removeChildren(of: frameHolder)
        gtk_box_append(
            ptr(frameHolder),
            ForgeBoardView.frame(board) { [weak self] in
                self?.frameRows() ?? []
            })
        Gtk.removeChildren(of: chipsHolder)
        gtk_box_append(
            ptr(chipsHolder),
            ForgeBoardView.chips(board) { [weak self] field, id in
                Gtk.onMain { [weak self] in self?.runner.pick(field, id: id) }
            })
        gtk_button_set_label(ptr(call), board.renderCall)
        gtk_widget_set_tooltip_text(call, board.expectation ?? board.job.hint)
        gtk_widget_remove_css_class(call, "forge-call-stop")
        if board.isBusy { Gtk.addClass(call, "forge-call-stop") }
        syncPrompt()
        syncAvoid()
        syncSound()
        gtk_widget_set_sensitive(promptView, board.isBusy ? 0 : 1)
        gtk_widget_set_sensitive(avoidEntry, board.isBusy ? 0 : 1)
        gtk_widget_set_sensitive(soundEntry, board.isBusy ? 0 : 1)
    }

    /// The Enhance control and the link beside it that names who would write: the helper, or
    /// where the survey stands. Press once to have the caption written, press again while it
    /// writes to stop it, and once more after taking it to get your own sentence back.
    private func refreshEnhance() {
        let helper = runner.helper
        let busy = runner.enhancing
        gtk_button_set_label(
            ptr(enhanceButton),
            busy ? ImageGenWords.enhancingTitle
                : (beforeEnhance == nil ? ImageGenWords.enhanceTitle : ImageGenWords.undoTitle))
        gtk_widget_set_tooltip_text(
            enhanceButton,
            busy ? ImageGenRewriteWords.stopTitle
                : helper.map(ImageGenWords.enhanceHint) ?? ImageGenWords.enhanceLookingHint)
        gtk_widget_set_sensitive(enhanceButton, busy || !board.isBusy ? 1 : 0)
        if busy || beforeEnhance != nil {
            Gtk.addClass(enhanceButton, "forge-chip-on")
        } else {
            gtk_widget_remove_css_class(enhanceButton, "forge-chip-on")
        }
        gtk_menu_button_set_label(op(helperMenu), ImageGenRewriteWords.withLine(HelperMenu.label(runner)))
        gtk_widget_set_tooltip_text(helperMenu, HelperMenu.tooltip(runner))
        reopenHelperMenuIfSurveyLanded()
        refreshRewrite()
    }

    /// A menu opened before the survey came back was a "Looking…" row; when the answer lands
    /// while it is still open, it is rebuilt in place rather than left to be closed and opened.
    private func reopenHelperMenuIfSurveyLanded() {
        guard let landed = runner.surveyedAt, landed != surveyShown else { return }
        surveyShown = landed
        guard let popover = gtk_menu_button_get_popover(op(helperMenu)),
            gtk_widget_get_mapped(UnsafeMutableRawPointer(popover).assumingMemoryBound(to: GtkWidget.self)) != 0
        else { return }
        gtk_menu_button_popdown(op(helperMenu))
        gtk_menu_button_popup(op(helperMenu))
    }

    /// The card follows the draft: hidden with none, writing with a Stop, landed with the three
    /// verbs and a line for what to change, failed with the reason and a way to try again.
    private func refreshRewrite() {
        guard let draft = runner.draft else {
            gtk_widget_set_visible(rewriteBox, 0)
            rewriteShown = ""
            return
        }
        gtk_widget_set_visible(rewriteBox, 1)
        gtk_label_set_text(op(rewriteHead), draft.headline)
        if case .failed = draft.phase {
            Gtk.addClass(rewriteHead, "danger")
        } else {
            gtk_widget_remove_css_class(rewriteHead, "danger")
        }
        let landedNow = !draft.isWriting && rewriteWasWriting
        rewriteWasWriting = draft.isWriting
        if draft.written != rewriteShown || landedNow {
            rewriteShown = draft.written
            let buffer = gtk_text_view_get_buffer(ptr(rewriteBody))
            gtk_text_buffer_set_text(buffer, draft.written, -1)
            var edge = GtkTextIter()
            if draft.isWriting {
                gtk_text_buffer_get_end_iter(buffer, &edge)
            } else {
                gtk_text_buffer_get_start_iter(buffer, &edge)
            }
            let mark = gtk_text_buffer_create_mark(buffer, nil, &edge, 0)
            gtk_text_view_scroll_mark_onscreen(ptr(rewriteBody), mark)
            gtk_text_buffer_delete_mark(buffer, mark)
        }
        let scroller = gtk_widget_get_parent(rewriteBody)
        gtk_widget_set_visible(scroller, draft.written.isEmpty ? 0 : 1)
        gtk_widget_set_visible(rewriteStop, draft.isWriting ? 1 : 0)
        gtk_widget_set_visible(rewriteUse, draft.isUsable ? 1 : 0)
        gtk_widget_set_visible(rewriteAgain, draft.isWriting ? 0 : 1)
        gtk_widget_set_visible(rewriteKeep, draft.isWriting ? 0 : 1)
        gtk_widget_set_visible(rewriteInstruction, draft.isUsable ? 1 : 0)
        gtk_widget_set_sensitive(rewriteUse, board.isBusy ? 0 : 1)
    }

    /// Takes the caption: into the box, where it can still be edited, with the typed sentence
    /// one press away. The shape the helper chose is followed only where nobody chose one by
    /// hand and the clip does not continue another, which takes its shape from that clip.
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

    /// One line of what to change sends the same caption back for a revision.
    private func revisePressed() {
        guard let draft = runner.draft, draft.isUsable,
            let raw = gtk_editable_get_text(op(rewriteInstruction))
        else { return }
        let instruction = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        gtk_editable_set_text(op(rewriteInstruction), "")
        runner.rewrite(draft.original, instruction: instruction)
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
        let rows = board.choices(of: field).map { choice in
            (
                choice.menuTitle,
                choice.detail.isEmpty ? nil : choice.detail,
                { [weak self] in
                    Gtk.onMain { [weak self] in self?.runner.pick(field, id: choice.id) }
                } as @Sendable () -> Void
            )
        }
        Gtk.contextMenu(on: chipsHolder, x: 8, y: 8, rows: rows)
    }

    private func activate(section: String, offset: Int) {
        runner.focus(section: section, offset: offset)
        guard let action = runner.activate() else {
            render()
            return
        }
        perform(action)
    }

    private func callPressed() {
        guard let action = runner.begin() else { return }
        perform(action)
    }

    /// What a kept clip offers besides being played: the next clip from where it ended, its
    /// settings back in the draft, and the way to let it go. A receipt for a file that is no
    /// longer on the other machine is exactly the kind of row a history has to be able to lose.
    private func presentClipMenu(_ entry: ForgeEntry, x: Double, y: Double) {
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
                 Gtk.onMain { [weak self] in
                     guard let self else { return }
                     self.runner.reuse(entry)
                 }
             }))
        rows.append(
            (Localized.text("Forget it"), nil,
             { [weak self] in
                 Gtk.onMain { [weak self] in self?.runner.forget(entry) }
             }))
        Gtk.contextMenu(on: filmHolder, x: x, y: y, rows: rows)
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
        gtk_stack_add_child(op(stageStack), area)
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
            Gtk.after(Self.arrivalFade + 400) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, self.loaded else { return }
                    self.dropSketch()
                }
            }
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
    /// releases at shutdown — an event arriving after the pane is gone finds nothing rather than
    /// a dangling object.
    private final class Box {
        weak var pane: ForgePane?
        init(pane: ForgePane) { self.pane = pane }
    }
}

extension ForgePane {
    /// Every state the surface has, put on screen without a renderer to make one happen. The board
    /// is stood up by the runner, which owns it; this only puts the prompt box back in step with
    /// the recipe that came with the state.
    func demonstrate(_ name: String) {
        showBoard()
        autoPlayed = nil
        runner.demonstrate(name)
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
