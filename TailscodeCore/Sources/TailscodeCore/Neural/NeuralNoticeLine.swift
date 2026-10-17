import Foundation

/// The counts a turn's one-line account is written from: how many tools and steps it took and what
/// they did. A turn in the app is counted from its steps; a notification carries the same counts
/// as a glyph's zones, so the sentence a long look shows is the one the stage's own words say.
public struct NeuralNoticeCounts: Sendable, Equatable {
    public var steps: Int
    public var tools: Int
    public var shell: Int
    public var read: Int
    public var search: Int
    public var edited: Int
    public var delegated: Int
    public var added: Int
    public var removed: Int

    public init(
        steps: Int, tools: Int, shell: Int = 0, read: Int = 0, search: Int = 0, edited: Int = 0,
        delegated: Int = 0, added: Int = 0, removed: Int = 0
    ) {
        self.steps = steps
        self.tools = tools
        self.shell = shell
        self.read = read
        self.search = search
        self.edited = edited
        self.delegated = delegated
        self.added = added
        self.removed = removed
    }

    /// The counts a notification's facts and glyph describe, or nil without a glyph: a sender
    /// that sent no zones said how many tools but not what they were.
    public init?(glyph: NeuralGlyphWire?, tools: Int?, added: Int?, removed: Int?) {
        guard let glyph, glyph.isDrawable else { return nil }
        let senses = glyph.zones[1]
        let reads = min(max(glyph.reads ?? 0, 0), senses)
        let writes = glyph.zones[2]
        self.init(
            steps: glyph.steps, tools: tools ?? 0, shell: glyph.zones[3], read: reads,
            search: senses - reads, edited: glyph.files.map { min(max($0, 0), writes) } ?? writes,
            delegated: glyph.zones[4], added: added ?? 0, removed: removed ?? 0)
    }
}

/// The sentence a finished turn is told in away from the transcript, written once from counts so
/// the app, the notification service and the long look read the same: "25 tools in 8m 25s: ran 18
/// commands, read 3 files, edited 2 files (+5 −2)". Only Foundation and the catalogue are used,
/// because the extensions compile this file by path.
public enum NeuralNoticeLine {
    /// The whole sentence: the count and the time, then what the work did.
    public static func sentence(_ counts: NeuralNoticeCounts, seconds: TimeInterval?) -> String {
        let count = countText(tools: counts.tools, steps: counts.steps)
        let head = seconds.map { Localized.text("%1$@ in %2$@", count, duration($0)) } ?? count
        guard let body = clauses(counts) else { return head }
        return Localized.text("%1$@: %2$@", head, body)
    }

    /// What the work did, with the lines written in brackets and no count or time before it:
    /// "ran 18 commands, read 3 files, edited 2 files (+5 −2)". Nil for work that was none of
    /// these, which has only the count to say.
    public static func clauses(_ counts: NeuralNoticeCounts) -> String? {
        let parts = clauseParts(counts)
        guard !parts.isEmpty else { return nil }
        var body = parts.dropFirst().reduce(parts[0]) { Localized.text("%1$@, %2$@", $0, $1) }
        if let tally = tally(counts.added, counts.removed) {
            body = Localized.text("%1$@ (%2$@)", body, tally)
        }
        return body
    }

    /// Each thing the work did as its own clause, in the order the sentence reads them: "ran 18
    /// commands", "read 3 files". A card sets them one at a time so it can drop whole clauses.
    public static func clauseParts(_ counts: NeuralNoticeCounts) -> [String] {
        var parts: [String] = []
        if counts.shell > 0 {
            parts.append(
                counts.shell == 1
                    ? Localized.text("ran 1 command") : Localized.text("ran %lld commands", counts.shell))
        }
        if counts.read > 0 {
            parts.append(
                counts.read == 1
                    ? Localized.text("read 1 file") : Localized.text("read %lld files", counts.read))
        }
        if counts.search > 0 {
            parts.append(
                counts.search == 1
                    ? Localized.text("searched 1 time")
                    : Localized.text("searched %lld times", counts.search))
        }
        if counts.edited > 0 {
            parts.append(
                counts.edited == 1
                    ? Localized.text("edited 1 file")
                    : Localized.text("edited %lld files", counts.edited))
        }
        if counts.delegated > 0 {
            parts.append(
                counts.delegated == 1
                    ? Localized.text("delegated 1 task")
                    : Localized.text("delegated %lld tasks", counts.delegated))
        }
        return parts
    }

    /// "25 tools"; "7 steps" for a turn that only thought or spoke.
    public static func countText(tools: Int, steps: Int) -> String {
        if tools == 1 { return Localized.text("1 tool") }
        if tools > 1 { return Localized.text("%lld tools", tools) }
        switch steps {
        case 0: return Localized.text("No steps")
        case 1: return Localized.text("1 step")
        default: return Localized.text("%lld steps", steps)
        }
    }

    /// "8m 25s", "42s", "1h 5m".
    public static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        if whole < 60 { return Localized.text("%llds", whole) }
        if whole < 3_600 { return Localized.text("%1$lldm %2$llds", whole / 60, whole % 60) }
        return Localized.text("%1$lldh %2$lldm", whole / 3_600, whole % 3_600 / 60)
    }

    /// "+5 −2" for what a turn wrote, nil when it wrote nothing.
    public static func tally(_ added: Int, _ removed: Int) -> String? {
        guard added > 0 || removed > 0 else { return nil }
        return "+\(added) \u{2212}\(removed)"
    }
}
