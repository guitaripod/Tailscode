import Foundation

/// The verbs a chat row offers to a pointer resting on it, without a right-click: the ones
/// somebody reaches for most, and the way into the rest.
public enum ChatRowVerb: CaseIterable, Sendable {
    case pin
    case save
    case archive
    case more
}

/// Which way each verb would go if pressed now, read when the pointer arrives rather than kept on
/// the row, because the stores can change under a row that is not being redrawn.
public struct ChatRowVerbState: Equatable, Sendable {
    public var pinned: Bool
    public var saved: Bool
    public var archived: Bool

    public init(pinned: Bool, saved: Bool, archived: Bool) {
        self.pinned = pinned
        self.saved = saved
        self.archived = archived
    }

    /// Whether the verb is currently in force on the chat — a pinned chat's pin is lit, because
    /// pressing it would take the pin away.
    public func isOn(_ verb: ChatRowVerb) -> Bool {
        switch verb {
        case .pin: return pinned
        case .save: return saved
        case .archive: return archived
        case .more: return false
        }
    }

    /// What pressing the verb does to this chat, in the words its context menu uses.
    public func title(_ verb: ChatRowVerb) -> String {
        switch verb {
        case .pin: return pinned ? Localized.text("Unpin") : Localized.text("Pin")
        case .save: return saved ? Localized.text("Unsave") : Localized.text("Save")
        case .archive: return archived ? Localized.text("Unarchive") : Localized.text("Archive")
        case .more: return Localized.text("More")
        }
    }
}
