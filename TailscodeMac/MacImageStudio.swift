import AppKit
import ImageIO
import TailscodeCore

/// What the stage is showing: a picture made this session, whose bytes and facts this Mac already
/// holds, or one the machine keeps, whose bytes are fetched and whose facts are read from the file.
/// The two wear the same caption, the same facts line and the same verbs.
enum StudioExhibit: Equatable {
    case made(ImageGenPicture)
    case kept(ImageGenLibraryItem)

    /// The name the machine's own folder knows this picture by where there is one, so a picture made
    /// here and its tile on the shelf are one identity from the moment the render lands.
    var id: String {
        switch self {
        case .made(let picture): return picture.remoteName ?? picture.path
        case .kept(let item): return item.id
        }
    }

    var libraryID: String? {
        switch self {
        case .made(let picture): return picture.remoteName
        case .kept(let item): return item.id
        }
    }

    var isKept: Bool {
        if case .kept = self { return true }
        return false
    }
}

/// The picture being made, held above whatever is drawing it.
///
/// A render is seconds to minutes of another machine's card, so the job, the slot, the decoded
/// pictures and the machine's folder live here and the panel is only a view onto them. Closing the
/// Studio closes a window rather than throwing away somebody's card, and opening it again finds the
/// same picture exactly where it was — which is also why a pane in the grid gets a studio of its
/// own: two surfaces never share a prompt, and neither can stop the other's render.
///
/// This is the Mac's `ForgeRunner`, about the other thing that machine does.
@MainActor
final class MacImageStudio {
    /// What changed, so a surface redraws only what that is: a sketch is one layer's contents and a
    /// step is one line and one bar, and a surface that rebuilt itself for each would spend the
    /// whole render on layout.
    enum Change: Equatable {
        case state
        case progress
        case sketch
        case rewrite
        case shelf(String?)
    }

    static let shared = MacImageStudio(endpoint: nil)

    private(set) var slot: ImageGenSlot
    private(set) var library: MacImageLibrary
    private(set) var startedAt: Date?
    private(set) var progress: ImageGenProgress?
    /// The sampler's own sketch of the picture so far. Nil until a frame lands — a server started
    /// without previews sends none, and the stage then says so in words rather than inventing one.
    private(set) var sketch: CGImage?
    /// A kept picture put on the stage by hand. Nil means the stage shows what the session made.
    private(set) var keptOnStage: ImageGenLibraryItem?
    /// The stage was cleared by hand and stays blank until a render lands or a picture is put on it.
    private(set) var stageCleared = false
    private(set) var checking = false
    private(set) var draft: ImageGenRewriteDraft?
    private(set) var aspectChosen = false
    private(set) var helperServers: [ImageGenHelperServer] = []
    private(set) var surveying = false
    private(set) var isStaged = false
    private(set) var stagedSighting: ImageGenSighting?

    private var runner: ImageGenRunner?
    private var checked = false
    private let rewriter = ImageGenRewriter()
    private var watchers: [ObjectIdentifier: Watcher] = [:]
    private let bitmaps = NSCache<NSString, Bitmap>()
    private var bitmapLoads: Set<String> = []

    /// A decoded picture, boxed because a cache holds objects and a `CGImage` is a Core Foundation
    /// reference that is not one.
    private final class Bitmap {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private struct Watcher {
        weak var owner: AnyObject?
        let notify: (Change) -> Void
    }

    /// A machine named for a headless run — `TAILSCODE_IMAGE_ENDPOINT` — so the harness can point
    /// the studio at a stand-in ComfyUI for screenshots without touching what the person has filed.
    /// Debug builds only; the installed app answers to the door alone.
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

    /// A seed named for a headless run — `TAILSCODE_IMAGE_SEED` — so a stand-in machine that hands
    /// back a picture it already rendered can be given the seed that picture was made with, and the
    /// caption under it states what is true of the picture. Debug builds only.
    static var pinnedSeed: UInt64? {
        #if DEBUG
            return ProcessInfo.processInfo.environment["TAILSCODE_IMAGE_SEED"].flatMap { UInt64($0) }
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
        slot.setSize(ImageGenStore.size())
        slot.setDetail(ImageGenStore.detail())
        library = MacImageLibrary(endpoint: resolved)
        bitmaps.countLimit = 6
        bitmaps.totalCostLimit = 160 * 1024 * 1024
        wireLibrary()
    }

