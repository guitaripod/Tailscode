import Foundation

/// What a draw slot is pointed at: the machine that renders, plus the shape of the ask.
/// Like `VideoTarget`, a slot's whole state survives a restart, so every part is a small
/// persistable value.
public struct ImageGenEndpoint: Sendable, Equatable, Codable {
    /// ComfyUI's own default, and the same port the video renderer answers on: one store holds
    /// the picture models and the video models, so a bare machine name typed here means the same
    /// door as the one the forge already found.
    public static let defaultPort = ForgeEndpoint.defaultPort

    /// Base address of the ComfyUI API, e.g. `http://127.0.0.1:8189`.
    public let address: String

    public init(address: String) {
        self.address = address.hasSuffix("/") ? String(address.dropLast()) : address
    }

    public init(host: String, port: Int = ImageGenEndpoint.defaultPort) {
        self.init(address: "http://\(host):\(port)")
    }

    /// The same door the videos are rendered through, asked for pictures. One box on the tailnet
    /// holds the card and one ComfyUI holds both sets of models, so pointing at it once is the
    /// whole of pointing at it.
    public init(sharing forge: ForgeEndpoint) {
        self.init(host: forge.host, port: forge.port)
    }

    private var components: URLComponents? { URLComponents(string: address) }

    public var host: String { components?.host ?? address }

    public var port: Int { components?.port ?? Self.defaultPort }

    public var displayHost: String { "\(host):\(port)" }

    /// A route on the machine, with its query escaped once here rather than by hand at every call.
    public func url(_ path: String, query: [String: String] = [:]) -> URL? {
        var parts = URLComponents(string: address)
        parts?.path = path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            parts?.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return parts?.url
    }

    /// The same socket the forge follows a render on, for this client's own frames.
    public func socketURL(clientID: String) -> URL? {
        var parts = URLComponents(string: address)
        parts?.scheme = "ws"
        parts?.path = "/ws"
        parts?.queryItems = [URLQueryItem(name: "clientId", value: clientID)]
        return parts?.url
    }

    /// The machine, not the address — a MagicDNS name is a hostname plus a tailnet plus a TLD,
    /// and the first label is what the tailnet calls the box.
    public var shortName: String {
        if host.hasSuffix(".ts.net") || host.hasSuffix(".tailscale.net"),
            let first = host.split(separator: ".").first
        {
            return String(first)
        }
        return host
    }

    /// What a person plausibly types, read through the parser the agent connection and the video
    /// renderer already share, so a bare name, `host:port`, a URL or a line pasted out of
    /// ComfyUI's own terminal all mean the same thing.
    public enum Reading: Sendable, Equatable {
        case empty
        case endpoint(ImageGenEndpoint)
        case bindAll
        case unsupportedScheme(String)
        case invalid
    }

    public static func read(_ raw: String) -> Reading {
        switch HostAddress.read(raw, defaultPort: defaultPort) {
        case .empty: return .empty
        case .bindAll: return .bindAll
        case .invalid: return .invalid
        case .unsupportedScheme(let scheme): return .unsupportedScheme(scheme)
        case .address(let address):
            guard let host = address.url.host, !host.isEmpty else { return .invalid }
            return .endpoint(
                ImageGenEndpoint(host: host, port: address.url.port ?? defaultPort))
        }
    }

    /// The sentence a client shows when a typed address cannot be used. The words are the video
    /// renderer's, because the mistake and the machine are the same ones.
    public static func complaint(_ reading: Reading) -> String? {
        switch reading {
        case .endpoint, .empty: return nil
        case .bindAll: return ForgeEndpoint.complaint(.bindAll)
        case .unsupportedScheme(let scheme):
            return ForgeEndpoint.complaint(.unsupportedScheme(scheme))
        case .invalid: return ForgeEndpoint.complaint(.invalid)
        }
    }
}

/// The two editors the store runs, named for what they are good at rather than by version.
public enum ImageGenEngine: String, Codable, Sendable, CaseIterable {
    case quality
    case fast

    public var label: String {
        switch self {
        case .quality: return Localized.text("Quality")
        case .fast: return Localized.text("Fast")
        }
    }

    /// What the identity strip calls a finished picture.
    public var short: String {
        switch self {
        case .quality: return Localized.text("Qwen")
        case .fast: return Localized.text("Klein")
        }
    }

    /// What each engine is for, said once so a chip's menu and a machine sheet agree.
    public var detail: String {
        switch self {
        case .quality: return Localized.text("Qwen Image Edit · 30 steps · edits and paints")
        case .fast: return Localized.text("FLUX.2 Klein · 4 steps · seconds, not a minute")
        }
    }

