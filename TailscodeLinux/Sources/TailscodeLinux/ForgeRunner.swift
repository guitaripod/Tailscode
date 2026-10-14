import CGdkPixbuf
import Foundation
import TailscodeCore

/// The render, held above the window that started it.
///
/// A render is minutes of another machine's card, and the surface it is watched on is a modal: it
/// closes, it reopens, and neither may touch work already out. So the board, the connection and the
/// render's own task live here — one per app, the way `ForgeRunner` already holds them on the phone
/// — and the modal is only a view over it. Closing the window closes a window; the socket stays up,
/// the job keeps arriving, and reopening finds the same render exactly where it was.
///
/// Everything here runs on the GLib main context, hopped through `Gtk.onMain` at every boundary a
/// task crosses, so the board is only ever read and written by the one thread that draws it.
final class ForgeRunner: @unchecked Sendable, HelperHost {
    static let shared = ForgeRunner()

    private(set) var board: ForgeBoard
    /// The render that is out, kept with the machine it went to.
    private var render: Render?
    private var renderTicket = 0
    /// The machine's last sketch of the clip being rendered, kept until the clip lands so it can
    /// be filed as the clip's poster — the job's own sketch is gone by the time it is done.
    private var heldSketch: ImageGenPreviewFrame?
    /// Which probe's answer the board still wants. A verdict crosses back to the main loop after
    /// the machine has answered, and by then the board may point somewhere else — so every probe
    /// is numbered and only the newest one is allowed to say what it found.
    private var probeTicket = 0
    private var reachTask: Task<Void, Never>?
    /// Whoever is drawing this right now — the modal while it is open, and the control in the
    /// sidebar for as long as the app is up, which is what lets a render still be seen once the
    /// window it was started from has gone.
    private var watchers: [ObjectIdentifier: @Sendable () -> Void] = [:]
    /// The rewrite in flight or landed and not yet taken, drawn as a card under the words.
    private(set) var draft: ImageGenRewriteDraft?
    private let rewriter = ImageGenRewriter()
    private var rewriteAnnouncePending = false
    /// One line for whoever is showing this — a helper found on its own, a helper gone.
    var onNotice: (@Sendable (String) -> Void)?
    /// Every machine that answered the last survey and what each serves, for the picker.
    private(set) var helperServers: [ImageGenHelperServer] = []
    private(set) var surveying = false
    private(set) var surveyedAt: Date?
    /// The clip that landed and has already been put in front of somebody. A clip is presented
    /// once, to whichever surface is up when it lands or the first one to open after: a surface
    /// that is built afresh each time it is shown would otherwise play last night's clip, sound
    /// and all, every time it opened.
    private var presented: ForgeAsset?
    /// The failure somebody has looked at, by the job's handle. A render that broke is lit on the
    /// video button until its card has been on a stage, the same way a clip that landed is until it
    /// has been presented.
    private var acknowledgedFailure: String?

    private init() {
        board = ForgeBoard(
            recipe: ForgeStore.recipe(), endpoint: ForgeStore.endpoint(),
            rendererName: ForgeStore.label(for: ForgeStore.endpoint()))
        board.filled(history: ForgeStore.history())
        board.learned(ForgeStore.clock())
        Gtk.onMain { [weak self] in self?.recover() }
    }

    /// Whether the other machine is working, which is the one fact a surface that is closed still
    /// has to be able to report.
    var isRendering: Bool { board.isBusy }

    var endpoint: ForgeEndpoint? { board.endpoint }

    func watch(_ owner: AnyObject, _ block: @escaping @Sendable () -> Void) {
        watchers[ObjectIdentifier(owner)] = block
    }

    func unwatch(_ owner: AnyObject) {
        watchers.removeValue(forKey: ObjectIdentifier(owner))
    }

    private func changed() {
        for watcher in watchers.values { watcher() }
    }

    /// What a surface about to be shown owes the reader: the machine asked again, in case it went
    /// to sleep since the last look, and the history re-read, in case another window changed it.
    /// A render in flight is left strictly alone — it is already the truest thing on the board.
    func prepare() {
        board.filled(history: ForgeStore.history())
        adopt(ForgeStore.endpoint())
        changed()
    }

