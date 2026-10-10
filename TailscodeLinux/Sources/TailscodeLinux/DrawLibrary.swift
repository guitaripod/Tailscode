import CGtkShim
import Foundation
import TailscodeCore

/// Every picture ComfyUI keeps in its own output directory, newest first — the durable account of
/// what has been made on a machine by any device, of which a picture made this session is simply
/// the newest entry. One shelf per machine: ``ImageStudio`` owns one and rebuilds it whenever it
/// points somewhere else, so a pane's shelf and its renders always answer for the same endpoint.
///
/// A machine may keep hundreds of pictures and this device holds a decoded thumbnail only for the
/// ones somebody can see: the shelf says which tiles are near the eye (``want(_:keeping:)``), the
/// library decodes those off the main loop from its disk cache or the machine's own small copy,
/// and lets go of the rest. The listing, the facts and the files stay on disk; only pixels are
/// bounded.
final class DrawLibrary: @unchecked Sendable {
    static let didChange = Notification.Name("tailscode.drawLibrary.didChange")

    let endpoint: ImageGenEndpoint
    private let client: ImageGenClient
    private let cache: ImageGenLibraryCache

    private(set) var items: [ImageGenLibraryItem] = []
    private(set) var facts: [String: ImageGenLibraryFacts] = [:]
    private(set) var textures: [String: UInt] = [:]
    private(set) var failure: ImageGenLibraryFailure?
    /// When the listing on screen was last true, or nil while it is the machine's own current
    /// answer — the difference between "as of a minute ago" and nothing to say at all.
    private(set) var staleSince: Date?
    private(set) var loading = false

    private var pendingDescribe: Set<String> = []
    private var pendingThumbnails: [ImageGenLibraryItem] = []
    private var decodingThumbnails = false
    private var wanted: Set<String> = []
    private var kept: Set<String> = []
    private var fetchingOriginals: Set<String> = []
    private var decoding: Set<String> = []

    init(endpoint: ImageGenEndpoint) {
        self.endpoint = endpoint
        client = ImageGenClient(endpoint: endpoint)
        cache = ImageGenLibraryCache(endpoint: endpoint)
        if let stored = cache.listing() {
            items = stored.items
            staleSince = stored.at
        }
        for item in items {
            if let known = cache.facts(item) { facts[item.id] = known }
        }
    }

    /// Lets go of every decoded thumbnail. A studio pointed at a fresh machine builds a fresh
    /// library rather than reusing this one, so the textures it decoded have to go with it.
    func release() {
        for bits in textures.values {
            if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
        }
        textures = [:]
        wanted = []
        pendingThumbnails = []
    }

