import CodingAgentKit
import Foundation

/// What a row in the chat list is currently saying.
///
/// Every state a session can be in has a component here rather than being inferred at the call
/// site: a list that silently renders "nothing is happening" for four different reasons is the
/// thing this app most needs not to do.
public enum SessionRowState: Equatable, Sendable {
    /// A turn is running and it needs an answer before it can go on.
    case awaitingApproval
    /// A turn is running.
    case live
    /// Listed, reachable, nothing running.
    case idle
    /// Its server did not answer the last listing; what is shown is remembered, not observed.
    case offline
    /// The last turn ended in an error.
    case failed

    public var pill: (text: String, css: String)? {
        switch self {
        case .awaitingApproval: return (Localized.text("NEEDS YOU"), "pill-needs")
        case .live: return (Localized.text("LIVE"), "pill-live")
        case .failed: return (Localized.text("FAILED"), "pill-error")
        case .offline: return (Localized.text("OFFLINE"), "pill-offline")
        case .idle: return nil
        }
    }

    /// The row's state in the vocabulary every client animates from. A listing can say that a turn
    /// is open but never what it is doing, so a live row is `.working` rather than a guess between
    /// thinking and writing; a chat this device is streaming says more, in its own chrome.
    /// Idle has no activity at all — the absence is the point, and a badge reading "idle" is noise.
    public var activity: ActivityKind? {
        switch self {
        case .awaitingApproval: return .needsApproval
        case .live: return .working
        case .failed: return .failed
        case .offline: return .offline
        case .idle: return nil
        }
    }

    /// What the glyph column draws, including for idle — a row that is doing nothing still holds
    /// its column, so a list of mixed states keeps one straight edge down its left side.
    public var icon: ActivityIcon {
        activity?.icon ?? .idle
    }

    public var glyph: (text: String, css: String) { (icon.glyph, icon.glyphCSS) }

    /// Whether the row belongs in LIVE NOW. A turn that stopped to ask something is still a turn
    /// in flight — it is the one the person most needs to find — so it leads the section rather
    /// than falling back into recency with everything that finished hours ago.
    public var isInFlight: Bool {
        self == .live || self == .awaitingApproval
    }
}

/// What this device knows about a session first-hand, which a listing cannot tell it.
///
/// A listing is a poll of another machine: it reports `active` for the seconds a turn is literally
/// open on the server and says nothing about a turn that stopped to ask permission, nothing about
/// one that failed, and nothing at all in the window between the local stream starting a turn and
/// the server's next sweep. A client that is streaming a conversation knows all of that already,
/// so it hands it in here instead of leaving the row to guess from a stale flag.
public enum SessionPresence: Sendable, Equatable {
    /// Nothing on this device is watching it; the listing is the only witness.
    case unobserved
    /// A turn is running here, optionally with the step it is on.
    case running(String?)
    /// A turn is running here and is waiting to be answered.
    case awaitingApproval
    /// The last turn this device watched ended in a failure.
    case failed
}

/// Everything one row needs, derived once so the widget builder has no logic in it.
public struct SessionRowModel: Equatable, Sendable {
    public let entry: SessionEntry
    public let state: SessionRowState
    public let title: String
    public let detail: String
    public let unread: Bool
    public let saved: Bool
    public let pinned: Bool
    /// The directory the conversation belongs to, which is what a person calls it.
    public let project: String?
    /// The machine it lives on, and the agent answering there, kept apart so a list can drop
    /// either one when it distinguishes nothing.
    public let serverName: String
    public let backendName: String
    /// How long ago it last moved, in the compact form the age column draws.
    public let age: String
    /// What the agent is working on, when it is working — the line a busy row leads with.
    public let snippet: String?

    /// - Parameter presence: what this device is watching first-hand. First-hand beats the
    ///   listing in both directions: a turn running here is live before the server's sweep agrees,
    ///   and a server that missed a listing cannot make a conversation this device is streaming
    ///   look offline.
    public init(
        entry: SessionEntry, unreachable: Bool, unread: Bool, saved: Bool, pinned: Bool = false,
        presence: SessionPresence = .unobserved
    ) {
        self.entry = entry
        self.unread = unread
        self.saved = saved
        self.pinned = pinned
        self.title =
            entry.session.hasPlaceholderTitle
            ? Localized.text("New conversation") : entry.session.title
        self.project = entry.session.directory.map { URL(fileURLWithPath: $0).lastPathComponent }
        self.serverName = entry.profileName
        self.backendName = ServerLabel.agent(entry.backendType)
        self.age = Self.age(of: entry.session.updatedAt)
        self.detail = [
            project, ServerLabel.display(name: entry.profileName, backend: entry.backendType), age,
        ].compactMap { $0 }.joined(separator: " · ")
        self.state = Self.resolve(entry: entry, unreachable: unreachable, presence: presence)
        switch presence {
        case .running(let step) where step?.isEmpty == false:
            self.snippet = step
        default:
            self.snippet = entry.session.isWorking ? entry.session.agentTask : nil
        }
    }

