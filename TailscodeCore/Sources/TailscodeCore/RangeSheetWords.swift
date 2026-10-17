import Foundation

/// Every word the Range sheet says that is not a number: its title, its section headings, the
/// labels of the two views of the window, the chart's axis and its captions. The three clients draw
/// the sheet and none of them writes a sentence for it, so a heading cannot be reworded on one desk.
public enum RangeSheetWords {
    public static func title(chat: String) -> String {
        chat.isEmpty ? Localized.text("Range") : Localized.text("Range · %@", chat)
    }

    public static var tanks: String { Localized.text("Tanks that govern this chat") }
    public static var cache: String { Localized.text("Cache") }
    public static var window: String { Localized.text("What is in the window") }
    public static var billingHeading: String { Localized.text("What fills it") }
    public static var content: String { Localized.text("Content") }
    public static var billing: String { Localized.text("Billing") }
    public static var footprint: String { Localized.text("Footprint per turn") }
    public static var firstTurn: String { Localized.text("first turn") }
    public static var nothingYet: String { Localized.text("Nothing to read yet.") }

    public static func projected(_ turns: Int) -> String {
        Localized.text("+%d at this pace", turns)
    }

    public static func turn(_ turn: Int, size: String) -> String {
        Localized.text("turn %d · %@", turn, size)
    }

    public static func of(window size: String) -> String {
        Localized.text("of %@", size)
    }

    /// What the content chart's total says it is: a measured figure whose shares are estimates.
    public static func compositionTotal(_ tokens: String) -> String {
        Localized.text("%@ tokens · estimated shares of a measured total", tokens)
    }
}

extension RangeFootprint {
    /// The chart's legend, one caption per thing on it that a reader could mistake: what a bar is,
    /// the rule where a compaction emptied the window, the hatched turns that have not happened,
    /// and where the danger line sits.
    public var captions: [String] {
        var words = [Localized.text("Each bar is the window after a turn.")]
        if bars.contains(where: { $0.kind == .refill }) {
            words.append(Localized.text("Dashed rule: a compaction."))
        }
        if bars.contains(where: { $0.kind == .projected }) {
            words.append(Localized.text("Hatched: the next turns at the recent pace."))
        }
        if let dangerLine {
            words.append(Localized.text("Dashed line: %d%% of the window.", Int((dangerLine * 100).rounded())))
        }
        return words
    }

    /// How many future turns the hatched bars stand for.
    public var projectedTurns: Int { bars.filter { $0.kind == .projected }.count }
}
