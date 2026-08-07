import CodingAgentKit
import Foundation

/// Several chats at once, and the words for what happens to them.
///
/// Clearing out a week of dead conversations one confirm dialog at a time is the tax this list
/// charges most often, so the list learns to hold a set. The set is deliberately ephemeral — it is
/// a gesture in progress, not a preference — and it is keyed on `(profileID, sessionID)` like every
/// other store here, because the same session id on two servers is two different chats and a bulk
/// delete that confused them would take the wrong one from the wrong machine.
///
/// Toolkit-free so the phone's editing mode, GTK's marks and AppKit's marks are one behaviour:
/// what is selected, what a verb may do to it, and what the person is told afterwards.
public struct ChatSelection: Sendable, Equatable {
    public private(set) var keys: Set<String> = []

    public init() {}

    public init(_ entries: [SessionEntry]) {
        keys = Set(entries.map(Self.key))
    }

    public static func key(_ entry: SessionEntry) -> String {
        SessionPinStore.key(entry.profileID, entry.session.id)
    }

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }

    public func contains(_ entry: SessionEntry) -> Bool {
        keys.contains(Self.key(entry))
    }

    /// Answers whether the chat is now selected, so a client can play the cue for what it did
    /// rather than re-reading the set to find out.
    @discardableResult
    public mutating func toggle(_ entry: SessionEntry) -> Bool {
        let id = Self.key(entry)
        if keys.contains(id) {
            keys.remove(id)
            return false
        }
        keys.insert(id)
        return true
    }

    public mutating func insert(_ entry: SessionEntry) {
        keys.insert(Self.key(entry))
    }

    public mutating func remove(_ entry: SessionEntry) {
        keys.remove(Self.key(entry))
    }

    public mutating func clear() {
        keys.removeAll()
    }

    /// Selects everything on screen, or clears when everything on screen is already selected —
    /// one key that means "all of it" and, pressed again, "none of it".
    @discardableResult
    public mutating func toggleAll(in visible: [SessionEntry]) -> Bool {
        let all = Set(visible.map(Self.key))
        if !all.isEmpty, all.isSubset(of: keys) {
            keys.subtract(all)
            return false
        }
        keys.formUnion(all)
        return true
    }

    /// The selected chats in the order the list is drawing them, so a confirm dialog names them
    /// the way the eye just read them.
    public func resolve(in visible: [SessionEntry]) -> [SessionEntry] {
        visible.filter { keys.contains(Self.key($0)) }
    }

    /// Drops keys the listing no longer covers. The list re-sorts and re-filters underneath a
    /// selection — a stream upsert, a filter chip, a server going quiet — and a set holding chats
    /// that are no longer anywhere would delete rows the person can no longer see.
    public mutating func prune(to visible: [SessionEntry]) {
        keys.formIntersection(Set(visible.map(Self.key)))
    }
}

/// What a selection can be told to do. Every verb here already exists as a single-row action; this
/// is the same meaning applied to a set, which is why nothing new needs explaining when it appears
/// on a toolbar.
public enum BulkChatAction: String, Sendable, CaseIterable {
    case delete
    case archive
    case unarchive
    case save
    case unsave
    case markRead
    case markUnread

    public var isDestructive: Bool { self == .delete }
}

/// The words a bulk gesture says, in one place because all three clients owe the same sentence.
/// A count is never left to a client to phrase: "Delete 4 conversations?" and "Deleted 3 · 1
/// failed" are the contract, and the singular is written out rather than left as "1 conversations".
public enum BulkChatCopy {
    public static func title(_ action: BulkChatAction, count: Int) -> String {
        switch action {
        case .delete:
            return count == 1
                ? Localized.text("Delete this conversation?")
                : Localized.text("Delete %@ conversations?", "\(count)")
        case .archive: return Localized.text("Archive")
        case .unarchive: return Localized.text("Unarchive")
        case .save: return Localized.text("Save")
        case .unsave: return Localized.text("Remove from Saved")
        case .markRead: return Localized.text("Mark as read")
        case .markUnread: return Localized.text("Mark as unread")
        }
    }

    /// What the person is agreeing to, named rather than counted where naming still fits: three
    /// titles read as three chats, thirty read as a number and a warning that it cannot be undone.
    public static func message(count: Int, titles: [String]) -> String {
        let listed = titles.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        let gone = Localized.text("This cannot be undone.")
        if count <= 3, !listed.isEmpty {
            return Localized.text("%@ will be removed from the server. %@", listed, gone)
        }
        if listed.isEmpty {
            return Localized.text("They will be removed from the server. %@", gone)
        }
        return Localized.text(
            "%@ and %@ more will be removed from the server. %@", listed, "\(count - 3)", gone)
    }

