import CodingAgentKit
import Foundation

/// The sentence at the head of Home, and the line under it.
///
/// Home is a status board, so the first thing it owes anybody is what the whole of it adds up to,
/// in words that can be read from arm's length: who is waiting on you, who is working, or that
/// nothing is. It is derived from the same rows the bands below are drawn from, never from a
/// second count, so the sentence and the list cannot disagree about the same second.
public struct HomeStatus: Equatable, Sendable {
    public let sentence: String
    public let detail: String
    /// The tone the sentence's lead light wears: attention while somebody is waiting, live while
    /// work is going on, quiet when nothing is. It follows the activity vocabulary, so the light
    /// breathes, knocks or holds still exactly as every other badge does.
    public let tone: ActivityTone
    /// The one thing the account's quotas have to say, present only when a window is on course to
    /// run out before it resets (`RangeHome.line`). It is its own line because it is a different
    /// kind of news from the board's: not what the machines are doing but what they will be able
    /// to keep doing.
    public let range: String?

    public init(sentence: String, detail: String, tone: ActivityTone, range: String? = nil) {
        self.sentence = sentence
        self.detail = detail
        self.tone = tone
        self.range = range
    }

    /// The whole reading in one breath, for a screen reader that cannot see the light.
    public var spoken: String {
        let head = detail.isEmpty ? sentence : "\(sentence). \(detail)"
        guard let range else { return head }
        return "\(head). \(range)"
    }

    /// - Parameter rows: every conversation Home can see, archived ones already left out.
    /// - Parameter offline: the names of servers that did not answer the last listing; a machine
    ///   that is down is a fact about the whole board, not about one of its rows.
    public static func reading(
        rows: [SessionRowModel], offline: [String] = [], range: String? = nil, now: Date = Date(),
        calendar: Calendar = .current
    ) -> HomeStatus {
        let waiting = rows.filter { $0.state.needsYou }.count
        let working = rows.filter { $0.state.isInFlight && !$0.state.needsYou }.count
        let settled = rows.filter { !$0.state.isInFlight }
        let finishedToday = settled.filter {
            $0.state == .idle && calendar.isDate($0.entry.session.updatedAt, inSameDayAs: now)
        }.count
        let failedToday = settled.filter {
            $0.state == .failed && calendar.isDate($0.entry.session.updatedAt, inSameDayAs: now)
        }.count

        let sentence: String
        let tone: ActivityTone
        var parts: [String] = []
        if waiting > 0 {
            sentence =
                waiting == 1
                ? Localized.text("1 needs you") : Localized.text("%d need you", waiting)
            tone = .attention
            if working > 0 { parts.append(Localized.text("%d working", working)) }
        } else if working > 0 {
            sentence = Localized.text("%d working", working)
            tone = .live
            parts.append(Localized.text("Nothing needs you"))
        } else if rows.isEmpty {
            sentence = Localized.text("No chats yet")
            tone = .quiet
            parts.append(Localized.text("Start one below."))
        } else {
            sentence = Localized.text("All quiet")
            tone = .quiet
            parts.append(Localized.text("Nothing running"))
            if let last = settled.map(\.entry.session.updatedAt).max() {
                parts.append(
                    Localized.text(
                        "last finished %@ ago", SessionRowModel.age(of: last, asOf: now)))
            }
        }
        if finishedToday > 0, waiting > 0 || working > 0 {
            parts.append(Localized.text("%d finished today", finishedToday))
        }
        if failedToday > 0 { parts.append(Localized.text("%d failed today", failedToday)) }
        switch offline.count {
        case 0: break
        case 1: parts.append(Localized.text("%@ is offline", offline[0]))
        default: parts.append(Localized.text("%d servers offline", offline.count))
        }
        return HomeStatus(
            sentence: sentence, detail: parts.joined(separator: " · "), tone: tone, range: range)
    }
}

/// How many rows each band of Home may carry before it says "See all". A band that grew without
/// limit would push the one below it off the screen, which is the opposite of a board: what is
/// waiting is never capped, because a decision must not be hidden, and everything the person set
/// aside is held to what fits beside the rest.
public struct HomeBandLimits: Equatable, Sendable {
    public let working: Int
    public let pinned: Int
    public let saved: Int
    public let recent: Int

    public init(working: Int, pinned: Int, saved: Int, recent: Int) {
        self.working = working
        self.pinned = pinned
        self.saved = saved
        self.recent = recent
    }

    /// The phone's Home, which is the only place a person looks at all of it.
    public static let phone = HomeBandLimits(working: 10, pinned: 3, saved: 3, recent: 6)

    /// Home beside a chat list, which already holds every recent conversation in its own column.
    public static let column = HomeBandLimits(working: 10, pinned: 3, saved: 3, recent: 0)

    /// Nil is no limit.
    public func limit(for section: SessionSection) -> Int? {
        switch section {
        case .needsYou: return nil
        case .working: return working
        case .pinned: return pinned
        case .saved: return saved
        case .recent: return recent
        }
    }
}

/// Home's bands and the sentence over them, decided once and shared by every client that draws a
/// board.
public struct HomeBoard: Equatable, Sendable {
    public struct Band: Equatable, Sendable {
        public let section: SessionSection
        public let rows: [SessionRowModel]
        /// How many more the band holds than it shows, so the foot can say "See all 48 chats".
        public let hidden: Int

