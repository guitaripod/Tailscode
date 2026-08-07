import AppKit
import Foundation

/// A decoded thumbnail crossing back from the fetch task to the main actor, exactly once.
private struct FetchedThumbnail: @unchecked Sendable {
    let url: String
    let image: NSImage
}

/// The pictures the watch board draws: stream previews and box art, decoded in memory keyed by
/// their address and kept on disk under this platform's cache root. These are ordinary public
/// images on somebody else's CDN rather than files on the tailnet, so they never go near a
/// backend — a board opened twice in a minute costs each picture once, and a board opened
/// tomorrow costs it once ever.
@MainActor
final class MediaImageStore {
    static let shared = MediaImageStore()

    private static let capacity = 64
    private static let refusalCapacity = 256

    private var entries: [String: NSImage] = [:]
    private var order: [String] = []
    private var inFlight: Set<String> = []
    /// Addresses the source refused, never sent, or sent as something that would not decode. A
    /// board re-renders on every keystroke and every answer that lands, so without this a picture
    /// that is never going to arrive is asked for again several times a second for as long as the
    /// slot stays open. Forgotten wholesale once it grows past its cap: these addresses rotate on
    /// both sources anyway, so the worst a reset costs is one more attempt each.
    private var refused: Set<String> = []

    /// The board's ear while it is on screen: a row whose picture was still being fetched repaints
    /// the moment it lands. One listener, held by whichever board rendered last — every other board
    /// picks the picture up from memory on its next render, so nothing is lost, only delayed.
    var onStored: ((String) -> Void)?

    private init() {}

    func image(for url: String) -> NSImage? {
        entries[url]
    }

    /// Asks for a picture the board wants but does not have. Guarded by the in-flight set, because
    /// a board re-renders on every keystroke and a row asking again is not a row asking twice.
    func fetch(_ url: String) {
        guard !url.isEmpty, entries[url] == nil, !inFlight.contains(url),
            !refused.contains(url)
        else { return }
        guard let remote = URL(string: url), remote.scheme != nil else {
            refuse(url)
            return
        }
        inFlight.insert(url)
        Task { [weak self] in
            let fetched = await Task.detached(priority: .utility) {
                await Self.load(remote, key: url)
            }.value
            guard let self else { return }
            self.inFlight.remove(url)
            guard let fetched else {
                self.refuse(url)
                return
            }
            self.store(fetched.image, for: fetched.url)
        }
    }

    private func refuse(_ url: String) {
        if refused.count >= Self.refusalCapacity { refused.removeAll() }
        refused.insert(url)
    }

    /// Decoded pictures are kept across boards, bounded: past the cap the least recently stored is
    /// released — its bytes are still on disk, one frame away.
    private func store(_ image: NSImage, for url: String) {
        entries[url] = image
        onStored?(url)
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > Self.capacity {
            entries[order.removeFirst()] = nil
        }
    }

    /// Disk first, then the network. Runs off the main actor because a decode on the UI loop is a
    /// visible stutter in a pane that is also playing a reveal.
    private nonisolated static func load(_ remote: URL, key: String) async -> FetchedThumbnail? {
        if let cached = MediaThumbDisk.load(key), let image = decode(cached) {
            return FetchedThumbnail(url: key, image: image)
        }
        guard let (data, response) = try? await URLSession.shared.data(from: remote) else {
            return nil
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        guard let image = decode(data) else { return nil }
        MediaThumbDisk.save(data, for: key)
        return FetchedThumbnail(url: key, image: image)
    }

    private nonisolated static func decode(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}

/// The bytes of every board picture on disk, mirroring `ImageDisk`'s shape one directory over.
/// Keyed by the address the picture came from — the same preview asked for in a later session is
/// the same bytes, and a preview that has rotated on the source is simply a different key.
enum MediaThumbDisk {
    private static let maxFiles = 256

    private static var directory: URL {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Caches")
        return base.appendingPathComponent("tailscode/thumbs", isDirectory: true)
    }

    static func identity(for url: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func load(_ url: String) -> Data? {
        let file = directory.appendingPathComponent(identity(for: url))
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    static func save(_ data: Data, for url: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(identity(for: url)), options: .atomic)
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
            (
                file,
                (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
            )
        }.sorted { $0.1 < $1.1 }
        for (file, _) in dated.prefix(files.count - maxFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