    /// The files this engine cannot run without. A machine is checked file by file, and an engine
    /// whose files are all there is offered even when the other's are not.
    public var files: [ImageGenModelFile] {
        ImageGenModelFile.all.filter { $0.engine == self }
    }
}

/// One model file the store must hold, and what it is in words a person recognises. The paths
/// are ComfyUI's own — a directory and a file name — because that is how the machine names them
/// when it reports what it has.
public struct ImageGenModelFile: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let path: String
    public let role: String
    public let engine: ImageGenEngine

    public var id: String { path }

    public var name: String { (path as NSString).lastPathComponent }

    public var directory: String { (path as NSString).deletingLastPathComponent }

    public static let all: [ImageGenModelFile] = [
        ImageGenModelFile(
            path: "diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors",
            role: Localized.text("Qwen diffusion model"), engine: .quality),
        ImageGenModelFile(
            path: "text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors",
            role: Localized.text("Qwen text encoder"), engine: .quality),
        ImageGenModelFile(
            path: "vae/qwen_image_vae.safetensors", role: Localized.text("Qwen VAE"),
            engine: .quality),
        ImageGenModelFile(
            path: "diffusion_models/flux-2-klein-4b.safetensors",
            role: Localized.text("Klein diffusion model"), engine: .fast),
        ImageGenModelFile(
            path: "text_encoders/qwen_3_4b.safetensors", role: Localized.text("Klein text encoder"),
            engine: .fast),
        ImageGenModelFile(
            path: "vae/flux2-vae.safetensors", role: Localized.text("Klein VAE"), engine: .fast),
    ]

    public static func named(_ path: String) -> ImageGenModelFile? {
        all.first { $0.path == path || $0.name == (path as NSString).lastPathComponent }
    }
}

/// Aspect the picture is drawn at, as pixel dimensions. A chip, not a free box: the sampler
/// wants multiples of 64, and every choice a person actually makes is one of four.
public enum ImageGenAspect: String, Codable, Sendable, CaseIterable {
    case square
    case landscape
    case portrait
    case wide

    public var pixels: (width: Int, height: Int) {
        switch self {
        case .square: return (1024, 1024)
        case .landscape: return (1280, 896)
        case .portrait: return (896, 1280)
        case .wide: return (1536, 640)
        }
    }

    public var label: String {
        let size = pixels
        return "\(size.width)×\(size.height)"
    }

    public var short: String {
        switch self {
        case .square: return Localized.text("Square")
        case .landscape: return Localized.text("Landscape")
        case .portrait: return Localized.text("Portrait")
        case .wide: return Localized.text("Wide")
        }
    }
}

/// The two decisions a picture is made from, worn as chips wherever an image is asked for — a
/// pane's own strip, the composer's lane, a phone's row.
///
/// A chip is a value that walks: pressing one changes what the next render is, immediately and
/// with nothing to confirm. Anything that opens something is not a chip and never was — whether
/// the render starts from a picture is decided by whether there is a picture attached, which is
/// the attach control's business, not a setting's.
public enum ImageGenField: String, Sendable, Equatable, CaseIterable {
    case engine
    case aspect

    public var label: String {
        switch self {
        case .engine: return Localized.text("Engine")
        case .aspect: return Localized.text("Aspect")
        }
    }

    /// One symbol per decision, so a chip is read down its left edge rather than word by word.
    public var symbol: String {
        switch self {
        case .engine: return "cpu"
        case .aspect: return "aspectratio"
        }
    }

    public var glyph: String {
        switch self {
        case .engine: return "%"
        case .aspect: return "#"
        }
    }

    /// Every one of these is a short list the value walks, so a press changes it rather than
    /// opening something to change it in.
    public var affordanceGlyph: String { "▾" }
}

/// Whether the render starts from words alone or from a picture the person handed it. This is
/// never asked as a question: it is read off whether anything is attached.
public enum ImageGenMode: String, Codable, Sendable, CaseIterable {
    case generate
    case edit

    public var label: String {
        switch self {
        case .generate: return Localized.text("Generate")
        case .edit: return Localized.text("Edit")
        }
    }
}

/// A picture handed to the model to work from. Holding one is the whole of asking for an edit,
/// so this value is the mode: attach and the next render starts from it, remove and it does not.
public struct ImageGenReference: Sendable, Equatable, Codable {
    public let path: String
    /// Set when the picture is one the machine already keeps: the graph then names the file in
    /// place and nothing is uploaded, and the chip draws the gallery's own thumbnail of it.
    public let kept: ImageGenLibraryItem?

    public init(path: String, kept: ImageGenLibraryItem? = nil) {
        self.path = path
        self.kept = kept
    }

