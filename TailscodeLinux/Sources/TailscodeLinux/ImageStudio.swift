import CGtkShim
import Foundation
import TailscodeCore

/// A picture the machine kept, put on the stage rather than made this session: the recipe read
/// from its own file stands in for a render's prompt, engine and seed, and `path` is nil until the
/// original has actually been downloaded once — a save, a reference or a reroll before then has
/// nothing yet to work from.
struct KeptStage: Sendable, Equatable {
    let item: ImageGenLibraryItem
    var path: String?
    var facts: ImageGenLibraryFacts?
}

/// The picture being made, held above whatever is drawing it.
///
/// Closing the surface may never stop a render: it runs on another machine and costs minutes of
/// that machine's card, so the job, the slot and the textures live here and the window is only a
/// view onto them. Reopening finds the same picture exactly where it was, and a pane in the grid
/// gets a studio of its own so the two never share a prompt.
final class ImageStudio: @unchecked Sendable {
    static let didChange = Notification.Name("tailscode.imageStudio.didChange")

    /// The one the modal shows, which is the one that keeps painting while nobody is looking.
    static let shared = ImageStudio(endpoint: nil)

    private(set) var slot: ImageGenSlot
    private(set) var textures: [String: UInt] = [:]
    /// Every picture the machine keeps, not only the ones made this session — rebuilt whenever
    /// the studio points somewhere else.
    private(set) var library: DrawLibrary
    /// A picture from the library on the stage instead of one this session made. Cleared the
    /// moment a session picture is chosen or a new render begins, so the two never both claim it.
    private(set) var keptStage: KeptStage?
    /// What the machine's own socket last said about the render in flight.
    private(set) var progress: ImageGenProgress?
    private var runner: ImageGenRunner?
    private var checked = false
    /// When the render in flight started, so the surface can say how long it has been rather than
    /// showing a bar it would have to invent — ComfyUI's queue tells this client done or failed
    /// and nothing in between, and a fake percentage is worse than an honest clock.
    private(set) var startedAt: Date?
    private var libraryObserver: NSObjectProtocol?

    init(endpoint: ImageGenEndpoint?) {
        let resolved =
            endpoint ?? ImageGenDoor.current().endpoint ?? ImageGenEndpoint(host: "127.0.0.1")
        slot = ImageGenSlot(endpoint: resolved)
        slot.setEngine(ImageGenStore.engine())
        slot.setAspect(ImageGenStore.aspect())
        library = DrawLibrary(endpoint: resolved)
        observeLibrary()
    }

