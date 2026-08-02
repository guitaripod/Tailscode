import CodingAgentKit
import Foundation

/// The bytes of every picture the transcript has shown, on disk: a conversation reopened shows
/// its pictures from the first frame instead of re-crossing the tailnet for each one, and a
/// bridge that takes thirty seconds to answer costs each picture exactly once. Keyed by the
/// server path of the file — the same screenshot re-read in a later turn is the same bytes.
enum ImageCache {
    private static let maxFiles = 256

    private static var directory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map {
            URL(fileURLWithPath: $0)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return base.appendingPathComponent("tailscode/images", isDirectory: true)
    }

    static func identity(for reference: FileReference) -> String? {
        guard let ident = reference.path ?? reference.url ?? reference.filename else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in ident.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func load(_ reference: FileReference) -> Data? {
        guard let identity = identity(for: reference) else { return nil }
        let file = directory.appendingPathComponent(identity)
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    static func save(_ data: Data, for reference: FileReference) {
        guard let identity = identity(for: reference) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(identity), options: .atomic)
        prune()
    }

    /// Oldest-untouched pictures fall out first; `load` refreshes what is still being looked at.
    private static func prune() {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles), files.count > maxFiles
        else { return }
        let dated = files.map { file in
            (file,
             (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast)
        }.sorted { $0.1 < $1.1 }
        for (file, _) in dated.prefix(files.count - maxFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