    public var name: String { kept?.filename ?? (path as NSString).lastPathComponent }

    /// What the graph's `LoadImage` is given: a name the machine can open. A kept picture is
    /// addressed in its own directory; anything else has to be put there first and is named by
    /// whoever did the putting.
    public var machineName: String? { kept?.annotatedName }

    /// What the chip under the prompt says it is holding, short enough to sit beside the words.
    public var chip: String {
        let short = name
        guard short.count > 28 else { return short }
        return String(short.prefix(25)) + "…"
    }
}

/// One finished picture the slot is holding: where the file is, what made it, and what it
/// cost in seconds — a fact, not a decoration.
public struct ImageGenPicture: Sendable, Equatable, Codable {
    public let path: String
    public let prompt: String
    public let engine: ImageGenEngine
    public let mode: ImageGenMode
    public let aspect: ImageGenAspect
    public let seconds: Double
    public let seed: UInt64
    public let madeAt: Date
    /// What the machine called the file it wrote, so the picture can be found again in the
    /// machine's own gallery — a render made here is the newest thing in it.
    public var remoteName: String?

    public init(
        path: String, prompt: String, engine: ImageGenEngine, mode: ImageGenMode,
        aspect: ImageGenAspect, seconds: Double, seed: UInt64, madeAt: Date = Date(),
        remoteName: String? = nil
    ) {
        self.path = path
        self.prompt = prompt
        self.engine = engine
        self.mode = mode
        self.aspect = aspect
        self.seconds = seconds
        self.seed = seed
        self.madeAt = madeAt
        self.remoteName = remoteName
    }

    public var name: String { (path as NSString).lastPathComponent }

    public var kept: ImageGenLibraryItem? { remoteName.map { ImageGenLibraryItem(filename: $0) } }
}

/// What a keystroke means inside a draw slot, shared so both desktops answer the same keys and
/// the headless drivers can name a verb instead of a keycode.
public enum ImageGenCommand: Sendable, Equatable {
    case submit
    case stop
    case engine
    case aspect
    case reference
    case save
    case copy
    case again
    case open
    case next
    case previous

    public static func command(for chord: KeyChord) -> ImageGenCommand? {
        let letter: Character? =
            chord.keyval < 0xFF00 ? Keymap.scalar(chord.keyval) : nil
        if chord.control {
            switch letter {
            case "e": return .engine
            case "a": return .aspect
            case "r": return .reference
            case "s": return .save
            case "c": return .copy
            case "g": return .again
            case "o": return ImageGenCommand.open
            case "]": return .next
            case "[": return .previous
            default: break
            }
        }
        if chord.keyval == Keymap.enter { return .submit }
        return nil
    }

    /// Whether this key means anything while a render is out. A studio mid-render answers stop
    /// and the keys that move around what is already made; it does not start a second one.
    public var duringRender: Bool {
        switch self {
        case .submit: return false
        default: return true
        }
    }
}

public struct ImageGenNotice {
    /// What a render costs the rest of the grid, said plainly, in the widths clients have room
    /// for — offered with the row that opens a slot and the slot's own empty body, the same way
    /// `VideoNotice.splitCostLine` is.
    public static let splitCostLine = Localized.text(
        "Renders this pane's GPU work on the machine ComfyUI runs on")

    public static let emptyBody = Localized.text(
        "Describe a picture. ComfyUI paints it here.")

    /// Where the work happens, said for a surface that is not a pane in the grid — the modal owes
    /// the same fact without borrowing the split's own sentence about what it costs the tiling.
    public static let costLine = Localized.text(
        "Rendered on the machine ComfyUI runs on")

    public static let offlineBody = Localized.text(
        "ComfyUI is not answering at")
}

/// Where the store's model files live, checked before a request is queued — a server that is up
/// but half-configured gets to say so rather than fail with a queue error nobody can read.
public struct ImageGenHealth: Sendable, Equatable {
    public let reachable: Bool
    public let missingModels: [String]
    public let version: String?
    public let running: Int?

    public init(reachable: Bool, missingModels: [String], version: String?, running: Int? = nil) {
        self.reachable = reachable
        self.missingModels = missingModels
        self.version = version
        self.running = running
    }

    public static func unknown() -> ImageGenHealth {
        ImageGenHealth(reachable: false, missingModels: [], version: nil)
    }

    public var ready: Bool { reachable && missingModels.isEmpty }
}

