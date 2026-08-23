import TailscodeCore
import UIKit

/// The render, kept above whatever happens to be drawing it.
///
/// A clip is minutes of another machine's card and a phone is a thing people put in their pocket
/// halfway through, so the socket, the job and the board it draws as live here rather than inside a
/// view controller: backing out of the surface and coming back finds the same render exactly where
/// it was, and the salvage loop in `ForgeClient` keeps following it while the screen is locked.
///
/// Nothing here decides a word. Every sentence on screen is `ForgeJob`'s or `ForgeBoard`'s; this
/// class only feeds them what arrived and says when something changed.
@MainActor
final class ForgeRunner {
    static let shared = ForgeRunner()

    /// Posted whenever the board restated itself — a frame off the socket, a probe landing, a
    /// setting walked. Surfaces redraw from `board` and nothing else.
    static let didChange = Notification.Name("tailscode.forge.runner.didChange")

    private(set) var board: ForgeBoard
    /// Clips the renderer no longer has. Asked once, when somebody tries to play one, and kept so
    /// the row can say the file is gone rather than failing the same way on every tap.
    private(set) var missingClips: Set<String> = []

    /// One client id for the life of the process. The POST and the websocket must carry the same
    /// one or the server delivers this render's frames to somebody else's socket and the job looks
    /// like it hung.
    private let clientID = UUID().uuidString
    private var renderTask: Task<Void, Never>?
    /// The machine the render on the board was submitted to, held for as long as that render is the
    /// one being shown. The address is a setting somebody can change while a card is busy, and an
    /// interrupt sent to whatever the board points at now stops a stranger's work while this render
    /// carries on unwatched — so the client that submitted is the one that stops it, and the one the
    /// file it made is asked for.
    private var renderClient: ForgeClient?
    /// Which render is the current one. A task that ends after another has begun must not fold a
    /// stale snapshot into the board, clear a handle it no longer owns, or file a receipt for a
    /// render nobody is watching — and a task cannot compare itself against that handle from the
    /// inside, so each one carries the number its start claimed.
    private var renderTicket = 0
    private var probeTask: Task<Void, Never>?
    /// Whether the board was put into a named state by hand rather than by a machine. A staged
    /// board is a photograph of a state, and a real probe landing on top of it would replace the
    /// state being photographed with whatever this device can reach.
    private var isStaged = false
    #if DEBUG
        /// A clip this device wrote for a staged board, standing in for the file a renderer would
        /// have on its own disk. Never set on a board any machine produced.
        private var stagedClip: URL?
    #endif

    private init() {
        board = ForgeBoard(
            recipe: ForgeStore.recipe(), endpoint: ForgeStore.endpoint(),
            rendererName: ForgeStore.label(for: ForgeStore.endpoint()))
        board.filled(history: ForgeStore.history())
        if let endpoint = ForgeStore.endpoint() {
            board.point(at: endpoint, named: ForgeStore.label(for: endpoint))
        }
    }

    var endpoint: ForgeEndpoint? { board.endpoint }

    var isRendering: Bool { board.isBusy }

    /// The renderer as something to talk to, rebuilt per call because the address is a setting
    /// somebody can change between two renders. The client id is not — see above.
    private var client: ForgeClient? {
        guard let endpoint = board.endpoint else { return nil }
        return ForgeClient(endpoint: endpoint, clientID: clientID)
    }

    // MARK: - The machine

    func point(at endpoint: ForgeEndpoint?) {
        ForgeStore.remember(endpoint)
        board.point(at: endpoint, named: ForgeStore.label(for: endpoint))
        announce()
        probe()
    }

    /// Points renders at a machine the setup settled on, and files it among the ones this device
    /// has used so the second time is a tap rather than an address somebody has to look up again.
    func use(_ renderer: ForgeRenderer) {
        ForgeStore.remember(renderer)
        board.point(at: renderer.endpoint, named: renderer.name ?? renderer.endpoint.shortName)
        announce()
        probe()
    }

    /// Drops a machine from the list this device offers back. Core drops the endpoint with it when
    /// it was the one in use, so the board is re-pointed at whatever the store still holds rather
    /// than at an address nobody wants offered.
    func forgetRenderer(_ id: String) {
        ForgeStore.forgetRenderer(id)
        board.point(at: ForgeStore.endpoint(), named: ForgeStore.label(for: ForgeStore.endpoint()))
        announce()
        probe()
    }

    /// Asks the port whether anything is there. Deliberately a TCP connect rather than a request:
    /// the box is socket-activated, so "listening" is the only thing that can be known cheaply and
    /// "ready" is a different question that the first render pays for either way.
    func probe() {
        guard let endpoint = board.endpoint, !isStaged else { return }
        probeTask?.cancel()
        board.checking()
        announce()
        probeTask = Task { [weak self] in
            let verdict = await endpoint.reach()
            guard let self, !Task.isCancelled else { return }
            self.board.reached(verdict)
            self.announce()
        }
    }

