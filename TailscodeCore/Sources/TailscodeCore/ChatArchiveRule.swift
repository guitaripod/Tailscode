import CodingAgentKit
import Foundation

/// When the device-local archive is allowed to take a conversation out of the main list, and what
/// it says when it files one.
///
/// Archiving files something that is over. A conversation that is still doing something is not
/// over: a turn is running, a question is waiting to be answered, or the agent's process is
/// carrying work between turns and will speak again on its own. The archive may not hide any of
/// those — a chat that is working and nowhere in the list is not filed, it is lost, and because
/// the archive is device-local the same conversation stays in plain sight on every other machine,
/// which is exactly how a hidden row reads as a client that dropped a session rather than one
/// that put it away.
///
/// The reading is never taken from the offline mark. A server that missed a listing turns every
/// row it holds `.offline`, so what was last observed about the conversation is what decides this
/// — a machine falling off the tailnet cannot make the archive swallow a chat that was working
/// the last time anybody looked at it.
public enum ChatArchiveRule {
    /// Whether anything about the conversation is still going, from what this device watched
    /// first-hand and what the listing last said, in that order.
    public static func isUnfinished(presence: SessionPresence, session: AgentSession) -> Bool {
        presence.isInFlight || session.isWorking || session.backgroundWork != nil
    }

    /// Whether a filed conversation may be hidden from the main list.
    public static func mayHide(presence: SessionPresence, session: AgentSession) -> Bool {
        !isUnfinished(presence: presence, session: session)
    }

    /// What the list says the moment a chat is filed or brought back, because on a desktop this is
    /// one keystroke and a row leaving the list without a word reads as a lost conversation. A
    /// chat filed while it is still working says so too: it stays listed, and an archive that
    /// looked like it did nothing would be worse than one that explains itself.
    public static func word(filed: Bool, title: String, unfinished: Bool) -> String {
        guard filed else { return Localized.text("“%@” is back in the list", title) }
        return unfinished
            ? Localized.text("Archived “%@” — it stays listed while it is working", title)
            : Localized.text("Archived “%@” — it is in the archive", title)
    }
}

extension SessionRowModel {
    /// Whether the conversation this row stands for is still going — the reading `ChatArchiveRule`
    /// makes, asked of a row that has already resolved its state.
    public var isUnfinished: Bool {
        state.isInFlight || entry.session.isWorking || entry.session.backgroundWork != nil
    }

    /// Whether the archive may take this row out of the main list.
    public var mayBeFiledAway: Bool { !isUnfinished }
}
