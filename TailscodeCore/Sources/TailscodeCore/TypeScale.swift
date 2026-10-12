import Foundation

/// A part of the window whose type a person can make bigger or smaller on its own.
///
/// Type size is not one number: the reason to enlarge what the agent writes (reading) is not the
/// reason to enlarge a sidebar (glancing), what you typed is yours to size apart from what came
/// back, and code that rewraps is worse than code that stays put. So the type ramp's three axes
/// become five areas — the prose axis split into the two voices of a conversation — and the
/// terminal under the conversation is its own because it is a shell's font and answers to nothing
/// else.
public enum TypeArea: String, CaseIterable, Sendable {
    case chrome
    case prompt
    case answer
    case mono
    case terminal

    public init(axis: TypeAxis) {
        switch axis {
        case .chrome: self = .chrome
        case .prose: self = .answer
        case .mono: self = .mono
        }
    }

    /// The area a role is set in: what a person types is theirs, and everything else follows the
    /// axis it was written on.
    public init(role: TypeRole) {
        switch role {
        case .prompt, .promptGlyph, .composer: self = .prompt
        default: self = TypeArea(axis: Typography.spec(role).axis)
        }
    }

    public var title: String {
        switch self {
        case .chrome: return Localized.text("Chat list and pills")
        case .prompt: return Localized.text("Your messages")
        case .answer: return Localized.text("Agent responses")
        case .mono: return Localized.text("Code and tools")
        case .terminal: return Localized.text("Terminal")
        }
    }

    /// What the area sets, said by the things a person points at.
    public var detail: String {
        switch self {
        case .chrome:
            return Localized.text("The chat list, pills, menus and every label around the conversation")
        case .prompt: return Localized.text("What you type: your prompts and the prompt box")
        case .answer:
            return Localized.text("What the agent writes back: answers, thinking and tables")
        case .mono: return Localized.text("Code blocks, tool calls and their output")
        case .terminal: return Localized.text("The shell under the conversation")
        }
    }

    /// The key every client reads and writes this area under. The agent's words keep the key
    /// the desktops already wrote for the transcript's prose, so a size chosen before the prose
    /// was split in two is still the size of the part it was chosen for.
    public var defaultsKey: String {
        switch self {
        case .answer: return "tailscode.scale.prose"
        default: return "tailscode.scale.\(rawValue)"
        }
    }
}

/// The size of every area, as a multiple of the normal size.
///
/// A value type so the arithmetic — what a step does at the ends, what a preset means, which preset
/// a set of sizes happens to be — is asserted without a toolkit and read the same on every desk.
public struct TypeScale: Equatable, Sendable {
    public static let lowest = 0.6
    public static let highest = 2.5
    public static let step = 0.05
    public static let standard = 1.0

    private var values: [TypeArea: Double]

    public init(_ values: [TypeArea: Double] = [:]) {
        self.values = [:]
        for (area, value) in values { store(area, value) }
    }

    /// An area at its normal size is absent rather than present at one, so two sets of sizes that
    /// say the same thing are equal however they were reached.
    private mutating func store(_ area: TypeArea, _ value: Double) {
        let snapped = Self.snapped(value)
        values[area] = snapped == Self.standard ? nil : snapped
    }

    /// The nearest size the controls can say: whole steps of five percent, held inside the range.
    public static func snapped(_ value: Double) -> Double {
        guard value.isFinite else { return standard }
        let stepped = (value / step).rounded() * step
        return min(highest, max(lowest, (stepped * 100).rounded() / 100))
    }

    public subscript(area: TypeArea) -> Double { values[area] ?? Self.standard }

    public func percent(_ area: TypeArea) -> Int { Int((self[area] * 100).rounded()) }

    public func isStandard(_ area: TypeArea) -> Bool { percent(area) == 100 }

    public var isStandard: Bool { TypeArea.allCases.allSatisfy(isStandard) }

    public func setting(_ area: TypeArea, to scale: Double) -> TypeScale {
        var next = self
        next.store(area, scale)
        return next
    }

