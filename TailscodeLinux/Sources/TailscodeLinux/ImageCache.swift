import CodingAgentKit
import Foundation

/// The bytes of every picture the transcript has shown, on disk: a conversation reopened shows
/// its pictures from the first frame instead of re-crossing the tailnet for each one, and a
/// bridge that takes thirty seconds to answer costs each picture exactly once. Keyed by the
/// server path of the file — the same screenshot re-read in a later turn is the same bytes.
///
/// The transcript keeps only previews in memory, so these files are also where the gallery's
/// original, a copy and a save read from. They are mapped, never read into memory whole.
enum ImageCache {
    private static let maxFiles = 256
    private static let pruneEvery = 16
    private static let pruneInterval: TimeInterval = 10
    private static let touchInterval: TimeInterval = 600

    private final class Bookkeeping: @unchecked Sendable {
        let lock = NSLock()
        var savesSincePrune = 0
        var lastPrune = Date.distantPast
        var pruning = false
        var touched: [String: Date] = [:]
    }

    private static let bookkeeping = Bookkeeping()
    private static let pruneQueue = DispatchQueue(label: "tailscode.image-cache.prune", qos: .utility)

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

    static func exists(_ reference: FileReference) -> Bool {
        guard let identity = identity(for: reference) else { return false }
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(identity).path)
    }

    static func load(_ reference: FileReference) -> Data? {
        guard let identity = identity(for: reference) else { return nil }
        let file = directory.appendingPathComponent(identity)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        touch(file, identity: identity)
        return data
    }

    static func save(_ data: Data, for reference: FileReference) {
        guard let identity = identity(for: reference) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(identity), options: .atomic)
        schedulePrune()
    }

    /// A picture being looked at is refreshed so it outlives the ones that are not, but a file
    /// already refreshed this session is not touched again: a transcript that rebuilds a row a
    /// hundred times does not ask the filesystem a hundred times.
    private static func touch(_ file: URL, identity: String) {
        let now = Date()
        bookkeeping.lock.lock()
        let recent = bookkeeping.touched[identity].map { now.timeIntervalSince($0) < touchInterval } ?? false
        if !recent { bookkeeping.touched[identity] = now }
        bookkeeping.lock.unlock()
        guard !recent else { return }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }

    /// Pruning lists the directory and stats every file, so it runs at most once at a time, off
    /// the caller's thread, and only after enough saves or enough time to be worth it — a burst
    /// of a hundred pictures landing costs a handful of listings, not a hundred.
    private static func schedulePrune() {
        bookkeeping.lock.lock()
        bookkeeping.savesSincePrune += 1
        let due = !bookkeeping.pruning
            && (bookkeeping.savesSincePrune >= pruneEvery
                || Date().timeIntervalSince(bookkeeping.lastPrune) >= pruneInterval)
        if due {
            bookkeeping.pruning = true
            bookkeeping.savesSincePrune = 0
        }
        bookkeeping.lock.unlock()
        guard due else { return }
        pruneQueue.async {
            prune()
            bookkeeping.lock.lock()
            bookkeeping.pruning = false
            bookkeeping.lastPrune = Date()
            bookkeeping.lock.unlock()
        }
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