    /// Points the board at whatever the store now holds, without disturbing a board already
    /// pointed there — re-pointing resets the reachability phase, and a renderer that answered a
    /// second ago must not read as unchecked because a window was reopened over it.
    private func adopt(_ endpoint: ForgeEndpoint?) {
        guard endpoint != board.endpoint else { return }
        board.point(at: endpoint, named: ForgeStore.label(for: endpoint))
        probe()
    }

    func pick(_ field: ForgeField, id: String) {
        board.pick(field, id: id)
        remember()
        changed()
    }

    func describe(_ words: String) {
        board.describe(words)
        changed()
    }

    func avoid(_ words: String) {
        board.avoid(words)
        remember()
        changed()
    }

    func hear(_ words: String) {
        board.hear(words)
        remember()
        changed()
    }

    /// Opens the next clip on a picture, with its shape read off the file when it is one on
    /// this device, or on nothing.
    func start(from frame: ForgeFrame?, width: Int? = nil, height: Int? = nil) {
        var width = width
        var height = height
        if width == nil, case .file(let path) = frame, let size = Gtk.imageSize(atPath: path) {
            width = size.width
            height = size.height
        }
        board.start(from: frame, pictureWidth: width, pictureHeight: height)
        remember()
        changed()
    }

    /// Continues a kept clip: the next render opens where it ended.
    func extend(_ entry: ForgeEntry) {
        board.extend(entry)
        remember()
        changed()
    }

    /// The shape the helper answered with, followed only where nobody chose one.
    func follow(size: ForgeSize) {
        board.follow(size: size)
        remember()
        changed()
    }

    func reuse(_ entry: ForgeEntry) {
        board.reuse(entry)
        remember()
        changed()
    }

    func focus(section: String, offset: Int) {
        board.focus(section: section, offset: offset)
    }

    func activate() -> ForgeAction? {
        let action = board.activate()
        if action == nil { remember() }
        changed()
        return action
    }

    func begin() -> ForgeAction? {
        let action = board.begin()
        changed()
        return action
    }

    func handle(_ command: ForgeCommand) -> (handled: Bool, action: ForgeAction?) {
        let outcome = board.handle(command)
        guard outcome.handled else { return outcome }
        if outcome.action == nil { remember() }
        changed()
        return outcome
    }

    /// A renderer chosen in the setup surface, taken into the board and asked at once. The store is
    /// the authority — the setup wrote it there — so this reads it back rather than being handed a
    /// second copy of the same decision.
    func pointAtStoredRenderer() {
        board.point(at: ForgeStore.endpoint(), named: ForgeStore.label(for: ForgeStore.endpoint()))
        SettingsFile.capture()
        probe()
        changed()
    }

    /// Whether anything is listening, asked the cheap way. The box is socket-activated, so this
    /// says the port answers and nothing more — which is exactly what the row it feeds claims.
    ///
    /// The verdict is claimed by number rather than by whichever probe answers last. A probe hops
    /// its answer to the main loop, so cancelling the task cannot stop one that has already
    /// resolved: without the number, a machine asked before the renderer was changed would report
    /// its reachability onto the row of the machine that replaced it.
    func probe() {
        probeTicket += 1
        reachTask?.cancel()
        reachTask = nil
        guard let endpoint = board.endpoint else { return }
        board.checking()
        let ticket = probeTicket
        reachTask = Task { [weak self] in
            let verdict = await endpoint.reach()
            Gtk.onMain { [weak self] in
                guard let self, self.probeTicket == ticket else { return }
                self.board.reached(verdict)
                self.changed()
            }
        }
    }

    /// One render, held with the machine it went to.
    ///
    /// The renderer is a setting somebody can change while a render burns, so an interrupt or a
    /// lookup aimed at "the renderer" would reach whichever machine was chosen last rather than the
    /// one holding the job — killing an unrelated render on the new box while the real one runs the
    /// old box's card out unwatched. The client that submitted is kept with the task that reads it,
    /// and everything asked about this render is asked of that client.
    private struct Render {
        let ticket: Int
        let client: ForgeClient
        let task: Task<Void, Never>
        /// Whether the stream is still arriving. The client outlives it deliberately: the clip a
        /// finished render left is a file on that machine's disk, and it has to be looked up there
        /// however the board has been re-pointed since.
        var isOut: Bool
    }

