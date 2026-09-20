import Foundation

/// How much picture is asked for, in megapixels rather than in a pair of numbers nobody wants to
/// choose. The model paints natively at 2K, so the middle rung is the one it was trained for and
/// the top rung is what it can actually do rather than an upscale.
public enum ImageGenSize: String, Codable, Sendable, CaseIterable {
    case quick
    case standard
    case large

    /// The pixel budget the two sides are fitted into, preserving the ratio.
    public var megapixels: Double {
        switch self {
        case .quick: return 1.0
        case .standard: return 2.0
        // 2048 × 2048 exactly, which is the square the model calls native 2K rather than a
        // round number of megapixels that lands 32 pixels short of it.
        case .large: return 4.2
        }
    }

    public var short: String {
        switch self {
        case .quick: return Localized.text("1 MP")
        case .standard: return Localized.text("2 MP")
        case .large: return Localized.text("2K")
        }
    }

    public var title: String {
        switch self {
        case .quick: return Localized.text("Quick")
        case .standard: return Localized.text("Standard")
        case .large: return Localized.text("Large")
        }
    }

    /// What the rung costs, said as the thing a person is actually trading away.
    public var detail: String {
        switch self {
        case .quick: return Localized.text("Fastest, good for trying words out")
        case .standard: return Localized.text("What the model paints natively")
        case .large: return Localized.text("Native 2K · roughly three times the wait")
        }
    }
}

/// How long the sampler is given. The fast engine is distilled to four steps and ignores this
/// entirely, which is why the chip is not offered beside it.
public enum ImageGenDetail: String, Codable, Sendable, CaseIterable {
    case draft
    case standard
    case fine

    public var steps: Int {
        switch self {
        case .draft: return 15
        case .standard: return 25
        case .fine: return 40
        }
    }

    public var short: String {
        switch self {
        case .draft: return Localized.text("Draft")
        case .standard: return Localized.text("Standard")
        case .fine: return Localized.text("Fine")
        }
    }

    public var detail: String {
        switch self {
        case .draft: return Localized.text("15 steps · rough, quick")
        case .standard: return Localized.text("25 steps · what the model ships with")
        case .fine: return Localized.text("40 steps · slower, steadier detail")
        }
    }
}

/// Which number the next render starts its noise from. Rolling is the default because two rolls
/// of the same words are the point; holding one is how a person changes one word and sees only
/// that word change.
public struct ImageGenSeed: Sendable, Equatable, Codable {
    /// Set while the seed is held. Nil means every render rolls a fresh one.
    public var held: UInt64?
    /// What the last render actually used, held or rolled, so a person can grab it afterwards.
    public var last: UInt64?

    public init(held: UInt64? = nil, last: UInt64? = nil) {
        self.held = held
        self.last = last
    }

    public var isHeld: Bool { held != nil }

    /// The number the next render runs on, and the record of it. Random is a real roll rather
    /// than a hash of the words: the same words twice is exactly the case that must differ.
    public mutating func next() -> UInt64 {
        let seed = held ?? UInt64.random(in: 0...0xFFFF_FFFF)
        last = seed
        return seed
    }

    /// Holds whatever the last render used, which is the gesture a person actually makes: they
    /// liked that one, and now they want to change one word against it.
    public mutating func hold() {
        guard let last else { return }
        held = last
    }

    public mutating func release() { held = nil }

    /// Short enough for a chip: held numbers are shown, a rolling seed says so.
    public var chip: String {
        guard let held else { return Localized.text("Seed rolls") }
        return Localized.text("Seed %@", Self.short(held))
    }

    public static func short(_ seed: UInt64) -> String {
        let text = "\(seed)"
        guard text.count > 8 else { return text }
        return String(text.prefix(4)) + "…" + String(text.suffix(4))
    }
}

/// Everything one render is: the words, what it must avoid, the shape, the size, how long the
/// sampler runs, the pictures it works from and the seed. The graph is built from this rather
/// than from a parameter list that grows by one every time the studio learns something.
public struct ImageGenRecipe: Sendable, Equatable {
    public var prompt: String
    public var negative: String
    public var engine: ImageGenEngine
    public var mode: ImageGenMode
    public var aspect: ImageGenAspect
    public var size: ImageGenSize
    public var detail: ImageGenDetail
    public var seed: UInt64
    /// What the machine calls each picture this render works from, in the order the prompt
    /// addresses them: the first is `<image1>`.
    public var references: [String]
    /// Whether the picture comes back on transparency rather than on a background.
    public var cutout: Bool

    public init(
        prompt: String, negative: String = "", engine: ImageGenEngine = .quality,
        mode: ImageGenMode = .generate, aspect: ImageGenAspect = .square,
        size: ImageGenSize = .standard, detail: ImageGenDetail = .standard, seed: UInt64 = 0,
        references: [String] = [], cutout: Bool = false
    ) {
        self.prompt = prompt
        self.negative = negative
        self.engine = engine
        self.mode = mode
        self.aspect = aspect
        self.size = size
        self.detail = detail
        self.seed = seed
        self.references = references
        self.cutout = cutout
    }

    /// The sentence the model was taught to read as "give this one an alpha channel". It is part
    /// of the words rather than a switch on the graph, which is why the studio writes it here
    /// once instead of asking every person to remember it.
    public static let cutoutPreamble = "This is an RGBA image with transparency. "
    public static let cutoutCoda =
        " The image has alpha channel and the background is transparent."

    /// Only the quality engine paints on transparency and only it reads a long negative, so the
    /// two switches quietly do nothing beside the fast one rather than lying about it.
    public var cutoutApplies: Bool { engine == .quality }
    public var detailApplies: Bool { engine == .quality }
    public var negativeApplies: Bool { engine == .quality }

    /// What the text encoder is actually given.
    public var words: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cutout, cutoutApplies, !trimmed.isEmpty else { return trimmed }
        guard !trimmed.lowercased().contains("rgba") else { return trimmed }
        return Self.cutoutPreamble + trimmed + Self.cutoutCoda
    }

    public var avoids: String {
        guard negativeApplies else { return "" }
        return negative.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Guidance follows whether anything is being avoided. At 1.0 the sampler never looks at the
    /// negative branch at all, so an avoid list at 1.0 would be a box that does nothing; raising
    /// it is what makes the words count, and it costs the second pass to do it.
    public var guidance: Double { avoids.isEmpty ? 1.0 : 2.5 }

    public var steps: Int {
        switch engine {
        case .quality: return detail.steps
        case .fast: return 4
        }
    }

    /// An edit takes its shape from the picture it starts from, so the size chips only decide a
    /// painting's frame.
    public var pixels: (width: Int, height: Int) { aspect.pixels(size) }
}

extension ImageGenAspect {
    /// The two sides fitted to a pixel budget, each rounded to the multiple of 32 the sampler
    /// wants. The ratio survives the rounding, which is why this is arithmetic rather than a
    /// table of hand-picked pairs that drift apart as sizes are added.
    public func pixels(_ size: ImageGenSize) -> (width: Int, height: Int) {
        let ratio = Double(self.ratio.width) / Double(self.ratio.height)
        let budget = size.megapixels * 1_000_000
        let width = Self.rounded(sqrt(budget * ratio))
        let height = Self.rounded(sqrt(budget / ratio))
        return (width, height)
    }

    static func rounded(_ value: Double) -> Int {
        max(256, Int((value / 32).rounded()) * 32)
    }

    /// What the chip says when the size matters too: the shape, then the budget.
    public func label(_ size: ImageGenSize) -> String {
        let pixels = self.pixels(size)
        return "\(pixels.width)×\(pixels.height)"
    }
}
