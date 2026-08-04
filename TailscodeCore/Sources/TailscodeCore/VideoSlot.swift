import Foundation

/// What a video slot is pointed at. A slot is a pane like any other — it splits, resizes, zooms
/// and closes with the same verbs — so what it holds has to be as small and as persistable as the
/// session a chat pane holds: an address that survives a restart and re-reads to the same thing.
public enum VideoTarget: Sendable, Equatable, Hashable, Codable {
    case twitch(String)
    case youtube(String)
    case link(String)
    case search(String)

    /// Reads a typed line for what it obviously is. A bare word is a Twitch channel because that
    /// is what people type when they mean one; anything with a space is words to search, and a
    /// link is taken at face value so a slot can hold a VOD, a clip, or a file on disk.
    public static func classify(_ input: String) -> VideoTarget? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let rest = strip(text, ["twitch:", "tw:", "ttv:"]) {
            return rest.contains(" ") ? .search(rest) : .twitch(login(rest))
        }
        if let rest = strip(text, ["youtube:", "yt:"]) {
            return isChannel(rest) ? .youtube(rest) : .search(rest)
        }
        if text.hasPrefix("@"), !text.contains(" ") { return .youtube(text) }
        if text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix("file://") {
            return .link(text)
        }
        if let url = fromURL(text) { return url }
        if text.contains(" ") { return .search(text) }
        return .twitch(login(text))
    }

    /// The string persisted in a layout snapshot, which reads back to the same target — the slot
    /// has to be able to say what it was watching after a restart, not merely that it was.
    public var address: String {
        switch self {
        case .twitch(let login): return "tw:\(login)"
        case .youtube(let handle): return "yt:\(handle)"
        case .link(let url): return url
        case .search(let words): return "yt:\(words)"
        }
    }

    /// What a player is handed. Every client passes this to something that already understands
    /// pages — mpv with yt-dlp behind it — so a slot never carries its own extraction.
    public var playbackURL: String {
        switch self {
        case .twitch(let login): return "https://www.twitch.tv/\(login)"
        case .youtube(let handle): return "\(Self.channelURL(handle))/live"
        case .link(let url): return url
        case .search(let words): return "ytdl://ytsearch1:\(words)"
        }
    }

    /// What the slot calls itself before the stream says its own title.
    public var label: String {
        switch self {
        case .twitch(let login): return login
        case .youtube(let handle): return handle
        case .link(let url): return Self.shortened(url)
        case .search(let words): return words
        }
    }

    public var source: String {
        switch self {
        case .twitch: return "twitch"
        case .youtube, .search: return "youtube"
        case .link: return "link"
        }
    }

    private static func channelURL(_ handle: String) -> String {
        if handle.hasPrefix("http") { return handle.hasSuffix("/") ? String(handle.dropLast()) : handle }
        if handle.hasPrefix("@") { return "https://www.youtube.com/\(handle)" }
        if handle.hasPrefix("UC"), handle.count == 24 {
            return "https://www.youtube.com/channel/\(handle)"
        }
        return "https://www.youtube.com/@\(handle)"
    }

    private static func isChannel(_ text: String) -> Bool {
        text.hasPrefix("@") || (text.hasPrefix("UC") && text.count == 24) || text.hasPrefix("http")
    }

    private static func login(_ text: String) -> String {
        text.hasPrefix("@") ? String(text.dropFirst()).lowercased() : text.lowercased()
    }

    private static func strip(_ text: String, _ prefixes: [String]) -> String? {
        for prefix in prefixes where text.lowercased().hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty, !rest.hasPrefix("//") { return rest }
        }
        return nil
    }

    private static func fromURL(_ text: String) -> VideoTarget? {
        guard text.hasPrefix("http://") || text.hasPrefix("https://") else { return nil }
        guard let url = URL(string: text), let host = url.host?.lowercased() else {
            return .link(text)
        }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let segments = url.path.split(separator: "/").map(String.init)
        if bare.hasSuffix("twitch.tv") {
            if bare == "clips.twitch.tv" { return .link(text) }
            if segments.count == 1 { return .twitch(segments[0].lowercased()) }
            return .link(text)
        }
        if bare.hasSuffix("youtube.com") || bare == "youtu.be" {
            if let first = segments.first, first.hasPrefix("@") {
                let tail = segments.count > 1 ? segments[1] : ""
                if segments.count == 1 || ["live", "streams", "videos"].contains(tail) {
                    return .youtube(first)
                }
            }
            if segments.count >= 2, ["channel", "c", "user"].contains(segments[0]),
                url.path.split(separator: "/").count <= 3
            {
                return .youtube(segments[1])
            }
            return .link(text)
        }
        return .link(text)
    }

    private static func shortened(_ url: String) -> String {
        let stripped = url
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
        return stripped.count > 42 ? String(stripped.prefix(41)) + "…" : stripped
    }
}