    /// One render, watched. Every snapshot the stream yields goes straight into the board, and the
    /// last one is always terminal — so a bar that stops moving is a render that stopped, never a
    /// client that stopped listening.
    ///
    /// A second press before the first snapshot lands is not a second render. `board.isBusy` only
    /// becomes true when the stream says so, which leaves a window in which the board still offers
    /// to render — and a start taken in that window would abandon the render already out without
    /// interrupting the machine doing it, then lose the handle that could have stopped it.
    func start(_ recipe: ForgeRecipe) {
        guard render?.isOut != true, let endpoint = board.endpoint else { return }
        remember()
        heldSketch = nil
        renderTicket += 1
        let ticket = renderTicket
        let client = ForgeClient(endpoint: endpoint)
        let expecting = board.clock.estimate(recipe)
        render = Render(
            ticket: ticket, client: client,
            task: Task { [weak self] in
                for await job in client.render(recipe, expecting: expecting) {
                    Gtk.onMain { [weak self] in self?.saw(job, from: ticket) }
                }
                Gtk.onMain { [weak self] in self?.ended(ticket) }
            },
            isOut: true)
        changed()
    }

    /// A render the app lost track of — it was closed, reinstalled or killed while the machine
    /// carried on — picked up again by the id it was filed under. Whatever became of it while
    /// nobody watched is told the way a render started here is: still running, finished and filed,
    /// failed in the machine's own words, or forgotten by a restart of the machine.
    private func recover() {
        guard render?.isOut != true, let pending = ForgeStore.pending() else { return }
        heldSketch = nil
        renderTicket += 1
        let ticket = renderTicket
        let client = ForgeClient(endpoint: pending.endpoint, clientID: pending.clientID)
        let expecting = board.clock.estimate(pending.recipe)
        AppLog.write(.ui, "forge recovering render prompt=\(pending.promptID) confirmed=\(pending.confirmed)")
        render = Render(
            ticket: ticket, client: client,
            task: Task { [weak self] in
                guard let stream = await client.recover(pending, expecting: expecting) else {
                    Gtk.onMain { [weak self] in self?.ended(ticket) }
                    return
                }
                for await job in stream {
                    Gtk.onMain { [weak self] in self?.saw(job, from: ticket) }
                }
                Gtk.onMain { [weak self] in self?.ended(ticket) }
            },
            isOut: true)
    }

    /// A snapshot, taken only from the render the board is showing. One from a render that was
    /// stopped or superseded is dropped rather than drawn: the socket is still being wound down
    /// while it arrives, and it would put a machine's account of abandoned work back over the
    /// terminal state the stop already wrote — except that a clip which did land is a clip, and
    /// is filed on the shelf without touching what the board says.
    private func saw(_ job: ForgeJob, from ticket: Int) {
        guard let render, render.ticket == ticket, render.isOut else {
            if job.asset != nil, let client = renderClient(of: ticket) {
                fileLate(job, on: client.endpoint)
            }
            return
        }
        if let frame = job.sketch { heldSketch = frame }
        if let asset = job.asset, let frame = heldSketch {
            ForgePosters.write(frame, for: asset)
            heldSketch = nil
        }
        board.saw(job)
        if job.isFinished, ForgeStore.record(job, on: render.client.endpoint) != nil {
            if let clock = board.learn(from: job) { ForgeStore.remember(clock: clock) }
            board.filled(history: ForgeStore.history())
        }
        SettingsFile.capture()
        changed()
    }

    private func renderClient(of ticket: Int) -> ForgeClient? {
        render?.ticket == ticket ? render?.client : nil
    }

    /// A clip that landed after the person stopped waiting for it. It stays on the shelf and
    /// nothing else moves: they asked for it to stop, and a clip taking the stage back would be
    /// the machine answering a question that was withdrawn.
    private func fileLate(_ job: ForgeJob, on endpoint: ForgeEndpoint) {
        guard ForgeStore.record(job, on: endpoint) != nil else { return }
        SettingsFile.capture()
        board.filled(history: ForgeStore.history())
        changed()
    }

    /// The stream is over. Only the task that owns the handle may put it down — by the time a
    /// stream ends, the handle can already belong to a render started after it, and clearing that
    /// one would leave a live render with nothing able to stop it.
    private func ended(_ ticket: Int) {
        guard render?.ticket == ticket else { return }
        render?.isOut = false
        SettingsFile.capture()
    }

