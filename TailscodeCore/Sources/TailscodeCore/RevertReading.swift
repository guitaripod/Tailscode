import CodingAgentKit
import Foundation

/// A conversation wound back to one of your messages, read into the banner every client docks
/// where the set-aside messages used to be.
///
/// Winding back is a big thing to do quietly: the messages after the point disappear from the
/// transcript and the files the agent changed since are put back on the machine. So the banner says
/// how much was set aside and which files changed, and keeps the way back one press away until
/// the next message is sent, which makes it final on the server.
public struct RevertBanner: Sendable, Hashable {
    /// One file the revert put back, as a row: its path, what happened to it, and by how much.
    public struct FileLine: Sendable, Hashable {
        public let path: String
        public let change: String
        public let counts: String?
    }

    public let title: String
    public let detail: String
    public let files: [FileLine]
    public let restoreTitle: String
    public let spoken: String

    public static let symbol = "arrow.uturn.backward.circle"
    public static let glyph = "↶"
    public static let tone = ActivityTone.attention

    /// The file rows a surface with room for `limit` of them draws, and the line that stands for
    /// the rest. One file over the limit is drawn rather than summed up, since a line saying "1
    /// more file" takes the room the file itself would.
    public func files(upTo limit: Int) -> (shown: [FileLine], more: String?) {
        guard files.count > limit + 1 else { return (files, nil) }
        return (
            Array(files.prefix(limit)),
            Localized.text("%@ more files", "\(files.count - limit)")
        )
    }
}

public enum RevertReading {
    /// The banner for a standing revert, or `nil` when nothing is wound back.
    public static func read(_ revert: SessionRevert?, setAside: [ChatMessage]) -> RevertBanner? {
        guard let revert else { return nil }
        let prompts = setAside.filter { $0.role == .user }.count
        let title =
            prompts == 1
            ? Localized.text("Wound back one message")
            : Localized.text("Wound back %@ messages", "\(max(prompts, 1))")
        let detail =
            revert.files.isEmpty
            ? Localized.text(
                "Your next message makes this final. Until then, Restore brings everything back.")
            : Localized.text(
                "The files the agent changed since are back as they were. Your next message makes this final; until then, Restore brings everything back.")
        let files = revert.files.map(fileLine)
        let spoken = ([title, detail] + files.map { "\($0.path), \($0.change)" }).joined(
            separator: ". ")
        return RevertBanner(
            title: title, detail: detail, files: files, restoreTitle: restoreTitle,
            spoken: spoken)
    }

    /// The words of the message the conversation was wound back to, for the composer: winding back
    /// to a message is most often the wish to say it differently, so it comes back ready to edit.
    public static func prompt(in setAside: [ChatMessage]) -> String? {
        guard let first = setAside.first, first.role == .user else { return nil }
        let text = first.parts.compactMap(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Whether a message can be wound back to: one of your own, on a server that can do it.
    public static func offersUndo(on message: ChatMessage, capabilities: BackendCapabilities)
        -> Bool
    {
        capabilities.supportsRevert && message.role == .user
    }

    public static var actionTitle: String { Localized.text("Undo from here") }
    public static var actionSymbol: String { "arrow.uturn.backward" }
    public static var confirmTitle: String { Localized.text("Undo from here?") }
    /// What the confirmation says the press will do. `stopping` is whether a turn is running, which
    /// the press stops first: the one part of it Restore cannot give back.
    public static func confirmMessage(stopping: Bool) -> String {
        stopping
            ? Localized.text(
                "The turn that is running stops. This message and everything after it are set aside, and the files the agent changed since are put back. You can restore the messages and files until you send your next message.")
            : Localized.text(
                "This message and everything after it are set aside, and the files the agent changed since are put back. You can restore it all until you send your next message.")
    }
    public static var confirmAction: String { Localized.text("Undo") }
    public static var restoreTitle: String { Localized.text("Restore") }
    public static var restoringTitle: String { Localized.text("Restoring…") }
    public static var undoingTitle: String { Localized.text("Winding back…") }

    /// What to say when a revert or its undoing failed, in the words the failure arrived with.
    public static func failure(restoring: Bool, _ error: Error) -> String {
        let reason = AgentErrorText.readable(error)
        return restoring
            ? Localized.text("The conversation could not be restored: %@", reason)
            : Localized.text("The conversation could not be wound back: %@", reason)
    }

    static func fileLine(_ file: SessionRevert.File) -> RevertBanner.FileLine {
        let change: String
        switch file.change {
        case .deleted: change = Localized.text("removed")
        case .added: change = Localized.text("brought back")
        case .modified: change = Localized.text("put back")
        }
        var counts: [String] = []
        if file.additions > 0 { counts.append("+\(file.additions)") }
        if file.deletions > 0 { counts.append("−\(file.deletions)") }
        return RevertBanner.FileLine(
            path: file.path, change: change,
            counts: counts.isEmpty ? nil : counts.joined(separator: " "))
    }
}
