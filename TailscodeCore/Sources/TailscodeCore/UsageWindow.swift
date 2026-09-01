import Foundation

/// How much of the ledger a reading covers, and how finely it is drawn.
///
/// "What am I spending this week" and "what did the quarter cost" are different questions asked at
/// different moments, and a surface that can only answer one of them is answering neither well.
/// The choice is the person's and it is remembered, because the window somebody reads in is a
/// habit rather than a decision they want to make twice a day.
///
/// The grain follows from the span rather than being a second choice: three hundred and sixty-five
/// columns is not a chart, and seven columns of one week each is not a week. A reader picks how
/// much time they are looking at; how tall a bar is stays the client's only decision.
public enum UsageWindow: String, Sendable, CaseIterable, Codable {
    case week
    case month
    case quarter
    case year

    public static let fallback = UsageWindow.month
    public static let storageKey = "tailscode.usageWindow"

    /// How many days of ledger to ask each server for.
    public var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .year: return 365
        }
    }

    /// The word on the control that picks it, short enough to sit in a row of four.
    public var title: String {
        switch self {
        case .week: return Localized.text("Week")
        case .month: return Localized.text("Month")
        case .quarter: return Localized.text("Quarter")
        case .year: return Localized.text("Year")
        }
    }

    /// What the surface calls itself while this window is the one being read.
    public var surfaceTitle: String {
        switch self {
        case .week: return Localized.text("The week in numbers")
        case .month: return Localized.text("The month in numbers")
        case .quarter: return Localized.text("The quarter in numbers")
        case .year: return Localized.text("The year in numbers")
        }
    }

    /// What the surface says it is showing.
    public var label: String {
        switch self {
        case .year: return Localized.text("Last 12 months")
        default: return Localized.text("Last %d days", days)
        }
    }

    /// What the chart over time calls itself, which has to follow the grain: thirteen columns
    /// headed "Day by day" is a chart that lies about what a column is.
    public var chartTitle: String {
        switch grain {
        case .day: return Localized.text("Day by day")
        case .week: return Localized.text("Week by week")
        case .month: return Localized.text("Month by month")
        }
    }

    /// One bar per what.
    public enum Grain: Sendable, Equatable {
        case day
        case week
        case month
    }

    public var grain: Grain {
        switch self {
        case .week, .month: return .day
        case .quarter: return .week
        case .year: return .month
        }
    }

    /// How far back the trend compares: the last quarter of the window against the quarter before
    /// it, which is a week inside a month and a month inside a year — long enough to be a trend,
    /// short enough to still be news.
    public var trendSpan: Int { max(2, days / 4) }

    /// The window a stored value names, with anything unreadable — a value from a newer build, a
    /// hand-edited file — falling back rather than failing.
    public static var current: UsageWindow {
        get {
            UserDefaults.standard.string(forKey: storageKey).flatMap(UsageWindow.init(rawValue:))
                ?? fallback
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}
