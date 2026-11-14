import CodingAgentKit
import Foundation

/// When a chat last moved, as the landmark a list files it under.
///
/// RECENT was one run of every chat there is, and its only fact was how many. A person looking for
/// yesterday's chat knows it was yesterday, so the list says where yesterday starts. The steps
/// widen with distance the way memory does: two single days, a week, a month, then months by name
/// inside this year and whole years before it.
public enum RecentBucket: Hashable, Sendable {
    case today
    case yesterday
    case week
    case month
    case named(year: Int, month: Int)
    case year(Int)

    /// Where the bucket sorts, newest first. A chat stamped into this device's future is two clocks
    /// disagreeing and reads as today.
    public var rank: Int {
        switch self {
        case .today: return 0
        case .yesterday: return 1
        case .week: return 2
        case .month: return 3
        case .named(let year, let month): return 1_000_000 - (year * 12 + month)
        case .year(let year): return 2_000_000 - year
        }
    }

    public static func of(_ date: Date, now: Date = Date(), calendar: Calendar = .current)
        -> RecentBucket
    {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return .today }
        if days == 1 { return .yesterday }
        if days <= 7 { return .week }
        if days <= 30 { return .month }
        let then = calendar.dateComponents([.year, .month], from: date)
        let year = then.year ?? 0
        guard year == calendar.component(.year, from: now) else { return .year(year) }
        return .named(year: year, month: then.month ?? 1)
    }

    public func title(calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch self {
        case .today: return Localized.text("TODAY")
        case .yesterday: return Localized.text("YESTERDAY")
        case .week: return Localized.text("PREVIOUS 7 DAYS")
        case .month: return Localized.text("PREVIOUS 30 DAYS")
        case .named(_, let month):
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            let names = formatter.standaloneMonthSymbols ?? formatter.monthSymbols ?? []
            guard names.indices.contains(month - 1) else { return "\(month)" }
            return names[month - 1].uppercased(with: locale)
        case .year(let year): return String(year)
        }
    }
}

/// A section of the full chat list: the four that say what a chat is doing or how it was set
/// aside, then the rest of it by when.
public enum ChatListSection: Hashable, Sendable {
    case needsYou
    case working
    case pinned
    case saved
    case recent(RecentBucket)
    /// The archive, listed alone when the person asks for it.
    case archived

    /// The board section this one came from, which is what a row's own marks are judged against.
    public var board: SessionSection? {
        switch self {
        case .needsYou: return .needsYou
        case .working: return .working
        case .pinned: return .pinned
        case .saved: return .saved
        case .recent: return .recent
        case .archived: return nil
        }
    }

    public var title: String {
        switch self {
        case .recent(let bucket): return bucket.title()
        case .archived: return Localized.text("ARCHIVED")
        case .needsYou, .working, .pinned, .saved: return board?.title ?? ""
        }
    }

    /// A stable name for the section, for a snapshot that must notice a section coming or going.
    public var key: String {
        switch self {
        case .needsYou: return "needs"
        case .working: return "working"
        case .pinned: return "pinned"
        case .saved: return "saved"
        case .archived: return "archived"
        case .recent(.today): return "today"
        case .recent(.yesterday): return "yesterday"
        case .recent(.week): return "week"
        case .recent(.month): return "month"
        case .recent(.named(let year, let month)): return "\(year)-\(month)"
        case .recent(.year(let year)): return "\(year)"
        }
    }
}

/// What a section's heading says beside its name.
///
/// A heading counted its rows, and "RECENT 1800" is a number nobody acts on. The two sections a
/// person steers by keep their totals, because how many agents are waiting or working is the
/// reading of the whole fleet. Every other heading says only how many of its rows are new, and
/// says nothing when none are, so a figure beside a heading always means there is something to do.
public struct SectionHeading: Equatable, Sendable {
    public let section: ChatListSection
    public let title: String
    public let total: Int?
    public let fresh: Int

    public init(section: ChatListSection, rows: Int, fresh: Int) {
        self.section = section
        self.title = section.title
        switch section {
        case .needsYou, .working:
            self.total = rows
            self.fresh = 0
        case .pinned, .saved, .recent, .archived:
            self.total = nil
            self.fresh = fresh
        }
    }

    /// The heading over the items one section draws, a split counted by the chats it stands for.
    public init(section: ChatListSection, items: [ChatListItem]) {
        self.init(
            section: section, rows: items.reduce(0) { $0 + $1.entries.count },
            fresh: items.reduce(0) { $0 + $1.freshCount })
    }

    public var needsYou: Bool { section == .needsYou }

    /// "2 new", or nil when the heading has nothing new under it.
    public var freshLabel: String? {
        fresh > 0 ? Localized.text("%@ new", "\(fresh)") : nil
    }

    /// The heading as a sentence, for a screen reader and a plain-text client.
    public var spoken: String {
        if let total { return "\(title), \(total)" }
        if let freshLabel { return "\(title), \(freshLabel)" }
        return title
    }
}

/// The full chat list in the order it is drawn: `groupIntoSections`, with RECENT filed by when.
///
/// Home's board keeps the five bands and its own limits; this is for a list that holds every chat.
/// Rows keep the order the listing gave them inside each landmark, which is newest first, so a
/// chat never moves between two draws unless it moved.
public func groupIntoListSections(
    _ rows: [SessionRowModel], now: Date = Date(), calendar: Calendar = .current
) -> [(ChatListSection, [SessionRowModel])] {
    var out: [(ChatListSection, [SessionRowModel])] = []
    for (section, members) in groupIntoSections(rows) {
        switch section {
        case .needsYou: out.append((.needsYou, members))
        case .working: out.append((.working, members))
        case .pinned: out.append((.pinned, members))
        case .saved: out.append((.saved, members))
        case .recent:
            var filed: [RecentBucket: [SessionRowModel]] = [:]
            for row in members {
                let bucket = RecentBucket.of(
                    row.entry.session.updatedAt, now: now, calendar: calendar)
                filed[bucket, default: []].append(row)
            }
            for bucket in filed.keys.sorted(by: { $0.rank < $1.rank }) {
                out.append((.recent(bucket), filed[bucket] ?? []))
            }
        }
    }
    return out
}

extension ChatListItem {
    /// How many of the conversations the item stands for are unread.
    public var freshCount: Int {
        switch self {
        case .chat(let row): return row.unread ? 1 : 0
        case .tab(let row): return row.members.count { $0.unread }
        }
    }
}
