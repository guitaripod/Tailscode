import Foundation
import TailscodeCore

/// The render, held above the window that started it.
///
/// A render is minutes of another machine's card, and the surface it is watched on is a modal: it
/// closes, it reopens, and neither may touch work already out. So the board, the connection and the
/// render's own task live here — one per app, the way `ForgeRunner` already holds them on the phone
/// and on the GTK desk — and the sheet is only a view over it. Closing the sheet closes a sheet; the
/// socket stays up, the job keeps arriving, and reopening finds the same render exactly where it was.
///
/// Nothing here decides a word. Every sentence on screen is `ForgeJob`'s or `ForgeBoard`'s; this
/// class only feeds them what arrived and says when something changed.
@MainActor
final class ForgeRunner {
    static let shared = ForgeRunner()

    private(set) var board: ForgeBoard
    /// Clips the renderer no longer has. Asked once, when somebody tries to play one, and kept here
    /// rather than in the view so a receipt that is known to be dead stays known across a close.
    private(set) var missing: Set<String> = []

    /// One client id for the life of the process. The POST and the websocket must carry the same
    /// one or the server delivers this render's frames to somebody else's socket and the job looks
    /// like it hung.
    private let clientID = UUID().uuidString
    private var client: ForgeClient?
    private var renderTask: Task<Void, Never>?
    /// The machine the render on the board was submitted to, held for as long as that render is the
    /// one being shown. The address is a setting somebody can change while a card is busy, and an
    /// interrupt sent to whatever the board points at now stops a stranger's work while this render
    /// carries on unwatched — so the client that submitted is the one that stops it, and the one the
    /// file it made is asked for.
    private var renderClient: ForgeClient?
    /// Which render is the current one. A task that ends after another has begun must not fold a
    /// stale snapshot into the board or put down a handle it no longer owns, and a task cannot
    /// compare itself against that handle from the inside, so each one carries the number its start
    /// claimed.
    private var renderTicket = 0
    private var reachTask: Task<Void, Never>?
    /// Whether the board was put into a named state by hand rather than by a machine. A staged board
    /// is a photograph of a state, and a real probe landing on top of it would replace the state
    /// somebody asked to look at with whatever this Mac can reach.
    private var isStaged = false
    /// Whoever is drawing this right now — the sheet while it is open, and the toolbar control for
    /// as long as the app is up, which is what lets a render still be seen once the surface it was
    /// started from has gone.
    private var watchers: [ObjectIdentifier: Watcher] = [:]

    /// Who asked to be told, held weakly beside what to tell them. An `ObjectIdentifier` is an
    /// address and an address is reused, so an entry outliving its owner does not merely waste a
    /// call: the next object allocated there inherits its slot, and one of the two watchers is
    /// silently lost. The owner is kept only to know it is still there.
    private struct Watcher {
        weak var owner: AnyObject?
        let notify: () -> Void
    }

    private init() {
        board = ForgeBoard(recipe: ForgeStore.recipe(), endpoint: ForgeStore.endpoint())
        board.filled(history: ForgeStore.history())
    }

    /// Whether the other machine is working, which is the one fact a surface that is closed still
    /// has to be able to report.
    var isRendering: Bool { board.isBusy }

    var endpoint: ForgeEndpoint? { board.endpoint }

    func watch(_ owner: AnyObject, _ block: @escaping () -> Void) {
        watchers[ObjectIdentifier(owner)] = Watcher(owner: owner, notify: block)
    }

    func unwatch(_ owner: AnyObject) {
        watchers.removeValue(forKey: ObjectIdentifier(owner))
    }

    /// How many surfaces are still being told. A watcher that outlived its owner changes nothing on
    /// screen, so this count is the only place the mistake can be seen before the address is reused.
    var watcherCount: Int {
        forgetTheDeparted()
        return watchers.count
    }