/// The slot's whole model, toolkit-free: what it points at, what it is doing, and the words both
/// desktops draw. The renderer itself is the client's business — this is the contract they share.
public struct ImageGenSlot: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case asking
        case composing(prompt: String)
        case painting(prompt: String, engine: ImageGenEngine, mode: ImageGenMode)
        case failed(prompt: String, reason: String)
    }

    public var endpoint: ImageGenEndpoint
    public var phase: Phase
    public var engine: ImageGenEngine
    public var aspect: ImageGenAspect
    /// The picture the next render starts from, if there is one. Whether this is nil is the mode.
    public var reference: ImageGenReference?
    /// The picture on the stage. Nil means the newest, which is what a fresh render becomes —
    /// so a person comparing an older one against new words keeps looking at the one they chose
    /// until they choose another.
    public var selected: String?
    public var promptDraft: String
    /// The session's finished pictures, newest first. A slot keeps its own history: a picture is
    /// a thing you compare against the words that made it, not a thing you overwrite.
    public var pictures: [ImageGenPicture]
    /// Bytes of the newest picture, held by the client — not part of equality, not persisted.
    public var transient: [String: String]?

    public init(
        endpoint: ImageGenEndpoint, engine: ImageGenEngine = .quality,
        aspect: ImageGenAspect = .square
    ) {
        self.endpoint = endpoint
        self.phase = .asking
        self.engine = engine
        self.aspect = aspect
        self.promptDraft = ""
        self.pictures = []
    }

    /// Read rather than chosen: a render that has a picture to work from is an edit, and one
    /// that does not is a generate. Nobody is ever asked which.
    public var mode: ImageGenMode { reference == nil ? .generate : .edit }

    /// Whether the aspect chip means anything right now. An edit takes its size from the picture
    /// it starts from — both editors scale the reference and paint at that size — so while one is
    /// held the chip is a setting with no effect, and a chip with no effect is not shown as one.
    public var aspectApplies: Bool { reference == nil }

    /// The picture the stage is showing: the one chosen, else the newest there is.
    public var onStage: ImageGenPicture? {
        if let selected, let match = pictures.first(where: { $0.path == selected }) { return match }
        return pictures.first
    }

    public var isAsking: Bool {
        if case .asking = phase { return true }
        return false
    }

    public var isBusy: Bool {
        if case .painting = phase { return true }
        return false
    }

    public var activePrompt: String? {
        switch phase {
        case .asking: return nil
        case .composing(let prompt): return prompt
        case .painting(let prompt, _, _): return prompt
        case .failed(let prompt, _): return prompt
        }
    }

    public var failure: String? {
        if case .failed(_, let reason) = phase { return reason }
        return nil
    }

    public var hint: String {
        switch mode {
        case .generate: return Localized.text("Words to paint from")
        case .edit: return Localized.text("What to change, and what to keep")
        }
    }

    /// Whether the machine, as last seen, can run the engine chosen. Nil when nobody has looked:
    /// a machine nobody has asked is not refused, it is tried.
    public func engineAvailable(given sighting: ImageGenSighting?) -> Bool? {
        guard let sighting, sighting.reachable else { return nil }
        return sighting.available(engine)
    }

    /// One line for the identity strip: what this slot is right now.
    public var title: String {
        switch phase {
        case .asking: return ImageGenEntryPoint.title
        case .composing(let prompt):
            return prompt.isEmpty ? ImageGenEntryPoint.title : prompt.ellipsized(to: 42)
        case .painting(let prompt, let engine, _):
            return Localized.text("%@ · %@", engine.short, prompt.ellipsized(to: 38))
        case .failed(let prompt, _):
            return prompt.ellipsized(to: 46)
        }
    }

    /// What a chip wears for one decision, so a strip of them is filled from the slot rather than
    /// from three separate readings a client keeps in step by hand.
    public func value(of field: ImageGenField) -> String {
        switch field {
        case .engine: return engine.short
        case .aspect: return aspect.short
        }
    }

    /// Walks one decision to its next value. Three short lists, so a press is the whole gesture.
    public mutating func advance(_ field: ImageGenField) {
        switch field {
        case .engine: engine = Self.next(engine)
        case .aspect: aspect = Self.next(aspect)
        }
    }

    private static func next<Value: CaseIterable & Equatable>(_ value: Value) -> Value {
        let all = Array(Value.allCases)
        guard let index = all.firstIndex(of: value) else { return value }
        return all[(index + 1) % all.count]
    }

    public mutating func setEngine(_ engine: ImageGenEngine) { self.engine = engine }
    public mutating func setAspect(_ aspect: ImageGenAspect) { self.aspect = aspect }
    /// Attaches or lets go of the picture the next render works from, which is also how the mode
    /// is set — there is no third thing to keep in step.
    public mutating func hold(_ reference: ImageGenReference?) { self.reference = reference }

    /// Puts one of the pictures already made on the stage. A path this slot never made is
    /// ignored rather than blanking the stage.
    public mutating func show(_ path: String?) {
        guard let path else {
            selected = nil
            return
        }
        guard pictures.contains(where: { $0.path == path }) else { return }
        selected = path
    }

    public mutating func begin(prompt: String) {
        promptDraft = prompt
        phase = .painting(prompt: prompt, engine: engine, mode: mode)
    }

    /// A finished picture takes the stage: it is the thing that was just asked for, and a person
    /// who then chooses an older one is choosing against it rather than being overruled by it.
    public mutating func finish(_ picture: ImageGenPicture) {
        pictures.insert(picture, at: 0)
        selected = picture.path
        phase = .composing(prompt: picture.prompt)
        promptDraft = picture.prompt
    }

    /// Lets go of one picture. The stage falls back to the newest rather than going blank.
    public mutating func discard(_ path: String) {
        pictures.removeAll { $0.path == path }
        if selected == path { selected = pictures.first?.path }
    }

    public mutating func fail(prompt: String, reason: String) {
        phase = .failed(prompt: prompt, reason: reason)
    }

    /// Back to blank: nothing chosen, no reference, no words, and a failure put away. A render in
    /// flight is left exactly as it is — this clears a stage, it does not stop a machine.
    public mutating func clearStage() {
        selected = nil
        reference = nil
        promptDraft = ""
        if case .painting = phase { return }
        phase = .asking
    }
}

