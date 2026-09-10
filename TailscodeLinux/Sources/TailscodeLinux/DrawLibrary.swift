import CGtkShim
import Foundation
import TailscodeCore

/// Every picture ComfyUI keeps in its own output directory, newest first — the durable account of
/// what has been made on a machine by any device, of which a picture made this session is simply
/// the newest entry. One shelf per machine: ``ImageStudio`` owns one and rebuilds it whenever it
/// points somewhere else, so a pane's shelf and its renders always answer for the same endpoint.
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
                    self.queueThumbnails(for: items)
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

    /// Small copies for the tiles, decoded a few at a time so a shelf of seventy pictures does not
    /// hand the cairo renderer seventy textures in one frame.
    private func queueThumbnails(for items: [ImageGenLibraryItem]) {
        let missing = items.filter { textures[$0.id] == nil }
        pendingThumbnails.append(contentsOf: missing)
        pump()
    }

    private static let batchSize = 6
    private static let thumbnailDimension: Int32 = 256

    private func pump() {
        guard !decodingThumbnails, !pendingThumbnails.isEmpty else { return }
        decodingThumbnails = true
        let batch = Array(pendingThumbnails.prefix(Self.batchSize))
        pendingThumbnails.removeFirst(batch.count)
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
                guard let data = bytes else { continue }
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
                guard bits != 0 else { continue }
                Gtk.onMain { [weak self] in
                    guard let self else { return }
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

    private func announce() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