        public init(section: SessionSection, rows: [SessionRowModel], hidden: Int) {
            self.section = section
            self.rows = rows
            self.hidden = hidden
        }
    }

    public let status: HomeStatus
    public let bands: [Band]

    public init(status: HomeStatus, bands: [Band]) {
        self.status = status
        self.bands = bands
    }

    public static func make(
        rows: [SessionRowModel], limits: HomeBandLimits = .phone, offline: [String] = [],
        now: Date = Date(), calendar: Calendar = .current
    ) -> HomeBoard {
        let bands: [Band] = groupIntoSections(rows).compactMap { section, members in
            guard let limit = limits.limit(for: section) else {
                return Band(section: section, rows: members, hidden: 0)
            }
            guard limit > 0 else { return nil }
            return Band(
                section: section, rows: Array(members.prefix(limit)),
                hidden: max(0, members.count - limit))
        }
        return HomeBoard(
            status: HomeStatus.reading(rows: rows, offline: offline, now: now, calendar: calendar),
            bands: bands)
    }

    public var rows: [SessionRowModel] { bands.flatMap(\.rows) }
}

/// What a waiting turn is asking, in the words a person decides on.
///
/// The row of a conversation that stopped to ask is the one place a person might act without
/// opening the chat, and acting on "needs you" alone is acting blind. Only a conversation this
/// device is streaming has the call in hand; for any other the row says the plain thing and the
/// chat itself has the whole of it. A permission is a command or a file and wears the machine's
/// face; a question is the agent's own words and does not.
public struct ApprovalAsk: Equatable, Sendable {
    public let lead: String
    public let object: String?

    public init(lead: String, object: String? = nil) {
        self.lead = lead
        self.object = object
    }

    public static func reading(in state: ConversationState) -> ApprovalAsk? {
        if let question = state.pendingQuestions.first?.questions.first?.question,
            !question.isEmpty
        {
            return ApprovalAsk(lead: question)
        }
        guard !state.pendingPermissions.isEmpty else { return nil }
        let calls = LiveActivityReading.turnCalls(in: state)
        guard
            let call = calls.first(where: { $0.status == .pending || $0.status == .running })
                ?? calls.first
        else { return nil }
        let summary = call.summary
        switch summary.kind {
        case .shell:
            guard let command = summary.command ?? summary.title, !command.isEmpty else { return nil }
            return ApprovalAsk(lead: Localized.text("Wants to run"), object: firstLine(command))
        case .fileEdit, .fileWrite:
            guard let path = summary.title ?? summary.filePath, !path.isEmpty else { return nil }
            return ApprovalAsk(lead: Localized.text("Wants to edit"), object: path)
        default:
            return ApprovalAsk(lead: Localized.text("Wants to use"), object: call.name)
        }
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
    }
}

/// The line under a row's title, which says only what is news.
///
/// A chat that is waiting, working, failed or unread has something to say, and a settled one that
/// has been read does not: no line at all is how a row says "nothing happened", and writing "idle"
/// there would spend a line of every row on the one thing nobody asked. `lead` is words; `object`
/// is the command or path the lead is about and is set in the machine's face.
public struct ChatRowNews: Equatable, Sendable {
    public let lead: String
    public let object: String?

    public init(lead: String, object: String? = nil) {
        self.lead = lead
        self.object = object
    }

    public var spoken: String {
        object.map { "\(lead) \($0)" } ?? lead
    }

    /// - Parameter ask: what the turn is waiting to do, when this device has the call in hand.
    /// - Parameter missed: why the person was told about this chat while they were away, which is
    ///   what an unread row has to say about itself.
    public static func reading(
        for row: SessionRowModel, ask: ApprovalAsk? = nil, missed: MissedActivity.Reason? = nil
    ) -> ChatRowNews? {
        switch row.state {
        case .awaitingApproval:
            if let ask { return ChatRowNews(lead: ask.lead, object: ask.object) }
            return ChatRowNews(lead: ActivityKind.needsApproval.spoken)
        case .stalled(let tasks):
            return ChatRowNews(lead: ActivityKind.stalled(tasks: tasks).title, object: row.snippet)
        case .live:
            return ChatRowNews(lead: row.snippet ?? Localized.text("Working"))
        case .background(let tasks):
            if let snippet = row.snippet { return ChatRowNews(lead: snippet) }
            return ChatRowNews(lead: ActivityKind.inBackground(tasks: tasks).title)
        case .failed:
            return ChatRowNews(lead: Localized.text("Last turn failed"))
        case .offline:
            return ChatRowNews(lead: Localized.text("Last heard %@ ago", row.age))
        case .idle:
            guard row.unread else { return nil }
            switch missed {
            case .turnFailed?: return ChatRowNews(lead: Localized.text("Last turn failed"))
            case .needsAnswer?: return ChatRowNews(lead: Localized.text("Asked you a question"))
            case .needsApproval?: return ChatRowNews(lead: ActivityKind.needsApproval.spoken)
            case .turnEnded?, nil: return ChatRowNews(lead: Localized.text("Finished"))
            }
        }
    }
}
