import Foundation
import TailscodeCore

/// The words of the step list, the filter panel and the browse menus that only this desk draws,
/// beside Core's `NeuralBrowse` words.
extension BrainWords {
    static var search: String { Localized.text("Search") }
    static var filter: String { Localized.text("FILTER") }
    static var keysOneToSix: String { Localized.text("keys 1–6") }
    static var failedWord: String { Localized.text("FAILED") }
    static var browseVerb: String { Localized.text("browse") }
    static var filterVerb: String { Localized.text("filter") }
    static var copyVerb: String { Localized.text("copy") }
    static var keysVerb: String { Localized.text("keys") }
    static var copy: String { Localized.text("Copy") }
    static var followingPaused: String { Localized.text("Following paused · jump to latest") }
    static var clearFilters: String { Localized.text("Clear filters") }
    static var orPress: String { Localized.text("or press") }
    static var stepList: String { Localized.text("Steps") }
    static var stepFilters: String { Localized.text("Step filters") }
    static var keyLegend: String { Localized.text("Keys") }

    static func moreFailures(_ count: Int) -> String { Localized.text("%lld more failures", count) }
    static func moreFiles(_ count: Int) -> String { Localized.text("%lld more files", count) }

    static func noMatch(_ description: String) -> String {
        Localized.text("No steps match %@.", description)
    }

    static func stepRowLabel(number: Int, total: Int, title: String, argument: String, status: String) -> String {
        let subject = argument.isEmpty ? title : "\(title), \(argument)"
        return Localized.text("step %1$lld of %2$lld, %3$@, %4$@", number, total, subject, status)
    }

    /// What a filter set says it holds, for the empty list: "DELEGATE + failed + \u{201C}cut\u{201D}".
    static func filterDescription(_ filter: NeuralStepList.Filter) -> String {
        var parts = NeuralZone.allCases.filter { filter.zones.contains($0) }.map(\.label)
        if filter.failedOnly { parts.append(Localized.text("failed")) }
        if !filter.query.isEmpty { parts.append("\u{201C}\(filter.query)\u{201D}") }
        return parts.joined(separator: " + ")
    }

    /// The key a menu item is also reached by, shown at its right.
    static func menuKey(_ item: NeuralBrowse.MenuItem, zone: NeuralZone) -> String? {
        switch item {
        case .copySubject: return "c"
        case .copyOutput: return "C"
        case .copyMarkdown: return nil
        case .showOnlyThisZone: return "\(zone.filterKey)"
        case .goToRelated: return "r"
        case .showInRows: return nil
        }
    }
}