extension ImageGenSlot {
    /// What the stage says instead of a picture while one is being made: which editor is at work
    /// and which of the two things it is doing.
    public var busyLine: String {
        if case .painting(_, let engine, let mode) = phase {
            let verb = mode == .edit ? Localized.text("editing") : Localized.text("painting")
            return Localized.text("%@ · %@", engine.label, verb)
        }
        return ""
    }

    /// The same line with the wait on the end of it: what the machine says it is doing when it has
    /// said, else which editor is at work, and how long this has been going either way — one
    /// second is the whole resolution a wait like this needs.
    public func waitingLine(
        since started: Date?, progress: ImageGenProgress? = nil, now: Date = Date()
    ) -> String {
        let lead = progress?.line ?? busyLine
        guard let started else { return lead }
        let seconds = Int(now.timeIntervalSince(started).rounded())
        return Localized.text("%@ · %@s", lead, "\(max(0, seconds))")
    }
}

/// What the machine is doing to a render right now, read off its own socket rather than guessed.
/// ComfyUI announces each node as it starts and the sampler's step as it goes; a client that only
/// polled history saw done or nothing. The words are Core's so every desk narrates the same wait.
public struct ImageGenProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        /// Accepted and waiting its turn behind this many other renders.
        case queued(ahead: Int)
        case sendingReference
        case loading
        case reading
        case encoding
        case painting
        case decoding
        case saving
    }

    public var stage: Stage
    public var step: Int?
    public var steps: Int?
    /// How far through the whole graph, counted in nodes — the honest bar, because the sampler's
    /// step counter is one node's business.
    public var fraction: Double?

    public init(stage: Stage, step: Int? = nil, steps: Int? = nil, fraction: Double? = nil) {
        self.stage = stage
        self.step = step
        self.steps = steps
        self.fraction = fraction
    }

    /// Which stage a graph node belongs to, from its class. A class this table has never heard of
    /// leaves the stage where it was rather than inventing one.
    public static func stage(forNodeClass type: String) -> Stage? {
        switch type {
        case "UNETLoader", "CLIPLoader", "VAELoader", "CheckpointLoaderSimple",
            "ModelSamplingAuraFlow", "CFGNorm", "UnetLoaderGGUF":
            return .loading
        case "LoadImage", "FluxKontextImageScale", "ImageScaleToTotalPixels", "GetImageSize",
            "VAEEncode":
            return .reading
        case "CLIPTextEncode", "TextEncodeQwenImageEditPlus", "ConditioningZeroOut",
            "ReferenceLatent", "FluxKontextMultiReferenceLatentMethod", "EmptySD3LatentImage",
            "EmptyFlux2LatentImage", "Flux2Scheduler", "CFGGuider", "RandomNoise",
            "KSamplerSelect":
            return .encoding
        case "KSampler", "KSamplerAdvanced", "SamplerCustomAdvanced", "SamplerCustom":
            return .painting
        case "VAEDecode": return .decoding
        case "SaveImage", "PreviewImage": return .saving
        default: return nil
        }
    }

    public var line: String {
        switch stage {
        case .queued(let ahead):
            if ahead <= 0 { return Localized.text("Waiting for the machine") }
            return ahead == 1
                ? Localized.text("Behind 1 other render")
                : Localized.text("Behind %@ other renders", "\(ahead)")
        case .sendingReference: return Localized.text("Sending the reference")
        case .loading: return Localized.text("Loading the model")
        case .reading: return Localized.text("Reading the reference")
        case .encoding: return Localized.text("Reading the words")
        case .painting:
            if let step, let steps, steps > 0 {
                return Localized.text("Painting · step %@ of %@", "\(min(step, steps))", "\(steps)")
            }
            return Localized.text("Painting")
        case .decoding: return Localized.text("Decoding the picture")
        case .saving: return Localized.text("Saving")
        }
    }

    /// A bar is drawn only once there is a count to draw it from; before that the wait is words and
    /// a clock, never a bar sitting at zero.
    public var bar: Double? {
        if case .painting = stage, let step, let steps, steps > 0 {
            return min(1, max(0, Double(step) / Double(steps)))
        }
        return nil
    }
}