/// What a stream costs the rest of the grid, said plainly, in the three widths the clients have
/// room for. A player repaints its pane every frame, so the verbs that move panes around it —
/// splitting, dragging a divider, zooming — get less of the machine and answer less smoothly while
/// it runs. This is a fact offered, not a warning: it stops nothing, asks nothing, and is worded so
/// that someone who notices the grid feeling heavy already has the reason and the way out.
public enum VideoNotice {
    /// The whole of it, for an empty slot's own body — read before a pane is committed to a stream.
    public static var splitCost: String {
        Localized.text(
            "Video repaints this pane constantly, so splitting and resizing panes feels less smooth while it plays. Pause it with space, or close the pane with ctrl+w c, to get that back."
        )
    }

    /// One line, for the chooser row that offers a stream — a clause under the row's own detail.
    public static var splitCostLine: String {
        Localized.text("Splitting and resizing panes feel less smooth while this plays")
    }

    /// A few words, for a pane's identity strip, where the whole line is already a tight status.
    public static var splitCostTag: String {
        Localized.text("splits feel less smooth")
    }
}

/// Where a slot is in its short life: asking what to watch, opening it, showing it, or explaining
/// why it cannot. A slot that fails says so in its own body rather than emptying itself, because
/// the pane still occupies grid space and has to account for it.
public enum VideoSlotPhase: Sendable, Equatable {
    case asking
    case loading
    case playing
    case failed(String)
}

/// The slot's whole model, toolkit-free: what it points at, what it is doing, and what the two
/// desktops draw. The player itself is the client's business — libmpv on one, an embedded mpv on
/// the other — but every word on screen and every key that means something comes from here.
public struct VideoSlot: Sendable, Equatable {
    public private(set) var target: VideoTarget?
    public private(set) var phase: VideoSlotPhase
    public private(set) var mediaTitle: String?
    public var draft: String
    public var paused: Bool
    public var muted: Bool

    public init(target: VideoTarget? = nil) {
        self.target = target
        phase = target == nil ? .asking : .loading
        mediaTitle = nil
        draft = ""
        paused = false
        muted = false
    }

    public mutating func point(at target: VideoTarget) {
        self.target = target
        phase = .loading
        mediaTitle = nil
        paused = false
        draft = ""
    }

    public mutating func loaded(title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        mediaTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        phase = .playing
    }

    public mutating func failed(_ reason: String) {
        phase = .failed(reason)
    }

    /// Back to the question, keeping what it was watching in the box so a mistyped channel is one
    /// correction away rather than a retype.
    public mutating func ask() {
        draft = target?.label ?? draft
        phase = .asking
    }

    public var isAsking: Bool { phase == .asking }

    /// What the pane's identity strip says: the stream's own title once it has one, the target
    /// until then. Never empty — a pane with no name in a grid of panes is a puzzle.
    public var title: String {
        if let mediaTitle { return mediaTitle }
        if let target { return target.label }
        return Localized.text("Watch")
    }

    /// What the pane's identity strip says under its name. A slot that is actually painting frames
    /// carries the cost of doing so at the end of its own status line — the one place a person is
    /// already looking when they wonder why the divider they are dragging feels heavy.
    public var subtitle: String {
        switch phase {
        case .asking: return Localized.text("Nothing playing")
        case .loading: return Localized.text("Opening…")
        case .playing:
            let source = target?.source ?? ""
            let state = muted ? Localized.text("%@ · muted", source) : source
            return paused ? state : "\(state) · \(VideoNotice.splitCostTag)"
        case .failed(let reason): return reason
        }
    }

    /// The plain sentence an empty slot shows before a pane is spent on a stream.
    public var notice: String { VideoNotice.splitCost }

    public var prompt: String { Localized.text("Channel, link, or words") }

    public var hint: String {
        Localized.text("enter watches · space pauses · m mutes · e changes · ctrl+w c closes")
    }
}

/// What a keystroke means inside a slot that is playing. Shared so both desktops answer the same
/// keys, and so the headless drivers can name a verb instead of a keycode.
public enum VideoCommand: Sendable, Equatable {
    case playPause
    case mute
    case volumeUp
    case volumeDown
    case seekBack
    case seekForward
    case reload
    case change

    public static func command(for chord: KeyChord) -> VideoCommand? {
        guard !chord.control, !chord.alt else { return nil }
        switch chord.keyval {
        case 0x20: return .playPause
        case 0xFF51: return .seekBack
        case 0xFF53: return .seekForward
        case 0xFF52: return .volumeUp
        case 0xFF54: return .volumeDown
        default: break
        }
        guard let character = Keymap.scalar(chord.keyval) else { return nil }
        switch character {
        case "m": return .mute
        case "e": return .change
        case "r": return .reload
        case "h": return .seekBack
        case "l": return .seekForward
        case "k": return .volumeUp
        case "j": return .volumeDown
        default: return nil
        }
    }

    /// The mpv command line each verb becomes, so neither desktop invents its own vocabulary.
    public var mpvCommand: [String] {
        switch self {
        case .playPause: return ["cycle", "pause"]
        case .mute: return ["cycle", "mute"]
        case .volumeUp: return ["add", "volume", "5"]
        case .volumeDown: return ["add", "volume", "-5"]
        case .seekBack: return ["seek", "-10"]
        case .seekForward: return ["seek", "10"]
        case .reload: return ["playlist-play-index", "current"]
        case .change: return []
        }
    }
}
