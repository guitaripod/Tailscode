import Foundation

/// The diagnostics this client owes anyone who hits a bug on a machine nobody can watch.
///
/// The phone has had a file logger from the start and the README advertises one as a product
/// feature; on Linux there was only `Trace`, which is off unless an environment variable is set and
/// goes to stdout, where a launcher click sends it to the journal and a person will never find it.
/// So a stranger reporting a problem had nothing to attach and no way to say what they were running.
///
/// Append-only, size-rotated one generation deep, serialised on its own queue so a logging call
/// never blocks a frame. It writes under `XDG_STATE_HOME` rather than the config directory: a log is
/// not a preference, and restoring settings onto another machine must not carry one machine's
/// diagnostics onto another.
///
/// What it must never contain is the point: this app carries prompts, transcripts and server
/// passwords, and a log a person is invited to paste into a bug report is the easiest way to
/// publish all three. Nothing here takes message text, and `redacted` is what every call site that
/// might hold a secret goes through.
enum AppLog {
    enum Category: String {
        case lifecycle
        case connection
        case session
        case streaming
        case persistence
        case ui
        case update
    }

    private static let queue = DispatchQueue(label: "tailscode.log", qos: .utility)
    private static let limit = 2 * 1024 * 1024
    private static nonisolated(unsafe) var handle: FileHandle?

    static var directory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state", isDirectory: true)
        return base.appendingPathComponent("tailscode", isDirectory: true)
    }

    static var current: URL { directory.appendingPathComponent("tailscode.log") }
    static var previous: URL { directory.appendingPathComponent("tailscode.previous.log") }

    static func write(_ category: Category, _ message: String) {
        let line = "\(stamp()) [\(category.rawValue)] \(message)\n"
        queue.async { append(line) }
        Trace.mark("\(category.rawValue) \(message)")
    }

    /// A value that might be a secret, reduced to the shape of one. Enough to tell "the password was
    /// empty" from "the password was 24 characters" without ever writing the characters.
    static func redacted(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        return "\(value.count) chars"
    }

    /// The tail, for the About window's copyable diagnostics. Bounded rather than whole: a bug
    /// report wants the last thing that happened, not two megabytes of it.
    static func tail(lines: Int = 60) -> String {
        guard let text = try? String(contentsOf: current, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    private static func append(_ line: String) {
        let files = FileManager.default
        if handle == nil {
            try? files.createDirectory(at: directory, withIntermediateDirectories: true)
            if !files.fileExists(atPath: current.path) {
                _ = files.createFile(atPath: current.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: current)
            _ = try? handle?.seekToEnd()
        }
        guard let handle else { return }
        if let size = try? handle.offset(), size > limit {
            try? handle.close()
            self.handle = nil
            try? files.removeItem(at: previous)
            try? files.moveItem(at: current, to: previous)
            append(line)
            return
        }
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private static func stamp() -> String {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now)
    }
}