extension String {
    /// Cut for a strip that must stay one line, on a word boundary where there is one.
    public func ellipsized(to limit: Int) -> String {
        guard count > limit else { return self }
        let cut = prefix(limit)
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) + "…" }
        return cut + "…"
    }
}
/// What a finished picture can be made to do. These are the reason the surface is a place rather
/// than a button: a render that lands and then needs a file manager, a browser and a terminal to
/// be worth anything is a render nobody keeps.
///
/// The order is the order a hand reaches for them — the two that get the picture out of the app
/// first, then the ones that make another, then the one that throws it away.
public enum ImageGenAction: String, Sendable, Equatable, CaseIterable {
    case save
    case share
    case copy
    case open
    case again
    case reference
    case discard
    /// Put the picture on the stage without opening it — a deliberate choice, offered where a
    /// tap opens the picture instead so that tapping never decides what the next render is about.
    case stage

    public var title: String {
        switch self {
        case .save: return Localized.text("Save…")
        case .share: return Localized.text("Share")
        case .copy: return Localized.text("Copy")
        case .open: return Localized.text("Open")
        case .again: return Localized.text("Again")
        case .reference: return Localized.text("Use as reference")
        case .discard: return Localized.text("Discard")
        case .stage: return Localized.text("Show on stage")
        }
    }

    /// The same verb on a phone, where saving means the photo library and the sheet says where
    /// else a picture can go.
    public var phoneTitle: String {
        switch self {
        case .save: return Localized.text("Save")
        case .reference: return Localized.text("Edit this")
        default: return title
        }
    }

    public var symbol: String {
        switch self {
        case .save: return "square.and.arrow.down"
        case .share: return "square.and.arrow.up"
        case .copy: return "doc.on.doc"
        case .open: return "arrow.up.left.and.arrow.down.right"
        case .again: return "arrow.triangle.2.circlepath"
        case .reference: return "photo.badge.plus"
        case .discard: return "trash"
        case .stage: return "rectangle.stack"
        }
    }

    public var glyph: String {
        switch self {
        case .save: return "↓"
        case .share: return "↗"
        case .copy: return "⧉"
        case .open: return "⤢"
        case .again: return "↻"
        case .reference: return "+"
        case .discard: return "✕"
        case .stage: return "◧"
        }
    }

    /// What the control promises before it is pressed, which is the whole difference between a
    /// row of icons and a row of verbs somebody can trust.
    public var hint: String {
        switch self {
        case .save: return Localized.text("Write the picture somewhere of your own")
        case .share: return Localized.text("Hand the picture to another app or person")
        case .copy: return Localized.text("Put the picture on the clipboard")
        case .open: return Localized.text("See it at full size")
        case .again: return Localized.text("Same words, another roll of the dice")
        case .reference: return Localized.text("Start the next render from this picture")
        case .discard: return Localized.text("Let go of this one")
        case .stage: return Localized.text("Put this picture on the stage without opening it")
        }
    }

    /// The one action that destroys something, which a client draws differently and never puts
    /// under a hand reaching for the ones beside it.
    public var isDestructive: Bool { self == .discard }

    /// Everything worth offering for a picture made this session on a desk with no share sheet.
    public static var forPicture: [ImageGenAction] {
        allCases.filter { $0 != .share && $0 != .stage }
    }

    /// What a picture can be made to do, decided by what it is and where it is shown. A picture
    /// the machine keeps has no words to roll again unless its file recorded them, and cannot be
    /// discarded from a folder this app does not own; a phone shares through a sheet and opens by a
    /// tap, so neither is a button in its bar.
    public static func offered(
        kept: Bool, hasWords: Bool, sharing: Bool, tapOpens: Bool
    ) -> [ImageGenAction] {
        var actions: [ImageGenAction] = [.save]
        if sharing { actions.append(.share) }
        actions.append(.copy)
        if !tapOpens { actions.append(.open) }
        if hasWords { actions.append(.again) }
        actions.append(.reference)
        if !kept { actions.append(.discard) }
        return actions
    }
}

