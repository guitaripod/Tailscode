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
    /// The sampler's own sketch of the picture so far, decoded to a texture the stage can wear.
    /// Zero while the machine has sent none — a server started without previews sends none.
    private(set) var previewTexture: UInt = 0
    /// Posted for every sketch that lands, apart from ``didChange``: a frame changes one
    /// paintable, and a surface that rebuilt itself for each would spend the render on widgets.
    static let previewDidChange = Notification.Name("tailscode.imageStudio.previewDidChange")
    private var runner: ImageGenRunner?
    private var checked = false
    /// When the render in flight started, so the surface can say how long it has been rather than
    /// showing a bar it would have to invent — ComfyUI's queue tells this client done or failed
    /// and nothing in between, and a fake percentage is worse than an honest clock.
    private(set) var startedAt: Date?
    private var libraryObserver: NSObjectProtocol?

    /// A machine named for a headless run — `TAILSCODE_IMAGE_ENDPOINT` — so the harness can point
    /// the studio at a stand-in ComfyUI for screenshots and selftests without touching what the
    /// person has filed. Debug builds only; the installed app answers to the door alone.
    static var pinnedEndpoint: ImageGenEndpoint? {
        #if DEBUG
            guard let raw = ProcessInfo.processInfo.environment["TAILSCODE_IMAGE_ENDPOINT"],
                !raw.isEmpty
            else { return nil }
            return ImageGenEndpoint(address: raw)
        #else
            return nil
        #endif
    }

    init(endpoint: ImageGenEndpoint?) {
        let resolved =
            endpoint ?? Self.pinnedEndpoint ?? ImageGenDoor.current().endpoint
            ?? ImageGenEndpoint(host: "127.0.0.1")
        slot = ImageGenSlot(endpoint: resolved)
        slot.setEngine(ImageGenStore.engine())
        slot.setAspect(ImageGenStore.aspect())
        library = DrawLibrary(endpoint: resolved)
        observeLibrary()
    }

    /// A listing that lands, a thumbnail that decodes or a file's facts that come back are all
    /// the library's own news — forwarded as this studio's, so every surface already watching
    /// ``ImageStudio/didChange`` redraws the shelf without watching a second notification. Only
    /// this studio's own library: a slot in the grid and the modal each hold one for the same
    /// machine, and a studio that listened to both redrew twice for every thumbnail. The match is
    /// made by hand rather than through the observer's `object:` filter, which on this Foundation
    /// never matches a sender that is not an NSObject and so silently delivered nothing.
    private func observeLibrary() {
        if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) }
        libraryObserver = NotificationCenter.default.addObserver(
            forName: DrawLibrary.didChange, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, let sender = note.object as AnyObject?, sender === self.library else {
                return
            }
            self.announce()
        }
    }

    var isPainting: Bool { slot.isBusy }

    var endpoint: ImageGenEndpoint { slot.endpoint }

    /// Points the studio at the machine the door resolves to, unless a render is in flight — a
    /// picture is fetched from the machine that queued it, so moving mid-render loses it.
    func adoptDoor() {
        guard Self.pinnedEndpoint == nil else { return }
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
        if field == .aspect { aspectChosen = true }
        rememberChoices()
        announce()
    }

    /// Sets one decision outright rather than walking to it, which is what a menu row means.
    func choose(engine: ImageGenEngine) {
        slot.setEngine(engine)
        rememberChoices()
        announce()
    }

    func choose(aspect: ImageGenAspect) {
        slot.setAspect(aspect)
        aspectChosen = true
        rememberChoices()
        announce()
    }

    /// The shape the helper answered with: followed, but never counted as a choice by hand.
    func follow(aspect: ImageGenAspect) {
        guard aspect != slot.aspect else { return }
        slot.setAspect(aspect)
        rememberChoices()
        announce()
    }

    func choose(size: ImageGenSize) {
        slot.setSize(size)
        rememberChoices()
        announce()
    }

    func choose(detail: ImageGenDetail) {
        slot.setDetail(detail)
        rememberChoices()
        announce()
    }

    /// The small model that thickens a thin brief, when this device knows one.
    var helper: ImageGenHelper? { ImageGenStore.helper() }

    /// The rewrite in flight or landed and not yet taken, drawn as a card under the words.
    private(set) var draft: ImageGenRewriteDraft?
    private let rewriter = ImageGenRewriter()

    /// Whether a rewrite is out right now. The card says so and the composer stays the person's
    /// to edit while it runs.
    var enhancing: Bool { draft?.isWriting == true }

    /// Whether the shape was picked by hand in this studio's life. A chosen shape is kept by the
    /// helper; an inherited one is the helper's to improve on.
    private(set) var aspectChosen = false

    /// Asks the helper for the paragraph, streaming it into ``draft`` as it is written. With no
    /// helper filed the machines near the painter are surveyed first and the best writer is
    /// filed. `instruction` turns the ask into a revision of the paragraph already written.
    func rewrite(_ brief: String, instruction: String? = nil) {
        let previous = instruction == nil ? nil : draft?.written
        let context = slot.rewriteContext(
            aspectChosen: aspectChosen, instruction: instruction, previous: previous)
        rewriter.start(
            brief: brief, context: context, filed: helper, near: slot.endpoint,
            onHelper: { found in
                Gtk.onMain { ImageGenStore.remember(helper: found) }
            },
            onChange: { [weak self] draft in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    guard let draft else {
                        self.draft = nil
                        self.onNotice?(ImageGenRewriteWords.noneFoundTitle)
                        self.announce()
                        return
                    }
                    let grewOnly = self.draft?.isWriting == true && draft.isWriting
                    self.draft = draft
                    if grewOnly {
                        self.announceRewrite()
                    } else {
                        self.announce()
                    }
                }
            })
        draft = nil
        announce()
    }

    /// Posted when the paragraph grew and nothing else changed. A token a few times a second is
    /// a change to one text view, and a surface that rebuilt itself for each starved the frame
    /// clock and painted nothing until the paragraph was done. Coalesced to a few a second.
    static let rewriteDidChange = Notification.Name("tailscode.imageStudio.rewriteDidChange")
    private var rewriteAnnouncePending = false

    private func announceRewrite() {
        guard !rewriteAnnouncePending else { return }
        rewriteAnnouncePending = true
        Gtk.after(70) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.rewriteAnnouncePending = false
                NotificationCenter.default.post(name: ImageStudio.rewriteDidChange, object: nil)
            }
        }
    }

    /// Stops a rewrite that is still writing and drops what it had.
    func stopRewrite() {
        rewriter.cancel()
        draft = nil
        announce()
    }

    /// Closes the card, keeping nothing. The words in the box were never touched.
    func dismissRewrite() {
        rewriter.cancel()
        draft = nil
        announce()
    }

    /// One line for whoever is showing this studio — a helper found on its own, a helper gone.
    var onNotice: (@Sendable (String) -> Void)?

    /// Every machine that answered the last survey and what each serves, for the picker.
    private(set) var helperServers: [ImageGenHelperServer] = []
    private(set) var surveying = false
    private(set) var surveyedAt: Date?

    /// Asks every door near the painter and on this device what it serves, and files the best
    /// writer when none is filed yet.
    func surveyHelpers() {
        guard !surveying else { return }
        surveying = true
        announce()
        let endpoint = slot.endpoint
        Task.detached { [weak self] in
            let servers = await ImageGenHelperFinder.survey(near: endpoint)
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
                self.announce()
            }
        }
    }

    /// Files the helper a person picked from the list, which is kept over anything found later.
    func setHelper(_ helper: ImageGenHelper?) {
        var chosen = helper
        chosen?.chosenByHand = true
        ImageGenStore.remember(helper: chosen)
        announce()
    }

    /// Switches the filed helper off or on without forgetting it.
    func toggleHelper() {
        guard var current = helper else { return }
        current.enabled.toggle()
        ImageGenStore.remember(helper: current)
        announce()
    }

    func setNegative(_ words: String) {
        slot.setNegative(words)
        announce()
    }

    func setCutout(_ on: Bool) {
        slot.setCutout(on)
        announce()
    }

    /// Holds the seed the last render rolled, or lets it roll again. Holding is how a person
    /// changes one word and sees only that word change.
    func toggleSeedHold() {
        if slot.seed.isHeld {
            slot.releaseSeed()
        } else {
            slot.holdSeed()
        }
        announce()
    }

    private func rememberChoices() {
        ImageGenStore.remember(engine: slot.engine, aspect: slot.aspect)
        ImageGenStore.remember(size: slot.size, detail: slot.detail)
    }

    /// Attaches or lets go of the picture the next render works from. Nothing else decides the
    /// mode, so this one call is the whole gesture.
    func hold(_ reference: ImageGenReference?) {
        slot.hold(reference)
        announce()
    }

    /// Adds one more picture for the next render to work from, up to what the encoder holds.
    func attach(_ reference: ImageGenReference) {
        slot.attach(reference)
        announce()
    }

    func release(_ path: String) {
        slot.release(path)
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
        dropPreview()
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
        let recipe = slot.recipe(prompt: text, seed: slot.seed.next())
        let references = slot.references
        let fresh = ImageGenRunner(endpoint: slot.endpoint, recipe: recipe)
        runner = fresh
        announce()
        dropPreview()
        fresh.run(
            references: references,
            progress: { [weak self] progress in
                Gtk.onMain { [weak self] in
                    guard let self, fresh === self.runner else { return }
                    let stageChanged = self.progress?.stage != progress.stage
                    self.progress = progress
                    if stageChanged {
                        self.announce()
                    } else {
                        self.announceProgress()
                    }
                }
            },
            preview: { [weak self] frame in
                Gtk.onMain { [weak self] in
                    guard let self, fresh === self.runner else { return }
                    self.adoptPreview(frame)
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
                aspect: runner.aspect, size: runner.recipe?.size ?? .standard, seconds: seconds,
                seed: runner.seed, steps: runner.recipe?.steps, remoteName: remoteName)
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
            dropPreview()
        }
        announce()
    }

    /// Decodes one sketch and wears it in place of the last. The frames are small — the machine
    /// bounds them to a few hundred pixels — so a decode per step is cheaper than a layout.
    private func adoptPreview(_ frame: ImageGenPreviewFrame) {
        let bits: UInt = frame.bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress,
                let texture = tailscode_texture_from_bytes(base, gsize(frame.bytes.count))
            else { return 0 }
            return UInt(bitPattern: UnsafeMutableRawPointer(texture))
        }
        guard bits != 0 else { return }
        dropPreview()
        previewTexture = bits
        NotificationCenter.default.post(name: ImageStudio.previewDidChange, object: nil)
    }

    private func dropPreview() {
        guard previewTexture != 0 else { return }
        if let raw = UnsafeMutableRawPointer(bitPattern: previewTexture) { g_object_unref(raw) }
        previewTexture = 0
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

    /// Every surface watching this studio rebuilds on a change, so changes are announced once
    /// per short beat rather than once each: a render's socket speaks several times a second, and
    /// a rebuild per frame sat above the frame clock and painted nothing until the picture landed.
    private var announcePending = false
    private static let announceBeat: UInt32 = 80

    private func announce() {
        Gtk.onMain { [weak self] in
            guard let self, !self.announcePending else { return }
            self.announcePending = true
            Gtk.after(Self.announceBeat) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.announcePending = false
                    NotificationCenter.default.post(name: ImageStudio.didChange, object: nil)
                }
            }
        }
    }

    /// The sampler's step or the node census moved and nothing else did: a line, a bar and a
    /// clock change, and the stage stays exactly where it is. Coalesced the same way.
    static let progressDidChange = Notification.Name("tailscode.imageStudio.progressDidChange")
    private var progressAnnouncePending = false

    private func announceProgress() {
        guard !progressAnnouncePending else { return }
        progressAnnouncePending = true
        Gtk.after(Self.announceBeat) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.progressAnnouncePending = false
                NotificationCenter.default.post(name: ImageStudio.progressDidChange, object: nil)
            }
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
        rewriter.cancel()
        dropPreview()
        for bits in textures.values {
            if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
        }
        textures = [:]
        library.release()
        if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) }
        libraryObserver = nil
    }
}
