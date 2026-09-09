import CGtkShim
import Foundation
import TailscodeCore

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
    private var runner: ImageGenRunner?
    private var checked = false

    init(endpoint: ImageGenEndpoint?) {
        slot = ImageGenSlot(
            endpoint: endpoint ?? ImageGenDoor.current().endpoint
                ?? ImageGenEndpoint(host: "127.0.0.1"))
        slot.setEngine(ImageGenStore.engine())
        slot.setAspect(ImageGenStore.aspect())
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
        checked = false
        checkMachine()
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

    func show(_ path: String?) {
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

    /// Stops the render on this machine's side and says so. The queue on the other machine runs
    /// its course — a client that promised to unspend somebody's card would be lying.
    func stop() {
        guard let runner, case .painting(let prompt, _, _) = slot.phase else { return }
        runner.cancel()
        self.runner = nil
        slot.fail(prompt: prompt, reason: Localized.text("Stopped"))
        announce()
    }

    /// The same words again, with a fresh seed — the one thing a person wants after a render
    /// that was nearly right.
    func again() {
        guard let picture = slot.onStage, !isPainting else { return }
        submit(prompt: picture.prompt)
    }

    /// The bytes as they were written, for a save or a clipboard — never a re-encode of the
    /// scaled texture a tile is drawn from.
    func bytes(of picture: ImageGenPicture) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: picture.path))
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
        slot.begin(prompt: text)
        let engine = slot.engine
        let mode = slot.mode
        let aspect = slot.aspect
        let reference = slot.reference?.path
        let fresh = ImageGenRunner(
            endpoint: slot.endpoint, prompt: text, engine: engine, mode: mode, aspect: aspect)
        runner = fresh
        announce()
        fresh.run(
            prompt: text, engine: engine, mode: mode, aspect: aspect, referencePath: reference
        ) { [weak self] outcome in
            Gtk.onMain { [weak self] in self?.finished(outcome, from: fresh) }
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
            decode(picture.path, data: data)
        case .failure(let reason):
            slot.fail(prompt: runner.prompt, reason: reason)
        }
        if runner === self.runner { self.runner = nil }
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
        return
            "image \(phase) engine=\(slot.engine.rawValue) aspect=\(slot.aspect.rawValue) mode=\(slot.mode.rawValue) prompt=\(prompt.isEmpty ? "-" : prompt) tiles=\(slot.pictures.count) reason=\(slot.failure ?? "-")"
    }

    /// A pane closing releases the textures it decoded. The shared studio never does — its whole
    /// job is to still be holding the picture when somebody opens the surface again.
    func release() {
        runner?.cancel()
        runner = nil
        for bits in textures.values {
            if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
        }
        textures = [:]
    }
}
