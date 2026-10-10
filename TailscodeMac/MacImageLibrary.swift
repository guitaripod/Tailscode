import AppKit
import ImageIO
import TailscodeCore

/// The pictures the machine keeps, as this Mac sees them.
///
/// One per machine: the listing, what the head of each file said, the small copies the shelf draws
/// and the originals the stage and a save need. Everything here is a copy of something the server
/// holds, so it lives in the caches directory through Core's `ImageGenLibraryCache` and is read from
/// disk before the network — the second opening costs nothing, and a machine that is asleep still
/// has a shelf, marked as of when it was last true. Decoding is always off the main actor and always
/// to the size a tile is drawn at, so a folder of hundreds of full renders is a bounded amount of
/// memory and never a scroll that waits on a megapixel decode.
@MainActor
final class MacImageLibrary {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let endpoint: ImageGenEndpoint
    private(set) var items: [ImageGenLibraryItem] = []
    private(set) var state: State = .idle
    private(set) var freshAt: Date?
    private(set) var rememberedAt: Date?
    var onChange: ((_ item: String?) -> Void)?

    private let client: ImageGenClient
    private let cache: ImageGenLibraryCache
    private var facts: [String: ImageGenLibraryFacts] = [:]
    private var describing: Set<String> = []
    private let thumbnails = NSCache<NSString, NSImage>()
    private var thumbnailLoads: [String: Task<NSImage?, Never>] = [:]
    private var originalLoads: [String: Task<Data?, Never>] = [:]
    private var refreshing: Task<Void, Never>?

    private static let thumbnailFormat: ImageGenFileKind = .webp
    nonisolated static let tileSide: CGFloat = 256

    init(endpoint: ImageGenEndpoint) {
        self.endpoint = endpoint
        client = ImageGenClient(endpoint: endpoint)
        cache = ImageGenLibraryCache(endpoint: endpoint)
        thumbnails.countLimit = 240
        thumbnails.totalCostLimit = 48 * 1024 * 1024
        if let remembered = cache.listing() {
            items = remembered.items
            rememberedAt = remembered.at
            state = .loaded
        }
    }

    var machine: String { endpoint.shortName }

    /// The count and, when the listing is a remembered one rather than the machine's answer just
    /// now, when it was last true — or the one sentence that says why there is no listing.
    var line: String {
        if case .failed(let reason) = state, items.isEmpty { return reason }
        return ImageGenLibraryWords.line(
            count: items.count, staleSince: freshAt == nil ? rememberedAt : nil)
    }

    /// Why the machine cannot list what it made, said once, while the shelf still shows the
    /// session's own pictures.
    var failure: String? {
        if case .failed(let reason) = state { return reason }
        return nil
    }

    func item(named id: String) -> ImageGenLibraryItem? {
        items.first { $0.id == id }
    }

    /// Asks the machine for its listing. One ask at a time; a second call while one is out joins it
    /// rather than racing it.
    func refresh() {
        guard refreshing == nil else { return }
        if items.isEmpty { state = .loading }
        onChange?(nil)
        let client = self.client
        refreshing = Task { [weak self] in
            let result = await client.listOutputs()
            guard let self else { return }
            self.refreshing = nil
            switch result {
            case .success(let listed):
                self.items = listed
                self.freshAt = Date()
                self.rememberedAt = nil
                self.state = .loaded
                self.cache.store(listing: listed)
                self.cache.pruneOriginals()
            case .failure(let failure):
                self.state = .failed(failure.reason(machine: self.machine))
            }
            self.onChange?(nil)
        }
    }

    func cancel() {
        refreshing?.cancel()
        refreshing = nil
        for load in thumbnailLoads.values { load.cancel() }
        thumbnailLoads = [:]
    }

    /// What is known about one picture, from memory, then disk. Nil until `describe` has landed.
    func facts(of item: ImageGenLibraryItem) -> ImageGenLibraryFacts? {
        if let held = facts[item.id] { return held }
        guard let stored = cache.facts(item) else { return nil }
        facts[item.id] = stored
        return stored
    }

    /// Reads the head of the file once, and says so when it lands.
    func describe(_ item: ImageGenLibraryItem) {
        guard facts(of: item) == nil, !describing.contains(item.id) else { return }
        describing.insert(item.id)
        let client = self.client
        Task { [weak self] in
            let learned = await client.describe(item)
            guard let self else { return }
            self.describing.remove(item.id)
            guard let learned else { return }
            self.facts[item.id] = learned
            self.cache.store(learned, for: item)
            self.onChange?(item.id)
        }
    }

    func cachedThumbnail(of item: ImageGenLibraryItem) -> NSImage? {
        thumbnails.object(forKey: item.id as NSString)
    }

    /// A tile's picture: memory, then the disk copy, then the machine's re-encoded preview —
    /// decoded small, because a shelf of full renders is a shelf this Mac cannot scroll.
    func thumbnail(of item: ImageGenLibraryItem) async -> NSImage? {
        if let held = cachedThumbnail(of: item) { return held }
        if let running = thumbnailLoads[item.id] { return await running.value }
        let client = self.client
        let file = cache.thumbnailURL(item, format: Self.thumbnailFormat)
        let format = Self.thumbnailFormat
        let load = Task<NSImage?, Never> {
            let bytes: Data?
            if let stored = FileManager.default.contents(atPath: file.path), !stored.isEmpty {
                bytes = stored
            } else if let fetched = await client.thumbnail(item, format: format) {
                try? fetched.write(to: file, options: .atomic)
                bytes = fetched
            } else {
                bytes = nil
            }
            guard let bytes else { return nil }
            return await Self.decode(bytes, fitting: Self.tileSide)
        }
        thumbnailLoads[item.id] = load
        let image = await load.value
        thumbnailLoads[item.id] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            thumbnails.setObject(image, forKey: item.id as NSString, cost: cost)
        }
        return image
    }

    /// The bytes as the machine wrote them, kept on disk once fetched so a save, a share, a drag
    /// and the stage all read one copy.
    func original(of item: ImageGenLibraryItem) async -> Data? {
        let file = cache.originalURL(item)
        if let stored = FileManager.default.contents(atPath: file.path), !stored.isEmpty {
            return stored
        }
        if let running = originalLoads[item.id] { return await running.value }
        let client = self.client
        let load = Task<Data?, Never> {
            guard let data = try? await client.original(item) else { return nil }
            try? data.write(to: file, options: .atomic)
            return data
        }
        originalLoads[item.id] = load
        let data = await load.value
        originalLoads[item.id] = nil
        return data
    }

    /// Where the original lives on disk once fetched, which is the path a reference is named by.
    func originalPath(of item: ImageGenLibraryItem) -> String? {
        let file = cache.originalURL(item)
        return FileManager.default.fileExists(atPath: file.path) ? file.path : nil
    }

    func thumbnailPath(of item: ImageGenLibraryItem) -> String? {
        let file = cache.thumbnailURL(item, format: Self.thumbnailFormat)
        return FileManager.default.fileExists(atPath: file.path) ? file.path : nil
    }

    /// Decodes off the main actor and downsamples to the tile in one pass, so the full bitmap is
    /// never held.
    nonisolated static func decode(_ data: Data, fitting side: CGFloat) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            guard let cg = downsample(data, longestSide: side) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }

    /// One decode to a bounded size, whatever the file's own. `kCGImageSourceShouldCacheImmediately`
    /// makes the work happen here rather than at the first draw on the main thread.
    nonisolated static func downsample(_ data: Data, longestSide: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
