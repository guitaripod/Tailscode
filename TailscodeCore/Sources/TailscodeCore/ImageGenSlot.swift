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

    public var forgeEndpoint: ForgeEndpoint { ForgeEndpoint(host: host, port: port) }

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
    /// The pixel budget it was painted at, so the fact line can say the frame rather than the
    /// shape. Older records carry none and read as the size the model paints natively.
    public var size: ImageGenSize
    public let seconds: Double
    public let seed: UInt64
    /// How long the sampler ran, when this app was the one that asked.
    public var steps: Int?
    public let madeAt: Date
    /// What the machine called the file it wrote, so the picture can be found again in the
    /// machine's own gallery — a render made here is the newest thing in it.
    public var remoteName: String?

    public init(
        path: String, prompt: String, engine: ImageGenEngine, mode: ImageGenMode,
        aspect: ImageGenAspect, size: ImageGenSize = .standard, seconds: Double, seed: UInt64,
        steps: Int? = nil, madeAt: Date = Date(), remoteName: String? = nil
    ) {
        self.path = path
        self.prompt = prompt
        self.engine = engine
        self.mode = mode
        self.aspect = aspect
        self.size = size
        self.seconds = seconds
        self.seed = seed
        self.steps = steps
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
    case size
    case detail
    case cutout
    case seed
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
            case "u": return .size
            case "d": return .detail
            case "k": return .cutout
            case "j": return .seed
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
    /// How many pixels the shape is filled with, held apart from the shape itself.
    public var size: ImageGenSize
    /// How long the sampler runs, where the engine reads it at all.
    public var detail: ImageGenDetail
    /// What the render must keep out of the picture. Empty is the ordinary case, and an empty
    /// list is why guidance stays at 1.0 and a render stays fast.
    public var negative: String
    /// Whether the next render rolls a number or reuses the one being held.
    public var seed: ImageGenSeed
    /// Whether the picture comes back on transparency rather than on a background.
    public var cutout: Bool
    /// The pictures the next render works from, in the order the words address them. Empty is a
    /// painting from words; one or more is an edit, and nobody is ever asked which.
    public var references: [ImageGenReference]
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
        aspect: ImageGenAspect = .square, size: ImageGenSize = .standard,
        detail: ImageGenDetail = .standard
    ) {
        self.endpoint = endpoint
        self.phase = .asking
        self.engine = engine
        self.aspect = aspect
        self.size = size
        self.detail = detail
        self.negative = ""
        self.seed = ImageGenSeed()
        self.cutout = false
        self.references = []
        self.promptDraft = ""
        self.pictures = []
    }

    /// The single picture the older surfaces know about: the first of the references, which is
    /// the one the words call `<image1>`.
    public var reference: ImageGenReference? {
        get { references.first }
        set { references = newValue.map { [$0] } ?? [] }
    }

    /// How many pictures one render may work from. The encoder grows a slot per reference and
    /// the model was trained up to sixteen; beyond that the graph would be lying.
    public static let referenceLimit = 16

    /// Read rather than chosen: a render that has a picture to work from is an edit, and one
    /// that does not is a generate. Nobody is ever asked which.
    public var mode: ImageGenMode { references.isEmpty ? .generate : .edit }

    /// Whether the aspect chip means anything right now. An edit takes its size from the picture
    /// it starts from — both editors scale the reference and paint at that size — so while one is
    /// held the chip is a setting with no effect, and a chip with no effect is not shown as one.
    public var aspectApplies: Bool { references.isEmpty }

    /// Whether a decision means anything given what else is chosen, so a surface can offer only
    /// the chips that would change the next picture and never a dead one.
    public func applies(_ field: ImageGenField) -> Bool {
        switch field {
        case .engine: return true
        case .aspect, .size: return aspectApplies
        case .detail: return engine == .quality
        }
    }

    /// Whether painting on transparency is on the table: the Qwen engines share a VAE that keeps
    /// an alpha channel, and the fast engine's does not.
    public var cutoutApplies: Bool { engine != .fast }

    /// Whether an avoid list would be read. Guidance rises to make it count, which the fast and
    /// turbo engines' distilled steps cannot afford.
    public var negativeApplies: Bool { engine == .quality }

    /// Everything the next render is, gathered in one place so a client hands the runner a
    /// recipe rather than eight arguments it has to keep in step by hand.
    public func recipe(prompt: String, seed: UInt64) -> ImageGenRecipe {
        ImageGenRecipe(
            prompt: prompt, negative: negative, engine: engine, mode: mode, aspect: aspect,
            size: size, detail: detail, seed: seed,
            references: references.compactMap { $0.machineName ?? $0.name }, cutout: cutout)
    }

    /// What the prompt helper is told beside the brief. `aspectChosen` says whether the shape
    /// was picked by hand this session — a chosen shape is kept, an inherited one is the helper's
    /// to improve on; an edit takes its shape from the picture either way.
    public func rewriteContext(
        aspectChosen: Bool, instruction: String? = nil, previous: String? = nil
    ) -> ImageGenRewriteContext {
        ImageGenRewriteContext(
            engine: engine, aspect: aspectChosen && aspectApplies ? aspect : nil,
            referenceCount: references.count, negative: negativeApplies ? negative : "",
            instruction: instruction, previous: previous)
    }

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
        case .size: return size.short
        case .detail: return detail.short
        }
    }

    /// Walks one decision to its next value. Three short lists, so a press is the whole gesture.
    public mutating func advance(_ field: ImageGenField) {
        switch field {
        case .engine: engine = Self.next(engine)
        case .aspect: aspect = Self.next(aspect)
        case .size: size = Self.next(size)
        case .detail: detail = Self.next(detail)
        }
    }

    private static func next<Value: CaseIterable & Equatable>(_ value: Value) -> Value {
        let all = Array(Value.allCases)
        guard let index = all.firstIndex(of: value) else { return value }
        return all[(index + 1) % all.count]
    }

    public mutating func setEngine(_ engine: ImageGenEngine) { self.engine = engine }
    public mutating func setAspect(_ aspect: ImageGenAspect) { self.aspect = aspect }
    public mutating func setSize(_ size: ImageGenSize) { self.size = size }
    public mutating func setDetail(_ detail: ImageGenDetail) { self.detail = detail }
    public mutating func setNegative(_ words: String) { self.negative = words }
    public mutating func setCutout(_ on: Bool) { self.cutout = on }

    /// Adds one more picture for the render to work from, up to what the encoder can hold. The
    /// same picture twice is one picture: a slot that already has it moves nothing.
    public mutating func attach(_ reference: ImageGenReference) {
        guard references.count < Self.referenceLimit else { return }
        guard !references.contains(where: { $0.path == reference.path }) else { return }
        references.append(reference)
    }

    public mutating func release(_ path: String) {
        references.removeAll { $0.path == path }
    }

    public mutating func releaseAllReferences() { references = [] }
    /// Attaches or lets go of the picture the next render works from, which is also how the mode
    /// is set — there is no third thing to keep in step.
    public mutating func hold(_ reference: ImageGenReference?) { self.reference = reference }

    /// Holds the seed the last render used, so the next one changes only what the words changed.
    public mutating func holdSeed() { seed.hold() }

    public mutating func releaseSeed() { seed.release() }

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
        references = []
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
