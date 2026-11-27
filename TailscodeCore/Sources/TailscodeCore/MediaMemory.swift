import CodingAgentKit
import Foundation

/// The files the agent named that turned out not to be there, so a picture that is gone stands as
/// one quiet line like a missing video does, rather than as an empty tile.
///
/// A client notes a miss where its fetch learns of it (`note(_:)`), and `MediaMentions` reads the
/// set when it builds the parts: a picture it names that is missed is drawn under
/// `MediaMisses.missingMime`, which every client draws as `MediaTileReading.missing`. A client
/// listens for `didChange` to build its rows again.
public enum MediaMisses {
    public static let didChange = Notification.Name("MediaMisses.didChange")

    /// The type a missed picture is carried under: no client draws it as a picture.
    public static let missingMime = "application/x-tailscode-missing"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var urls: Set<String> = []

    /// Records that a named file is not on its server. Only a reference an agent named counts.
    public static func note(_ file: FileReference) {
        guard ServerFile.path(of: file) != nil, let url = file.url else { return }
        let added = lock.withLock { urls.insert(url).inserted }
        guard added else { return }
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["url": url])
    }

    /// Whether an error a fetch threw says the file is not there.
    public static func isMissing(_ error: any Error) -> Bool {
        if case AgentError.http(let status, _) = error { return status == 404 || status == 410 }
        return false
    }

    public static func contains(_ url: String) -> Bool {
        lock.withLock { urls.contains(url) }
    }

    static var isEmpty: Bool { lock.withLock { urls.isEmpty } }

    public static func isMissed(_ file: FileReference) -> Bool { file.mime == missingMime }
}

/// Where each named video or song was left, so opening it again starts there. A file of a few
/// seconds starts from the top, and so does one left within its last few seconds.
public enum MediaPlayhead {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var positions: [String: Double] = [:]

    public static func keep(_ seconds: Double, of duration: Double?, for key: String) {
        lock.withLock {
            guard seconds.isFinite, seconds > 3 else {
                positions[key] = nil
                return
            }
            if let duration, duration.isFinite, seconds > duration - 3 {
                positions[key] = nil
                return
            }
            if positions.count > 256, positions[key] == nil { positions.removeAll() }
            positions[key] = seconds
        }
    }

    public static func start(for key: String) -> Double? {
        lock.withLock { positions[key] }
    }
}

/// How a named video plays: one of a few seconds loops like a picture that moves, anything longer
/// plays once.
public enum MediaLoop {
    public static let longest: Double = 20

    public static func loops(duration: Double?) -> Bool {
        guard let duration, duration.isFinite, duration > 0 else { return false }
        return duration <= longest
    }
}

/// What this app tells every server it shows, on every request (`ClientFeatures`): a bridge then
/// starts a conversation's agent knowing that a path it writes shows the file.
public enum TailscodeClientFeatures {
    public static func declare() {
        ClientFeatures.declare([ClientFeatures.mediaByPath])
    }
}
