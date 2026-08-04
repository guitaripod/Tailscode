import Foundation

/// Turns a `VideoTarget` into something a plain player can open. Clients that embed mpv never need
/// this — mpv resolves pages itself — but a client playing through the system's own player (AVKit)
/// has to be handed a stream, so the extraction happens here, once, in the same vocabulary.
public enum VideoResolver {
    public enum Failure: Error, CustomStringConvertible, Sendable {
        case toolMissing
        case nothingPlayable(String)

        public var description: String {
            switch self {
            case .toolMissing:
                return Localized.text("yt-dlp is not installed, so a slot cannot open a page")
            case .nothingPlayable(let reason):
                return reason
            }
        }
    }

    /// Where a GUI app can expect to find yt-dlp: a launched app inherits the login shell's PATH
    /// on neither desktop, so the usual places are checked by name rather than trusted to be on it.
    public static let searchPaths = [
        "/opt/homebrew/bin/yt-dlp",
        "/usr/local/bin/yt-dlp",
        "/usr/bin/yt-dlp",
        "/home/linuxbrew/.linuxbrew/bin/yt-dlp",
    ]

    public static let format = "best[height<=?1080]/bestvideo[height<=?1080]+bestaudio/best"

    #if os(macOS) || os(Linux)
        public static func tool() -> String? {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let candidates =
                searchPaths + ["\(home)/.local/bin/yt-dlp", "\(home)/bin/yt-dlp"]
                + (ProcessInfo.processInfo.environment["PATH"]?
                    .split(separator: ":").map { "\($0)/yt-dlp" } ?? [])
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        }

        /// The direct stream for a target, or a stated reason. Runs off the main thread; the caller
        /// is expected to be `async` already because opening a page costs a network round trip.
        public static func directURL(for target: VideoTarget) throws -> URL {
            guard let tool = tool() else { throw Failure.toolMissing }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = [
                "--quiet", "--no-warnings", "--ignore-config", "-f", format, "-g",
                target.extractionArgument,
            ]
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let problem = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n").map(String.init)
            guard let first = lines.first, let url = URL(string: first) else {
                let reason = String(decoding: problem, as: UTF8.self)
                    .split(separator: "\n").last.map(String.init)
                throw Failure.nothingPlayable(
                    reason ?? Localized.text("That would not play"))
            }
            return url
        }
    #endif
}

extension VideoTarget {
    /// What an extractor is asked for. Only a search differs from what a player would be handed:
    /// the `ytdl://` scheme is mpv's, so the plain search term goes out instead.
    public var extractionArgument: String {
        if case .search(let words) = self { return "ytsearch1:\(words)" }
        return playbackURL
    }
}
