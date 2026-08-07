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
