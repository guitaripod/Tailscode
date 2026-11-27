import CodingAgentKit
import Foundation

/// What a video or a song an agent named says in a transcript, in the same words on every desk.
public enum MediaTileReading {
    /// The name a named file goes by: its own, or the last part of its path.
    public static func name(of file: FileReference) -> String {
        file.filename ?? file.path.map(PictureShowing.basename) ?? Localized.text("file")
    }

    /// A length or a position as a player shows it: `0:06`, `12:34`, `1:02:03`.
    public static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds.rounded(.down))
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let rest = whole % 60
        let two = { (value: Int) in value < 10 ? "0\(value)" : "\(value)" }
        return hours > 0 ? "\(hours):\(two(minutes)):\(two(rest))" : "\(minutes):\(two(rest))"
    }

    /// Where a playing file is against its length (`0:12 / 1:03`), its length alone before it
    /// plays, or nil while neither is known.
    ///
    /// A length is read to the nearest second, as players print one: a container that says 7.98
    /// seconds is an eight-second song. A position counts whole seconds gone.
    public static func progress(at position: Double?, of duration: Double?) -> String? {
        let length = duration.flatMap { $0.isFinite && $0 > 0 ? $0.rounded() : nil }
        guard let position, position.isFinite, position >= 0 else { return length.map(clock) }
        guard let length else { return clock(position) }
        return "\(clock(min(position, length))) / \(clock(length))"
    }

    /// How far through its length a playing file is, from 0 to 1.
    public static func fraction(at position: Double?, of duration: Double?) -> Double {
        guard let position, let duration, duration.isFinite, duration > 0, position.isFinite else {
            return 0
        }
        return min(1, max(0, position / duration))
    }

    public static func kindWord(_ kind: MediaKind) -> String {
        switch kind {
        case .picture: return Localized.text("Picture")
        case .video: return Localized.text("Video")
        case .audio: return Localized.text("Audio")
        }
    }

    /// The tile's name line: the file's name, and its kind and length once they are known.
    public static func caption(name: String, kind: MediaKind, duration: Double?) -> String {
        var parts = [name, kindWord(kind)]
        if let length = progress(at: nil, of: duration) { parts.append(length) }
        return parts.joined(separator: " · ")
    }

    /// The one quiet line a file stands as when the server has nothing at that path.
    public static func missing(_ name: String) -> String {
        Localized.text("%@ · not found on the server", name)
    }

    /// A server that cannot send this kind of file at all (opencode 1.x sends only pictures).
    public static func unsendable(_ name: String) -> String {
        Localized.text("%@ · this server can't send it", name)
    }

    /// A file this device has no player for: WebM, Matroska and Ogg on Apple's.
    public static func unplayable(_ name: String) -> String {
        Localized.text("%@ · can't play on this device", name)
    }

    /// A fetch that failed for a reason worth trying again.
    public static func unreachable(_ name: String) -> String {
        Localized.text("%@ · couldn't load, try again", name)
    }

    /// Why a file could not be had, read from what the backend threw.
    public static func failure(_ error: any Error) -> NamedMediaFailure {
        switch error {
        case AgentError.http(let status, _) where status == 404 || status == 410:
            return .missing
        case AgentError.unsupported:
            return .unsendable
        default:
            return .unreachable
        }
    }

    public static func words(_ failure: NamedMediaFailure, name: String) -> String {
        switch failure {
        case .missing: return missing(name)
        case .unsendable: return unsendable(name)
        case .unplayable: return unplayable(name)
        case .unreachable: return unreachable(name)
        }
    }
}

/// Why a named file is not drawn as a player.
public enum NamedMediaFailure: Error, Sendable, Equatable {
    case missing
    case unsendable
    case unplayable
    case unreachable

    /// Whether asking again could change the answer.
    public var isRetryable: Bool { self == .unreachable }
}
