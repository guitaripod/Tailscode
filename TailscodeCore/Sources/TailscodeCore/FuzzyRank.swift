import Foundation

/// Why a candidate matched what was typed, best first. The order is the whole point: a run of
/// letters at the front of a name, or at the front of one of its segments, is what a person meant;
/// the same letters found loose in the middle of something else is a guess, and letters merely
/// appearing in order is the last resort before giving up.
public enum FuzzyTier: Int, Sendable, Comparable, CaseIterable {
    /// The whole candidate, typed out.
    case exact = 0
    /// The candidate starts with what was typed.
    case prefix = 1
    /// A segment of it starts with what was typed — `plan` finding `project:planner`, `Dev`
    /// finding `~/code/Dev/thing`.
    case segment = 2
    /// The letters appear together somewhere inside it.
    case inner = 3
    /// The letters appear in order but apart — `gm` finding `git:merge`.
    case scattered = 4

    public static func < (lhs: FuzzyTier, rhs: FuzzyTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One match: how well it matched, and which letters it landed on so a row can show the person
/// what it read. Offsets are into the candidate as it was handed in, never into a lowercased copy.
public struct FuzzyHit: Sendable, Equatable {
    public let tier: FuzzyTier
    public let highlight: [Int]

    public init(tier: FuzzyTier, highlight: [Int]) {
        self.tier = tier
        self.highlight = highlight
    }
}

/// The one place this app decides whether some letters find some name.
///
/// It started as slash-command completion and is now also how a directory is found in a list of
/// paths — the same five tiers, differing only in what counts as a segment boundary. Sharing it is
/// what keeps `/gm` and `~/Dev/thing` feeling like the same keyboard.
public enum FuzzyRank {
    public static func hit(
        _ needle: String, in candidate: String, separators: Set<Character> = [":"]
    ) -> FuzzyHit? {
        let letters = Array(needle.lowercased())
        let name = Array(candidate.lowercased())
        guard !letters.isEmpty else { return FuzzyHit(tier: .prefix, highlight: []) }
        if name == letters {
            return FuzzyHit(tier: .exact, highlight: Array(0..<name.count))
        }
        if let start = run(of: letters, in: name), start == 0 {
            return span(.prefix, start: start, length: letters.count)
        }
        if let start = segmentStart(of: letters, in: name, separators: separators) {
            return span(.segment, start: start, length: letters.count)
        }
        if let start = run(of: letters, in: name) {
            return span(.inner, start: start, length: letters.count)
        }
        if let scattered = subsequence(of: letters, in: name) {
            return FuzzyHit(tier: .scattered, highlight: scattered)
        }
        return nil
    }

    private static func span(_ tier: FuzzyTier, start: Int, length: Int) -> FuzzyHit {
        FuzzyHit(tier: tier, highlight: Array(start..<(start + length)))
    }

    private static func run(of letters: [Character], in name: [Character]) -> Int? {
        guard !letters.isEmpty, letters.count <= name.count else { return nil }
        for start in 0...(name.count - letters.count)
        where Array(name[start..<(start + letters.count)]) == letters {
            return start
        }
        return nil
    }

    /// A candidate answers to any of its parts: `namespace:name` to its bare second half, a path to
    /// any folder along it, so nobody has to remember which plugin contributed a command or how
    /// deep a project sits.
    private static func segmentStart(
        of letters: [Character], in name: [Character], separators: Set<Character>
    ) -> Int? {
        var cursor = 0
        while cursor < name.count {
            guard let mark = name[cursor...].firstIndex(where: separators.contains) else {
                return nil
            }
            let start = name.index(after: mark)
            guard start + letters.count <= name.count else { return nil }
            if Array(name[start..<(start + letters.count)]) == letters { return start }
            cursor = start
        }
        return nil
    }

    private static func subsequence(of letters: [Character], in name: [Character]) -> [Int]? {
        var hits: [Int] = []
        var index = 0
        for letter in letters {
            guard let found = name[index...].firstIndex(of: letter) else { return nil }
            hits.append(found)
            index = found + 1
        }
        return hits
    }
}

/// A name lowered once, to be matched many times. A project's files are asked about on every
/// key typed after an `@`, and lowering thousands of names into characters each time was nearly
/// all of the work.
struct FuzzyKey: Sendable {
    let text: String
    /// The lowered bytes of a name written in printable ASCII, which a file's name nearly always
    /// is: there a byte is a character and the match never has to read graphemes. Any other name
    /// goes the general way.
    let bytes: [UInt8]?

    init(_ text: String) {
        self.text = text
        let printable = text.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        bytes = printable ? text.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 } : nil
    }
}

/// What separates the parts of a name, held both ways a match may need it.
struct FuzzySeparators: Sendable {
    let characters: Set<Character>
    let bytes: [UInt8]?

