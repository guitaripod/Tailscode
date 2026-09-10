import TailscodeCore
import UIKit

/// The picture being made, held above whatever is drawing it.
///
/// A render is seconds to minutes of another machine's card and a phone goes in a pocket halfway
/// through, so the job, the slot and the decoded pictures live here and the screen is only a view
/// onto them. Backing out of the studio closes a screen rather than throwing away somebody's card,
/// and opening it again finds the same picture exactly where it was.
///
/// This is the phone's `ForgeRunner`: the same shape, about the other thing that machine does.
@MainActor
final class ImageStudio {
    static let didChange = Notification.Name("tailscode.imageStudio.didChange")
    static let shared = ImageStudio()

    private(set) var slot: ImageGenSlot
    /// When the render in flight started, so a surface can say how long it has been rather than
    /// drawing a bar it would have to invent — ComfyUI's queue reports done or failed and nothing
    /// in between, and a fake percentage is worse than an honest clock.
    private(set) var startedAt: Date?

    private var runner: ImageGenRunner?
    private var checked = false
    private let decoded = NSCache<NSString, UIImage>()

    init() {
        slot = ImageGenSlot(
            endpoint: ImageGenDoor.current().endpoint ?? ImageGenEndpoint(host: "127.0.0.1"))
        slot.setEngine(ImageGenStore.engine())
        slot.setAspect(ImageGenStore.aspect())
        decoded.countLimit = 12
    }

    var isPainting: Bool { slot.isBusy }

    var endpoint: ImageGenEndpoint { slot.endpoint }

    var door: ImageGenDoor { ImageGenDoor.current() }

    /// Points the studio at the machine the door resolves to, unless a render is in flight — a
    /// picture is fetched from the machine that queued it, so moving mid-render loses it.
    func adoptDoor() {
        guard !isPainting, let endpoint = door.endpoint, endpoint != slot.endpoint else { return }
        var fresh = ImageGenSlot(endpoint: endpoint)
        fresh.setEngine(slot.engine)
        fresh.setAspect(slot.aspect)
        fresh.hold(slot.reference)
        slot = fresh
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

    /// A picture handed in from the photo library has no path of its own, so it is given one —
    /// the renderer is handed a file wherever it comes from.
    func hold(data: Data, named name: String) {
        guard let path = ImageGenFiles.stage(data, named: name) else { return }
        hold(ImageGenReference(path: path))
    }

    /// The words the box was left holding, kept where the render state is so leaving the studio
    /// and coming back finds the sentence half-written rather than an empty box.
    func rememberDraft(_ words: String) {
        slot.promptDraft = words
    }

    func show(_ path: String?) {
        slot.show(path)
        announce()
    }

    /// Lets go of one picture and the bitmap it was drawn from. The file stays: this surface is a
    /// place to work, not a thing that deletes what somebody's machine wrote.
    func discard(_ path: String) {
        slot.discard(path)
        decoded.removeObject(forKey: path as NSString)
        announce()
    }

    /// Stops the render on this device's side and says so. The queue on the other machine runs its
    /// course — a client that promised to unspend somebody's card would be lying.
    func stop() {
        guard let runner, case .painting(let prompt, _, _) = slot.phase else { return }
        runner.cancel()
        self.runner = nil
        slot.fail(prompt: prompt, reason: String(localized: "Stopped"))
        startedAt = nil
        announce()
    }

    /// The same words again, with a fresh seed — the one thing a person wants after a render that
    /// was nearly right.
    func again() {
        guard let picture = slot.onStage, !isPainting else { return }
        submit(prompt: picture.prompt)
    }

    func submit(prompt raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isPainting else { return }
        slot.begin(prompt: text)
        startedAt = Date()
        let fresh = ImageGenRunner(
            endpoint: slot.endpoint, prompt: text, engine: slot.engine, mode: slot.mode,
            aspect: slot.aspect)
        runner = fresh
        let reference = slot.reference?.path
        announce()
        fresh.run(
            prompt: text, engine: slot.engine, mode: slot.mode, aspect: slot.aspect,
            referencePath: reference
        ) { outcome in
            Task { @MainActor [weak self] in self?.finished(outcome, from: fresh) }
        }
    }

    /// The outcome belongs to the runner that produced it, not to whatever is running now — a
    /// second submit while one paints must not steal the first's picture or its words.
    private func finished(_ outcome: ImageGenRunner.Outcome, from runner: ImageGenRunner) {
        switch outcome {
        case .picture(let data, let seconds):
            let path = ImageGenFiles.write(data, engine: runner.engine)
            let picture = ImageGenPicture(
                path: path, prompt: runner.prompt, engine: runner.engine, mode: runner.mode,
                aspect: runner.aspect, seconds: seconds, seed: runner.seed)
            slot.finish(picture)
            if let image = UIImage(data: data) {
                decoded.setObject(image, forKey: path as NSString)
            }
            Theme.Haptics.received()
        case .failure(let reason):
            slot.fail(prompt: runner.prompt, reason: reason)
            Theme.Haptics.error()
        }
        if runner === self.runner {
            self.runner = nil
            startedAt = nil
        }
        announce()
    }

    /// Asks the machine whether it is there and whether it holds the model files, and files the
    /// answer where every surface can read it. Nothing waits on it: a socket-activated ComfyUI
    /// takes the better part of a minute to wake, and a surface that stared at a spinner for it
    /// would be a surface that lied about what it knows.
    func checkMachine() {
        guard !checked else { return }
        checked = true
        let endpoint = slot.endpoint
        Task.detached { [weak self] in
            let health = await ImageGenClient(endpoint: endpoint).health()
            await MainActor.run {
                ImageGenStore.record(ImageGenSighting(endpoint: endpoint, health: health))
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

    /// The bytes as the machine wrote them, for a save or the pasteboard — never a re-encode of
    /// the bitmap a thumbnail was drawn from.
    func payload(of picture: ImageGenPicture) -> ImagePayload? {
        guard let image = image(of: picture) else { return nil }
        return ImagePayload(
            image: image, data: FileManager.default.contents(atPath: picture.path),
            filename: ImageGenFacts.fileName(for: picture))
    }

    private func announce() {
        NotificationCenter.default.post(name: ImageStudio.didChange, object: nil)
    }
}