/// Where a reference can come from, in the order a hand reaches: the pictures already on the
/// device, the camera, the file system, whatever was last copied, and the machine's own gallery.
/// A client offers the ones its platform has.
public enum ImageGenReferenceSource: String, Sendable, Equatable, CaseIterable {
    case photos
    case camera
    case files
    case clipboard
    case library

    public var title: String {
        switch self {
        case .photos: return Localized.text("Photo Library")
        case .camera: return Localized.text("Take a Photo")
        case .files: return Localized.text("Choose a File")
        case .clipboard: return Localized.text("Paste")
        case .library: return Localized.text("From the Library")
        }
    }

    public var symbol: String {
        switch self {
        case .photos: return "photo.on.rectangle"
        case .camera: return "camera"
        case .files: return "folder"
        case .clipboard: return "doc.on.clipboard"
        case .library: return "photo.stack"
        }
    }
}

/// What a picture cost and what made it, said as facts rather than as a caption. The words are
/// Core's so a Mac, a phone and a GTK pane cannot each round the seconds differently.
public enum ImageGenFacts {
    public static func line(for picture: ImageGenPicture) -> String {
        let seconds =
            picture.seconds < 10
            ? String(format: "%.1f s", picture.seconds)
            : "\(Int(picture.seconds.rounded())) s"
        return [picture.engine.short, picture.aspect.label, seconds, seedMark(picture.seed)]
            .joined(separator: " · ")
    }

    /// A seed is twenty digits and a fact line is one line. What a person does with a seed is
    /// recognise it and copy it whole from the viewer, so the mark shows both ends rather than
    /// spending the row on the middle.
    public static func seedMark(_ seed: UInt64) -> String {
        let digits = "\(seed)"
        guard digits.count > 12 else { return "#" + digits }
        return "#\(digits.prefix(4))…\(digits.suffix(4))"
    }

    /// The words that made it, which is the one thing worth reading before the facts.
    public static func caption(for picture: ImageGenPicture) -> String { picture.prompt }

    /// The same two lines for a picture the machine keeps, read from its file rather than from a
    /// render this device remembers: what is known is said and what is not is left out, so a
    /// foreign file reads as its size and its day rather than as a row of zeros.
    public static func caption(for facts: ImageGenLibraryFacts?) -> String {
        guard let words = facts?.recipe?.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
            !words.isEmpty
        else { return ImageGenLibraryWords.noWords }
        return words
    }

    public static func line(for facts: ImageGenLibraryFacts?, now: Date = Date()) -> String {
        guard let facts else { return "" }
        var parts: [String] = []
        if let engine = facts.recipe?.engine {
            parts.append(engine.short)
        } else if let model = facts.recipe?.model {
            parts.append((model as NSString).deletingPathExtension)
        }
        if let dimensions = facts.dimensions { parts.append(dimensions) }
        if let steps = facts.recipe?.steps { parts.append(Localized.text("%@ steps", "\(steps)")) }
        if let seed = facts.recipe?.seed { parts.append(seedMark(seed)) }
        if let date = facts.modifiedAt { parts.append(ImageGenLibraryWords.day(date, now: now)) }
        return parts.joined(separator: " · ")
    }

    /// A file's size in the unit a person reads it in.
    public static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// A name to offer the desktop's save dialog: the words, made into a filename, so a folder of
    /// these reads as what they are rather than as a row of timestamps.
    public static func fileName(for picture: ImageGenPicture) -> String {
        let allowed = picture.prompt.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let squashed = String(allowed).split(separator: "-").prefix(6).joined(separator: "-")
        let stem = squashed.isEmpty ? "image" : squashed
        return "\(stem).png"
    }
}

/// Every word the image surface says that is not a field, an action or a fact. Held here so a
/// client draws a studio rather than inventing one.
public enum ImageGenWords {
    /// The button that starts a render, which says which of the two things it is about to do.
    public static func renderTitle(mode: ImageGenMode) -> String {
        mode == .edit ? Localized.text("Edit") : Localized.text("Generate")
    }

    public static var stopTitle: String { Localized.text("Stop") }

    public static var attachTitle: String { Localized.text("Add a reference") }

    /// What the attached picture's chip promises when it is let go of.
    public static var detachHint: String { Localized.text("Render from words alone again") }

    public static func referenceHint(_ reference: ImageGenReference) -> String {
        Localized.text("Editing %@ — the next render starts from it", reference.name)
    }

