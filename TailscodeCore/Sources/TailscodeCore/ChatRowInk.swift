import Foundation

/// How a chat row is inked, the same on three desks.
///
/// A list of two thousand chats is scanned, not read, and what is scanned for is the handful that
/// want something. So the ink is spent in that order: weight for the rows that are waiting or
/// unread, full strength for the ones that are busy, and one step back for everything that is
/// settled and has been seen. The figures are here rather than in each client because a list that
/// dims by 84% on one desk and 70% on another is two lists.
public enum ChatRowInk {
    public enum Emphasis: Equatable, Sendable {
        /// Waiting on the person, or unread: the heavier face at full strength.
        case strong
        /// Busy, failed or away: the regular face at full strength.
        case plain
        /// Settled and read: the regular face, one step back.
        case receded
    }

    public enum ColumnMark: Equatable, Sendable {
        case activity(ActivityKind)
        case unread
        case none
    }

    public enum TitleMark: Equatable, Sendable {
        case pinned
        case saved
        case scheduled

        /// The SF Symbol an Apple client draws.
        public var symbol: String {
            switch self {
            case .pinned: return "pin.fill"
            case .saved: return "bookmark.fill"
            case .scheduled: return "clock"
            }
        }

        /// The one-column glyph a text client draws.
        public var glyph: String {
            switch self {
            case .pinned: return "⌃"
            case .saved: return "◆"
            case .scheduled: return "◷"
            }
        }

        public var spoken: String {
            switch self {
            case .pinned: return Localized.text("Pinned")
            case .saved: return Localized.text("Saved")
            case .scheduled: return Localized.text("A schedule asks in this conversation")
            }
        }
    }

    /// How hard a row's title is pressed. A row waiting on the person and a settled row they have
    /// not read are the two that are looked for, so they share the heaviest ink. A turn in flight
    /// is full strength without the weight, read or not: its clock moves with every token, so it
    /// is unread for as long as it runs, and weighting it would weight the whole section. A row
    /// that failed or lost its machine is the same once seen, and a settled row that has been read
    /// steps back, because it is most of the list and none of the news.
    public static func emphasis(state: SessionRowState, unread: Bool) -> Emphasis {
        if state.needsYou { return .strong }
        if state.isInFlight { return .plain }
        if unread { return .strong }
        return state.activity == nil ? .receded : .plain
    }

    /// A read row's title against the label colour. The mocks tried 68%, which finds an unread row
    /// instantly and greys the nine rows in ten a person scans to resume something.
    public static let recededTitle = 0.84
    /// A read row's model chip against its own hues, so the rainbow on a row nobody needs to look
    /// at is never the brightest thing in the list.
    public static let recededChip = 0.62
    /// The quoted answer on an unread row, a step under its title.
    public static let quotedNews = 0.8

    public static func titleOpacity(_ emphasis: Emphasis) -> Double {
        emphasis == .receded ? recededTitle : 1
    }

    public static func chipOpacity(_ emphasis: Emphasis) -> Double {
        emphasis == .receded ? recededChip : 1
    }

    /// How many lines the news may take: a quoted answer is the payload and gets two, everything
    /// else is a status and gets one on a desktop.
    public static func newsLines(_ voice: ChatRowNews.Voice, roomy: Bool) -> Int {
        roomy || voice == .said || voice == .asking ? 2 : 1
    }
}
