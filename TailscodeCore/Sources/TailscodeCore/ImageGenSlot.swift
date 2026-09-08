import Foundation

/// What a draw slot is pointed at: the machine that renders, plus the shape of the ask.
/// Like `VideoTarget`, a slot's whole state survives a restart, so every part is a small
/// persistable value.
public struct ImageGenEndpoint: Sendable, Equatable, Codable {
    /// Base address of the ComfyUI API, e.g. `http://127.0.0.1:8189`.
    public let address: String

    public init(address: String) {
        self.address = address.hasSuffix("/") ? String(address.dropLast()) : address
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

/// Whether the slot paints from words alone or from a picture the person handed it.
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

    public init(
        path: String, prompt: String, engine: ImageGenEngine, mode: ImageGenMode,
        aspect: ImageGenAspect, seconds: Double, seed: UInt64, madeAt: Date = Date()
    ) {
        self.path = path
        self.prompt = prompt
        self.engine = engine
        self.mode = mode
        self.aspect = aspect
        self.seconds = seconds
        self.seed = seed
        self.madeAt = madeAt
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// What a keystroke means inside a draw slot, shared so both desktops answer the same keys and
/// the headless drivers can name a verb instead of a keycode.
public enum ImageGenCommand: Sendable, Equatable {
    case submit
    case engine
    case aspect
    case mode
    case bigger
    case smaller
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
            case "m": return .mode
            case "o": return ImageGenCommand.open
            case "]": return .next
            case "[": return .previous
            default: break
            }
        }
        if chord.keyval == Keymap.enter { return .submit }
        return nil
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

    public static let offlineBody = Localized.text(
        "ComfyUI is not answering at")
}

/// Where the store's model files live, checked before a request is queued — a server that is up
/// but half-configured gets to say so rather than fail with a queue error nobody can read.
public struct ImageGenHealth: Sendable, Equatable {
    public let reachable: Bool
    public let missingModels: [String]
    public let version: String?

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
    public var mode: ImageGenMode
    public var promptDraft: String
    /// The session's finished pictures, newest first. A slot keeps its own history: a picture is
    /// a thing you compare against the words that made it, not a thing you overwrite.
    public var pictures: [ImageGenPicture]
    /// Bytes of the newest picture, held by the client — not part of equality, not persisted.
    public var transient: [String: String]?

    public init(
        endpoint: ImageGenEndpoint, engine: ImageGenEngine = .quality,
        aspect: ImageGenAspect = .square, mode: ImageGenMode = .generate
    ) {
        self.endpoint = endpoint
        self.phase = .asking
        self.engine = engine
        self.aspect = aspect
        self.mode = mode
        self.promptDraft = ""
        self.pictures = []
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

    /// One line for the identity strip: what this slot is right now.
    public var title: String {
        switch phase {
        case .asking: return Localized.text("Draw")
        case .composing(let prompt):
            return prompt.isEmpty ? Localized.text("Draw") : prompt.ellipsized(to: 42)
        case .painting(let prompt, let engine, _):
            return Localized.text("%@ · %@", engine.short, prompt.ellipsized(to: 38))
        case .failed(let prompt, _):
            return prompt.ellipsized(to: 46)
        }
    }

    public mutating func setEngine(_ engine: ImageGenEngine) { self.engine = engine }
    public mutating func setAspect(_ aspect: ImageGenAspect) { self.aspect = aspect }
    public mutating func setMode(_ mode: ImageGenMode) { self.mode = mode }

    public mutating func begin(prompt: String) {
        promptDraft = prompt
        phase = .painting(prompt: prompt, engine: engine, mode: mode)
    }

    public mutating func finish(_ picture: ImageGenPicture) {
        pictures.insert(picture, at: 0)
        phase = .composing(prompt: picture.prompt)
        promptDraft = picture.prompt
    }

    public mutating func fail(prompt: String, reason: String) {
        phase = .failed(prompt: prompt, reason: reason)
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