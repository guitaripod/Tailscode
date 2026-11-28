import CodingAgentKit
import Foundation

extension ModelChooser {
    /// The given candidates ordered by how well each name answers the query. Ties inside a tier
    /// break on what the person picked recently, then alphabetically, so the list never reshuffles
    /// itself for reasons nobody can see.
    func matches(in candidates: [ModelCandidate]) -> [(ModelCandidate, [Int])] {
        let recency = Dictionary(
            uniqueKeysWithValues: recents.enumerated().map { ($0.element, $0.offset) })
        func rank(_ candidate: ModelCandidate) -> Int {
            candidate.offers.compactMap { recency[$0.selection] }.min() ?? Int.max
        }
        guard !query.isEmpty else {
            return
                candidates
                .sorted { lhs, rhs in
                    let (walledL, walledR) = (
                        walls[lhs.selection.rawValue] != nil, walls[rhs.selection.rawValue] != nil
                    )
                    if walledL != walledR { return !walledL }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                .map { ($0, []) }
        }
        let words = Self.words(of: query)
        let scored =
            candidates
            .compactMap { candidate -> (ModelCandidate, ModelMatch, Int, [Int])? in
                guard let found = Self.classify(candidate, words: words) else { return nil }
                return (candidate, found.kind, found.missed, found.highlight)
            }
        let answered = scored.filter { $0.2 == 0 }
        return (answered.isEmpty ? scored : answered)
            .sorted { lhs, rhs in
                if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.isElsewhere != rhs.0.isElsewhere { return !lhs.0.isElsewhere }
                let (walledL, walledR) = (
                    walls[lhs.0.selection.rawValue] != nil, walls[rhs.0.selection.rawValue] != nil
                )
                if walledL != walledR { return !walledL }
                let (a, b) = (rank(lhs.0), rank(rhs.0))
                if a != b { return a < b }
                return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
            }
            .map { ($0.0, $0.3) }
    }

    /// What a query is made of: a person searching for a model types its descriptor as readily as
    /// its codename — "inkling 2 mini nvfp4" — and most of those words (the size, the quant, the
    /// engine) are nowhere in the catalog, which carries ids and names alone. So a multi-word query
    /// is matched word by word while some row answers every word — the answer that contains the
    /// query is the answer it was asking for — and only when nothing does does the list fall back
    /// to the rows that answer most of it, so a word nobody's catalog carries (the quant, the
    /// engine) never throws away the row the person was sure about.
    private static func words(of query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private struct Found {
        let kind: ModelMatch
        let missed: Int
        let highlight: [Int]
    }

    private static func classify(_ candidate: ModelCandidate, words: [String]) -> Found? {
        guard words.count > 1 else {
            guard let word = words.first, let hit = classify(candidate, needle: word) else {
                return nil
            }
            return Found(kind: hit.0, missed: 0, highlight: hit.1)
        }
        var best: (ModelMatch, [Int])?
        var missed = 0
        for word in words {
            guard let hit = classify(candidate, needle: word) else {
                missed += 1
                continue
            }
            if best == nil || hit.0 < best!.0 { best = hit }
        }
        guard let best, missed < words.count else { return nil }
        return Found(kind: best.0, missed: missed, highlight: best.1)
    }

    /// Tried best-first over the name, then over everything else the person might have typed —
    /// a provider, a family, the raw id — so "ollama", "claude" and "sonnet-4-5" all find rows,
    /// but a name that answers the query outranks a provider that merely carries it.
    private static func classify(
        _ candidate: ModelCandidate, needle: String
    ) -> (ModelMatch, [Int])? {
        let name = Array(candidate.name.lowercased())
        let letters = Array(needle)
        if name == letters { return (.exact, Array(0..<name.count)) }
        if let start = run(of: letters, in: name) {
            if start == 0 { return (.prefix, Array(start..<(start + letters.count))) }
            let boundary = !name[start - 1].isLetter && !name[start - 1].isNumber
            return (boundary ? .word : .inner, Array(start..<(start + letters.count)))
        }
        if let scattered = subsequence(of: letters, in: name) { return (.scattered, scattered) }
        let elsewhere =
            candidate.offers.contains {
                $0.providerName.lowercased().contains(needle)
                    || $0.providerID.lowercased().contains(needle)
                    || $0.model.id.lowercased().contains(needle)
            } || candidate.family.title.lowercased().contains(needle)
            || candidate.serverName.lowercased().contains(needle)
        return elsewhere ? (.elsewhere, []) : nil
    }

    private static func run(of letters: [Character], in name: [Character]) -> Int? {
        guard !letters.isEmpty, letters.count <= name.count else { return nil }
        for start in 0...(name.count - letters.count)
        where Array(name[start..<(start + letters.count)]) == letters {
            return start
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
