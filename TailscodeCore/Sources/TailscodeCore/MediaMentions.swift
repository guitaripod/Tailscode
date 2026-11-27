import CodingAgentKit
import Foundation

/// What kind of media a file is, read from its type or, failing that, its extension.
public enum MediaKind: String, Sendable, CaseIterable {
    case picture
    case video
    case audio

    /// The kind and type a path's extension names, or nil for anything that is not media.
    public static func of(path: String) -> (kind: MediaKind, mime: String)? {
        guard let dot = path.lastIndex(of: "."), path[dot...].count > 1 else { return nil }
        let ext = path[path.index(after: dot)...].lowercased()
        guard !ext.contains("/") else { return nil }
        return types[ext]
    }

    public static func of(_ file: FileReference) -> MediaKind? {
        let mime = (file.mime ?? "").lowercased()
        if mime.hasPrefix("image/") { return .picture }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }
        return (file.filename ?? file.path).flatMap { of(path: $0)?.kind }
    }

    /// Whether AVFoundation plays a file of this extension. WebM, Matroska and Ogg are mpv's alone,
    /// so an Apple client says it cannot play them rather than showing a player that never starts.
    public static func playsOnApple(path: String) -> Bool {
        guard let dot = path.lastIndex(of: ".") else { return false }
        return applePlayable.contains(path[path.index(after: dot)...].lowercased())
    }

    private static let applePlayable: Set<String> = [
        "mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "flac", "aif", "aiff", "caf",
    ]

    private static let types: [String: (kind: MediaKind, mime: String)] = [
        "png": (.picture, "image/png"), "jpg": (.picture, "image/jpeg"),
        "jpeg": (.picture, "image/jpeg"), "gif": (.picture, "image/gif"),
        "webp": (.picture, "image/webp"), "heic": (.picture, "image/heic"),
        "heif": (.picture, "image/heif"), "avif": (.picture, "image/avif"),
        "bmp": (.picture, "image/bmp"), "tif": (.picture, "image/tiff"),
        "tiff": (.picture, "image/tiff"),
        "mp4": (.video, "video/mp4"), "m4v": (.video, "video/x-m4v"),
        "mov": (.video, "video/quicktime"), "webm": (.video, "video/webm"),
        "mkv": (.video, "video/x-matroska"),
        "mp3": (.audio, "audio/mpeg"), "m4a": (.audio, "audio/mp4"), "aac": (.audio, "audio/aac"),
        "wav": (.audio, "audio/wav"), "flac": (.audio, "audio/flac"), "ogg": (.audio, "audio/ogg"),
        "oga": (.audio, "audio/ogg"), "opus": (.audio, "audio/ogg"), "aif": (.audio, "audio/aiff"),
        "aiff": (.audio, "audio/aiff"), "caf": (.audio, "audio/x-caf"),
    ]
}

/// Media an agent shows by writing where it is.
///
/// An agent that renders a picture, cuts a clip or bounces a song tells the person where it put it,
/// and until now that was words: a path nobody on a phone can open. A reply that names a file by
/// its absolute path (or a home-relative `~/` one) and a media extension now carries the file
/// itself, drawn right after the paragraph that names it the way a picture a tool handed back is
/// drawn, fetched from the machine the conversation runs on. The decision is Core's so the three
/// clients draw the same files for the same words.
///
/// Only settled words count: a path is complete only once the sentence around it is, so a reply
/// still streaming, and the newest message of a turn still open (which a bridge does not mark as
/// streaming), is read when it settles, never once per token. A command is not a showing, so inside fenced
/// code a path counts only when it is the whole line. A turn shows each file once, after the last
/// paragraph that names it, and a picture a tool already handed back in that turn under the same
/// name is left to `PictureShowing`, which draws it from its own copy.
public enum MediaMentions {
    /// The part id a mention is drawn under, after the text part `part` that names it.
    public static func partID(after part: String, index: Int) -> String { "\(part)#media\(index)" }

