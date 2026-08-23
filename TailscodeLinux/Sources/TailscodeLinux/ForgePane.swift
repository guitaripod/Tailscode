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
/// A finished clip plays in the stage rather than taking the window: the prompt and the chips stay
/// put, so the next one is one edit away.
final class ForgePane: @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private var player: OpaquePointer?
    private var surface: UnsafeMutablePointer<GtkWidget>?
    private var callbackBox: UnsafeMutableRawPointer?
    private(set) var playing: ForgeAsset?

    private let split = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
    private let stage = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let stageFrame = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let stageFace = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let statusLine = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    private let filmHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let rendererHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let chipsHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let promptView = gtk_text_view_new()!
    private let avoidEntry = gtk_entry_new()!
    private let call = gtk_button_new_with_label(ForgeBoard().renderCall)!
    private let reasonLabel: UnsafeMutablePointer<GtkWidget>

    private var parent: UnsafeMutablePointer<GtkWidget>?
    private let runner = ForgeRunner.shared
    private var openTask: Task<Void, Never>?
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
        buildRoot()
        runner.watch(self) { [weak self] in
            Gtk.onMain { [weak self] in self?.render() }
        }
        runner.prepare()
        syncPrompt()
        syncAvoid()
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
        gtk_widget_set_hexpand(stageFace, 1)
        gtk_widget_set_vexpand(stageFace, 1)
        gtk_box_append(ptr(stageFrame), stageFace)
        gtk_box_append(ptr(stage), statusLine)
        gtk_box_append(ptr(stage), stageFrame)
        gtk_box_append(ptr(stage), filmHolder)
        gtk_widget_set_hexpand(filmHolder, 1)
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
        gtk_widget_set_vexpand(promptView, 1)
        gtk_widget_set_size_request(promptView, -1, 120)
        Gtk.connect(
            UnsafeMutableRawPointer(gtk_text_view_get_buffer(ptr(promptView))), "changed"
        ) { [weak self] in
            self?.typed()
        }
        gtk_box_append(ptr(promptFrame), promptView)
        gtk_box_append(ptr(column), promptFrame)

        gtk_entry_set_placeholder_text(ptr(avoidEntry), Localized.text("Nothing in particular"))
        gtk_widget_set_hexpand(avoidEntry, 1)
        gtk_widget_set_tooltip_text(avoidEntry, ForgeField.negative.label)
        Gtk.connect(UnsafeMutableRawPointer(avoidEntry), "changed") { [weak self] in
            self?.typedAvoid()
        }
        gtk_box_append(ptr(column), avoidEntry)

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

    var isPlaying: Bool { playing != nil }

    var isBusy: Bool { board.isBusy }

    /// One line for the headless driver: where the renderer is, where the render is, what the
    /// button under it would do, how the board is grouped, and what is playing.
    var summary: String {
        let sections = board.sections.map {
            "\($0.id):\($0.rows.count)\($0.hidden > 0 ? "+\($0.hidden)" : "")"
        }
        let bar = board.job.percent.map { "\($0)%" } ?? "-"
        return
            "\(jobWord) renderer=\(board.value(of: .endpoint))/\(reachWord) [\(board.job.title)] \(board.job.subtitle) badge=\(board.job.badge ?? "-") bar=\(bar) call=\(board.renderCall) [\(sections.joined(separator: " "))] cursor=\(board.focused?.title ?? "-") history=\(board.history.count) playing=\(playing?.filename ?? "-") aside=\(reason ?? working ?? "-")"
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

    private func promptText() -> String {
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
        guard promptText() != words else { return }
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
            if !promptHasFocus, let command = VideoCommand.command(for: chord) {
                guard command != .change else {
                    showBoard()
                    return true
                }
                drive(command)
                return true
            }
        }
        guard let command = ForgeBoard.command(for: chord) else { return false }
        if promptHasFocus || avoidHasFocus {
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
        openTask?.cancel()
        openTask = nil
    }

    /// The window is closing. The render is deliberately not touched — it lives in the runner, and
    /// a person who closed a window asked for the window to go, never for the other machine to stop
    /// — so what is let go of here is exactly what belongs to this view: the player and the lookup
    /// that would have fed it.
    func shutdown() {
        stopDrawing()
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
    private var avoidHasFocus: Bool { gtk_widget_has_focus(avoidEntry) != 0 }

    private func typed() {
        guard !typing else { return }
        runner.describe(promptText())
    }

    private func typedAvoid() {
        guard !typing else { return }
        guard let raw = gtk_editable_get_text(op(avoidEntry)) else { return }
        runner.avoid(String(cString: raw))
    }

    /// What activating a row means here. Everything the board can do on its own — walking a
    /// setting, expanding a section, putting an old recipe back in the draft — never reaches this.
    private func perform(_ action: ForgeAction) {
        switch action {
        case .render(let recipe):
            reason = nil
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
        case .size, .seconds, .fps, .model, .seed:
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

    /// The player, pointed at a file the machine has just confirmed it still has.
    private func open(_ asset: ForgeAsset, at url: URL) {
        working = nil
        guard ensurePlayer() else {
            return refuse(String(cString: tailscode_mpv_last_error()))
        }
        reason = nil
        playing = asset
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
        reason = sentence
        render()
    }

    /// Back to the stage with the clip stopped and the recipe that made it still in the boxes —
    /// the point of keeping a seed is that the next one is one edit away rather than a retype.
    private func showBoard() {
        guard isPlaying else { return }
        playing = nil
        if player != nil { drive(["stop"]) }
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
        gtk_widget_set_visible(stageFace, isPlaying ? 0 : 1)
        if let surface { gtk_widget_set_visible(surface, isPlaying ? 1 : 0) }
        drawStage()
        drawControls()
        onChange?()
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
        Gtk.removeChildren(of: stageFace)
        gtk_box_append(ptr(stageFace), ForgeBoardView.stageFace(board.job))
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

    private func drawControls() {
        Gtk.removeChildren(of: rendererHolder)
        gtk_box_append(
            ptr(rendererHolder),
            ForgeBoardView.renderer(board) { [weak self] in
                Gtk.onMain { [weak self] in self?.openSetup() }
            })
        Gtk.removeChildren(of: chipsHolder)
        gtk_box_append(
            ptr(chipsHolder),
            ForgeBoardView.chips(board) { [weak self] field, id in
                Gtk.onMain { [weak self] in self?.runner.pick(field, id: id) }
            })
        gtk_button_set_label(ptr(call), board.renderCall)
        gtk_widget_remove_css_class(call, "forge-call-stop")
        if board.isBusy { Gtk.addClass(call, "forge-call-stop") }
        syncPrompt()
        syncAvoid()
        gtk_widget_set_sensitive(promptView, board.isBusy ? 0 : 1)
        gtk_widget_set_sensitive(avoidEntry, board.isBusy ? 0 : 1)
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

    /// What a kept clip offers besides being played: its settings back in the draft, and the way
    /// to let it go. A receipt for a file that is no longer on the other machine is exactly the
    /// kind of row a history has to be able to lose.
    private func presentClipMenu(_ entry: ForgeEntry, x: Double, y: Double) {
        var rows: [(String, String?, @Sendable () -> Void)] = []
        if let asset = entry.asset {
            rows.append(
                (Localized.text("Play"), entry.detail,
                 { [weak self] in Gtk.onMain { [weak self] in self?.play(asset) } }))
        }
        rows.append(
            (Localized.text("Use it"), entry.recipe.summary,
             { [weak self] in
                 Gtk.onMain { [weak self] in
                     guard let self else { return }
                     self.runner.reuse(entry)
                     self.syncPrompt()
                     self.syncAvoid()
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
        gtk_box_append(ptr(stageFrame), area)
        return true
    }

    /// mpv's own words about the file. A clip that will not play says why and hands the board
    /// back, because a black surface with nothing in it is indistinguishable from one still loading.
    private func received(event: String, payload: String) {
        switch event {
        case "error":
            refuse(payload.isEmpty ? Localized.text("That would not play") : payload)
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
        runner.demonstrate(name)
        syncPrompt()
        syncAvoid()
        reason = nil
        working = nil
        render()
    }
}