    /// Stops the render on the machine doing it, and stops watching for it here.
    ///
    /// Three things have to happen and none of them follows from another. The stop goes to the
    /// client that submitted, because the board may name a different machine by now, and names the
    /// job — a job still queued behind another has nothing running to interrupt, and the machine
    /// is shared. Cancelling the stream is what ends the watch — a machine that has gone quiet
    /// answers no frame at all. And the job is put into its stopped state right here: cancelling
    /// the consumer terminates the stream before ``ForgeClient`` can yield the snapshot it makes on
    /// its way out, so a runner that waited for that snapshot would sit on a board that never
    /// leaves `.running` and a button stuck on Stop.
    ///
    /// A job caught in its last seconds has a clip, and the machine says so when it is asked to
    /// stop it: that clip is filed rather than thrown away.
    func stop() {
        guard board.isBusy else { return }
        let handle = board.job.handle
        let recipe = board.job.recipe
        if var current = render, current.isOut {
            let client = current.client
            if let handle {
                Task { [weak self] in
                    let outcome = await client.cancel(handle)
                    guard case .finished(let asset)? = outcome else { return }
                    Gtk.onMain { [weak self] in
                        self?.fileLate(handle, recipe: recipe, asset: asset, on: client.endpoint)
                    }
                }
            }
            current.task.cancel()
            current.isOut = false
            render = current
        }
        ForgeStore.clearPending(handle)
        var job = board.job
        job.cancelled()
        board.saw(job)
        SettingsFile.capture()
        changed()
    }

    private func fileLate(_ id: String, recipe: ForgeRecipe, asset: ForgeAsset, on endpoint: ForgeEndpoint) {
        ForgeStore.record(ForgeEntry(id: id, recipe: recipe, asset: asset, endpoint: endpoint))
        SettingsFile.capture()
        board.filled(history: ForgeStore.history())
        changed()
    }

    /// Which machine to ask about a kept clip: the one that wrote it. A renderer numbers its own
    /// files, the board can be re-pointed at another machine any time after, and the machine that
    /// replaced it has either never heard of `forge_00007.mp4` or has a different clip by that name.
    /// A receipt filed before machines were recorded is asked of the one the board names now.
    func client(for entry: ForgeEntry) -> ForgeClient? {
        guard let endpoint = entry.endpoint ?? board.endpoint else { return nil }
        return ForgeClient(endpoint: endpoint)
    }

    /// The clip that has landed and not yet been shown to anybody, if there is one.
    var unpresented: ForgeAsset? {
        guard let asset = board.job.asset, asset != presented else { return nil }
        return asset
    }

    func present(_ asset: ForgeAsset) {
        guard presented != asset else { return }
        presented = asset
        changedNext()
    }

    /// The failure on the board has been put in front of somebody.
    func acknowledgeFailure() {
        guard case .failed = board.job.phase, let handle = board.job.handle,
            acknowledgedFailure != handle
        else { return }
        acknowledgedFailure = handle
        changedNext()
    }

    /// Whether the person has looked at how the job on the board ended: the clip on a stage, the
    /// failure on a card. A job still out has no ending to have seen.
    private var outcomeSeen: Bool {
        switch board.job.phase {
        case .done: return unpresented == nil
        case .failed: return board.job.handle == acknowledgedFailure
        case .drafting, .submitting, .queued, .running, .cancelled: return false
        }
    }

    /// What the video button says about the render: its light.
    var light: ForgeLight { ForgeLight.read(job: board.job, seen: outcomeSeen) }

    /// Tells the watchers on the next turn of the loop. Looking at an outcome happens inside a
    /// surface that is itself a watcher, and calling it back from the middle of its own redraw is
    /// how a redraw ends up drawing itself.
    private func changedNext() {
        Gtk.onMain { [weak self] in self?.changed() }
    }

    func forget(_ entry: ForgeEntry) {
        ForgeStore.remove(entry.id)
        SettingsFile.capture()
        board.filled(history: ForgeStore.history())
        changed()
    }

    /// What the next render starts from, kept. `UserDefaults` on Linux is keyed to the executable's
    /// path, so the durable copy is written in the same breath — otherwise the settings somebody
    /// built survive only until the next install puts the binary somewhere else.
    private func remember() {
        ForgeStore.remember(board.recipe)
        SettingsFile.capture()
    }
}