    init(_ characters: Set<Character>) {
        self.characters = characters
        let units = characters.compactMap { $0.isASCII ? $0.asciiValue : nil }
        bytes = units.count == characters.count ? units : nil
    }
}

extension FuzzyRank {
    /// How well the letters find the name, without saying where: enough to rank thousands of
    /// names, leaving the letters to be lit only on the few rows that are shown. Always the tier
    /// `hit` would give.
    static func tier(_ needle: FuzzyKey, in candidate: FuzzyKey, separators: FuzzySeparators) -> FuzzyTier? {
        guard let letters = needle.bytes, let name = candidate.bytes, let marks = separators.bytes else {
            return hit(needle.text, in: candidate.text, separators: separators.characters)?.tier
        }
        return match(letters, in: name, separators: marks)?.tier
    }

    /// `hit` for keys made ready beforehand.
    static func hit(_ needle: FuzzyKey, in candidate: FuzzyKey, separators: FuzzySeparators) -> FuzzyHit? {
        guard let letters = needle.bytes, let name = candidate.bytes, let marks = separators.bytes else {
            return hit(needle.text, in: candidate.text, separators: separators.characters)
        }
        guard let found = match(letters, in: name, separators: marks) else { return nil }
        switch found.tier {
        case .exact: return FuzzyHit(tier: .exact, highlight: Array(0..<name.count))
        case .scattered: return FuzzyHit(tier: .scattered, highlight: scattered(letters, in: name) ?? [])
        default: return span(found.tier, start: found.start, length: letters.count)
        }
    }

    /// The same five tiers as `hit`, in the same order, over bytes. Every tier finds the letters
    /// in order, so a name that does not hold them that way is turned away before anything else.
    private static func match(_ letters: [UInt8], in name: [UInt8], separators: [UInt8])
        -> (tier: FuzzyTier, start: Int)?
    {
        guard !letters.isEmpty else { return (.prefix, 0) }
        guard letters.count <= name.count, inOrder(letters, in: name) else { return nil }
        if letters.count == name.count, letters == name { return (.exact, 0) }
        if holds(letters, in: name, at: 0) { return (.prefix, 0) }
        if let start = segment(letters, in: name, separators: separators) { return (.segment, start) }
        if let start = run(letters, in: name) { return (.inner, start) }
        return (.scattered, 0)
    }

    private static func holds(_ letters: [UInt8], in name: [UInt8], at start: Int) -> Bool {
        guard start + letters.count <= name.count else { return false }
        for offset in 0..<letters.count where name[start + offset] != letters[offset] { return false }
        return true
    }

    private static func run(_ letters: [UInt8], in name: [UInt8]) -> Int? {
        for start in 0...(name.count - letters.count) where holds(letters, in: name, at: start) {
            return start
        }
        return nil
    }

    private static func segment(_ letters: [UInt8], in name: [UInt8], separators: [UInt8]) -> Int? {
        var cursor = 0
        while cursor < name.count {
            guard let mark = name[cursor...].firstIndex(where: separators.contains) else { return nil }
            let start = mark + 1
            guard start + letters.count <= name.count else { return nil }
            if holds(letters, in: name, at: start) { return start }
            cursor = start
        }
        return nil
    }

    private static func inOrder(_ letters: [UInt8], in name: [UInt8]) -> Bool {
        var index = 0
        for letter in letters {
            while index < name.count, name[index] != letter { index += 1 }
            guard index < name.count else { return false }
            index += 1
        }
        return true
    }

    private static func scattered(_ letters: [UInt8], in name: [UInt8]) -> [Int]? {
        var hits: [Int] = []
        hits.reserveCapacity(letters.count)
        var index = 0
        for letter in letters {
            while index < name.count, name[index] != letter { index += 1 }
            guard index < name.count else { return nil }
            hits.append(index)
            index += 1
        }
        return hits
    }
}
