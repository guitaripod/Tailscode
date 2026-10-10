import Foundation

/// The words for the iCloud sync, written once so every screen that mentions it says the same
/// thing and none of them claims more than was checked.
public enum CloudSyncReading {
    public static var title: String { Localized.text("Sync with iCloud") }

    public static var explanation: String {
        Localized.text(
            "Which chats you have read, saved, pinned or archived follows you to your other devices signed in to the same iCloud account. Their titles and folder names are kept in your iCloud; conversations, servers and passwords never are."
        )
    }

    public static var footer: String {
        Localized.text(
            "Read marks and bookmarks travel through your own iCloud, not through your servers or Midgar. A device that is offline catches up when it is back."
        )
    }

    public struct Line: Sendable, Equatable {
        public var headline: String
        public var detail: String?
        public var isWarning: Bool
    }

    public static func line(for status: CloudSyncStatus, lastSyncedAt: Date?, now: Date = Date())
        -> Line
    {
        switch status {
        case .off:
            return Line(headline: Localized.text("Off"), detail: nil, isWarning: false)
        case .unavailable:
            return Line(
                headline: Localized.text("iCloud is not available"),
                detail: Localized.text(
                    "Sign in to iCloud in Settings on this device, and make sure Tailscode is allowed to use it."
                ),
                isWarning: true)
        case .syncing:
            return Line(headline: Localized.text("Syncing…"), detail: nil, isWarning: false)
        case .synced(let at):
            guard let when = at ?? lastSyncedAt else {
                return Line(headline: Localized.text("Up to date"), detail: nil, isWarning: false)
            }
            return Line(
                headline: Localized.text("Up to date"),
                detail: Localized.text("Last checked %@", relative(when, now: now)),
                isWarning: false)
        }
    }

    private static func relative(_ date: Date, now: Date) -> String {
        #if canImport(Darwin)
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: now)
        #else
            return date.formatted(date: .abbreviated, time: .shortened)
        #endif
    }
}