    private func wireLibrary() {
        library.onChange = { [weak self] item in self?.changed(.shelf(item)) }
    }

    func watch(_ owner: AnyObject, _ block: @escaping (Change) -> Void) {
        watchers[ObjectIdentifier(owner)] = Watcher(owner: owner, notify: block)
    }

    func unwatch(_ owner: AnyObject) {
        watchers.removeValue(forKey: ObjectIdentifier(owner))
    }

    private func changed(_ change: Change = .state) {
        watchers = watchers.filter { $0.value.owner != nil }
        for watcher in watchers.values { watcher.notify(change) }
    }

    var isPainting: Bool { slot.isBusy }

    var endpoint: ImageGenEndpoint { slot.endpoint }

    var door: ImageGenDoor { ImageGenDoor.current() }

    /// The last look at the machine this studio is pointed at: a staged one when a state was put on
    /// by hand, else whatever the shared store holds for this address.
    var sighting: ImageGenSighting? {
        if isStaged { return stagedSighting }
        guard let seen = ImageGenStore.lastSeen(), seen.host == endpoint.displayHost else {
            return nil
        }
        return seen
    }

    /// How many renders are ahead of or at this one on the machine: this studio's own while it
    /// paints, else whatever the machine said it was running when last looked at.
    var queueCount: Int {
        if slot.isBusy {
            if case .queued(let ahead)? = progress?.stage { return ahead + 1 }
            return 1
        }
        return sighting?.running ?? 0
    }

    /// What the stage shows when nothing is being painted: the picture chosen, else the newest made
    /// this session. A picture the machine keeps reaches the stage only by being put there.
    var exhibit: StudioExhibit? {
        if let keptOnStage { return .kept(keptOnStage) }
        if stageCleared { return nil }
        if let made = slot.onStage { return .made(made) }
        return nil
    }

    /// The machine's newest picture, held dimmed behind the empty stage's invitations.
    var newestKept: ImageGenLibraryItem? { library.items.first }

    /// Whether a render can honestly start with the engine chosen: the machine, as last seen, has
    /// that engine's files. Unknown is not a refusal.
    var engineBlocked: String? {
        guard let sighting, sighting.reachable, !sighting.available(slot.engine) else { return nil }
        return ImageGenWords.cannotRender(engine: slot.engine, machine: endpoint.shortName)
    }

    /// The engine the machine can paint with when the chosen one cannot, so a refusal can offer the
    /// one tap that fixes it.
    var fallbackEngine: ImageGenEngine? {
        guard let sighting, sighting.reachable else { return nil }
        return sighting.readyEngines.first { $0 != slot.engine }
    }

    var helper: ImageGenHelper? { ImageGenStore.helper() }

    var enhancing: Bool { draft?.isWriting == true }

    func adoptDoor() {
        guard Self.pinnedEndpoint == nil, !isStaged, !isPainting,
            let endpoint = door.endpoint, endpoint != slot.endpoint
        else { return }
        point(at: endpoint)
    }

    func point(at endpoint: ImageGenEndpoint) {
        guard endpoint != slot.endpoint else { return }
        var fresh = ImageGenSlot(endpoint: endpoint)
        fresh.setEngine(slot.engine)
        fresh.setAspect(slot.aspect)
        fresh.setSize(slot.size)
        fresh.setDetail(slot.detail)
        fresh.hold(slot.reference)
        fresh.promptDraft = slot.promptDraft
        slot = fresh
        library.cancel()
        library.onChange = nil
        library = MacImageLibrary(endpoint: endpoint)
        wireLibrary()
        keptOnStage = nil
        checked = false
        checkMachine()
        library.refresh()
        changed()
    }

    func advance(_ field: ImageGenField) {
        slot.advance(field)
        if field == .aspect { aspectChosen = true }
        remember()
    }

    func choose(engine: ImageGenEngine) {
        slot.setEngine(engine)
        remember()
    }

    func choose(aspect: ImageGenAspect) {
        slot.setAspect(aspect)
        aspectChosen = true
        remember()
    }

