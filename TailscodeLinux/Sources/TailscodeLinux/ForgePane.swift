import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A video being asked for, made, and watched — the body of the forge modal.
///
/// The whole of what this shows is `ForgeBoard`'s: which machine renders and whether it answered,
/// the render in hand with its bar and its stage, the settings the next one is made from, and the
/// clips already kept. Nothing here is state: the board, the connection and the render's own task
/// live in ``ForgeRunner`` so that closing the window cannot cancel four minutes of somebody else's
/// card. What this owns is the drawing — the prompt box, the rows, and the player.
///
/// The clip plays where the board was rather than in a window of its own: the surface keeps its
/// prompt and its keys, so a finished render is watched in place and Escape puts the board back
/// with the recipe that made it still in the boxes.
final class ForgePane: @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private var player: OpaquePointer?
    private var surface: UnsafeMutablePointer<GtkWidget>?
    private var callbackBox: UnsafeMutableRawPointer?
    private(set) var playing: ForgeAsset?

    private let askBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let entry = gtk_entry_new()!
    private let hintLabel: UnsafeMutablePointer<GtkWidget>
    private let reasonLabel: UnsafeMutablePointer<GtkWidget>
    private let stage = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let boardScroller = gtk_scrolled_window_new()!
    private let boardHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)

    private var parent: UnsafeMutablePointer<GtkWidget>?
    private let runner = ForgeRunner.shared
    private var openTask: Task<Void, Never>?
    /// Why the last thing somebody pressed did not happen — a machine that would not answer, a
    /// file that is gone, a player that would not decode. Never a render's own failure: that one
    /// is the job's, and the board says it on the render row where it happened.
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
        hintLabel = Gtk.label(ForgeRunner.shared.board.hint, css: "dim", selectable: false)
        reasonLabel = Gtk.label("", css: "forge-reason", wrap: true, selectable: false)
        buildRoot()
        runner.watch(self) { [weak self] in
            Gtk.onMain { [weak self] in self?.render() }
        }
        runner.prepare()
        syncPrompt()
        render()
    }

    private func buildRoot() {
        Gtk.addClass(root, "canvas")
        Gtk.addClass(root, "forge-pane")
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)

        Gtk.addClass(askBox, "watch-ask")
        gtk_widget_set_vexpand(askBox, 1)
        Gtk.margins(askBox, top: 14, bottom: 12, leading: 14, trailing: 14)

        gtk_entry_set_placeholder_text(ptr(entry), board.prompt)
        gtk_widget_set_hexpand(entry, 1)
        Gtk.connect(UnsafeMutableRawPointer(entry), "changed") { [weak self] in
            self?.typed()
        }

        gtk_label_set_wrap(op(hintLabel), 0)
        gtk_label_set_ellipsize(op(hintLabel), PANGO_ELLIPSIZE_END)

        gtk_scrolled_window_set_policy(op(boardScroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(boardScroller), boardHolder)
        gtk_scrolled_window_set_min_content_height(op(boardScroller), 0)
        gtk_widget_set_vexpand(boardScroller, 1)
        gtk_widget_set_hexpand(boardScroller, 1)
        gtk_widget_set_hexpand(boardHolder, 1)
        gtk_widget_set_valign(boardHolder, GTK_ALIGN_START)

        gtk_widget_set_vexpand(stage, 1)
        gtk_widget_set_hexpand(stage, 1)
        gtk_box_append(ptr(stage), boardScroller)

        gtk_box_append(ptr(askBox), entry)
        gtk_box_append(ptr(askBox), reasonLabel)
        gtk_box_append(ptr(askBox), stage)
        gtk_box_append(ptr(askBox), hintLabel)
        gtk_box_append(ptr(root), askBox)
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
        gtk_widget_grab_focus(entry)
    }

    /// Types into the prompt as a person would, so the driver exercises the same path a keystroke
    /// does rather than a private one that could drift from it.
    func describe(_ text: String) {
        typing = true
        gtk_editable_set_text(op(entry), text)
        typing = false
        typed()
    }

    /// Puts the prompt box back in step with the recipe the board holds — after an old clip's
    /// settings are put back in the draft, or after the driver has stood the board in a state. The
    /// write is not an edit, so it must not be read back as one.
    private func syncPrompt() {
        let words = board.recipe.prompt
        guard Dialogs.entryText(entry) != words else { return }
        typing = true
        gtk_editable_set_text(op(entry), words)
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
        let (handled, action) = runner.handle(command)
        guard handled else { return false }
        guard let action else { return true }
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

    private var promptHasFocus: Bool { gtk_widget_has_focus(entry) != 0 }

    private func typed() {
        guard !typing else { return }
        guard let raw = gtk_editable_get_text(op(entry)) else { return }
        runner.describe(String(cString: raw))
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
            askForAvoidance()
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

    private func askForAvoidance() {
        Dialogs.prompt(
            title: ForgeField.negative.label, body: nil,
            placeholder: board.value(of: .negative), initial: board.recipe.negative,
            confirmLabel: Localized.text("Save"), parent: parent
        ) { [weak self] text in
            Gtk.onMain { [weak self] in self?.runner.avoid(text) }
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

    /// Back to the board with the clip stopped and the recipe that made it still in the boxes —
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
        gtk_label_set_text(op(hintLabel), isPlaying ? board.job.hint : board.hint)
        drawAside()
        gtk_widget_set_visible(boardScroller, isPlaying ? 0 : 1)
        if let surface { gtk_widget_set_visible(surface, isPlaying ? 1 : 0) }
        renderBoard()
        onChange?()
    }

    /// The one line the surface says on its own behalf, under the prompt: what it is waiting on, or
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

    /// The board, rebuilt whole. A render yields snapshots several times a second and a section is
    /// a few dozen widgets, so rebuilding costs less than keeping a widget tree and a model in
    /// agreement about a shape that changes every time a phase does.
    private func renderBoard() {
        Gtk.removeChildren(of: boardHolder)
        guard !isPlaying else { return }
        let built = ForgeBoardView.make(
            board,
            onActivate: { [weak self] section, offset in
                Gtk.onMain { [weak self] in self?.activate(section: section, offset: offset) }
            },
            onCall: { [weak self] in
                Gtk.onMain { [weak self] in self?.call() }
            },
            onClipMenu: { [weak self] entry, x, y in
                Gtk.onMain { [weak self] in self?.presentClipMenu(entry, x: x, y: y) }
            })
        gtk_box_append(ptr(boardHolder), built.root)
        reveal(built.focused)
    }

    private func activate(section: String, offset: Int) {
        runner.focus(section: section, offset: offset)
        guard let action = runner.activate() else { return }
        perform(action)
    }

    /// The button under the render, which means a different thing in each of its four states —
    /// stop what is running, play what came back, ask for a machine that was never given, or
    /// render. Which of them it is is the board's answer, not this surface's.
    private func call() {
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
                 }
             }))
        rows.append(
            (Localized.text("Forget it"), nil,
             { [weak self] in
                 Gtk.onMain { [weak self] in self?.runner.forget(entry) }
             }))
        Gtk.contextMenu(on: boardHolder, x: x, y: y, rows: rows)
    }

    /// Scrolls the row under the cursor into view. The board is rebuilt on every snapshot, so the
    /// widget is found again at the moment it is measured rather than remembered from the frame
    /// that made it — the one it was is very likely already freed. A board built this frame has no
    /// allocation yet, and a row that measures nothing is a row GTK has not laid out rather than a
    /// row at the top, so it is asked again on the next frame instead of scrolling to nowhere.
    private func reveal(_ position: Int?) {
        guard let position else { return }
        Gtk.after(0) { [weak self] in
            guard let self, !self.scrollIntoView(position) else { return }
            Gtk.after(32) { [weak self] in self?.scrollIntoView(position) }
        }
    }

    @discardableResult
    private func scrollIntoView(_ position: Int) -> Bool {
        guard let column = gtk_widget_get_first_child(boardHolder) else { return false }
        var child = gtk_widget_get_first_child(column)
        var index = 0
        while let current = child, index < position {
            child = gtk_widget_get_next_sibling(current)
            index += 1
        }
        guard let target = child, index == position,
            let bounds = Gtk.bounds(of: target, in: column), bounds.height > 0,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(boardScroller))
        else { return false }
        let page = gtk_adjustment_get_page_size(adjustment)
        guard page > 0 else { return false }
        let value = gtk_adjustment_get_value(adjustment)
        if bounds.y < value {
            gtk_adjustment_set_value(adjustment, bounds.y)
        } else if bounds.y + bounds.height > value + page {
            gtk_adjustment_set_value(adjustment, bounds.y + bounds.height - page)
        }
        return true
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
        gtk_box_append(ptr(stage), area)
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
        reason = nil
        working = nil
        render()
    }
}
