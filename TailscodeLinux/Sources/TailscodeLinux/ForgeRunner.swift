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
final class ForgeRunner: @unchecked Sendable {
    static let shared = ForgeRunner()

    private(set) var board: ForgeBoard
    /// The render that is out, kept with the machine it went to.
    private var render: Render?
    private var renderTicket = 0
    /// Which probe's answer the board still wants. A verdict crosses back to the main loop after
    /// the machine has answered, and by then the board may point somewhere else — so every probe
    /// is numbered and only the newest one is allowed to say what it found.
    private var probeTicket = 0
    private var reachTask: Task<Void, Never>?
    /// Whoever is drawing this right now — the modal while it is open, and the control in the
    /// sidebar for as long as the app is up, which is what lets a render still be seen once the
    /// window it was started from has gone.
    private var watchers: [ObjectIdentifier: @Sendable () -> Void] = [:]

    private init() {
        board = ForgeBoard(recipe: ForgeStore.recipe(), endpoint: ForgeStore.endpoint())
        board.filled(history: ForgeStore.history())
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
        board.point(at: endpoint)
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
        board.point(at: ForgeStore.endpoint())
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
        renderTicket += 1
        let ticket = renderTicket
        let client = ForgeClient(endpoint: endpoint)
        render = Render(
            ticket: ticket, client: client,
            task: Task { [weak self] in
                for await job in client.render(recipe) {
                    Gtk.onMain { [weak self] in self?.saw(job, from: ticket) }
                }
                Gtk.onMain { [weak self] in self?.ended(ticket) }
            },
            isOut: true)
        changed()
    }

    /// A snapshot, taken only from the render the board is showing. One from a render that was
    /// stopped or superseded is dropped rather than drawn: the socket is still being wound down
    /// while it arrives, and it would put a machine's account of abandoned work back over the
    /// terminal state the stop already wrote.
    private func saw(_ job: ForgeJob, from ticket: Int) {
        guard let render, render.ticket == ticket, render.isOut else { return }
        board.saw(job)
        if job.isFinished, ForgeStore.record(job) != nil {
            SettingsFile.capture()
            board.filled(history: ForgeStore.history())
        }
        changed()
    }

    /// The stream is over. Only the task that owns the handle may put it down — by the time a
    /// stream ends, the handle can already belong to a render started after it, and clearing that
    /// one would leave a live render with nothing able to stop it.
    private func ended(_ ticket: Int) {
        guard render?.ticket == ticket else { return }
        render?.isOut = false
    }

    /// Stops the render on the machine doing it, and stops watching for it here.
    ///
    /// Three things have to happen and none of them follows from another. The interrupt goes to the
    /// client that submitted, because the board may name a different machine by now. Cancelling the
    /// stream is what ends the watch — a job still queued behind another has nothing running to
    /// interrupt, and a machine that has gone quiet answers no frame at all. And the job is put
    /// into its stopped state right here: cancelling the consumer terminates the stream before
    /// ``ForgeClient`` can yield the snapshot it makes on its way out, so a runner that waited for
    /// that snapshot would sit on a board that never leaves `.running` and a button stuck on Stop.
    func stop() {
        guard board.isBusy else { return }
        if var current = render, current.isOut {
            let client = current.client
            Task { await client.cancel() }
            current.task.cancel()
            current.isOut = false
            render = current
        }
        var job = board.job
        job.cancelled()
        board.saw(job)
        changed()
    }

    /// Which machine to ask about a file. A clip this run produced is asked of the machine that
    /// wrote it — the board can be re-pointed between a render finishing and its clip being pressed,
    /// and the machine that replaced it has never heard of the file — and anything else is asked of
    /// the machine the board names now.
    func renderer(for asset: ForgeAsset) -> ForgeClient? {
        if let render, board.job.asset == asset { return render.client }
        guard let endpoint = board.endpoint else { return nil }
        return ForgeClient(endpoint: endpoint)
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
        let renderer = ForgeEndpoint(host: Self.demoHost)
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