    func choose(size: ImageGenSize) {
        slot.setSize(size)
        remember()
    }

    func choose(detail: ImageGenDetail) {
        slot.setDetail(detail)
        remember()
    }

    /// The shape the helper answered with: followed, but never counted as a choice by hand.
    func follow(aspect: ImageGenAspect) {
        guard aspect != slot.aspect, slot.applies(.aspect) else { return }
        slot.setAspect(aspect)
        remember()
    }

    private func remember() {
        if !isStaged {
            ImageGenStore.remember(engine: slot.engine, aspect: slot.aspect)
            ImageGenStore.remember(size: slot.size, detail: slot.detail)
        }
        changed()
    }

    func setNegative(_ words: String) {
        slot.setNegative(words)
        changed()
    }

    func setCutout(_ on: Bool) {
        slot.setCutout(on)
        changed()
    }

    /// Holds the seed the last render rolled, or lets it roll again — the gesture behind "change
    /// one word and see only that word change".
    func toggleSeedHold() {
        if slot.seed.isHeld {
            slot.releaseSeed()
        } else {
            slot.holdSeed()
        }
        changed()
    }

    /// The words the box was left holding, kept where the render state is so closing the Studio and
    /// coming back finds the sentence half-written rather than an empty box.
    func rememberDraft(_ words: String) {
        slot.promptDraft = words
    }

    func hold(_ reference: ImageGenReference?) {
        slot.hold(reference)
        changed()
    }

    func attach(_ reference: ImageGenReference) {
        slot.attach(reference)
        changed()
    }

    func release(_ path: String) {
        slot.release(path)
        changed()
    }

    /// A picture handed in from a drop, the pasteboard or a file has no path the renderer could
    /// open, so it is given one — the machine is handed a file wherever the picture came from.
    func hold(data: Data, named name: String) {
        guard let path = ImageGenFiles.stage(data, named: name) else { return }
        slot.hold(ImageGenReference(path: path))
        changed()
    }

    /// A picture the machine keeps becomes the reference by name: the graph opens it where it is and
    /// nothing travels. The path kept beside it is only for the chip's thumbnail.
    func hold(kept item: ImageGenLibraryItem) {
        let path = library.originalPath(of: item) ?? library.thumbnailPath(of: item) ?? ""
        slot.hold(ImageGenReference(path: path, kept: item))
        changed()
    }

    /// Whether the picture on the stage is already what the next render starts from.
    func isReference(_ exhibit: StudioExhibit) -> Bool {
        slot.references.contains { reference in
            switch exhibit {
            case .made(let picture):
                return reference.path == picture.path
                    || (reference.kept != nil && reference.kept?.id == picture.remoteName)
            case .kept(let item):
                return reference.kept?.id == item.id
            }
        }
    }

    func show(_ path: String?) {
        keptOnStage = nil
        stageCleared = false
        slot.show(path)
        changed()
    }

    /// Puts one of the machine's own pictures on the stage. One the session also made is shown as
    /// the session's own, because that copy has its bytes and its seconds already.
    func show(kept item: ImageGenLibraryItem) {
        if let made = slot.pictures.first(where: { $0.remoteName == item.id }) {
            show(made.path)
            return
        }
        keptOnStage = item
        stageCleared = false
        slot.show(nil)
        library.describe(item)
        changed()
        loadBitmap(for: .kept(item))
    }

    func show(_ exhibit: StudioExhibit) {
        switch exhibit {
        case .made(let picture): show(picture.path)
        case .kept(let item): show(kept: item)
        }
    }

    /// Lets go of one picture and the bitmap it was drawn from. The file stays: this surface is a
    /// place to work, not a thing that deletes what somebody's machine wrote.
    func discard(_ path: String) {
        slot.discard(path)
        bitmaps.removeObject(forKey: path as NSString)
        changed()
    }

    /// Stops the render here and on the machine: a render still queued is deleted and never costs a
    /// second of the card, one already running is interrupted.
    func stop() {
        guard let runner, case .painting(let prompt, _, _) = slot.phase else { return }
        runner.cancel()
        self.runner = nil
        slot.fail(prompt: prompt, reason: ImageGenWords.stoppedNotice)
        startedAt = nil
        progress = nil
        sketch = nil
        changed()
    }

