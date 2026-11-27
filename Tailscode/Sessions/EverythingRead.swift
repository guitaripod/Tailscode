import CodingAgentKit
import MidgarCore
import TailscodeCore
import UIKit

/// The one press that reads everything, wherever the app offers it: Home's heading and its tools,
/// and the chat list beside a conversation, where Home has neither.
@MainActor
enum EverythingRead {
    /// What a press would read right now, from the listing the caller holds.
    static func sweep(entries: [SessionEntry], unreachable: [String]) -> ReadSweep {
        ReadSweep.reading(
            entries: entries, saved: SavedChatStore.all(),
            presence: SessionActivity.shared.presenceSummary(), unreachable: Set(unreachable),
            notices: ActivityInbox.all().count, isUnread: SessionSeenStore.unreadEvaluator())
    }

    /// Reads every chat in the sweep, each told to its server like a single press, and takes back
    /// every notice still standing, so the list, Notification Center and the app icon's number
    /// come to rest together.
    static func perform(_ sweep: ReadSweep) {
        SessionSeenStore.markSeen(sweep.chats)
        NotificationManager.clearAllNotices()
        MidgarLog.info(
            "everything marked read: \(sweep.chats.count) chat(s), \(sweep.notices) notice(s)",
            category: .ui)
        Theme.Haptics.success()
    }
}
