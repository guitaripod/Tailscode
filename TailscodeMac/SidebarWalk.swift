import CodingAgentKit
import Foundation
import TailscodeCore

/// Everything the chat list decides by walking the whole fleet: each chat's row (remembered
/// against the facts it was worded from), the bookmarks no listing holds, the archive count, the
/// sections under the scope and the filter, the words the list shares and, when the listing moved,
/// what the fleet says for the notices. A Mac that has been used for months lists two thousand
/// chats, and this walk was over half of every draw — about twelve milliseconds of a MacBook's main
/// thread, once for every push a working turn made. It is read from values alone, so a draw a push
/// asked for works it out away from the main thread and the list only lays out what it found.
struct SidebarWalk: Sendable {
    struct Input: Sendable {
        let entries: [SessionEntry]
        let pendingDeletes: Set<String>
        let unreachable: [String]
        let savedChats: [SavedChat]
        let saved: Set<String>
        let pins: Set<String>
        let archived: Set<ArchivedChatStore.ChatKey>
        let unread: @Sendable (String, Date) -> Bool
        let presence: [String: SessionPresence]
        let lastHeard: [String: Date]
        let memo: [String: SidebarViewController.RowMemo]
        let needle: String
        let scope: ProjectScope?
        let showingArchive: Bool
        let splitTab: SplitTab?
        let observes: Bool
        let now: Date
    }

    let models: [SessionRowModel]
    let memo: [String: SidebarViewController.RowMemo]
    let archivedTotal: Int
    let sections: [(ChatListSection, [ChatListItem])]
    let vocabulary: ChatListVocabulary
    /// What the fleet says for the notices, made only when the listing moved since they last heard.
    let observations: [ActivityObservation]?

    static func make(_ input: Input) -> SidebarWalk {
        var models: [SessionRowModel] = []
        models.reserveCapacity(input.entries.count + 8)
        var memo: [String: SidebarViewController.RowMemo] = [:]
        memo.reserveCapacity(input.entries.count + 8)
        for entry in input.entries {
            let key = ChatSelection.key(entry)
            guard !input.pendingDeletes.contains(key) else { continue }
            let label = ServerLabel.display(name: entry.profileName, backend: entry.backendType)
            let down = input.unreachable.contains(label)
            let unread = input.unread(entry.session.id, entry.session.updatedAt)
            let saved = input.saved.contains(entry.session.id)
            let pinned = input.pins.contains(SessionPinStore.key(entry.profileID, entry.session.id))
            let seen = input.presence[key] ?? .unobserved
            let observedAt = input.lastHeard[label]
            let bucket = ageBucket(
                entry.session.updatedAt, asOf: down ? (observedAt ?? input.now) : input.now)
            if let held = input.memo[key],
                held.matches(
                    session: entry.session, unreachable: down, unread: unread, saved: saved,
                    pinned: pinned, presence: seen, observedAt: observedAt, bucket: bucket)
            {
                models.append(held.model)
                memo[key] = held
                continue
            }
            let model = SessionRowModel(
                entry: entry, unreachable: down, unread: unread, saved: saved, pinned: pinned,
                presence: seen, observedAt: observedAt, now: input.now)
            models.append(model)
            memo[key] = SidebarViewController.RowMemo(
                session: entry.session, unreachable: down, unread: unread, saved: saved,
                pinned: pinned, presence: seen, observedAt: observedAt, bucket: bucket, model: model)
        }
        models += orphanedSavedRows(input.savedChats, listed: input.entries)
        let observations =
            input.observes
            ? models.map {
                ActivityObservation(
                    profileID: $0.entry.profileID, session: $0.entry.session, title: $0.title)
            } : nil
        let isArchived: (SessionRowModel) -> Bool = {
            input.archived.contains(
                ArchivedChatStore.ChatKey(profileID: $0.entry.profileID, sessionID: $0.entry.session.id))
        }
        let scoped = input.scope.map { scope in models.filter { scope.matches($0.entry) } } ?? models
        let archivedTotal = scoped.filter(isArchived).count
        let needle = input.needle
        let matching = scoped.filter {
            needle.isEmpty || $0.title.lowercased().contains(needle)
                || $0.detail.lowercased().contains(needle)
                || ($0.snippet?.lowercased().contains(needle) ?? false)
        }
        let active = matching.filter { !isArchived($0) || $0.isUnfinished }
        let grouped: [(ChatListSection, [SessionRowModel])] =
            input.showingArchive
            ? [(ChatListSection.archived, matching.filter(isArchived))].filter { !$0.1.isEmpty }
            : groupIntoListSections(active, now: input.now)
        let sections = SplitTabGrouping.apply(
            to: grouped, tab: input.showingArchive ? nil : input.splitTab)
        return SidebarWalk(
            models: models, memo: memo, archivedTotal: archivedTotal, sections: sections,
            vocabulary: ChatListVocabulary(rows: models), observations: observations)
    }

    /// The walk on the cooperative pool, never on the main actor, with the CPU time it took there.
    @concurrent
    static func away(_ input: Input) async -> (walk: SidebarWalk, spent: Double) {
        let began = threadTime()
        let walk = make(input)
        return (walk, threadTime() - began)
    }

    /// How an age column's word is bucketed: the one number that changes when the string would.
    static func ageBucket(_ date: Date, asOf reference: Date) -> Int {
        let seconds = max(0, Int(reference.timeIntervalSince(date)))
        if seconds < 60 { return seconds }
        if seconds < 3600 { return 60 + seconds / 60 }
        if seconds < 86_400 { return 3_660 + seconds / 3_600 }
        return 90_000 + seconds / 86_400
    }

    /// A bookmark must still list and explain itself when its server is unreachable, its session
    /// deleted, or its profile removed — the saved list never depends on a live listing. Rows for
    /// chats the listing no longer covers are rebuilt from the bookmark's own snapshot.
    private static func orphanedSavedRows(
        _ savedChats: [SavedChat], listed: [SessionEntry]
    ) -> [SessionRowModel] {
        let listedIDs = Set(listed.map(\.session.id))
        return savedChats.filter { !listedIDs.contains($0.sessionID) }.map { chat in
            let session = AgentSession(
                id: chat.sessionID, agentType: chat.backend, title: chat.displayTitle,
                directory: chat.directory, createdAt: chat.savedAt, updatedAt: chat.updatedAt)
            let entry = SessionEntry(
                profileID: chat.profileID, profileName: chat.profileName,
                host: chat.profileName, backendType: chat.backend, session: session)
            return SessionRowModel(entry: entry, unreachable: true, unread: false, saved: true)
        }
    }

    private static func threadTime() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }
}
