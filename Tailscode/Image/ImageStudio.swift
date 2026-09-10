import TailscodeCore
import UIKit

/// What the stage is showing: a picture made this session, whose bytes and facts this device
/// already holds, or one the machine keeps, whose bytes are fetched and whose facts are read from
/// the file. The two wear the same caption, the same facts line and the same verbs.
enum ImageExhibit: Equatable {
    case made(ImageGenPicture)
    case kept(ImageGenLibraryItem)

    var id: String {
        switch self {
        case .made(let picture): return picture.path
        case .kept(let item): return item.id
        }
    }

    /// The name the machine's gallery knows this picture by, so a made picture and its tile agree.
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
/// A render is seconds to minutes of another machine's card and a phone goes in a pocket halfway
/// through, so the job, the slot, the decoded pictures and the machine's gallery live here and the
/// screen is only a view onto them. Backing out of the studio closes a screen rather than throwing
/// away somebody's card, and opening it again finds the same picture exactly where it was.
///
/// This is the phone's `ForgeRunner`: the same shape, about the other thing that machine does.
@MainActor
final class ImageStudio {
    static let didChange = Notification.Name("tailscode.imageStudio.didChange")
    /// The machine spoke about the render in flight. Its own notification, because a frame per
    /// sampler step must move the stage's bar and nothing else.
    static let progressDidChange = Notification.Name("tailscode.imageStudio.progressDidChange")
    static let shared = ImageStudio()

    private(set) var slot: ImageGenSlot
    /// When the render in flight started, so a surface can say how long it has been. The machine
    /// says what it is doing; the clock says for how long — neither is invented.
    private(set) var startedAt: Date?
    private(set) var progress: ImageGenProgress?
    private(set) var library: ImageLibrary
    /// A kept picture put on the stage by hand. Nil means the stage shows what the session made,
    /// or — with nothing made yet — the newest thing on the machine.
    private(set) var keptOnStage: ImageGenLibraryItem?
    /// Whether the machine is being asked about itself right now, so a sheet can say so.
    private(set) var checking = false

    private var runner: ImageGenRunner?
    private var checked = false
    private let decoded = NSCache<NSString, UIImage>()

    init() {
        let endpoint = ImageGenDoor.current().endpoint ?? ImageGenEndpoint(host: "127.0.0.1")
        slot = ImageGenSlot(endpoint: endpoint)
        slot.setEngine(ImageGenStore.engine())
        slot.setAspect(ImageGenStore.aspect())
        library = ImageLibrary(endpoint: endpoint)
        decoded.countLimit = 12
    }

    var isPainting: Bool { slot.isBusy }

    var endpoint: ImageGenEndpoint { slot.endpoint }

    var door: ImageGenDoor { ImageGenDoor.current() }

    var sighting: ImageGenSighting? { door.currentSighting }

    /// What the stage shows when nothing is being painted: the picture chosen, else the newest
    /// made here, else the newest the machine keeps — a studio that opens on something.
    var exhibit: ImageExhibit? {
        if let keptOnStage { return .kept(keptOnStage) }
        if let made = slot.onStage { return .made(made) }
        if let newest = library.items.first { return .kept(newest) }
        return nil
    }

    /// Points the studio at the machine the door resolves to, unless a render is in flight — a
    /// picture is fetched from the machine that queued it, so moving mid-render loses it.
    func adoptDoor() {
        guard !isPainting, let endpoint = door.endpoint, endpoint != slot.endpoint else { return }
        var fresh = ImageGenSlot(endpoint: endpoint)
        fresh.setEngine(slot.engine)
        fresh.setAspect(slot.aspect)
        fresh.hold(slot.reference)
        slot = fresh
        library = ImageLibrary(endpoint: endpoint)
        keptOnStage = nil
        checked = false
        checkMachine()
        announce()
    }

    func advance(_ field: ImageGenField) {
        slot.advance(field)
        remember()
    }

    func choose(engine: ImageGenEngine) {
        slot.setEngine(engine)
        remember()
    }

    func choose(aspect: ImageGenAspect) {
        slot.setAspect(aspect)
        remember()
    }

    private func remember() {
        ImageGenStore.remember(engine: slot.engine, aspect: slot.aspect)
        announce()
    }

    /// Attaches or lets go of the picture the next render works from. Nothing else decides the
    /// mode, so this one call is the whole gesture.
    func hold(_ reference: ImageGenReference?) {
        slot.hold(reference)
        announce()
    }