extension ForgeRunner {
    /// Every state the surface has, put on the board without a renderer to make one happen. A
    /// render is minutes of another machine's card, so the states between pressing the button and
    /// holding a file cannot be reached in a build loop — and they are exactly the states worth
    /// checking, since each of them is a different sentence. Every value here is Core's own: the
    /// phases come from `ForgeJob`'s mutators and the frames from `ForgeEvent`, so nothing is
    /// described in words this client made up.
    func demonstrate(_ name: String) {
        quiet()
        presented = nil
        acknowledgedFailure = nil
        let renderer = ForgeEndpoint(host: Self.demoHost, port: Self.demoPort)
        let recipe = ForgeRecipe(
            prompt: name == "unset" ? "" : Self.demoPrompt, negative: Self.demoAvoidance,
            seconds: 5, fps: 24, seed: 7)
        board = ForgeBoard(recipe: recipe, endpoint: name == "unset" ? nil : renderer)
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
        changed()
    }

    /// Everything already in flight, let go of before a state is put on the board by hand — the
    /// probe and the render both answer on their own clock, and a snapshot landing a second later
    /// would quietly rewrite the state somebody asked to look at.
    private func quiet() {
        probeTicket += 1
        reachTask?.cancel()
        reachTask = nil
        render?.task.cancel()
        render = nil
    }

    private static let demoHost = "arch"

    /// The port the demo's renderer answers on: the default, unless `TAILSCODE_DEMO_FORGE_PORT`
    /// names a stand-in server, so a harness that stages clips never asks a real machine about them.
    private static var demoPort: Int {
        ProcessInfo.processInfo.environment["TAILSCODE_DEMO_FORGE_PORT"].flatMap(Int.init)
            ?? ForgeEndpoint.defaultPort
    }
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
            job.saw(
                .progressed(demoPromptID, census: ForgeCensus(finished: 27, total: 28, running: "save")))
            job.saw(.finished(demoPromptID))
            if name == "done" { job.delivered(demoAsset) }
        default:
            job.saw(.started(demoPromptID))
            job.saw(
                .progressed(demoPromptID, census: ForgeCensus(finished: 7, total: 28, running: "pass1")))
            job.saw(.sampling(demoPromptID, node: "pass1", step: 3, steps: 8))
            if let frame = demoSketches.first { job.saw(.sketched(frame)) }
        }
        return job
    }

    /// Pictures to stand in for the machine's sketches and the clips' posters in a demo, named by
    /// `TAILSCODE_DEMO_SKETCH` as a comma-separated list of files — a harness with no renderer to
    /// stream a sketch has to be told what one looks like. Nothing is read without the variable.
    private static var demoSketches: [ImageGenPreviewFrame] {
        guard let list = ProcessInfo.processInfo.environment["TAILSCODE_DEMO_SKETCH"] else { return [] }
        return list.split(separator: ",").compactMap { path in
            guard let data = FileManager.default.contents(atPath: String(path)) else { return nil }
            let png = path.lowercased().hasSuffix(".png")
            return ImageGenPreviewFrame(encoding: png ? .png : .jpeg, bytes: data)
        }
    }

    /// The clips' posters in a demo: with more than one file named, the first is the sketch of the
    /// render in flight and the rest are the posters, so a half-painted frame is never also a
    /// finished clip's cover.
    private static var demoPosters: [ImageGenPreviewFrame] {
        let all = demoSketches
        return all.count > 1 ? Array(all.dropFirst()) : all
    }

    private static func demoHistory(_ recipe: ForgeRecipe) -> [ForgeEntry] {
        let made = (0..<6).map { index in
            ForgeEntry(
                id: "\(demoPromptID)\(index)", recipe: recipe.with(seed: index),
                asset: ForgeAsset(filename: "forge_0000\(index).mp4", subfolder: "video"),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        }
        let sketches = demoPosters
        if !sketches.isEmpty {
            for (index, entry) in made.enumerated() {
                if let asset = entry.asset { ForgePosters.write(sketches[index % sketches.count], for: asset) }
            }
        }
        let lost = ForgeEntry(
            id: "\(demoPromptID)gone", recipe: recipe.with(seed: 9), asset: nil,
            failure: ForgeFailure.unreachable(demoHost).description,
            finishedAt: Date(timeIntervalSince1970: 1_700_000_000))
        return sketches.isEmpty ? made + [lost] : made
    }

    private static let demoPromptID = "demo"
    private static let demoAsset = ForgeAsset(
        filename: "forge_00001.mp4", subfolder: "video", type: "output")
}