    // MARK: - The render

    /// Starts the render the board is currently describing and folds every snapshot the stream
    /// yields back into it. The stream always ends on a terminal phase, so nothing here has to
    /// invent a timeout.
    func render(_ recipe: ForgeRecipe) {
        guard renderTask == nil, let client else { return }
        ForgeStore.remember(recipe)
        AppLogger.ui.info("forge render \(recipe.size.label) \(recipe.seconds)s seed=\(recipe.seed)")
        renderClient = client
        renderTicket += 1
        let ticket = renderTicket
        renderTask = Task { [weak self] in
            for await job in client.render(recipe) {
                guard let self, self.renderTicket == ticket else { return }
                self.board.saw(job)
                self.announce()
            }
            self?.settle(ticket)
        }
    }

    /// Stops what is running, on the machine that is running it and on this device. The interrupt
    /// goes to the render's own renderer rather than to whatever the setting names now, is fired
    /// rather than awaited — it either landed or the render was already over — and the job is put
    /// into its stopped state here so the surface says so even if the socket never answers again.
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
        Theme.Haptics.warning()
        announce()
    }

    /// Files the receipt and says how it went. A cancelled job files nothing — `ForgeEntry` refuses
    /// to make history out of a render nobody finished.
    private func settle(_ ticket: Int) {
        guard renderTicket == ticket else { return }
        renderTask = nil
        if ForgeStore.record(board.job) != nil {
            board.filled(history: ForgeStore.history())
        }
        switch board.job.phase {
        case .done: Theme.Haptics.received()
        case .failed: Theme.Haptics.error()
        case .drafting, .submitting, .queued, .running, .cancelled: break
        }
        announce()
    }

    // MARK: - The files

    /// Where to point a player, confirmed before it is pointed there. A clip whose file has been
    /// cleaned up off the renderer answers 404, and a video player reports that in words about
    /// nothing a person can act on — so the ask happens here and the row gets to say it is gone.
    func locate(_ asset: ForgeAsset, entryID: String? = nil) async throws -> URL {
        #if DEBUG
            if let stagedClip { return stagedClip }
        #endif
        guard let renderer = host(for: asset) else { throw ForgeFailure.unconfigured }
        do {
            let url = try await renderer.locate(asset)
            if let entryID, missingClips.remove(entryID) != nil { announce() }
            return url
        } catch ForgeFailure.missingFile(let host) {
            if let entryID, missingClips.insert(entryID).inserted { announce() }
            throw ForgeFailure.missingFile(host)
        }
    }

    /// The bytes the renderer wrote, for the places a URL is not enough — the photo library, a
    /// share sheet. Never a re-encode of what a preview happened to decode.
    func fetch(_ asset: ForgeAsset) async throws -> Data {
        guard let renderer = host(for: asset) else { throw ForgeFailure.unconfigured }
        return try await renderer.fetch(asset)
    }

    /// Which machine to ask for a file. A clip belongs to the machine that wrote it, so the one the
    /// render on the board just delivered is asked of that render's own renderer even when the
    /// setting has since been pointed somewhere else; everything else is asked of the machine in
    /// force, which is where this device's history was made.
    private func host(for asset: ForgeAsset) -> ForgeClient? {
        guard board.job.asset == asset, let renderClient else { return client }
        return renderClient
    }

    func isMissing(_ entry: ForgeEntry) -> Bool { missingClips.contains(entry.id) }

    // MARK: - The board

    func activate(_ row: ForgeRow) -> ForgeAction? {
        let action = board.activate(row)
        if action == nil { ForgeStore.remember(board.recipe) }
        announce()
        return action
    }

    func begin() -> ForgeAction? {
        let action = board.begin()
        announce()
        return action
    }

    func pick(_ field: ForgeField, id: String) {
        board.pick(field, id: id)
        ForgeStore.remember(board.recipe)
        announce()
    }

    func describe(_ words: String) {
        board.describe(words)
        announce()
    }

    func avoid(_ words: String) {
        board.avoid(words)
        announce()
    }

    func reuse(_ entry: ForgeEntry) {
        board.reuse(entry)
        ForgeStore.remember(board.recipe)
        announce()
    }

    func forget(_ entry: ForgeEntry) {
        ForgeStore.remove(entry.id)
        missingClips.remove(entry.id)
        board.filled(history: ForgeStore.history())
        announce()
    }

    /// What the last render was set to, kept for the next one. Written on the way out rather than
    /// on every keystroke: the prompt is dropped when it is read back anyway.
    func rememberRecipe() {
        ForgeStore.remember(board.recipe)
    }

    private func announce() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