    /// A picture handed in from the photo library, the camera or the clipboard has no path of its
    /// own, so it is given one — the renderer is handed a file wherever it comes from.
    func hold(data: Data, named name: String) {
        guard let path = ImageGenFiles.stage(data, named: name) else { return }
        hold(ImageGenReference(path: path))
    }

    /// A picture the machine keeps becomes the reference by name: the graph opens it where it is
    /// and nothing travels. The path kept beside it is only for the chip's thumbnail.
    func hold(kept item: ImageGenLibraryItem) {
        let path = library.originalPath(of: item) ?? library.thumbnailPath(of: item) ?? ""
        hold(ImageGenReference(path: path, kept: item))
    }

    /// Whether the picture on the stage is already what the next render starts from.
    func isReference(_ exhibit: ImageExhibit) -> Bool {
        guard let reference = slot.reference else { return false }
        switch exhibit {
        case .made(let picture):
            return reference.path == picture.path
                || (reference.kept != nil && reference.kept?.id == picture.remoteName)
        case .kept(let item):
            return reference.kept?.id == item.id
        }
    }

    /// The words the box was left holding, kept where the render state is so leaving the studio
    /// and coming back finds the sentence half-written rather than an empty box.
    func rememberDraft(_ words: String) {
        slot.promptDraft = words
    }

    /// Puts a picture made this session on the stage.
    func show(_ path: String?) {
        keptOnStage = nil
        slot.show(path)
        announce()
    }

    /// Puts a kept picture on the stage. One the session also made is shown as the session's own,
    /// because that copy has its bytes and its seconds already.
    func show(kept item: ImageGenLibraryItem) {
        if let made = slot.pictures.first(where: { $0.remoteName == item.id }) {
            show(made.path)
            return
        }
        keptOnStage = item
        slot.show(nil)
        library.describe(item)
        announce()
    }

    /// Lets go of one picture and the bitmap it was drawn from. The file stays: this surface is a
    /// place to work, not a thing that deletes what somebody's machine wrote.
    func discard(_ path: String) {
        slot.discard(path)
        decoded.removeObject(forKey: path as NSString)
        announce()
    }

    /// Stops the render here and on the machine: a render still queued is deleted and never costs
    /// a second of the card, one already running is interrupted.
    func stop() {
        guard let runner, case .painting(let prompt, _, _) = slot.phase else { return }
        runner.cancel()
        self.runner = nil
        slot.fail(prompt: prompt, reason: ImageGenWords.stoppedNotice)
        startedAt = nil
        progress = nil
        announce()
    }

    /// The same words again, with a fresh seed — the one thing a person wants after a render that
    /// was nearly right. A kept picture rolls again with the words its file recorded, on the
    /// engine that made it where the file names one.
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

    /// Whether a render can honestly start with the engine chosen: the machine, as last seen, has
    /// that engine's files. Unknown is not a refusal.
    var engineBlocked: String? {
        guard let sighting, sighting.reachable, !sighting.available(slot.engine) else { return nil }
        return ImageGenWords.cannotRender(engine: slot.engine, machine: endpoint.shortName)
    }

    func submit(prompt raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isPainting else { return }
        if let blocked = engineBlocked {
            slot.promptDraft = text
            slot.fail(prompt: text, reason: blocked)
            Theme.Haptics.warning()
            announce()
            return
        }
        slot.begin(prompt: text)
        startedAt = Date()
        progress = nil
        keptOnStage = nil
        let fresh = ImageGenRunner(
            endpoint: slot.endpoint, prompt: text, engine: slot.engine, mode: slot.mode,
            aspect: slot.aspect)
        runner = fresh
        announce()
        AppLogger.session.info(
            "image render queued on \(endpoint.displayHost) engine=\(slot.engine.rawValue) mode=\(slot.mode.rawValue) aspect=\(slot.aspect.rawValue)"
        )
        fresh.run(
            prompt: text, engine: slot.engine, mode: slot.mode, aspect: slot.aspect,
            reference: slot.reference,
            progress: { [weak self] report in
                Task { @MainActor [weak self] in self?.progressed(report, from: fresh) }
            }
        ) { [weak self] outcome in
            Task { @MainActor [weak self] in self?.finished(outcome, from: fresh) }
        }
    }

