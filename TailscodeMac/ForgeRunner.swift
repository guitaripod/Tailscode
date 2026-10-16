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
    /// The clip that landed and has already been put in front of somebody. A clip is presented once,
    /// to whichever surface is up when it lands or the first one to open after: a surface that is
    /// shown afresh would otherwise play last night's clip, sound and all, every time it opened.
    private var presented: ForgeAsset?
    /// Whether the failure on the board has been put in front of somebody, the way `presented` is
    /// for a clip. Dropped the moment the board holds anything but that failure, so the next one is
    /// news again.
    private var acknowledgedFailure = false
    /// Whether the watchers are being called right now. A watcher that answers by changing what the
    /// runner holds must not be answered before the first round of calls has finished.
    private var notifying = false

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
    private var guess: MediaEndpointPlan.Choice?
    private var homeProfile: String?
    /// Whether the board was put into a named state by hand rather than by a machine. A staged board
    /// is a photograph of a state, and a real probe landing on top of it would replace the state
    /// somebody asked to look at with whatever this Mac can reach.
    private var isStaged = false
    /// The file a staged board plays from. A board that is a photograph of a state has no machine
    /// to ask where its clip is, so the state that holds one carries its own.
    private var demoClip: URL?
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
        board = ForgeBoard(
            recipe: ForgeStore.recipe(), endpoint: ForgeStore.endpoint(),
            rendererName: ForgeStore.label(for: ForgeStore.endpoint()))
        board.filled(history: ForgeStore.history())
        board.learned(ForgeStore.clock())
        Task { [weak self] in self?.recover() }
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
        if !hasFailed { acknowledgedFailure = false }
        let wasNotifying = notifying
        notifying = true
        defer { notifying = wasNotifying }
        for watcher in watchers.values { watcher.notify() }
    }

    /// Tells the watchers now, or on the next turn of the main actor when this is being asked from
    /// inside one of their own callbacks, which would otherwise be called again before it returned.
    private func announce() {
        guard notifying else {
            changed()
            return
        }
        Task { [weak self] in self?.changed() }
    }

    private var hasFailed: Bool {
        if case .failed = board.job.phase { return true }
        return false
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
        suggest()
        changed()
    }

    /// Points the board at whatever the store now holds, without disturbing a board already pointed
    /// there — re-pointing resets the reachability phase, and a renderer that answered a second ago
    /// must not read as unchecked because a sheet was reopened over it.
    private func adopt(_ endpoint: ForgeEndpoint?) {
        guard endpoint != board.endpoint else { return }
        board.point(at: endpoint, named: ForgeStore.label(for: endpoint))
        client = nil
        forgetMissingOnMachineLeft()
        probe(force: false)
    }

    /// A receipt filed before machines were recorded is read as being on the one chosen now, so
    /// what was learnt about it on the machine just left says nothing about the one arrived at.
    /// Receipts that name their machine keep what was learnt: they are still asked of that one.
    private func forgetMissingOnMachineLeft() {
        missing.subtract(board.history.filter { $0.endpoint == nil }.map(\.id))
    }

    /// A renderer the setup settled on, taken into the board and asked at once. The store is the
    /// authority — the setup wrote it there — so this reads it back rather than being handed a
    /// second copy of the same decision.
    func pointAtStoredRenderer() {
        isStaged = false
        let moved = ForgeStore.endpoint() != board.endpoint
        board.point(at: ForgeStore.endpoint(), named: ForgeStore.label(for: ForgeStore.endpoint()))
        client = nil
        if moved { forgetMissingOnMachineLeft() }
        probe()
        changed()
    }

    /// What the machine has, asked once for the video board and the picture studios alike: whether
    /// ComfyUI answers, and if it does, whether the lanes have their nodes and model files. A
    /// verdict newer than the cache's lifetime is reused, so opening a surface costs nothing twice.
    func probe(force: Bool = true) {
        guard let endpoint = board.endpoint, !isStaged else { return }
        board.checking()
        reachTask?.cancel()
        reachTask = Task { [weak self] in
            let verdict = await MediaReadiness.shared.verdict(for: endpoint, force: force)
            guard let self, !Task.isCancelled else { return }
            self.board.assessed(verdict)
            self.keepGuess(if: verdict)
            self.changed()
            if let wait = verdict.recheck { self.recheck(after: wait, endpoint: endpoint) }
        }
        changed()
    }

    /// A ComfyUI that is still loading is asked again in a few seconds until it answers or the
    /// board is pointed elsewhere.
    private func recheck(after seconds: TimeInterval, endpoint: ForgeEndpoint) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.board.endpoint == endpoint, !self.board.isBusy, !self.isStaged
            else { return }
            self.probe()
        }
    }

    /// The renderer before anybody has said where it is: the machine the agent runs on, on the
    /// port ComfyUI answers on, asked silently and filed against that server only once it answers.
    func suggest() {
        guard !isStaged else { return }
        let profiles = ServerDirectory.shared.profiles
        guard let choice = MediaEndpointPlan.choose(profiles: profiles) else { return }
        homeProfile = choice.profileID
        guard board.endpoint == nil, !board.isBusy else { return }
        guess = choice
        board.point(at: choice.endpoint)
        client = nil
        probe()
        changed()
    }

    /// A renderer somebody chose, filed against the server it belongs to as well as on this Mac.
    func file(_ renderer: ForgeRenderer) {
        if let homeProfile {
            ForgeStore.remember(renderer, forProfile: homeProfile)
        } else {
            ForgeStore.remember(renderer)
        }
        guess = nil
    }

    private func keepGuess(if verdict: MediaVerdict) {
        guard let guess, guess.endpoint == verdict.endpoint, MediaEndpointPlan.confirms(verdict) else {
            return
        }
        file(guess.renderer)
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

    func hear(_ words: String) {
        board.hear(words)
        ForgeStore.remember(board.recipe)
        changed()
    }

    func reuse(_ entry: ForgeEntry) {
        board.reuse(entry)
        ForgeStore.remember(board.recipe)
        changed()
    }

    /// Opens the next clip on a picture, with its shape read off the file when it is one on this
    /// Mac and none was given, or on nothing. The board then lets the size follow the picture
    /// unless somebody chose one by hand.
    func start(from frame: ForgeFrame?, width: Int? = nil, height: Int? = nil) {
        var width = width
        var height = height
        if width == nil, case .file(let path)? = frame, let size = StudioDrop.pixelSize(ofFileAt: path) {
            width = size.width
            height = size.height
        }
        board.start(from: frame, pictureWidth: width, pictureHeight: height)
        ForgeStore.remember(board.recipe)
        changed()
    }

    /// Continues a clip already made: the next render opens where that one ended, with the same
    /// words to edit into what happens next and a fresh seed.
    func extend(_ entry: ForgeEntry) {
        board.extend(entry)
        ForgeStore.remember(board.recipe)
        changed()
    }

    /// The shape a helper answered with, followed only where nobody chose one.
    func follow(size: ForgeSize) {
        board.follow(size: size)
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
        let expecting = board.clock.estimate(recipe)
        renderTask = Task { [weak self] in
            await self?.follow(
                connection.render(recipe, expecting: expecting), via: connection, ticket: ticket)
        }
        changed()
    }

    /// A render the app lost track of — it was closed, reinstalled or killed while the machine
    /// carried on — picked up again by the id it was filed under. Whatever became of it while
    /// nobody watched is told the way a render started here is: still running, finished and filed,
    /// failed in the machine's own words, or forgotten by a restart of the machine.
    private func recover() {
        guard !isStaged, renderTask == nil, let pending = ForgeStore.pending() else { return }
        renderTicket += 1
        let ticket = renderTicket
        let recovering = ForgeClient(endpoint: pending.endpoint, clientID: pending.clientID)
        renderClient = recovering
        let expecting = board.clock.estimate(pending.recipe)
        renderTask = Task { [weak self] in
            guard let stream = await recovering.recover(pending, expecting: expecting) else {
                self?.settle(ticket)
                return
            }
            await self?.follow(stream, via: recovering, ticket: ticket)
        }
    }

    /// The snapshots of one render, taken only while it is the render the board is showing. One
    /// from a render that was stopped or superseded is dropped rather than drawn — it would put a
    /// machine's account of abandoned work back over the terminal state the stop already wrote —
    /// except that a clip which did land is a clip, and is filed on the shelf without touching what
    /// the board says.
    private func follow(_ stream: AsyncStream<ForgeJob>, via client: ForgeClient, ticket: Int) async {
        for await job in stream {
            guard renderTicket == ticket else {
                if job.asset != nil { fileLate(ForgeEntry(job: job, endpoint: client.endpoint)) }
                return
            }
            saw(job, via: client)
        }
        settle(ticket)
    }

    /// The stream is over and nothing is holding the socket. Only the task that claimed the ticket
    /// may put the handle down: a render that was abandoned must not unlock the button for the one
    /// still arriving.
    private func settle(_ ticket: Int) {
        guard renderTicket == ticket else { return }
        renderTask = nil
    }

    private func saw(_ job: ForgeJob, via client: ForgeClient) {
        board.saw(job)
        if job.isFinished, ForgeStore.record(job, on: client.endpoint) != nil {
            if let clock = board.learn(from: job) { ForgeStore.remember(clock: clock) }
            board.filled(history: ForgeStore.history())
        }
        changed()
    }

    /// A clip that landed after the person stopped waiting for it. It stays on the shelf and nothing
    /// else moves: they asked for it to stop, and a clip taking the stage back would be the machine
    /// answering a question that was withdrawn.
    private func fileLate(_ entry: ForgeEntry?) {
        guard let entry else { return }
        ForgeStore.record(entry)
        board.filled(history: ForgeStore.history())
        changed()
    }

    /// Stops the render on the machine that is doing it, and here. The stop goes to the render's own
    /// renderer rather than to whatever the setting names now, names the job — the machine is shared,
    /// and a job still waiting behind another has nothing running to interrupt — and the job is put
    /// into its stopped state so the surface says so even if the socket never answers again. A job
    /// caught in its last seconds has a clip, and the machine says so when it is asked to stop it:
    /// that clip is filed rather than thrown away.
    func stop() {
        guard board.isBusy else { return }
        let handle = board.job.handle
        let recipe = board.job.recipe
        if let renderer = renderClient, renderTask != nil, let handle {
            Task { [weak self] in
                guard case .finished(let asset)? = await renderer.cancel(handle) else { return }
                self?.fileLate(
                    ForgeEntry(id: handle, recipe: recipe, asset: asset, endpoint: renderer.endpoint))
            }
        }
        renderTask?.cancel()
        renderTask = nil
        renderTicket += 1
        if let handle { ForgeStore.clearPending(handle) }
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

    /// Which machine to ask about a kept clip: the one that wrote it. A renderer numbers its own
    /// files, the board can be re-pointed at another machine any time after, and the machine that
    /// replaced it has either never heard of `forge_00007.mp4` or has a different clip by that name.
    /// A receipt filed before machines were recorded is asked of the one the board names now.
    func client(for entry: ForgeEntry) -> ForgeClient? {
        guard let endpoint = entry.endpoint ?? board.endpoint else { return nil }
        return ForgeClient(endpoint: endpoint)
    }

    /// Where to point a player, confirmed before it is pointed there. A clip whose file has been
    /// cleaned up off the renderer answers 404, and a video player reports that in words about
    /// nothing a person can act on — so the ask happens here and the row gets to say it is gone.
    func locate(_ entry: ForgeEntry) async throws -> URL {
        if isStaged, let demoClip { return demoClip }
        guard let asset = entry.asset, let renderer = client(for: entry) else {
            throw ForgeFailure.unconfigured
        }
        do {
            let url = try await renderer.locate(asset)
            if missing.remove(entry.id) != nil { changed() }
            return url
        } catch ForgeFailure.missingFile(let host) {
            if missing.insert(entry.id).inserted { changed() }
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

    /// Whether the board is a photograph of a state somebody asked to look at, rather than the
    /// machine as it is.
    var isDemo: Bool { isStaged }

    /// The clip that has landed and not yet been shown to anybody, if there is one.
    var unpresented: ForgeAsset? {
        guard let asset = board.job.asset, asset != presented else { return nil }
        return asset
    }

    func present(_ asset: ForgeAsset) {
        let before = light
        presented = asset
        if light != before { announce() }
    }

    /// The failure on the board has been read: its card is on the stage. Only a failure that is on
    /// the board can be, and it is read once.
    func acknowledgeFailure() {
        guard hasFailed, !acknowledgedFailure else { return }
        acknowledgedFailure = true
        announce()
    }

    /// What the way in to video says about the render: the job's face, dark once its ending has been
    /// looked at.
    var light: ForgeLight { ForgeLight.read(job: board.job, seen: outcomeSeen) }

    /// Whether the person has looked at how the job ended — the clip on a stage, the failure on a
    /// card.
    private var outcomeSeen: Bool {
        hasFailed ? acknowledgedFailure : unpresented == nil
    }

    /// The finished outcome of the last render, put away: a stopped, failed or landed job goes back
    /// to a draft with its words still in the boxes, so a clip chosen from the shelf is what the
    /// stage shows rather than the ending of a render that is over.
    func settle() {
        guard !board.isBusy else { return }
        board.revise(board.recipe)
        changed()
    }

    /// Asks the machine once if nobody has: a surface about to be shown owes the reader a pill that
    /// says whether the machine answers, and one that says "not checked yet" is a question.
    func probeIfUnchecked() {
        guard !isStaged, board.endpoint != nil,
            board.sections.first(where: { $0.id == ForgeBoard.rendererID })?.phase == .idle
        else { return }
        probe(force: false)
    }
}

extension ForgeRunner {
    /// Every state the surface has, put on the board without a renderer to make one happen. A render
    /// is minutes of another machine's card, so the states between pressing the button and holding a
    /// file cannot be reached in a build loop — and they are exactly the states worth checking, since
    /// each of them is a different sentence. Every value is `ForgeDemo`'s, which builds them out of
    /// Core's own mutators rather than describing them in words this client made up.
    func demonstrate(_ name: String) {
        stage(ForgeDemo.board(name))
    }

    /// A prepared board put on the runner as the state to look at. `clip` is the file a staged clip
    /// plays from, since there is no machine to ask where one is, `lost` are the receipts whose
    /// files the renderer no longer has, and a landed clip is taken as already shown unless
    /// `arriving` says it has just come in.
    func stage(_ staged: ForgeBoard, clip: URL? = nil, lost: Set<String> = [], arriving: Bool = false) {
        quiet()
        isStaged = true
        board = staged
        presented = arriving ? nil : staged.job.asset
        acknowledgedFailure = false
        demoClip = clip
        missing = lost
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