#if DEBUG
    extension ForgeRunner {
        /// Puts the board into one named state without a renderer on the other end, so every face
        /// this surface has can be photographed on a simulator. `TAILSCODE_VIDEO_STATE` names one.
        func stage(_ state: String) {
            isStaged = true
            let recipe = ForgeRecipe(
                prompt: "a cat asleep on a warm tiled roof, late afternoon light",
                negative: "blurry, jitter", width: 1280, height: 704, seconds: 5, fps: 24,
                seed: 481_723)
            let asset = ForgeAsset(filename: "forge_00007.mp4", subfolder: "video", type: "output")
            board = ForgeBoard(recipe: recipe, endpoint: ForgeEndpoint(host: "arch"))
            board.filled(history: state == "empty" ? [] : Self.stagedHistory(recipe))
            switch state {
            case "unconfigured":
                board = ForgeBoard(recipe: ForgeRecipe(), endpoint: nil)
                board.filled(history: [])
            case "checking":
                board.point(at: ForgeEndpoint(host: "arch"))
            case "down":
                board.reached(.timedOut)
            case "waking":
                board.reached(.listening)
                board.saw(Self.stagedJob(recipe) { $0.submitting() })
            case "queued":
                board.reached(.listening)
                board.saw(
                    Self.stagedJob(recipe) {
                        $0.submitting()
                        $0.accepted(promptID: "p", queued: 2)
                    })
            case "running":
                board.reached(.listening)
                board.saw(
                    Self.stagedJob(recipe) {
                        $0.submitting(at: Date().addingTimeInterval(-74))
                        $0.accepted(promptID: "p")
                        $0.saw(.progressed("p", census: ForgeCensus(finished: 17, total: 28, running: "pass2")))
                        $0.saw(.sampling("p", node: "pass2", step: 3, steps: 4))
                    })
            case "saving":
                board.reached(.listening)
                board.saw(
                    Self.stagedJob(recipe) {
                        $0.submitting(at: Date().addingTimeInterval(-96))
                        $0.accepted(promptID: "p")
                        $0.saw(.finished("p"))
                    })
            case "done":
                board.reached(.listening)
                deliver(recipe, asset)
            case "failed":
                board.reached(.listening)
                board.saw(
                    Self.stagedJob(recipe) {
                        $0.submitting(at: Date().addingTimeInterval(-11))
                        $0.accepted(promptID: "p")
                        $0.saw(.failed("p", reason: "UNETLoader failed: CUDA out of memory"))
                    })
            case "stopped":
                board.reached(.listening)
                board.saw(
                    Self.stagedJob(recipe) {
                        $0.submitting(at: Date().addingTimeInterval(-31))
                        $0.accepted(promptID: "p")
                        $0.saw(.interrupted("p"))
                    })
            default:
                board.reached(.listening)
            }
            announce()
        }

        /// Files machines as though this device had used them, so the setup screen's list — which
        /// is the whole of what remembering a renderer buys — and every face a check can land on
        /// can be photographed without setting a real machine up first. The value is a
        /// comma-separated list of addresses; `known` is the two-machine tailnet the shots use.
        func seedRenderers(_ spec: String) {
            let addresses =
                spec == "known"
                ? ["studio", "arch"] : spec.split(separator: ",").map(String.init)
            for address in addresses {
                guard case .endpoint(let endpoint) = ForgeEndpoint.read(address) else { continue }
                ForgeStore.remember(ForgeRenderer(endpoint: endpoint, name: endpoint.host))
            }
        }

        /// The finished state is the only one with a file to look at, and a staged board has no
        /// renderer to fetch one from — so this device writes the clip itself, and the job is only
        /// handed the asset once the file it names actually exists.
        private func deliver(_ recipe: ForgeRecipe, _ asset: ForgeAsset) {
            Task { [weak self] in
                let url = await ForgeSampleClip.make()
                guard let self else { return }
                self.stagedClip = url
                self.board.saw(
                    Self.stagedJob(recipe) {
                        $0.submitting(at: Date().addingTimeInterval(-23))
                        $0.accepted(promptID: "p")
                        $0.delivered(asset)
                    })
                self.announce()
            }
        }

        private static func stagedJob(
            _ recipe: ForgeRecipe, _ walk: (inout ForgeJob) -> Void
        ) -> ForgeJob {
            var job = ForgeJob(recipe: recipe)
            walk(&job)
            return job
        }

        private static func stagedHistory(_ recipe: ForgeRecipe) -> [ForgeEntry] {
            let words = [
                "a cat asleep on a warm tiled roof, late afternoon light",
                "rain on a neon street, shallow depth of field",
                "a paper boat going over a weir in slow motion",
                "a lighthouse beam sweeping fog",
                "a hand turning the page of an old atlas",
                "steam rising off a cup on a cold morning",
            ]
            return words.enumerated().map { index, prompt in
                ForgeEntry(
                    id: "staged-\(index)", recipe: recipe.with(prompt: prompt).with(seed: 1000 + index),
                    asset: index == 2
                        ? nil : ForgeAsset(filename: "clip\(index).mp4", subfolder: "video"),
                    failure: index == 2 ? "The renderer ran out of memory" : nil,
                    finishedAt: Date().addingTimeInterval(-Double(index) * 3600))
            }
        }
    }
#endif