    /// Asks the machine what it has made, newest first. The cached listing is shown the moment
    /// this object exists; this is what makes it current.
    func refresh() {
        guard !loading else { return }
        loading = true
        announce()
        let client = self.client
        Task.detached { [weak self] in
            let result = await client.listOutputs()
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.loading = false
                switch result {
                case .success(let items):
                    self.items = items
                    self.failure = nil
                    self.staleSince = nil
                    self.cache.store(listing: items)
                case .failure(let failure):
                    self.failure = failure
                }
                self.announce()
            }
        }
    }

    /// The head of one kept file, fetched once and kept forever — a file ComfyUI wrote is never
    /// rewritten under the same name. Safe to call for every tile as it is shown: a picture whose
    /// facts are already known, or already being asked about, costs nothing to ask again.
    func describe(_ item: ImageGenLibraryItem) {
        guard facts[item.id] == nil, !pendingDescribe.contains(item.id) else { return }
        pendingDescribe.insert(item.id)
        let client = self.client
        Task.detached { [weak self] in
            let result = await client.describe(item)
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.pendingDescribe.remove(item.id)
                guard let result else { return }
                self.facts[item.id] = result
                self.cache.store(result, for: item)
                self.announce()
            }
        }
    }

    func originalURL(_ item: ImageGenLibraryItem) -> URL { cache.originalURL(item) }

    /// The path of a picture's own bytes when this device already holds them — what a drag out
    /// hands a file manager. Nil until they have been fetched once.
    func localOriginal(_ item: ImageGenLibraryItem) -> String? {
        let path = cache.originalURL(item).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Fetches the original in the background so a drag out has something to carry by the time
    /// the pointer moves: a tile the pointer has rested on is one somebody may pick up.
    func prefetchOriginal(_ item: ImageGenLibraryItem) {
        guard localOriginal(item) == nil, fetchingOriginals.insert(item.id).inserted else { return }
        Task.detached { [weak self] in
            _ = await self?.fetchOriginal(item)
            Gtk.onMain { [weak self] in self?.fetchingOriginals.remove(item.id) }
        }
    }

    /// The file's own bytes: from disk when this device already has them, else fetched once and
    /// kept — a save, a reference or the stage never asks the machine for the same picture twice.
    func fetchOriginal(_ item: ImageGenLibraryItem) async -> Data? {
        let url = cache.originalURL(item)
        if let onDisk = FileManager.default.contents(atPath: url.path) { return onDisk }
        guard let data = try? await client.original(item) else { return nil }
        try? data.write(to: url, options: .atomic)
        cache.pruneOriginals()
        return data
    }

    /// Says which pictures somebody can see: their thumbnails are decoded, and every thumbnail
    /// that is neither wanted nor named in `keeping` is let go of. The tiles ask this on every
    /// scroll and on every listing, so a shelf of three hundred holds a few dozen.
    func want(_ ids: [String], keeping: Set<String> = []) {
        wanted = Set(ids)
        kept = keeping
        for (id, bits) in textures where !wanted.contains(id) && !kept.contains(id) {
            textures.removeValue(forKey: id)
            if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
        }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        pendingThumbnails = ids.compactMap { id in
            textures[id] == nil && !decoding.contains(id) ? byID[id] : nil
        }
        pump()
    }

    /// Small copies for the tiles, decoded a few at a time so a shelf does not hand the cairo
    /// renderer a texture per picture in one frame.
    private static let batchSize = 4
    private static let thumbnailDimension: Int32 = 176

    private func pump() {
        guard !decodingThumbnails, !pendingThumbnails.isEmpty else { return }
        decodingThumbnails = true
        let batch = Array(pendingThumbnails.prefix(Self.batchSize))
        pendingThumbnails.removeFirst(batch.count)
        for item in batch { decoding.insert(item.id) }
        let client = self.client
        let cache = self.cache
        Task.detached { [weak self] in
            for item in batch {
                let file = cache.thumbnailURL(item, format: .jpeg)
                var bytes = FileManager.default.contents(atPath: file.path)
                if bytes == nil {
                    bytes = await client.thumbnail(item, format: .jpeg)
                    if let fresh = bytes { try? fresh.write(to: file, options: .atomic) }
                }
                guard let data = bytes else {
                    Gtk.onMain { [weak self] in self?.decoding.remove(item.id) }
                    continue
                }
                let bits: UInt = data.withUnsafeBytes { buffer in
                    guard let base = buffer.baseAddress else { return 0 }
                    var width: Int32 = 0
                    var height: Int32 = 0
                    guard
                        let texture = tailscode_texture_scaled(
                            base, gsize(data.count), Self.thumbnailDimension, &width, &height)
                    else { return 0 }
                    return UInt(bitPattern: UnsafeMutableRawPointer(texture))
                }
                guard bits != 0 else {
                    Gtk.onMain { [weak self] in self?.decoding.remove(item.id) }
                    continue
                }
                Gtk.onMain { [weak self] in
                    guard let self else {
                        if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
                        return
                    }
                    self.decoding.remove(item.id)
                    guard self.wanted.contains(item.id) || self.kept.contains(item.id),
                        self.textures[item.id] == nil
                    else {
                        if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
                        return
                    }
                    self.textures[item.id] = bits
                    self.announce()
                }
            }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.decodingThumbnails = false
                self.pump()
            }
        }
    }

    /// How many decoded thumbnails this library is holding, for a harness that has to prove the
    /// shelf stays bounded.
    var heldThumbnails: Int { textures.count }

    /// News is batched rather than shouted: a listing of a hundred pictures decodes a hundred
    /// thumbnails and reads a hundred file heads, and a surface told about each one redrew a
    /// hundred times on the main loop at a priority above the frame clock, so nothing was painted
    /// until the last one landed. One announcement per short beat carries everything that
    /// arrived in it.
    private var announcePending = false

    private func announce() {
        guard !announcePending else { return }
        announcePending = true
        Gtk.after(Self.announceBeat) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.announcePending = false
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
        }
    }

    private static let announceBeat: UInt32 = 80
}