    /// The row's second line, split into the weights a client draws it at and stripped of
    /// whatever the listing as a whole already says. A row that would be left with nothing on its
    /// left falls back to naming its server: an anonymous line is worse than a repeated one.
    public func facets(_ vocabulary: ChatListVocabulary = .full) -> SessionRowFacets {
        var origin: [String] = []
        if vocabulary.namesServer { origin.append(serverName) }
        if vocabulary.namesBackend, !serverName.localizedCaseInsensitiveContains(backendName) {
            origin.append(backendName)
        }
        if origin.isEmpty, project == nil { origin.append(serverName) }
        return SessionRowFacets(
            project: project, origin: origin.isEmpty ? nil : origin.joined(separator: " · "),
            age: age)
    }

    /// The order the row's five states are decided in. What this device watched wins over what the
    /// listing remembered, an unreachable server outranks a flag it can no longer vouch for, and
    /// `isWorking` — not the bare `isActive` — is the listing's own answer, so a session whose
    /// subagents are still out counts as live.
    private static func resolve(
        entry: SessionEntry, unreachable: Bool, presence: SessionPresence
    ) -> SessionRowState {
        switch presence {
        case .awaitingApproval: return .awaitingApproval
        case .running: return .live
        case .failed where !unreachable: return .failed
        case .failed, .unobserved: break
        }
        if unreachable { return .offline }
        return entry.session.isWorking ? .live : .idle
    }

    /// Compact and monospace-friendly, so a column of them lines up: seconds, minutes, hours, days.
    public static func age(of date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}

/// The sections the chat list is grouped into, in the order the phone's board uses.
public enum SessionSection: String, CaseIterable, Sendable {
    case pinned
    case live
    case saved
    case recent

    public var title: String {
        switch self {
        case .pinned: return Localized.text("PINNED")
        case .live: return Localized.text("LIVE NOW")
        case .saved: return Localized.text("SAVED")
        case .recent: return Localized.text("RECENT")
        }
    }
}

/// Splits a flat listing into the sections the sidebar draws, dropping empty ones so the list
/// never shows a heading with nothing under it. Pinned rows lead in their own section, in the
/// order the pins were made, and keep their state pill — a pinned live session reads as pinned
/// *and* live, never as one or the other.
///
/// Membership is decided on `(profileID, sessionID)` rather than the bare session id, because the
/// same id on two servers is two different chats: keying on the id alone let one machine's live
/// conversation swallow another machine's row out of every section below it.
///
/// LIVE NOW is ordered by when each conversation began, newest first, and never by recency of
/// activity: a working chat's `updatedAt` is a clock rather than an identity — it moves every time
/// a token lands — so ordering the section on it made two working chats trade places several times
/// a second under a reader trying to click one. The section a row is *in* already says it is
/// working; where it sits in that section must be a fact that holds still for as long as it is
/// there, and the moment it started is the one fact about a live turn that cannot change.
public func groupIntoSections(_ rows: [SessionRowModel]) -> [(SessionSection, [SessionRowModel])] {
    func key(_ row: SessionRowModel) -> String {
        SessionPinStore.key(row.entry.profileID, row.entry.session.id)
    }
    let pinned = rows.filter { $0.pinned }.sorted {
        guard
            let a = SessionPinStore.rank(
                profileID: $0.entry.profileID, sessionID: $0.entry.session.id),
            let b = SessionPinStore.rank(
                profileID: $1.entry.profileID, sessionID: $1.entry.session.id)
        else { return false }
        return a < b
    }
    var seen = Set(pinned.map(key))
    let live = rows.filter { $0.state.isInFlight && !seen.contains(key($0)) }.sorted {
        $0.entry.session.createdAt == $1.entry.session.createdAt
            ? key($0) < key($1) : $0.entry.session.createdAt > $1.entry.session.createdAt
    }
    seen.formUnion(live.map(key))
    let saved = rows.filter { $0.saved && !seen.contains(key($0)) }
    seen.formUnion(saved.map(key))
    let recent = rows.filter { !seen.contains(key($0)) }
    return [(.pinned, pinned), (.live, live), (.saved, saved), (.recent, recent)]
        .filter { !$0.1.isEmpty }
}
