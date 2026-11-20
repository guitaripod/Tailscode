import CodingAgentKit
import Foundation

/// Which of the pictures an agent's tools handed back it actually showed the person.
///
/// A tool that reads a picture hands it to the model and to the transcript alike, so every
/// screenshot an agent took to check its own work landed in the turn's strip: dozens of pictures
/// the agent looked at for itself, none of them meant for the reader, and the one it wanted seen
/// lost among them. An agent shows a picture by naming it, so a picture a tool handed back is
/// drawn only when the words the agent wrote in that turn name its file, and of several pictures
/// of one name only the newest, because a file taken again after a fix is the file the words are
/// about. A picture no tool handed back, and every picture the person sent, is always drawn.
///
/// The decision is about one turn's messages and nothing else, so a finished turn is read once:
/// the words are searched again only when the turn they belong to changes.
public enum PictureShowing {
    /// The key a client gives the row it builds for a part, which is what `unshown(in:)` holds.
    public static func key(message: String, part: String) -> String { "\(message):\(part)" }

    /// The pictures to leave out of the transcript, by `key(message:part:)`.
    public static func unshown(in messages: some Sequence<ChatMessage>) -> Set<String> {
        var unshown = Set<String>()
        var turn = Turn()
        for message in messages {
            if message.role == .user {
                unshown.formUnion(turn.unshown(ledger: ledger))
                turn = Turn()
            }
            turn.read(message)
        }
        unshown.formUnion(turn.unshown(ledger: ledger))
        return unshown
    }

    /// The names a picture can be pointed at by: its file's own name and the last part of the path
    /// it was read from, or, for a picture that carries neither, the path the tool that handed it
    /// back was given. Only a name with a stem and an extension counts, so "screenshot" said in
    /// passing names nothing.
    static func names(of file: FileReference, from call: ToolCall?) -> [String] {
        var own = [file.filename, file.path]
        if let url = file.url, url.hasPrefix("file://") {
            own.append(String(url.dropFirst("file://".count)).removingPercentEncoding)
        }
        let names = nameable(own)
        guard names.isEmpty else { return names }
        return nameable(["filePath", "file_path", "path"].map { call?.input?[$0]?.stringValue })
    }

    private static func nameable(_ paths: [String?]) -> [String] {
        var names: [String] = []
        for case let path? in paths {
            let name = basename(path)
            if isNameable(name), !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// The last component of a path, read without Foundation's path APIs, which trap on Linux for
    /// some of the relative paths a tool call carries.
    static func basename(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return String(trimmed) }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// Whether a name is specific enough that finding it in prose means the prose is about it.
    static func isNameable(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return name.index(after: dot) != name.endIndex
    }

    private static let ledger = Ledger()

    private struct Picture: Equatable {
        let key: String
        let names: [String]
    }

    /// What decides a turn: the pictures its tools handed back and the words the agent wrote,
    /// held as a print that differs whenever either does.
    private struct Turn {
        var anchor: String?
        var print = Print()

        mutating func read(_ message: ChatMessage) {
            if anchor == nil { anchor = message.id }
            print.messages += 1
            print.last = message.id
            guard message.role == .assistant else { return }
            var call: ToolCall?
            for part in message.parts {
                switch part.kind {
                case .tool(let tool):
                    call = tool
                case .text(let text):
                    guard !text.isEmpty else { continue }
                    print.prose.append(text)
                case .file(let file):
                    guard let call, (file.mime ?? "").hasPrefix("image/") else { continue }
                    print.pictures.append(
                        Picture(
                            key: PictureShowing.key(message: message.id, part: part.id),
                            names: PictureShowing.names(of: file, from: call)))
                default:
                    continue
                }
            }
        }

        func unshown(ledger: Ledger) -> [String] {
            guard let anchor, !print.pictures.isEmpty else { return [] }
            if let known = ledger.unshown(turn: anchor, print: print) { return known }
            let decided = decide()
            ledger.keep(decided, turn: anchor, print: print)
            return decided
        }

        private func decide() -> [String] {
            var named: [String: Bool] = [:]
            func isNamed(_ name: String) -> Bool {
                if let known = named[name] { return known }
                let found = print.prose.contains { $0.contains(name) }
                named[name] = found
                return found
            }
            var newest: [String: String] = [:]
            var hidden: [String] = []
            var shownAs: [(key: String, name: String)] = []
            for picture in print.pictures {
                guard let name = picture.names.first(where: isNamed) else {
                    hidden.append(picture.key)
                    continue
                }
                newest[name] = picture.key
                shownAs.append((picture.key, name))
            }
            for (key, name) in shownAs where newest[name] != key {
                hidden.append(key)
            }
            return hidden
        }
    }

    /// A turn as the ledger compares it. The words are held, not counted: a finished turn hands
    /// back the same strings on every rebuild, which compare at once, and two turns that only
    /// match in length are still told apart.
    private struct Print: Equatable {
        var messages = 0
        var last = ""
        var prose: [String] = []
        var pictures: [Picture] = []
    }

    /// The turns already decided, by the id of the message that opens each, held only while the
    /// turn still reads the same.
    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (print: Print, unshown: [String])] = [:]
        private static let capacity = 4096

        func unshown(turn: String, print: Print) -> [String]? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[turn], entry.print == print else { return nil }
            return entry.unshown
        }

        func keep(_ unshown: [String], turn: String, print: Print) {
            lock.lock()
            defer { lock.unlock() }
            if entries.count >= Self.capacity, entries[turn] == nil { entries.removeAll() }
            entries[turn] = (print, unshown)
        }
    }
}