    /// The messages with each settled reply's named media added after the text that names it, or
    /// `messages` itself when no reply names any. `turnOpen` says the newest message is still
    /// being written.
    public static func expanded(_ messages: [ChatMessage], turnOpen: Bool = false) -> [ChatMessage] {
        let writing = turnOpen ? messages.indices.last : nil
        var placements: [Placement] = []
        var turnStart = 0
        var turnPlacements: [String: Placement] = [:]
        var order: [String] = []
        func closeTurn(before end: Int) {
            guard !turnPlacements.isEmpty else { return }
            let handed = toolPictureNames(in: messages[turnStart..<end])
            for path in order {
                guard let placement = turnPlacements[path] else { continue }
                if placement.kind == .picture, handed.contains(ServerFileName.of(path)) { continue }
                placements.append(placement)
            }
            turnPlacements.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
        }
        for (messageIndex, message) in messages.enumerated() {
            if message.role == .user {
                closeTurn(before: messageIndex)
                turnStart = messageIndex
                continue
            }
            guard message.role == .assistant, !message.isStreaming, messageIndex != writing else {
                continue
            }
            for (partIndex, part) in message.parts.enumerated() {
                guard case .text(let text) = part.kind, !text.isEmpty else { continue }
                for path in ledger.paths(message: message.id, part: part.id, text: text) {
                    guard let media = MediaKind.of(path: path) else { continue }
                    if turnPlacements[path] == nil { order.append(path) }
                    turnPlacements[path] = Placement(
                        message: messageIndex, part: partIndex, path: path, kind: media.kind,
                        mime: media.mime)
                }
            }
        }
        closeTurn(before: messages.count)
        guard !placements.isEmpty else { return messages }
        var byMessage: [Int: [Placement]] = [:]
        for placement in placements { byMessage[placement.message, default: []].append(placement) }
        var expanded = messages
        for (messageIndex, placed) in byMessage {
            expanded[messageIndex] = withMentions(messages[messageIndex], placed)
        }
        return expanded
    }