    /// The same words again, with a fresh seed — the one thing a person wants after a render that
    /// was nearly right. A kept picture rolls again with the words its file recorded, on the engine
    /// that made it where the file names one.
    func again() {
        guard !isPainting, let exhibit else { return }
        switch exhibit {
        case .made(let picture):
            submit(prompt: picture.prompt)
        case .kept(let item):
            guard let recipe = library.facts(of: item)?.recipe, let words = recipe.prompt,
                !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            if let engine = recipe.engine { slot.setEngine(engine) }
            submit(prompt: words)
        }
    }

    /// Whether Again has words to roll: a made picture always does, a kept one only when its own
    /// file recorded them.
    func hasWords(_ exhibit: StudioExhibit) -> Bool {
        switch exhibit {
        case .made(let picture):
            return !picture.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .kept(let item):
            let words = library.facts(of: item)?.recipe?.prompt ?? ""
            return !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func submit(prompt raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isPainting else { return }
        if let blocked = engineBlocked {
            slot.promptDraft = text
            slot.fail(prompt: text, reason: blocked)
            MacHaptics.shared.play(.warning)
            changed()
            return
        }
        slot.begin(prompt: text)
        startedAt = Date()
        progress = nil
        keptOnStage = nil
        stageCleared = false
        sketch = nil
        draft = nil
        let recipe = slot.recipe(prompt: text, seed: Self.pinnedSeed ?? slot.seed.next())
        let fresh = ImageGenRunner(endpoint: slot.endpoint, recipe: recipe)
        runner = fresh
        MacHaptics.shared.play(.send)
        changed()
        fresh.run(
            references: slot.references,
            progress: { [weak self] report in
                Task { @MainActor [weak self] in self?.progressed(report, from: fresh) }
            },
            preview: { [weak self] frame in
                let image = MacImageLibrary.downsample(frame.bytes, longestSide: 1024)
                Task { @MainActor [weak self] in self?.sketched(image, from: fresh) }
            }
        ) { [weak self] outcome in
            let image: CGImage?
            if case .picture(let data, _, _) = outcome {
                image = Self.stageBitmap(data)
            } else {
                image = nil
            }
            Task { @MainActor [weak self] in self?.finished(outcome, bitmap: image, from: fresh) }
        }
    }

    private func progressed(_ report: ImageGenProgress, from runner: ImageGenRunner) {
        guard runner === self.runner else { return }
        let stageMoved = progress?.stage != report.stage
        progress = report
        changed(stageMoved ? .state : .progress)
    }

    private func sketched(_ image: CGImage?, from runner: ImageGenRunner) {
        guard runner === self.runner, let image else { return }
        sketch = image
        changed(.sketch)
    }

    /// The outcome belongs to the runner that produced it, not to whatever is running now — a second
    /// submit while one paints must not steal the first's picture or its words.
    private func finished(
        _ outcome: ImageGenRunner.Outcome, bitmap: CGImage?, from runner: ImageGenRunner
    ) {
        switch outcome {
        case .picture(let data, let seconds, let remoteName):
            let path = ImageGenFiles.write(data, engine: runner.engine)
            let picture = ImageGenPicture(
                path: path, prompt: runner.prompt, engine: runner.engine, mode: runner.mode,
                aspect: runner.aspect, size: runner.recipe?.size ?? .standard, seconds: seconds,
                seed: runner.seed, steps: runner.recipe?.steps, remoteName: remoteName)
            slot.finish(picture)
            keptOnStage = nil
            stageCleared = false
            if let bitmap { bitmaps.setObject(Bitmap(bitmap), forKey: picture.path as NSString) }
            MacHaptics.shared.play(.received)
            library.refresh()
        case .failure(let reason):
            slot.fail(prompt: runner.prompt, reason: reason)
            MacHaptics.shared.play(.error)
        }
        if runner === self.runner {
            self.runner = nil
            startedAt = nil
            progress = nil
            if case .failure = outcome { sketch = nil }
        }
        changed()
    }

    /// Lets go of the last sketch once the stage has faded it into the picture. A landed render
    /// keeps its sketch for exactly that long, so the picture can arrive under it rather than in
    /// place of it.
    func settleSketch() {
        guard sketch != nil, !isPainting else { return }
        sketch = nil
    }

    /// Asks the machine whether it is there and whether it holds the model files, and files the
    /// answer where every surface can read it. Nothing waits on it: a socket-activated ComfyUI takes
    /// the better part of a minute to wake, and a surface that stared at a spinner for it would be a
    /// surface that lied about what it knows.
    func checkMachine(force: Bool = false) {
        guard !isStaged, force || !checked, !checking else { return }
        checked = true
        checking = true
        changed()
        let endpoint = slot.endpoint
        Task { [weak self] in
            let health = await Task.detached { await ImageGenClient(endpoint: endpoint).health() }
                .value
            ImageGenStore.record(ImageGenSighting(endpoint: endpoint, health: health))
            self?.checking = false
            self?.changed()
        }
    }

    func enhance(_ brief: String, instruction: String? = nil) {
        let words = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !enhancing else { return }
        let previous = instruction == nil ? nil : draft?.written
        let context = slot.rewriteContext(
            aspectChosen: aspectChosen, instruction: instruction, previous: previous)
        rewriter.start(
            brief: words, context: context, filed: helper, near: slot.endpoint,
            onHelper: { found in
                Task { @MainActor in ImageGenStore.remember(helper: found) }
            },
            onChange: { [weak self] draft in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let draft else {
                        self.draft = nil
                        self.changed()
                        self.noticeHandler?(ImageGenRewriteWords.noneFoundTitle)
                        return
                    }
                    let growing = self.draft?.isWriting == true && draft.isWriting
                    self.draft = draft
                    self.changed(growing ? .rewrite : .state)
                }
            })
        draft = nil
        changed(.rewrite)
    }

    /// One line for whoever is showing this studio — a helper found on its own, none to be found.
    var noticeHandler: ((String) -> Void)?

    func dismissRewrite() {
        rewriter.cancel()
        draft = nil
        changed()
    }

    /// Takes the shape a writer asked for when taking its words, unless the shape was chosen by
    /// hand or this engine has no shape to give.
    func followWriter(aspect: ImageGenAspect?) {
        guard let aspect, !aspectChosen else { return }
        follow(aspect: aspect)
    }

    /// Asks every door near the painter and on this Mac what it serves, and files the best writer
    /// unless a person already chose one.
    func surveyHelpers() {
        guard !surveying else { return }
        surveying = true
        changed()
        let endpoint = slot.endpoint
        Task { [weak self] in
            let servers = await Task.detached { await ImageGenHelperFinder.survey(near: endpoint) }
                .value
            guard let self else { return }
            self.surveying = false
            self.helperServers = servers
            if let found = ImageGenHelperFinder.preferred(across: servers),
                self.helper?.yields(to: found) ?? true
            {
                ImageGenStore.remember(helper: found)
            }
            self.changed()
        }
    }

    func setHelper(_ helper: ImageGenHelper?) {
        var chosen = helper
        chosen?.chosenByHand = true
        ImageGenStore.remember(helper: chosen)
        changed()
    }

    func toggleHelper() {
        guard var current = helper else { return }
        current.enabled.toggle()
        ImageGenStore.remember(helper: current)
        changed()
    }

    func stageBitmap(for exhibit: StudioExhibit) -> CGImage? {
        bitmaps.object(forKey: exhibit.id as NSString)?.image
            ?? bitmaps.object(forKey: pathKey(exhibit))?.image
    }

    private func pathKey(_ exhibit: StudioExhibit) -> NSString {
        if case .made(let picture) = exhibit { return picture.path as NSString }
        return exhibit.id as NSString
    }

    /// Decodes the picture on stage once, off the main actor and to the size a stage can show —
    /// the full render stays on disk, one drag or one save away.
    func loadBitmap(for exhibit: StudioExhibit) {
        guard stageBitmap(for: exhibit) == nil, !bitmapLoads.contains(exhibit.id) else { return }
        bitmapLoads.insert(exhibit.id)
        let library = self.library
        Task { [weak self] in
            let data: Data?
            switch exhibit {
            case .made(let picture):
                data = FileManager.default.contents(atPath: picture.path)
            case .kept(let item):
                data = await library.original(of: item)
            }
            let image = await Task.detached { data.flatMap { Self.stageBitmap($0) } }.value
            guard let self else { return }
            self.bitmapLoads.remove(exhibit.id)
            guard let image else { return }
            self.bitmaps.setObject(
                Bitmap(image), forKey: self.pathKey(exhibit),
                cost: image.width * image.height * 4)
            self.changed()
        }
    }

    nonisolated static func stageBitmap(_ data: Data) -> CGImage? {
        MacImageLibrary.downsample(data, longestSide: 2400)
    }

    /// The bytes as the machine wrote them, for a save, a drag or the pasteboard — never a re-encode
    /// of the bitmap a stage was drawn from.
    func bytes(of exhibit: StudioExhibit) async -> Data? {
        switch exhibit {
        case .made(let picture):
            return FileManager.default.contents(atPath: picture.path)
        case .kept(let item):
            return await library.original(of: item)
        }
    }

    /// A name to offer the save panel: the words made into a filename, so a folder of these reads
    /// as what they are rather than as a row of timestamps.
    func fileName(of exhibit: StudioExhibit) -> String {
        switch exhibit {
        case .made(let picture):
            return ImageGenFacts.fileName(for: picture)
        case .kept(let item):
            let words = library.facts(of: item)?.recipe?.prompt ?? ""
            let stem = words.isEmpty ? (item.filename as NSString).deletingPathExtension : words
            return Self.fileName(stem: stem, fallback: item.filename)
        }
    }

    private static func fileName(stem raw: String, fallback: String) -> String {
        let allowed = raw.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let squashed = String(allowed).split(separator: "-").prefix(6).joined(separator: "-")
        let ext = (fallback as NSString).pathExtension
        return "\(squashed.isEmpty ? "image" : squashed).\(ext.isEmpty ? "png" : ext)"
    }

    /// What the stage says it was made from: the words, then the line of facts.
    func caption(of exhibit: StudioExhibit) -> (words: String, facts: String) {
        switch exhibit {
        case .made(let picture):
            return (ImageGenFacts.caption(for: picture), ImageGenFacts.line(for: picture))
        case .kept(let item):
            let facts = library.facts(of: item)
            return (ImageGenFacts.caption(for: facts), ImageGenFacts.line(for: facts))
        }
    }

    /// The estimate beside Generate: what this session's own comparable renders took, or the plain
    /// fact of where the work happens until there is one.
    var estimateLine: String {
        ImageGenEstimate.line(
            machine: endpoint.shortName, engine: slot.engine, size: slot.size, mode: slot.mode,
            among: slot.pictures) ?? ImageGenNotice.costLine
    }

    /// Everything this studio holds is let go of: the render is stopped on the machine, the
    /// listing and the decodes are dropped. The shared studio never calls this — its whole job is
    /// to still be holding the picture when somebody opens the surface again.
    func release() {
        runner?.cancel()
        runner = nil
        rewriter.cancel()
        library.cancel()
        library.onChange = nil
        bitmaps.removeAllObjects()
        watchers = [:]
    }

    /// Puts a state on the studio without a machine to make it happen — the road `--open
    /// studio:<state>` takes, because the states between pressing Generate and holding a picture
    /// cannot be reached in a build loop and are exactly the ones worth looking at.
    func stage(
        slot staged: ImageGenSlot, sighting: ImageGenSighting?, progress: ImageGenProgress?,
        sketch: CGImage?, started: Date?, bitmaps pictures: [String: CGImage],
        library items: MacImageLibrary?, rewrite: ImageGenRewriteDraft? = nil
    ) {
        runner?.cancel()
        runner = nil
        isStaged = true
        slot = staged
        stagedSighting = sighting
        self.progress = progress
        self.sketch = sketch
        startedAt = started
        keptOnStage = nil
        stageCleared = false
        draft = rewrite
        if let items {
            library.cancel()
            library.onChange = nil
            library = items
            wireLibrary()
        }
        for (key, image) in pictures {
            bitmaps.setObject(Bitmap(image), forKey: key as NSString)
        }
        changed()
    }
}