    public static func confirm(_ action: BulkChatAction, count: Int) -> String {
        switch action {
        case .delete:
            return count == 1
                ? Localized.text("Delete") : Localized.text("Delete %@", "\(count)")
        case .archive, .unarchive, .save, .unsave, .markRead, .markUnread:
            return title(action, count: count)
        }
    }

    /// The button that starts the gesture, counting what it would act on so the number is read
    /// before the tap rather than in the dialog after it.
    public static func button(_ action: BulkChatAction, count: Int) -> String {
        count == 0 ? title(action, count: 0) : confirm(action, count: count)
    }

    /// How the person is told what actually happened. Silence when everything worked — the rows
    /// are gone, which is the whole report — and one sentence naming the shortfall when it did
    /// not, because a partial failure that says nothing reads as a delete that silently skipped.
    public static func outcome(_ outcome: BulkChatOutcome) -> String? {
        guard outcome.failed > 0 else { return nil }
        if outcome.deleted == 0 {
            return outcome.failed == 1
                ? Localized.text("Could not delete it: %@", outcome.reason ?? "")
                : Localized.text(
                    "Could not delete %@ conversations: %@", "\(outcome.failed)",
                    outcome.reason ?? "")
        }
        return Localized.text(
            "Deleted %@ · %@ failed: %@", "\(outcome.deleted)", "\(outcome.failed)",
            outcome.reason ?? "")
    }
}

/// What a bulk delete came back with. Three of seven succeeding has no precedent as a single
/// error, so it is reported as a count and one reason — the first failure's, since a fan-out that
/// fails usually fails the same way for every row.
public struct BulkChatOutcome: Sendable, Equatable {
    public let deleted: Int
    public let failed: Int
    public let reason: String?

    public init(deleted: Int, failed: Int, reason: String?) {
        self.deleted = deleted
        self.failed = failed
        self.reason = reason
    }

    public var isClean: Bool { failed == 0 }
}

/// The selection's rules, checked headlessly so all three clients are proved against one set of
/// answers rather than each testing its own widgets.
public enum ChatSelectionCheck {
    public static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let a = entry(profileID: "one", sessionID: "s1")
        let b = entry(profileID: "one", sessionID: "s2")
        let clash = entry(profileID: "two", sessionID: "s1")
        let visible = [a, b, clash]

        var selection = ChatSelection()
        expect(selection.isEmpty, "a fresh selection holds nothing")
        expect(selection.toggle(a), "toggling an unselected chat selects it")
        expect(selection.contains(a), "and it is in the set")
        expect(!selection.contains(clash), "the same session id on another server is another chat")
        expect(!selection.toggle(a), "toggling again clears it")
        expect(selection.isEmpty, "and the set is empty again")

        selection.insert(a)
        selection.insert(clash)
        expect(selection.count == 2, "two servers, two rows")
        expect(
            selection.resolve(in: visible).map(\.profileID) == ["one", "two"],
            "resolution follows the drawn order")

        expect(selection.toggleAll(in: visible), "a partial selection fills up")
        expect(selection.count == 3, "everything visible is selected")
        expect(!selection.toggleAll(in: visible), "a full selection empties")
        expect(selection.isEmpty, "select-all is its own undo")

        selection.insert(a)
        selection.insert(b)
        selection.prune(to: [a])
        expect(selection.count == 1 && selection.contains(a), "pruning drops what left the list")

        expect(
            BulkChatCopy.title(.delete, count: 1) == Localized.text("Delete this conversation?"),
            "one chat is not counted at it")
        expect(
            BulkChatCopy.outcome(BulkChatOutcome(deleted: 4, failed: 0, reason: nil)) == nil,
            "a clean run says nothing")
        expect(
            BulkChatCopy.outcome(BulkChatOutcome(deleted: 2, failed: 1, reason: "offline")) != nil,
            "a partial run says what it missed")
        expect(BulkChatAction.delete.isDestructive, "delete is the destructive verb")
        expect(!BulkChatAction.archive.isDestructive, "archive is not")
        return failures
    }

    private static func entry(profileID: String, sessionID: String) -> SessionEntry {
        SessionEntry(
            profileID: profileID, profileName: profileID, host: profileID, backendType: .claudeCode,
            session: AgentSession(
                id: sessionID, agentType: .claudeCode, title: sessionID, directory: nil,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)))
    }
}
