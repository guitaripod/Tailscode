import Foundation
import TailscodeCore

/// The words of the step list, the filter chips and their empty state that only this desk draws,
/// beside Core's `NeuralBrowse` words.
enum BrainListWords {
    static var search: String { Localized.text("Search") }
    static var searchSteps: String { Localized.text("Search steps") }
    static var copy: String { Localized.text("Copy") }
    static var copied: String { Localized.text("Copied") }
    static var browseVerb: String { Localized.text("browse") }
    static var filterVerb: String { Localized.text("filter") }
    static var copyVerb: String { Localized.text("copy") }
    static var keysVerb: String { Localized.text("keys") }
    static var followingPaused: String { Localized.text("Following paused · jump to latest") }
    static var clearFilters: String { Localized.text("Clear filters") }
    static var orPress: String { Localized.text("or press") }
    static var stepList: String { Localized.text("Steps") }
    static var stepFilters: String { Localized.text("Step filters") }
    static var failedWord: String { Localized.text("failed") }
    static var on: String { Localized.text("on") }
    static var off: String { Localized.text("off") }

    static func noMatch(_ description: String) -> String {
        Localized.text("No steps match %@.", description)
    }

    static func stepRowLabel(
        number: Int, total: Int, title: String, argument: String, status: String
    ) -> String {
        let subject = argument.isEmpty ? title : "\(title), \(argument)"
        return Localized.text("step %1$lld of %2$lld, %3$@, %4$@", number, total, subject, status)
    }

    /// What a filter set says it holds, for the empty list: "DELEGATE + failed + “cut”".
    static func filterDescription(_ filter: NeuralStepList.Filter) -> String {
        var parts = NeuralZone.allCases.filter { filter.zones.contains($0) }.map(\.displayLabel)
        if filter.failedOnly { parts.append(failedWord) }
        if !filter.query.isEmpty { parts.append("\u{201C}\(filter.query)\u{201D}") }
        return parts.joined(separator: " + ")
    }

    /// The word a row's mark says at the right of a wide list, in the vocabulary of the verdicts.
    static func markWord(for row: NeuralStepList.Row) -> String {
        if case .fixed = row.verdict, let related = row.related, related.kind == .retry {
            return related.label
        }
        return row.verdict.word.lowercased()
    }
}