    private func progressed(_ report: ImageGenProgress, from runner: ImageGenRunner) {
        guard runner === self.runner else { return }
        progress = report
        NotificationCenter.default.post(name: ImageStudio.progressDidChange, object: nil)
    }

    /// The outcome belongs to the runner that produced it, not to whatever is running now — a
    /// second submit while one paints must not steal the first's picture or its words.
    private func finished(_ outcome: ImageGenRunner.Outcome, from runner: ImageGenRunner) {
        switch outcome {
        case .picture(let data, let seconds, let remoteName):
            let path = ImageGenFiles.write(data, engine: runner.engine)
            let picture = ImageGenPicture(
                path: path, prompt: runner.prompt, engine: runner.engine, mode: runner.mode,
                aspect: runner.aspect, seconds: seconds, seed: runner.seed, remoteName: remoteName)
            slot.finish(picture)
            keptOnStage = nil
            if let image = UIImage(data: data) {
                decoded.setObject(image, forKey: path as NSString)
            }
            AppLogger.session.info("image render landed as \(remoteName) in \(Int(seconds))s")
            Theme.Haptics.received()
            library.refresh()
        case .failure(let reason):
            slot.fail(prompt: runner.prompt, reason: reason)
            AppLogger.session.error("image render failed: \(reason)")
            Theme.Haptics.error()
        }
        if runner === self.runner {
            self.runner = nil
            startedAt = nil
            progress = nil
        }
        announce()
    }

    /// Asks the machine whether it is there and whether it holds the model files, and files the
    /// answer where every surface can read it. Nothing waits on it: a socket-activated ComfyUI
    /// takes the better part of a minute to wake, and a surface that stared at a spinner for it
    /// would be a surface that lied about what it knows.
    func checkMachine(force: Bool = false) {
        guard force || !checked, !checking else { return }
        checked = true
        checking = true
        announce()
        let endpoint = slot.endpoint
        Task.detached { [weak self] in
            let health = await ImageGenClient(endpoint: endpoint).health()
            await MainActor.run {
                ImageGenStore.record(ImageGenSighting(endpoint: endpoint, health: health))
                self?.checking = false
                self?.announce()
            }
        }
    }

    func image(of picture: ImageGenPicture) -> UIImage? {
        if let held = decoded.object(forKey: picture.path as NSString) { return held }
        guard let data = FileManager.default.contents(atPath: picture.path),
            let image = UIImage(data: data)
        else { return nil }
        decoded.setObject(image, forKey: picture.path as NSString)
        return image
    }

    /// A kept picture's bitmap, from the original once it is on disk.
    func image(of item: ImageGenLibraryItem) -> UIImage? {
        if let held = decoded.object(forKey: item.id as NSString) { return held }
        guard let path = library.originalPath(of: item),
            let data = FileManager.default.contents(atPath: path), let image = UIImage(data: data)
        else { return nil }
        decoded.setObject(image, forKey: item.id as NSString)
        return image
    }

    /// The bytes as the machine wrote them, for a save or the pasteboard — never a re-encode of
    /// the bitmap a thumbnail was drawn from.
    func payload(of picture: ImageGenPicture) -> ImagePayload? {
        guard let image = image(of: picture) else { return nil }
        return ImagePayload(
            image: image, data: FileManager.default.contents(atPath: picture.path),
            filename: ImageGenFacts.fileName(for: picture))
    }

    /// The same for a kept picture, fetching the original first when it is not here yet.
    func payload(of item: ImageGenLibraryItem) async -> ImagePayload? {
        guard let data = await library.original(of: item), let image = UIImage(data: data) else {
            return nil
        }
        decoded.setObject(image, forKey: item.id as NSString)
        let facts = library.facts(of: item)
        let words = facts?.recipe?.prompt ?? ""
        let stem = words.isEmpty ? (item.filename as NSString).deletingPathExtension : words
        return ImagePayload(image: image, data: data, filename: Self.fileName(stem: stem))
    }

    func payload(of exhibit: ImageExhibit) async -> ImagePayload? {
        switch exhibit {
        case .made(let picture): return payload(of: picture)
        case .kept(let item): return await payload(of: item)
        }
    }

    private static func fileName(stem raw: String) -> String {
        let allowed = raw.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let squashed = String(allowed).split(separator: "-").prefix(6).joined(separator: "-")
        return "\(squashed.isEmpty ? "image" : squashed).png"
    }

    private func announce() {
        NotificationCenter.default.post(name: ImageStudio.didChange, object: nil)
    }
}
