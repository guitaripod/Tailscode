import Foundation
import MidgarCore

/// Opens Tailscode's log on every process that writes one. MidgarLog writes it to
/// `Library/Logs/tailscode.log`, the name and place the retired logger used, so the `ios-device-logs`
/// workflow still finds it.
enum TailscodeLogging {
    static let subsystem = "com.guitaripod.tailscode"
    static let fileName = "tailscode.log"
    static let retiredArchiveName = "tailscode.previous.log"

    /// Names the log file and removes the archive the retired logger left behind. Call first thing at
    /// launch in the app and in every extension, so nothing before the rest of the setup is lost.
    static func configure() {
        MidgarLog.configure(
            subsystem: subsystem, fileName: fileName, maxBytes: 512 * 1024, keepFiles: 1)
        removeRetiredArchive()
    }

    /// Where `devicectl device copy from` reads the current log.
    static var currentURL: URL {
        logsDirectory.appendingPathComponent(fileName)
    }

    /// The log files that exist now, oldest first, so reading them in order reads the log in order.
    static var fileURLs: [URL] {
        MidgarLog.logFileURLs.reversed()
    }

    /// The recent log, archive before current, for the in-app log viewer.
    static func snapshot() -> String {
        MidgarLog.flush()
        return fileURLs.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
    }

    private static var logsDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
    }

    /// Deletes `tailscode.previous.log`. MidgarLog rotates into numbered archives, so nothing writes or
    /// reads the old name any more.
    private static func removeRetiredArchive() {
        try? FileManager.default.removeItem(
            at: logsDirectory.appendingPathComponent(retiredArchiveName))
    }
}

extension MidgarLog.Category {
    static let lifecycle = MidgarLog.Category("lifecycle")
    static let connection = MidgarLog.Category("connection")
    static let session = MidgarLog.Category("session")
    static let chat = MidgarLog.Category("chat")
    static let streaming = MidgarLog.Category("streaming")
    static let persistence = MidgarLog.Category("persistence")
    static let performance = MidgarLog.Category("performance")
}