    private func changed() {
        forgetTheDeparted()
        for watcher in watchers.values { watcher.notify() }
    }

    /// Owners that are gone, dropped before anybody is called — a backstop under every surface
    /// letting go by hand, never a substitute for it, since an entry only leaves here once
    /// something else happens to change.
    private func forgetTheDeparted() {
        watchers = watchers.filter { $0.value.owner != nil }
    }

    /// What a surface about to be shown owes the reader: the machine asked again, in case it went to
    /// sleep since the last look, and the history re-read, in case the setup changed it. A render in
    /// flight is left strictly alone — it is already the truest thing on the board.
    func prepare() {
        guard !isStaged else { return }
        board.filled(history: ForgeStore.history())
        adopt(ForgeStore.endpoint())
        changed()
    }

    /// Points the board at whatever the store now holds, without disturbing a board already pointed
    /// there — re-pointing resets the reachability phase, and a renderer that answered a second ago
    /// must not read as unchecked because a sheet was reopened over it.
    private func adopt(_ endpoint: ForgeEndpoint?) {
        guard endpoint != board.endpoint else { return }
        board.point(at: endpoint)
        client = nil
        probe()
    }

    /// A renderer the setup settled on, taken into the board and asked at once. The store is the
    /// authority — the setup wrote it there — so this reads it back rather than being handed a
    /// second copy of the same decision.
    func pointAtStoredRenderer() {
        isStaged = false
        board.point(at: ForgeStore.endpoint())
        client = nil
        probe()
        changed()
    }

    /// Whether anything is listening, asked the cheap way. The box is socket-activated, so this says
    /// the port answers and nothing more — which is exactly what the row it feeds claims.
    func probe() {
        guard let endpoint = board.endpoint, !isStaged else { return }
        board.checking()
        reachTask?.cancel()
        reachTask = Task { [weak self] in
            let verdict = await endpoint.reach()
            guard let self, !Task.isCancelled else { return }
            self.board.reached(verdict)
            self.changed()
        }
        changed()
    }

    func pick(_ field: ForgeField, id: String) {
        board.pick(field, id: id)
        ForgeStore.remember(board.recipe)
        changed()
    }

    func describe(_ words: String) {
        board.describe(words)
        changed()
    }

    func avoid(_ words: String) {
        board.avoid(words)
        ForgeStore.remember(board.recipe)
        changed()
    }

    func reuse(_ entry: ForgeEntry) {
        board.reuse(entry)
        ForgeStore.remember(board.recipe)
        changed()
    }

    func focus(section: String, offset: Int) {
        board.focus(section: section, offset: offset)
    }

    func activate() -> ForgeAction? {
        let action = board.activate()
        if action == nil { ForgeStore.remember(board.recipe) }
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
        if outcome.action == nil { ForgeStore.remember(board.recipe) }
        changed()
        return outcome
    }

    /// One render, watched, and only ever one. Every snapshot the stream yields goes straight into
    /// the board, and the last one is always terminal — so a bar that stops moving is a render that
    /// stopped, never a client that stopped listening.
    ///
    /// The board is not busy until the stream's first snapshot arrives, so a second press in that
    /// window would otherwise start a second render: the first would be dropped without the machine
    /// running it ever being interrupted, and the abandoned task would clear the live one's handle
    /// on its way out, after which Stop had nothing to cancel. A render already in hand is the
    /// guard, and the ticket is what makes an ending belong to the task that owns it.
    func start(_ recipe: ForgeRecipe) {
        guard renderTask == nil, let connection = connection() else { return }
        ForgeStore.remember(recipe)
        renderClient = connection
        renderTicket += 1
        let ticket = renderTicket
        renderTask = Task { [weak self] in
            for await job in connection.render(recipe) {
                guard let self, self.renderTicket == ticket else { return }
                self.saw(job)
            }
            self?.settle(ticket)
        }
        changed()
    }