    /// The absolute and home-relative paths with a media extension that a text names, in the order
    /// it names them, each once.
    public static func paths(in text: String) -> [String] {
        guard text.utf8.contains(UInt8(ascii: "/")) else { return [] }
        var found: [String] = []
        var fence: Substring?
        func keep(_ candidate: Substring) {
            guard let path = normalized(candidate), !found.contains(path) else { return }
            found.append(path)
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)[...]
            if let marker = fenceMarker(line) {
                if let open = fence {
                    if marker.first == open.first, marker.count >= open.count,
                        line.dropFirst(marker.count).allSatisfy(\.isWhitespace)
                    {
                        fence = nil
                    }
                } else {
                    fence = marker
                }
                continue
            }
            if fence != nil {
                if onePath(unwrapped(line)) { keep(unwrapped(line)) }
                continue
            }
            if wholeLinePath(line) { keep(unwrapped(line)) }
            for span in codeSpans(in: line) { keep(span) }
            for target in linkTargets(in: line) { keep(target) }
            for token in line.split(whereSeparator: \.isWhitespace) { keep(trimmed(token)) }
        }
        return found
    }

    private struct Placement {
        let message: Int
        let part: Int
        let path: String
        let kind: MediaKind
        let mime: String
    }

    private static func withMentions(_ message: ChatMessage, _ placed: [Placement]) -> ChatMessage {
        var after: [Int: [Placement]] = [:]
        for placement in placed { after[placement.part, default: []].append(placement) }
        var parts: [MessagePart] = []
        parts.reserveCapacity(message.parts.count + placed.count)
        for (index, part) in message.parts.enumerated() {
            parts.append(part)
            for (offset, placement) in (after[index] ?? []).enumerated() {
                parts.append(
                    MessagePart(
                        id: partID(after: part.id, index: offset),
                        kind: .file(
                            ServerFile.reference(
                                path: placement.path, mime: placement.mime, revision: message.id)),
                        startedAt: part.startedAt))
            }
        }
        var copy = message
        copy.parts = parts
        return copy
    }

    /// The names of the pictures tools handed back in a turn, which `PictureShowing` draws itself.
    private static func toolPictureNames(in turn: ArraySlice<ChatMessage>) -> Set<String> {
        var names = Set<String>()
        for message in turn where message.role == .assistant {
            var afterTool = false
            for part in message.parts {
                switch part.kind {
                case .tool:
                    afterTool = true
                case .file(let file):
                    guard afterTool, (file.mime ?? "").hasPrefix("image/") else { continue }
                    for name in [file.filename, file.path].compactMap({ $0 }) {
                        names.insert(ServerFileName.of(name))
                    }
                default:
                    continue
                }
            }
        }
        return names
    }

    private static func fenceMarker(_ line: Substring) -> Substring? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let marker = line.prefix { $0 == first }
        return marker.count >= 3 ? marker : nil
    }

    /// A line that is nothing but one path, which may hold spaces: a file under "My Videos" named
    /// on a line of its own is still one file.
    private static func wholeLinePath(_ line: Substring) -> Bool {
        let bare = unwrapped(line)
        return bare.contains(" ") && onePath(bare)
    }

    /// Whether words that start like a path are one path rather than a command line: no second
    /// path and no flag after a space.
    private static func onePath(_ words: Substring) -> Bool {
        guard words.hasPrefix("/") || words.hasPrefix("~/") || words.hasPrefix("file://") else {
            return false
        }
        return !words.contains(" /") && !words.contains(" -") && !words.contains(" ~/")
    }

    private static func unwrapped(_ line: Substring) -> Substring {
        var bare = line
        for (open, close) in [("`", "`"), ("\"", "\""), ("'", "'"), ("<", ">")] {
            if bare.count > 2, bare.hasPrefix(open), bare.hasSuffix(close) {
                bare = bare.dropFirst().dropLast()
            }
        }
        return bare
    }

    private static func codeSpans(in line: Substring) -> [Substring] {
        guard line.contains("`") else { return [] }
        var spans: [Substring] = []
        var rest = line[...]
        while let open = rest.firstIndex(of: "`") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "`") else { break }
            spans.append(after[..<close])
            rest = after[after.index(after: close)...]
        }
        return spans
    }

    private static func linkTargets(in line: Substring) -> [Substring] {
        guard line.contains("](") else { return [] }
        var targets: [Substring] = []
        var rest = line[...]
        while let open = rest.range(of: "](") {
            let after = rest[open.upperBound...]
            guard let close = after.firstIndex(of: ")") else { break }
            var target = after[..<close]
            if target.hasPrefix("<"), let end = target.firstIndex(of: ">") {
                target = target[target.index(after: target.startIndex)..<end]
            } else if let space = target.firstIndex(of: " ") {
                target = target[..<space]
            }
            targets.append(target)
            rest = after[after.index(after: close)...]
        }
        return targets
    }

    private static let leading: Set<Character> = ["(", "[", "<", "\"", "'", "`", "*", "_"]
    private static let trailing: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", ">", "\"", "'", "`", "*", "_",
    ]

    private static func trimmed(_ token: Substring) -> Substring {
        var token = token
        while let first = token.first, leading.contains(first) { token = token.dropFirst() }
        while let last = token.last, trailing.contains(last) { token = token.dropLast() }
        return token
    }

    private static let refused: Set<Character> = ["*", "?", "<", ">", "$", "{", "}", "|", "\\"]

    /// A candidate as the path a server can be asked for, or nil when it is not one: not absolute
    /// or home-relative, a glob or a placeholder, or not a media file.
    private static func normalized(_ candidate: Substring) -> String? {
        var path = String(candidate.trimmingCharacters(in: .whitespaces))
        if path.hasPrefix("file://") {
            path = String(path.dropFirst("file://".count))
            path = path.removingPercentEncoding ?? path
        }
        guard path.count > 3, path.count <= 1024 else { return nil }
        guard (path.hasPrefix("/") && !path.hasPrefix("//")) || path.hasPrefix("~/") else {
            return nil
        }
        guard !path.contains(where: { refused.contains($0) || $0.isNewline }),
            !path.hasPrefix("/path/to/")
        else { return nil }
        guard !path.hasSuffix("/"), MediaKind.of(path: path) != nil else { return nil }
        let name = ServerFileName.of(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return path
    }

    private static let ledger = Ledger()

    /// The paths already read out of each settled text part, held while the part's words are the
    /// same string: a transcript rebuild runs on every streamed token, and a settled reply is read
    /// once rather than on every one.
    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private struct Key: Hashable {
            let message: String
            let part: String
        }

        private var entries: [Key: (text: String, paths: [String])] = [:]
        private static let capacity = 8192

        func paths(message: String, part: String, text: String) -> [String] {
            let key = Key(message: message, part: part)
            lock.lock()
            if let entry = entries[key], entry.text == text {
                lock.unlock()
                return entry.paths
            }
            lock.unlock()
            let paths = MediaMentions.paths(in: text)
            lock.lock()
            if entries.count >= Self.capacity, entries[key] == nil { entries.removeAll() }
            entries[key] = (text, paths)
            lock.unlock()
            return paths
        }
    }
}

/// The last component of a path, read without Foundation's path APIs.
enum ServerFileName {
    static func of(_ path: String) -> String { PictureShowing.basename(path) }
}
