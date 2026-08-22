import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A video being asked for, made, and watched — inside the split tree, as a pane like any other.
///
/// The whole of what this shows is `ForgeBoard`'s: which machine renders and whether it answered,
/// the render in hand with its bar and its stage, the settings the next one is made from, and the
/// clips already kept. This owns four things the board cannot — the prompt box, the reachability
/// probe, the render stream, and the player — and hands every answer straight back into the board
/// so the words on screen are Core's in every state.
///
/// The clip plays where the board was rather than in a window of its own: the pane keeps its
/// heading, its prompt and its keys, so a finished render is watched in place and Escape puts the
/// board back with the recipe that made it still in the boxes.
final class ForgePane: @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private(set) var board: ForgeBoard
    private var player: OpaquePointer?
    private var surface: UnsafeMutablePointer<GtkWidget>?
    private var callbackBox: UnsafeMutableRawPointer?
    private(set) var playing: ForgeAsset?

    private let askBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let entry = gtk_entry_new()!
    private let headingLabel: UnsafeMutablePointer<GtkWidget>
    private let hintLabel: UnsafeMutablePointer<GtkWidget>
    private let reasonLabel: UnsafeMutablePointer<GtkWidget>
    private let noticeLabel: UnsafeMutablePointer<GtkWidget>
    private let stage = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let boardScroller = gtk_scrolled_window_new()!
    private let boardHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)

    private var parent: UnsafeMutablePointer<GtkWidget>?
    private var client: ForgeClient?
    private var renderTask: Task<Void, Never>?
    private var reachTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    /// Why the last thing somebody pressed did not happen — a machine that would not answer, a
    /// file that is gone, a player that would not decode. Never a render's own failure: that one
    /// is the job's, and the board says it on the render row where it happened.
    private var reason: String?
    /// What the pane itself is waiting on, as opposed to what the renderer is. Only the lookup
    /// before a clip opens lands here, and it says so rather than leaving a pressed row silent.
    private var working: String?
    private var typing = false

    /// Told to the pane's owner whenever what this slot says about itself changes, so the identity
    /// strip follows the render rather than lagging a state behind it.
    var onChange: (@Sendable () -> Void)?

    init(parent: UnsafeMutablePointer<GtkWidget>?) {
        self.parent = parent
        board = ForgeBoard(recipe: ForgeStore.recipe(), endpoint: ForgeStore.endpoint())
        headingLabel = Gtk.label(board.heading, css: "video-heading", selectable: false)
        hintLabel = Gtk.label(board.hint, css: "dim", selectable: false)
        reasonLabel = Gtk.label("", css: "forge-reason", wrap: true, selectable: false)
        noticeLabel = Gtk.label(board.notice, css: "video-notice", wrap: true, selectable: false)
        buildRoot()
        board.filled(history: ForgeStore.history())
        probe()
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
        gtk_label_set_max_width_chars(op(noticeLabel), 46)

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

        gtk_box_append(ptr(askBox), headingLabel)
        gtk_box_append(ptr(askBox), entry)
        gtk_box_append(ptr(askBox), reasonLabel)
        gtk_box_append(ptr(askBox), stage)
        gtk_box_append(ptr(askBox), hintLabel)
        gtk_box_append(ptr(askBox), noticeLabel)
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

    /// The board's own keys, offered before the box they are typed into gets them. Only chords a
    /// text field cannot want are claimed, so every letter and digit still types into the prompt —
    /// except while a clip is playing and the prompt does not have the keyboard, when the pane is
    /// a player and answers a player's keys.
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
        let (handled, action) = board.handle(command)
        guard handled else { return false }
        guard let action else {
            remember()
            render()
            return true
        }
        perform(action)
        return true
    }

    func shutdown() {
        renderTask?.cancel()
        renderTask = nil
        reachTask?.cancel()
        reachTask = nil
        openTask?.cancel()
        openTask = nil
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
        board.describe(String(cString: raw))
        render()
    }

    /// What activating a row means here. Everything the board can do on its own — walking a
    /// setting, expanding a section, putting an old recipe back in the draft — never reaches this.
    private func perform(_ action: ForgeAction) {
        switch action {
        case .render(let recipe):
            start(recipe)
        case .cancel:
            stop()
        case .play(let asset):
            play(asset)
        case .edit(let field):
            edit(field)
        case .configure:
            askForRenderer()
        }
    }

    private func edit(_ field: ForgeField) {
        switch field {
        case .endpoint:
            askForRenderer()
        case .prompt:
            focusPrompt()
        case .negative:
            askForAvoidance()
        case .size, .seconds, .fps, .model, .seed:
            return
        }
    }

    /// Where the renderer lives, asked for in the one place a person can answer it. The reading is
    /// Core's and so is every refusal, so a typed address that cannot be reached is explained in
    /// the same sentence on every client.
    private func askForRenderer() {
        Dialogs.prompt(
            title: ForgeField.endpoint.label, body: ForgeFailure.unconfigured.description,
            placeholder: board.value(of: .endpoint),
            initial: board.endpoint?.displayHost ?? "", confirmLabel: Localized.text("Save"),
            parent: parent
        ) { [weak self] text in
            Gtk.onMain { [weak self] in self?.point(at: text) }
        }
    }

    private func askForAvoidance() {
        Dialogs.prompt(
            title: ForgeField.negative.label, body: nil,
            placeholder: board.value(of: .negative), initial: board.recipe.negative,
            confirmLabel: Localized.text("Save"), parent: parent
        ) { [weak self] text in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.board.avoid(text)
                self.remember()
                self.render()
            }
        }
    }

    private func point(at raw: String) {
        let reading = ForgeEndpoint.read(raw)
        switch reading {
        case .endpoint(let endpoint):
            reason = nil
            ForgeStore.remember(endpoint)
            SettingsFile.capture()
            board.point(at: endpoint)
            probe()
        case .empty:
            reason = nil
            ForgeStore.remember(nil)
            SettingsFile.capture()
            board.point(at: nil)
            render()
        case .bindAll, .unsupportedScheme, .invalid:
            reason = ForgeEndpoint.complaint(reading)
            render()
        }
    }

    /// Whether anything is listening, asked the cheap way. The box is socket-activated, so this
    /// says the port answers and nothing more — which is exactly what the row it feeds claims.
    private func probe() {
        guard let endpoint = board.endpoint else { return }
        board.checking()
        reachTask?.cancel()
        reachTask = Task { [weak self] in
            let verdict = await endpoint.reach()
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.board.reached(verdict)
                self.render()
            }
        }
    }

    /// One render, watched. Every snapshot the stream yields goes straight into the board, and the
    /// last one is always terminal — so a bar that stops moving is a render that stopped, never a
    /// client that stopped listening.
    private func start(_ recipe: ForgeRecipe) {
        guard let endpoint = board.endpoint else { return }
        remember()
        reason = nil
        let client = ForgeClient(endpoint: endpoint)
        self.client = client
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            for await job in client.render(recipe) {
                Gtk.onMain { [weak self] in self?.saw(job) }
            }
        }
        render()
    }

    private func saw(_ job: ForgeJob) {
        board.saw(job)
        if job.isFinished, ForgeStore.record(job) != nil {
            SettingsFile.capture()
            board.filled(history: ForgeStore.history())
        }
        render()
    }

    /// Stops the render on the machine that is doing it. The interrupt is what ends the job, not
    /// this pane letting go: the socket answers with the frame that says it stopped, and the board
    /// draws that rather than this client's guess about it.
    private func stop() {
        guard let client = renderer() else { return }
        Task { await client.cancel() }
    }

    /// The client for whatever machine is configured right now, kept so a cancel and a lookup use
    /// the same one the render did rather than minting a connection per press.
    private func renderer() -> ForgeClient? {
        if let client, client.endpoint == board.endpoint { return client }
        guard let endpoint = board.endpoint else { return nil }
        let fresh = ForgeClient(endpoint: endpoint)
        client = fresh
        return fresh
    }

    /// A clip, asked for before it is opened. The file is on the other machine and `/view` answers
    /// one that has been cleaned up with a 404 — which a player reports in its own words, none of
    /// them about this machine — so Core is asked where the file is first and its sentence is what
    /// a clip that is gone says.
    private func play(_ asset: ForgeAsset) {
        guard let client = renderer() else { return }
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

    /// What the next render starts from, kept. `UserDefaults` on Linux is keyed to the executable's
    /// path, so the durable copy is written in the same breath — otherwise the settings somebody
    /// built survive only until the next install puts the binary somewhere else.
    private func remember() {
        ForgeStore.remember(board.recipe)
        SettingsFile.capture()
    }

    private func render() {
        gtk_label_set_text(op(headingLabel), board.heading)
        gtk_label_set_text(op(hintLabel), isPlaying ? board.job.hint : board.hint)
        gtk_label_set_text(op(noticeLabel), board.notice)
        drawAside()
        gtk_widget_set_visible(boardScroller, isPlaying ? 0 : 1)
        if let surface { gtk_widget_set_visible(surface, isPlaying ? 1 : 0) }
        renderBoard()
        onChange?()
    }

    /// The one line the pane says on its own behalf, under the prompt: what it is waiting on, or
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
        board.focus(section: section, offset: offset)
        guard let action = board.activate() else {
            remember()
            render()
            return
        }
        perform(action)
    }

    /// The button under the render, which means a different thing in each of its four states —
    /// stop what is running, play what came back, ask for a machine that was never given, or
    /// render. Which of them it is is the board's answer, not this pane's.
    private func call() {
        guard let action = board.begin() else {
            render()
            return
        }
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
                     self.board.reuse(entry)
                     self.describe(entry.recipe.prompt)
                     self.remember()
                     self.render()
                 }
             }))
        rows.append(
            (Localized.text("Forget it"), nil,
             { [weak self] in
                 Gtk.onMain { [weak self] in
                     guard let self else { return }
                     ForgeStore.remove(entry.id)
                     SettingsFile.capture()
                     self.board.filled(history: ForgeStore.history())
                     self.render()
                 }
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
    /// back, because a black pane with nothing in it is indistinguishable from one still loading.
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
    /// Every state the surface has, put on screen without a renderer to make one happen. A render
    /// is minutes of another machine's card, so the states between pressing the button and holding
    /// a file cannot be reached in a build loop — and they are exactly the states worth checking,
    /// since each of them is a different sentence. Every value here is Core's own: the phases come
    /// from `ForgeJob`'s mutators and the frames from `ForgeEvent`, so nothing is described in
    /// words this pane made up.
    func demonstrate(_ name: String) {
        quiet()
        let renderer = ForgeEndpoint(host: Self.demoHost)
        let recipe = ForgeRecipe(
            prompt: Self.demoPrompt, negative: Self.demoAvoidance, seconds: 5, fps: 24, seed: 7)
        board = ForgeBoard(recipe: recipe, endpoint: name == "unset" ? nil : renderer)
        describe(name == "unset" ? "" : Self.demoPrompt)
        reason = nil
        working = nil
        switch name {
        case "unset":
            board.filled(history: [])
        case "checking":
            board.checking()
            board.filled(history: [])
        case "down":
            board.reached(.timedOut)
            board.filled(history: [])
        case "history":
            board.reached(.listening)
            board.filled(history: Self.demoHistory(recipe))
        case "empty":
            board.reached(.listening)
            board.filled(history: [])
        default:
            board.reached(.listening)
            board.saw(Self.demoJob(name, recipe: recipe))
            board.filled(history: Self.demoHistory(recipe))
        }
        render()
    }

    /// Everything already in flight, let go of before a state is put on screen by hand — the probe
    /// and the render both answer on their own clock, and a snapshot landing a second later would
    /// quietly rewrite the state somebody asked to look at.
    private func quiet() {
        showBoard()
        reachTask?.cancel()
        reachTask = nil
        renderTask?.cancel()
        renderTask = nil
        openTask?.cancel()
        openTask = nil
    }

    private static let demoHost = "arch"
    private static let demoPrompt = "a cat asleep on a warm roof"
    private static let demoAvoidance = "blurry"

    private static func demoJob(_ name: String, recipe: ForgeRecipe) -> ForgeJob {
        var job = ForgeJob(recipe: recipe)
        guard name != "ready" else { return job }
        job.submitting()
        guard name != "waking" else { return job }
        job.accepted(promptID: demoPromptID, queued: 2)
        guard name != "queued" else { return job }
        switch name {
        case "failed":
            job.saw(.failed(demoPromptID, reason: ForgeFailure.noOutput(demoHost).description))
        case "cancelled":
            job.saw(.interrupted(demoPromptID))
        case "collecting", "done":
            job.saw(.progressed(demoPromptID, census: ForgeCensus(finished: 27, total: 28, running: "save")))
            job.saw(.finished(demoPromptID))
            if name == "done" { job.delivered(demoAsset) }
        default:
            job.saw(.started(demoPromptID))
            job.saw(.progressed(demoPromptID, census: ForgeCensus(finished: 7, total: 28, running: "pass1")))
            job.saw(.sampling(demoPromptID, node: "pass1", step: 3, steps: 8))
        }
        return job
    }

    private static func demoHistory(_ recipe: ForgeRecipe) -> [ForgeEntry] {
        let made = (0..<6).map { index in
            ForgeEntry(
                id: "\(demoPromptID)\(index)", recipe: recipe.with(seed: index),
                asset: ForgeAsset(filename: "forge_0000\(index).mp4", subfolder: "video"),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        }
        let lost = ForgeEntry(
            id: "\(demoPromptID)gone", recipe: recipe.with(seed: 9), asset: nil,
            failure: ForgeFailure.unreachable(demoHost).description,
            finishedAt: Date(timeIntervalSince1970: 1_700_000_000))
        return made + [lost]
    }

    private static let demoPromptID = "demo"
    private static let demoAsset = ForgeAsset(
        filename: "forge_00001.mp4", subfolder: "video", type: "output")
}