    /// `steps` notches of five percent, pinned at both ends rather than wrapped.
    public func stepping(_ area: TypeArea, by steps: Int) -> TypeScale {
        setting(area, to: self[area] + Double(steps) * Self.step)
    }

    public func applying(_ preset: TypePreset) -> TypeScale { preset.scale }

    /// The preset these sizes are exactly, or nil when the person has set them apart from every
    /// one — which the controls say as Custom rather than by naming the nearest.
    public var preset: TypePreset? {
        TypePreset.allCases.first { $0.scale == self }
    }

    /// A size said the way a person reads it: `110%`.
    public static func reading(_ percent: Int) -> String { "\(percent)%" }
}

/// A way of setting every area at once, for the person who wants bigger type and not four
/// decisions: all of it a little larger, all of it large, or only the part they read, or only the
/// part that is code.
public enum TypePreset: String, CaseIterable, Sendable {
    case standard
    case comfortable
    case large
    case reading
    case code

    public var title: String {
        switch self {
        case .standard: return Localized.text("Default")
        case .comfortable: return Localized.text("Comfortable")
        case .large: return Localized.text("Large")
        case .reading: return Localized.text("Bigger reading")
        case .code: return Localized.text("Bigger code")
        }
    }

    public var detail: String {
        switch self {
        case .standard: return Localized.text("Every area at its normal size")
        case .comfortable: return Localized.text("Every area a tenth larger")
        case .large: return Localized.text("Every area a third larger")
        case .reading: return Localized.text("Prompts and answers larger; the rest as it was")
        case .code: return Localized.text("Code, tools and the terminal larger; the rest as it was")
        }
    }

    public var scale: TypeScale {
        switch self {
        case .standard: return TypeScale()
        case .comfortable:
            return TypeScale(Dictionary(uniqueKeysWithValues: TypeArea.allCases.map { ($0, 1.1) }))
        case .large:
            return TypeScale(Dictionary(uniqueKeysWithValues: TypeArea.allCases.map { ($0, 1.3) }))
        case .reading: return TypeScale([.prompt: 1.3, .answer: 1.3])
        case .code: return TypeScale([.mono: 1.2, .terminal: 1.2])
        }
    }
}

/// Where the sizes live: one key per area, absent when the area is at its normal size, so a person
/// who never touched them has nothing stored and a reset leaves nothing behind.
///
/// Read on every font a client makes, which is every row of every list, so the answer is held and
/// only a write — or a client that wrote the defaults by another road — lets it go.
public enum TypeScaleStore {
    public static let didChange = Notification.Name("tailscode.typeScale.didChange")

    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: TypeScale?

    public static func current() -> TypeScale {
        lock.lock()
        defer { lock.unlock() }
        if let held { return held }
        var values: [TypeArea: Double] = [:]
        for area in TypeArea.allCases {
            let stored = defaults.double(forKey: area.defaultsKey)
            if stored != 0 { values[area] = stored }
        }
        let read = TypeScale(values)
        held = read
        return read
    }

    public static func scale(_ area: TypeArea) -> Double { current()[area] }

    /// Writes what changed and tells whoever draws type. Nothing is posted for a write that
    /// changed nothing, so a slider dragged through one value costs the screens one pass.
    public static func set(_ next: TypeScale) {
        let before = current()
        guard next != before else { return }
        for area in TypeArea.allCases {
            if next.isStandard(area) {
                defaults.removeObject(forKey: area.defaultsKey)
            } else {
                defaults.set(next[area], forKey: area.defaultsKey)
            }
        }
        lock.lock()
        held = next
        lock.unlock()
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func set(_ area: TypeArea, to scale: Double) {
        set(current().setting(area, to: scale))
    }

    public static func reset() { set(TypeScale()) }

    /// Lets go of the held answer after defaults were written some other way.
    public static func forget() {
        lock.lock()
        held = nil
        lock.unlock()
    }

    static func forgetAllForTesting() {
        for area in TypeArea.allCases { defaults.removeObject(forKey: area.defaultsKey) }
        forget()
    }
}