    /// The empty stage, which argues for itself rather than showing a grey rectangle.
    public static var emptyTitle: String { Localized.text("Nothing painted yet") }

    public static var emptyBody: String {
        Localized.text("Describe a picture below. It is painted on the machine with the card.")
    }

    /// What the strip of everything made so far is called once there is more than one.
    public static func historyTitle(count: Int) -> String {
        count == 1
            ? Localized.text("1 picture this session")
            : Localized.text("%@ pictures this session", "\(count)")
    }

    public static func savedNotice(path: String) -> String {
        Localized.text("Saved to %@", path)
    }

    public static var copiedNotice: String { Localized.text("Picture copied") }

    /// The way back out of full size, said in the surface rather than left to be guessed — a
    /// picture filling the room has hidden every other control, so the one that returns is the
    /// one thing that has to still be legible.
    public static var zoomHint: String {
        Localized.text("Click the picture or press Esc to go back")
    }

    public static var discardNotice: String { Localized.text("Picture let go of") }

    /// Why the aspect chip is not offered while a reference is held.
    public static var aspectFollowsReference: String {
        Localized.text("Size follows the reference")
    }

    public static var replaceReference: String { Localized.text("Replace…") }

    public static var removeReference: String { Localized.text("Remove") }

    /// The engine chip's own note when the machine, as last seen, lacks that engine's files.
    public static func engineUnavailable(_ engine: ImageGenEngine, missing: Int) -> String {
        missing == 1
            ? Localized.text("%@ is missing 1 of its model files", engine.label)
            : Localized.text("%@ is missing %@ of its model files", engine.label, "\(missing)")
    }

    /// What the render button says when it cannot honestly start: the engine's files are not on
    /// the machine, said before a queue error would have said it worse.
    public static func cannotRender(engine: ImageGenEngine, machine: String) -> String {
        Localized.text(
            "%@ is not set up for %@ — its model files are missing. Choose the other engine or add the files.",
            machine, engine.label)
    }

    public static var stoppedNotice: String { Localized.text("Stopped") }

    /// The picture on the stage is one the machine kept rather than one made here: said once, under
    /// the facts, so a reader knows the words came from the file.
    public static var keptNote: String { ImageGenLibraryWords.fromLibraryHint }

    public static var stageEmptyKept: String {
        Localized.text(
            "Describe a picture below, or press and hold one on the shelf to start from it.")
    }

    /// The one control that takes the studio back to blank: the stage, the reference, a failure
    /// and the words all go; the pictures stay on the shelf and in the session.
    public static var startOver: String { Localized.text("Start over") }

    public static var startOverHint: String {
        Localized.text("Clear the stage, the reference and the words. Every picture stays on the shelf.")
    }
}

/// The machine sheet: everything the picture machine has said about itself, on one surface, with
/// the two things a person does there — look again, and point somewhere else. Every word is here so
/// a phone and a desk describe the same machine the same way.
public enum ImageGenMachineWords {
    public static var title: String { Localized.text("Machine") }

    public static var addressLabel: String { Localized.text("Address") }

    public static var versionLabel: String { Localized.text("ComfyUI") }

    public static var checkedLabel: String { Localized.text("Last checked") }

    public static var queueLabel: String { Localized.text("Queue") }

    public static var modelsTitle: String { Localized.text("Model files") }

    public static var checkAgain: String { Localized.text("Check again") }

    public static var checking: String { Localized.text("Checking…") }

    public static var change: String { Localized.text("Change machine…") }

    public static var neverChecked: String { Localized.text("Not checked yet") }

    public static var inherited: String {
        Localized.text("Shared with the video renderer — one ComfyUI holds both sets of models.")
    }

    public static func queue(running: Int) -> String {
        switch running {
        case 0: return Localized.text("Idle")
        case 1: return Localized.text("1 render running")
        default: return Localized.text("%@ renders running", "\(running)")
        }
    }

    public static var present: String { Localized.text("Present") }

    public static var missing: String { Localized.text("Missing") }

    public static var unknown: String { Localized.text("Unknown") }

    /// One sentence for the whole machine, which is what a header wears.
    public static func summary(_ sighting: ImageGenSighting?) -> String {
        guard let sighting else { return neverChecked }
        guard sighting.reachable else { return Localized.text("Not answering when last checked") }
        let ready = ImageGenEngine.allCases.filter(sighting.available)
        switch ready.count {
        case ImageGenEngine.allCases.count: return Localized.text("Ready · both engines")
        case 0: return Localized.text("Answering, but no engine has all its files")
        default:
            return Localized.text(
                "Ready for %@ only", ready.map(\.label).joined(separator: ", "))
        }
    }
}
