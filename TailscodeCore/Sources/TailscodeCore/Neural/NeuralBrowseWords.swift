import Foundation

/// The words of the browse surface: the menu, the legend and the two things a key can announce.
extension NeuralBrowse {
    /// A line of the key legend: the keycaps, which are not translated, and what they do.
    public struct LegendEntry: Sendable, Equatable {
        public let keys: String
        public let does: String
    }

    public static var noFailedWords: String { Localized.text("No failed steps") }
    public static var noRelatedWords: String { Localized.text("No related step") }

    /// The line under the list when there is room.
    public static var hint: String { Localized.text("up down browse · / filter · c copy · ? keys") }

    public static func title(of item: MenuItem) -> String {
        switch item {
        case .copySubject: return Localized.text("Copy command or path")
        case .copyOutput: return Localized.text("Copy output")
        case .copyMarkdown: return Localized.text("Copy step as Markdown")
        case .showOnlyThisZone: return Localized.text("Show only this zone")
        case .goToRelated: return Localized.text("Go to related")
        case .showInRows: return Localized.text("Show in Rows")
        }
    }

    /// The key table, as the popover shows it.
    public static var legend: [LegendEntry] {
        [
            LegendEntry(keys: "\u{2191} \u{2193}  k j", does: Localized.text("Previous, next step")),
            LegendEntry(keys: "PgUp PgDn", does: Localized.text("Eight steps back, forward")),
            LegendEntry(
                keys: "Home End  g G",
                does: Localized.text("First, last step; End follows a running turn")),
            LegendEntry(
                keys: "\u{2190} \u{2192}  h l", does: Localized.text("Previous, next step in the same zone")),
            LegendEntry(keys: "[ ]  p n", does: Localized.text("Previous, next failed step")),
            LegendEntry(keys: "r", does: Localized.text("Go to the related step")),
            LegendEntry(keys: "s S", does: Localized.text("Next, previous thing it said")),
            LegendEntry(keys: "a", does: Localized.text("Go to what it is waiting for")),
            LegendEntry(
                keys: "1\u{2013}6  0", does: Localized.text("Filter by zone; clear the zones")),
            LegendEntry(keys: "! x", does: Localized.text("Failed steps only")),
            LegendEntry(keys: "/", does: Localized.text("Search the steps")),
            LegendEntry(keys: "Enter", does: Localized.text("Move into the readout and back")),
            LegendEntry(keys: "Space o", does: Localized.text("Expand or fold long output")),
            LegendEntry(keys: "c C", does: Localized.text("Copy command or path; copy output")),
            LegendEntry(keys: "?", does: Localized.text("Show or hide these keys")),
            LegendEntry(
                keys: "Esc", does: Localized.text("Clear search, filters and cursor, then close")),
        ]
    }
}