    /// A listing that lands, a thumbnail that decodes or a file's facts that come back are all
    /// the library's own news — forwarded as this studio's, so every surface already watching
    /// ``ImageStudio/didChange`` redraws the shelf without watching a second notification.
    private func observeLibrary() {
        if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) }
        libraryObserver = NotificationCenter.default.addObserver(
            forName: DrawLibrary.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.announce()
        }
    }

    var isPainting: Bool { slot.isBusy }

    var endpoint: ImageGenEndpoint { slot.endpoint }

    /// Points the studio at the machine the door resolves to, unless a render is in flight — a
    /// picture is fetched from the machine that queued it, so moving mid-render loses it.
    func adoptDoor() {
        guard !isPainting, let endpoint = ImageGenDoor.current().endpoint else { return }
        guard endpoint != slot.endpoint else { return }
        point(at: endpoint)
    }

    func point(at endpoint: ImageGenEndpoint) {
        guard endpoint != slot.endpoint else { return }
        var fresh = ImageGenSlot(endpoint: endpoint)
        fresh.setEngine(slot.engine)
        fresh.setAspect(slot.aspect)
        fresh.hold(slot.reference)
        slot = fresh
        library.release()
        library = DrawLibrary(endpoint: endpoint)
        observeLibrary()
        keptStage = nil
        checked = false
        checkMachine()
        library.refresh()
        announce()
    }

    func advance(_ field: ImageGenField) {
        slot.advance(field)
        ImageGenStore.remember(engine: slot.engine, aspect: slot.aspect)
        announce()
    }

    /// Attaches or lets go of the picture the next render works from. Nothing else decides the
    /// mode, so this one call is the whole gesture.
    func hold(_ reference: ImageGenReference?) {
        slot.hold(reference)
        announce()
    }

    /// Puts one of this session's own pictures on the stage. A picture from the library takes the
    /// stage a different way (``showKept``), and the two never both hold it.
    func show(_ path: String?) {
        keptStage = nil
        slot.show(path)
        announce()
    }

    /// Lets go of a picture and the texture it was drawn from. The file on disk stays: this
    /// surface is a place to work, not a thing that deletes what somebody's machine wrote.
    func discard(_ path: String) {
        slot.discard(path)
        if let bits = textures.removeValue(forKey: path),
            let raw = UnsafeMutableRawPointer(bitPattern: bits)
        {
            g_object_unref(raw)
        }
        announce()
    }

    /// Stops the render and takes it off the machine: ``ImageGenRunner/cancel()`` deletes it from
    /// the queue if it has not started, or interrupts it if it has — the queue on the other
    /// machine no longer runs its course, because a client that could ask it to stop and did not
    /// would be spending somebody's card on nothing.
    func stop() {
        guard let runner, case .painting(let prompt, _, _) = slot.phase else { return }
        runner.cancel()
        self.runner = nil
        slot.fail(prompt: prompt, reason: ImageGenWords.stoppedNotice)
        startedAt = nil
        progress = nil
        announce()
    }

    /// The same words again, with a fresh seed — the one thing a person wants after a render
    /// that was nearly right.
    func again() {
        guard let picture = slot.onStage, !isPainting else { return }
        submit(prompt: picture.prompt)
    }

    /// The same shape for a picture the machine kept: its recipe's own words, and its engine when
    /// the graph named one — rolling a kept picture again paints with whatever made it rather
    /// than with whichever chip happens to be selected right now.
    func again(prompt: String, engine: ImageGenEngine?) {
        guard !isPainting else { return }
        if let engine, engine != slot.engine {
            slot.setEngine(engine)
            ImageGenStore.remember(engine: engine, aspect: slot.aspect)
        }
        submit(prompt: prompt)
    }

    /// The bytes as they were written, for a save or a clipboard — never a re-encode of the
    /// scaled texture a tile is drawn from.
    func bytes(of picture: ImageGenPicture) -> Data? {
        bytes(atPath: picture.path)
    }

    func bytes(atPath path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Puts one of the machine's own kept pictures on the stage. A picture this device just made
    /// and the machine's own copy of it are the same picture, so a tile matching a session render
    /// simply selects that render again instead of downloading a second copy of it.
    func showKept(_ item: ImageGenLibraryItem) {
        if let match = slot.pictures.first(where: { $0.remoteName == item.id }) {
            keptStage = nil
            slot.show(match.path)
            announce()
            return
        }
        keptStage = KeptStage(item: item, path: nil, facts: library.facts[item.id])
        library.describe(item)
        announce()
        let library = self.library
        Task.detached { [weak self] in
            guard let data = await library.fetchOriginal(item) else { return }
            Gtk.onMain { [weak self] in
                guard let self, self.keptStage?.item.id == item.id else { return }
                self.decode(item.id, data: data)
                self.keptStage?.path = library.originalURL(item).path
                self.keptStage?.facts = self.library.facts[item.id]
                self.announce()
            }
        }
    }

    /// Asks the machine whether it is there and whether it holds the model files, and files the
    /// answer where every surface can read it. Nothing waits on it: a socket-activated ComfyUI
    /// takes the better part of a minute to wake, and a surface that stared at a spinner for it
    /// would be a surface that lied about what it knows.
    func checkMachine() {
        guard !checked else { return }
        checked = true
        let endpoint = slot.endpoint
        Task.detached {
            let health = await ImageGenClient(endpoint: endpoint).health()
            ImageGenStore.record(ImageGenSighting(endpoint: endpoint, health: health))
        }
    }

    func submit(prompt raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        keptStage = nil
        slot.begin(prompt: text)
        startedAt = Date()
        progress = nil
        let engine = slot.engine
        let mode = slot.mode
        let aspect = slot.aspect
        let reference = slot.reference?.path
        let fresh = ImageGenRunner(
            endpoint: slot.endpoint, prompt: text, engine: engine, mode: mode, aspect: aspect)
        runner = fresh
        announce()
        fresh.run(
            prompt: text, engine: engine, mode: mode, aspect: aspect, referencePath: reference,
            progress: { [weak self] progress in
                Gtk.onMain { [weak self] in
                    guard let self, fresh === self.runner else { return }
                    self.progress = progress
                    self.announce()
                }
            }
        ) { [weak self] outcome in
            Gtk.onMain { [weak self] in self?.finished(outcome, from: fresh) }
        }
    }

    /// The outcome belongs to the runner that produced it, not to whatever is running now — a
    /// second submit while one paints must not steal the first's picture or its words.
    private func finished(_ outcome: ImageGenRunner.Outcome, from runner: ImageGenRunner) {
        switch outcome {
        case .picture(let data, let seconds, let remoteName):
            let path = ImageGenFiles.write(data, engine: runner.engine)
            let picture = ImageGenPicture(
                path: path, prompt: runner.prompt, engine: runner.engine, mode: runner.mode,
                aspect: runner.aspect, seconds: seconds, seed: runner.seed,
                remoteName: remoteName)
            slot.finish(picture)
            decode(picture.path, data: data)
            library.refresh()
        case .failure(let reason):
            slot.fail(prompt: runner.prompt, reason: reason)
        }
        if runner === self.runner {
            self.runner = nil
            startedAt = nil
            progress = nil
        }
        announce()
    }

    private func decode(_ path: String, data: Data) {
        let bits: UInt = data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            var width: Int32 = 0
            var height: Int32 = 0
            guard
                let texture = tailscode_texture_scaled(
                    base, gsize(data.count), 1024, &width, &height)
            else { return 0 }
            return UInt(bitPattern: UnsafeMutableRawPointer(texture))
        }
        guard bits != 0 else { return }
        if let stale = textures[path], let raw = UnsafeMutableRawPointer(bitPattern: stale) {
            g_object_unref(raw)
        }
        textures[path] = bits
    }

    private func announce() {
        Gtk.onMain {
            NotificationCenter.default.post(name: ImageStudio.didChange, object: nil)
        }
    }

    /// One line for the headless driver: the phase, the chips, and what the stage is holding.
    var summary: String {
        let phase: String
        let prompt: String
        switch slot.phase {
        case .asking:
            phase = "asking"
            prompt = "-"
        case .composing(let text):
            phase = "composing"
            prompt = text
        case .painting(let text, _, _):
            phase = "painting"
            prompt = text
        case .failed(let text, _):
            phase = "failed"
            prompt = text
        }
        let libraryPart = library.failure != nil ? "error" : "\(library.items.count)"
        return
            "image \(phase) engine=\(slot.engine.rawValue) aspect=\(slot.aspect.rawValue) mode=\(slot.mode.rawValue) prompt=\(prompt.isEmpty ? "-" : prompt) tiles=\(slot.pictures.count) reason=\(slot.failure ?? "-") library=\(libraryPart)"
    }

    /// A pane closing releases the textures it decoded, and the shelf's own. The shared studio
    /// never does — its whole job is to still be holding the picture when somebody opens the
    /// surface again.
    func release() {
        runner?.cancel()
        runner = nil
        for bits in textures.values {
            if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
        }
        textures = [:]
        library.release()
        if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) }
        libraryObserver = nil
    }
}