    /// The stream is over and nothing is holding the socket. Only the task that claimed the ticket
    /// may put the handle down: a render that was abandoned must not unlock the button for the one
    /// still arriving.
    private func settle(_ ticket: Int) {
        guard renderTicket == ticket else { return }
        renderTask = nil
    }

    private func saw(_ job: ForgeJob) {
        board.saw(job)
        if job.isFinished, ForgeStore.record(job) != nil {
            board.filled(history: ForgeStore.history())
        }
        changed()
    }

    /// Stops the render on the machine that is doing it, and here. The interrupt goes to the
    /// render's own renderer rather than to whatever the setting names now, is fired rather than
    /// awaited — it either landed or the render was already over — and the job is put into its
    /// stopped state so the surface says so even if the socket never answers again.
    func stop() {
        guard board.isBusy else { return }
        let renderer = renderClient
        Task { await renderer?.cancel() }
        renderTask?.cancel()
        renderTask = nil
        renderTicket += 1
        var job = board.job
        job.cancelled()
        board.saw(job)
        changed()
    }

    /// The client for whatever machine is configured right now, kept so two presses in a row do not
    /// mint a connection each.
    private func connection() -> ForgeClient? {
        if let client, client.endpoint == board.endpoint { return client }
        guard let endpoint = board.endpoint else { return nil }
        let fresh = ForgeClient(endpoint: endpoint, clientID: clientID)
        client = fresh
        return fresh
    }

    /// Which machine to ask for a file. A clip belongs to the machine that wrote it, so the one the
    /// render on the board just delivered is asked of that render's own renderer even when the
    /// setting has since been pointed somewhere else; everything else is asked of the machine in
    /// force, which is where this Mac's history was made.
    func renderer(for asset: ForgeAsset) -> ForgeClient? {
        guard board.job.asset == asset, let renderClient else { return connection() }
        return renderClient
    }

    /// Where to point a player, confirmed before it is pointed there. A clip whose file has been
    /// cleaned up off the renderer answers 404, and a video player reports that in words about
    /// nothing a person can act on — so the ask happens here and the row gets to say it is gone.
    func locate(_ asset: ForgeAsset, entryID: String? = nil) async throws -> URL {
        guard let renderer = renderer(for: asset) else { throw ForgeFailure.unconfigured }
        do {
            let url = try await renderer.locate(asset)
            if let entryID, missing.remove(entryID) != nil { changed() }
            return url
        } catch ForgeFailure.missingFile(let host) {
            if let entryID, missing.insert(entryID).inserted { changed() }
            throw ForgeFailure.missingFile(host)
        }
    }

    func isMissing(_ entry: ForgeEntry) -> Bool { missing.contains(entry.id) }

    func forget(_ entry: ForgeEntry) {
        ForgeStore.remove(entry.id)
        missing.remove(entry.id)
        board.filled(history: ForgeStore.history())
        changed()
    }

    func rememberRecipe() {
        ForgeStore.remember(board.recipe)
    }
}

extension ForgeRunner {
    /// Every state the surface has, put on the board without a renderer to make one happen. A render
    /// is minutes of another machine's card, so the states between pressing the button and holding a
    /// file cannot be reached in a build loop — and they are exactly the states worth checking, since
    /// each of them is a different sentence. Every value is `ForgeDemo`'s, which builds them out of
    /// Core's own mutators rather than describing them in words this client made up.
    func demonstrate(_ name: String) {
        quiet()
        isStaged = true
        board = ForgeDemo.board(name)
        missing = []
        changed()
    }

    /// Everything already in flight, let go of before a state is put on the board by hand — the probe
    /// and the render both answer on their own clock, and a snapshot landing a second later would
    /// quietly rewrite the state somebody asked to look at.
    private func quiet() {
        reachTask?.cancel()
        reachTask = nil
        renderTask?.cancel()
        renderTask = nil
        renderTicket += 1
        renderClient = nil
    }
}
