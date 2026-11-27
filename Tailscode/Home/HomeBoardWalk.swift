import CodingAgentKit
import Foundation
import TailscodeCore

/// Everything Home's board decides by walking the whole fleet: which chats are kept, what each one
/// is, the words the list shares, the bands, the status sentence, the saved cards and whether
/// anything is news. A fleet that has been used for months lists two thousand chats, and walking
/// them was most of every rebuild — twelve to sixteen milliseconds of the main thread on an
/// iPhone Air, once or twice a second while a few agents worked, each one a dropped frame. It is
/// read from values alone, so a rebuild the listing asked for works it out away from the main
/// thread and the screen only draws what it found.
struct HomeBoardWalk: Sendable {
    struct Input: Sendable {
        let entries: [SessionEntry]
        let unreachable: [String]
        let archived: Set<ArchivedChatStore.ChatKey>
        let pins: Set<String>
        let unread: @Sendable (String, Date) -> Bool
        let presence: [String: SessionPresence]
        let saved: [SavedChat]
        let serverIDs: Set<String>
        let limits: HomeBandLimits
        let hasLoadedOnce: Bool
        let notices: Int
        let status: StatusInput?
    }

    /// What the status sentence reads besides the rows, present only when the board shows one.
    struct StatusInput: Sendable {
        let offline: [String]
        let quotas: [UsageQuota]
        let board: QuotaBoardPreferences
        let trail: QuotaTrail?
    }

    struct SavedPick: Sendable {
        let chat: SavedChat
        let unread: Bool
    }

    let isEmpty: Bool
    let vocabulary: ChatListVocabulary
    let bands: [HomeBoard.Band<HomeRowSeed>]
    let saved: [SavedPick]
    let status: HomeStatus?
    let hasNews: Bool

    /// The walk, on whatever thread asks. A rebuild the listing asked for calls ``away(_:)``.
    static func make(_ input: Input) -> HomeBoardWalk {
        let seeds = input.entries
            .filter {
                !input.archived.contains(
                    ArchivedChatStore.ChatKey(profileID: $0.profileID, sessionID: $0.session.id))
            }
            .map { entry in
                HomeRowSeed(
                    entry: entry, unreachable: input.unreachable.contains(entry.profileID),
                    unread: input.unread(entry.session.id, entry.session.updatedAt), saved: false,
                    pinned: input.pins.contains(SessionPinStore.key(entry.profileID, entry.session.id)),
                    presence: input.presence[entry.session.id] ?? .unobserved)
            }
        let saved = savedPicks(seeds: seeds, input: input)
        let savedKeys = Set(saved.map { key($0.chat.profileID, $0.chat.sessionID) })
        let bands = HomeBoard.bands(
            rows: savedKeys.isEmpty
                ? seeds : seeds.filter { !savedKeys.contains(key($0.entry.profileID, $0.entry.session.id)) },
            limits: input.limits)
        let status = input.status.map {
            HomeStatus.reading(
                rows: seeds, offline: $0.offline,
                range: RangeHome.line(quotas: $0.quotas, board: $0.board, trail: $0.trail))
        }
        let sweep = ReadSweep.reading(
            entries: input.entries, saved: input.saved, presence: input.presence,
            unreachable: Set(input.unreachable), notices: input.notices, isUnread: input.unread)
        return HomeBoardWalk(
            isEmpty: seeds.isEmpty, vocabulary: ChatListVocabulary(rows: seeds), bands: bands,
            saved: saved, status: status, hasNews: !sweep.isEmpty)
    }

    /// The walk on the cooperative pool, never on the main actor.
    @concurrent
    static func away(_ input: Input) async -> (walk: HomeBoardWalk, spent: TimeInterval) {
        let began = threadTime()
        let walk = make(input)
        return (walk, threadTime() - began)
    }

    /// The bookmarks Home shows: openable, not already on the board as a working or pinned chat,
    /// and no more than the saved band holds.
    private static func savedPicks(seeds: [HomeRowSeed], input: Input) -> [SavedPick] {
        guard !input.saved.isEmpty else { return [] }
        let listed = Set(input.entries.map { key($0.profileID, $0.session.id) })
        let kept = Set(
            seeds.filter { $0.state.isInFlight || $0.pinned }.map { key($0.entry.profileID, $0.entry.session.id) })
        return Array(
            input.saved.lazy
                .filter { isOpenable($0, input: input, listed: listed) }
                .filter { !kept.contains(key($0.profileID, $0.sessionID)) }
                .prefix(input.limits.saved)
                .map { SavedPick(chat: $0, unread: input.unread($0.sessionID, $0.updatedAt)) })
    }

    /// Home lists a saved chat only while it is something you can actually open. A bookmark whose
    /// conversation was deleted, or whose server was disconnected, is a tidying-up job for the
    /// Saved screen, not a launch pad.
    private static func isOpenable(_ chat: SavedChat, input: Input, listed: Set<String>) -> Bool {
        guard input.serverIDs.contains(chat.profileID) else { return false }
        if listed.contains(key(chat.profileID, chat.sessionID)) { return true }
        return !input.hasLoadedOnce || input.unreachable.contains(chat.profileID)
    }

    private static func key(_ profileID: String, _ sessionID: String) -> String {
        "\(profileID)\u{1}\(sessionID)"
    }

    /// The CPU time the calling thread has used, so a walk away from the main thread can still say
    /// what it cost.
    private static func threadTime() -> TimeInterval {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
    }
}
