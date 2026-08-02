import CodingAgentKit
import Foundation
import TailscodeCore

/// What a row in the chat list is currently saying.
///
/// Every state a session can be in has a component here rather than being inferred at the call
/// site: a list that silently renders "nothing is happening" for four different reasons is the
/// thing this app most needs not to do.
enum SessionRowState: Equatable {
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

    var pill: (text: String, css: String)? {
        switch self {
        case .awaitingApproval: return (Localized.text("NEEDS YOU"), "pill-needs")
        case .live: return (Localized.text("LIVE"), "pill-live")
        case .failed: return (Localized.text("FAILED"), "pill-error")
        case .offline: return (Localized.text("OFFLINE"), "pill-offline")
        case .idle: return nil
        }
    }

    var glyph: (text: String, css: String) {
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
struct SessionRowModel: Equatable {
    let entry: SessionEntry
    let state: SessionRowState
    let title: String
    let detail: String
    let unread: Bool
    let saved: Bool

    init(entry: SessionEntry, unreachable: Bool, unread: Bool, saved: Bool) {
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
    static func age(of date: Date) -> String {
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
enum SessionSection: String, CaseIterable {
    case live
    case saved
    case recent

    var title: String {
        switch self {
        case .live: return Localized.text("LIVE NOW")
        case .saved: return Localized.text("SAVED")
        case .recent: return Localized.text("RECENT")
        }
    }
}

/// Splits a flat listing into the sections the sidebar draws, dropping empty ones so the list
/// never shows a heading with nothing under it.
func groupIntoSections(_ rows: [SessionRowModel]) -> [(SessionSection, [SessionRowModel])] {
    let live = rows.filter { $0.state == .live || $0.state == .awaitingApproval }
    let saved = rows.filter { $0.saved && !live.contains($0) }
    let seen = Set((live + saved).map(\.entry.session.id))
    let recent = rows.filter { !seen.contains($0.entry.session.id) }
    return [(.live, live), (.saved, saved), (.recent, recent)].filter { !$0.1.isEmpty }
}