extension ForgeRunner {
    /// The small model that writes the caption, shared with the image studio: one helper on
    /// this device, filed once, offered in both places.
    var helper: ImageGenHelper? { ImageGenStore.helper() }

    /// Whether a rewrite is out right now.
    var enhancing: Bool { draft?.isWriting == true }

    /// Posted when the paragraph grew and nothing else changed, coalesced to a few a second,
    /// so the surface refreshes one text view rather than rebuilding itself per token.
    static let rewriteDidChange = Notification.Name("tailscode.forge.rewriteDidChange")

    /// Asks the helper for the caption, streaming it into ``draft`` as it is written. With no
    /// helper filed the machines near the renderer are surveyed first and the best writer is
    /// filed. `instruction` turns the ask into a revision of the caption already written.
    func rewrite(_ brief: String, instruction: String? = nil) {
        let previous = instruction == nil ? nil : draft?.written
        let context = ForgeRewriteContext(
            recipe: board.recipe, sizeChosen: board.sizeChosen, instruction: instruction,
            previous: previous)
        let near = board.endpoint.map { ImageGenEndpoint(host: $0.host, port: $0.port) }
        rewriter.start(
            brief: brief, ask: context.ask(brief), filed: helper, near: near,
            onHelper: { found in
                Gtk.onMain { ImageGenStore.remember(helper: found) }
            },
            onChange: { [weak self] draft in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    guard let draft else {
                        self.draft = nil
                        self.onNotice?(ImageGenRewriteWords.noneFoundTitle)
                        self.changed()
                        return
                    }
                    let grewOnly = self.draft?.isWriting == true && draft.isWriting
                    self.draft = draft
                    if grewOnly {
                        self.announceRewrite()
                    } else {
                        self.changed()
                    }
                }
            })
        draft = nil
        changed()
    }

    private func announceRewrite() {
        guard !rewriteAnnouncePending else { return }
        rewriteAnnouncePending = true
        Gtk.after(70) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.rewriteAnnouncePending = false
                NotificationCenter.default.post(name: ForgeRunner.rewriteDidChange, object: nil)
            }
        }
    }

    /// Stops a rewrite that is still writing and drops what it had.
    func stopRewrite() {
        rewriter.cancel()
        draft = nil
        changed()
    }

    /// Closes the card, keeping nothing. The words in the box were never touched.
    func dismissRewrite() {
        rewriter.cancel()
        draft = nil
        changed()
    }

    /// Asks every door near the renderer and on this device what it serves, and files the best
    /// writer when none is filed yet.
    func surveyHelpers() {
        guard !surveying else { return }
        surveying = true
        changed()
        let near = board.endpoint.map { ImageGenEndpoint(host: $0.host, port: $0.port) }
        Task.detached { [weak self] in
            let servers = await ImageGenHelperFinder.survey(near: near)
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.surveying = false
                self.surveyedAt = Date()
                self.helperServers = servers
                if let found = ImageGenHelperFinder.preferred(across: servers),
                    self.helper?.yields(to: found) ?? true
                {
                    ImageGenStore.remember(helper: found)
                }
                self.changed()
            }
        }
    }

    /// Files the helper a person picked from the list, which is kept over anything found later.
    func setHelper(_ helper: ImageGenHelper?) {
        var chosen = helper
        chosen?.chosenByHand = true
        ImageGenStore.remember(helper: chosen)
        changed()
    }

    /// Switches the filed helper off or on without forgetting it.
    func toggleHelper() {
        guard var current = helper else { return }
        current.enabled.toggle()
        ImageGenStore.remember(helper: current)
        changed()
    }
}

extension Gtk {
    /// A picture file's pixel size, read from its header without decoding it.
    static func imageSize(atPath path: String) -> (width: Int, height: Int)? {
        var width: gint = 0
        var height: gint = 0
        guard gdk_pixbuf_get_file_info(path, &width, &height) != nil, width > 0, height > 0 else {
            return nil
        }
        return (Int(width), Int(height))
    }
}
