import CodingAgentKit
import Foundation
import TailscodeCore

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

    public var glyph: (text: String, css: String) {
        switch self {
        case .awaitingApproval: return ("⏸", "glyph-running")
        case .live: return ("◐", "glyph-running")
        case .idle: return ("·", "glyph-pending")
        case .offline: return ("⚠", "glyph-pending")
        case .failed: return ("✗", "glyph-error")
        }
    }
}

/// Everything one row needs, derived once so the widget builder has no logic in it.
public struct SessionRowModel: Equatable, Sendable {
    public let entry: SessionEntry
    public let state: SessionRowState
    public let title: String
    public let detail: String
    public let unread: Bool
    public let saved: Bool

    public init(entry: SessionEntry, unreachable: Bool, unread: Bool, saved: Bool) {
        self.entry = entry
        self.unread = unread
        self.saved = saved
        self.title =
            entry.session.hasPlaceholderTitle
            ? Localized.text("New conversation") : entry.session.title
        let project = entry.session.directory.map { URL(fileURLWithPath: $0).lastPathComponent }
        let age = Self.age(of: entry.session.updatedAt)
        self.detail = [
            project, ServerLabel.display(name: entry.profileName, backend: entry.backendType), age,
        ].compactMap { $0 }.joined(separator: " · ")
        if unreachable {
            self.state = .offline
        } else if entry.session.isActive == true {
            self.state = .live
        } else {
            self.state = .idle
        }
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
    case live
    case saved
    case recent

    public var title: String {
        switch self {
        case .live: return Localized.text("LIVE NOW")
        case .saved: return Localized.text("SAVED")
        case .recent: return Localized.text("RECENT")
        }
    }
}

/// Splits a flat listing into the sections the sidebar draws, dropping empty ones so the list
/// never shows a heading with nothing under it.
public func groupIntoSections(_ rows: [SessionRowModel]) -> [(SessionSection, [SessionRowModel])] {
    let live = rows.filter { $0.state == .live || $0.state == .awaitingApproval }
    let liveIDs = Set(live.map(\.entry.session.id))
    let saved = rows.filter { $0.saved && !liveIDs.contains($0.entry.session.id) }
    let seen = liveIDs.union(saved.map(\.entry.session.id))
    let recent = rows.filter { !seen.contains($0.entry.session.id) }
    return [(.live, live), (.saved, saved), (.recent, recent)].filter { !$0.1.isEmpty }
}
