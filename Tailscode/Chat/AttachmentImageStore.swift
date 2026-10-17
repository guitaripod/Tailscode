import CodingAgentKit
import ImageIO
import TailscodeCore
import UIKit

/// Fetches and caches attachment images. The bytes live behind the server's
/// auth on a private tailnet, so they can only be pulled through the backend —
/// and a chat scrolls, so the same thumbnail is asked for over and over.
@MainActor
final class AttachmentImageStore {
    static let shared = AttachmentImageStore()

    private let cache = NSCache<NSString, UIImage>()
    /// The bytes as they arrived, kept for saving and sharing: what the photo
    /// library should receive is the file the server has, not a re-encode of the
    /// downsampled bitmap a chat bubble displays.
    private let originals = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// What a bubble or a strip actually draws: the picture cut down to the pixels its frame has,
    /// kept apart from `cache` because that one holds the full bitmap the viewer zooms into, and a
    /// viewer handed a thumbnail would zoom into a blur.
    private let thumbnails = NSCache<NSString, UIImage>()
    private var thumbnailsInFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        thumbnails.countLimit = 160
        thumbnails.totalCostLimit = 48 * 1024 * 1024
        cache.countLimit = 60
        cache.totalCostLimit = 64 * 1024 * 1024
        originals.countLimit = 12
        originals.totalCostLimit = 48 * 1024 * 1024
    }

    func cached(_ file: FileReference) -> UIImage? {
        Self.key(file).flatMap { cache.object(forKey: $0 as NSString) }
    }

    func cachedData(_ file: FileReference) -> Data? {
        Self.key(file).flatMap { originals.object(forKey: $0 as NSString) } as Data?
    }

    /// The thumbnail already made for this picture at this size, so a scroll back is instant.
    func cachedThumbnail(_ file: FileReference, box: ThumbnailBox) -> UIImage? {
        Self.key(file).flatMap { thumbnails.object(forKey: Self.thumbnailKey($0, box) as NSString) }
    }

    /// The picture cut down to its frame by ImageIO, off the main thread, from the bytes the caller
    /// already holds. The full bitmap is never made: a photo is read once at the size it is drawn.
    /// A caller that cannot get ImageIO to read the bytes still gets the full decode, so a format
    /// UIKit can show never turns into a failure card here.
    func thumbnail(for file: FileReference, data: Data, box: ThumbnailBox) async -> UIImage? {
        guard let key = Self.key(file) else { return nil }
        let thumbKey = Self.thumbnailKey(key, box)
        if let hit = thumbnails.object(forKey: thumbKey as NSString) { return hit }
        if let running = thumbnailsInFlight[thumbKey] { return await running.value }
        let task = Task<UIImage?, Never> { [weak self] in
            let made = await Self.thumbnail(from: data, box: box)
            guard let made else { return nil }
            self?.store(thumbnail: made, key: thumbKey)
            return made
        }
        thumbnailsInFlight[thumbKey] = task
        let image = await task.value
        thumbnailsInFlight[thumbKey] = nil
        return image
    }

    /// The same, for bytes still on the server: fetched through the backend, kept as the
    /// originals the viewer and the export read, and never decoded at full size here.
    func thumbnail(
        for file: FileReference, box: ThumbnailBox, using backend: any CodingAgentBackend
    ) async -> UIImage? {
        guard let key = Self.key(file) else { return nil }
        if let hit = thumbnails.object(forKey: Self.thumbnailKey(key, box) as NSString) {
            return hit
        }
        let data: Data
        if let held = cachedData(file) {
            data = held
        } else {
            guard let fetched = try? await backend.attachmentData(file) else { return nil }
            store(fetched, key: key)
            data = fetched
        }
        return await thumbnail(for: file, data: data, box: box)
    }

    /// Decoded off the main thread:
    /// a full-resolution photo costs tens of megabytes as a CGImage and stutters
    /// the first scroll past it.
    func image(for file: FileReference, using backend: any CodingAgentBackend) async -> UIImage? {
        guard let key = Self.key(file) else { return nil }
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return await running.value }
        let task = Task<UIImage?, Never> { [weak self] in
            let data = try? await backend.attachmentData(file)
            guard let data, let image = await Self.decode(data) else { return nil }
            self?.store(image, key: key)
            self?.store(data, key: key)
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    func store(_ image: UIImage, for file: FileReference, data: Data? = nil) {
        guard let key = Self.key(file) else { return }
        store(image, key: key)
        if let data { store(data, key: key) }
    }

    private func store(_ image: UIImage, key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// Keeps the bytes a picture arrived as, for the viewer and the export, without a bitmap.
    func keep(_ data: Data, for file: FileReference) {
        guard let key = Self.key(file) else { return }
        store(data, key: key)
    }

    private func store(thumbnail: UIImage, key: String) {
        let cost = Int(thumbnail.size.width * thumbnail.size.height * thumbnail.scale * thumbnail.scale * 4)
        thumbnails.setObject(thumbnail, forKey: key as NSString, cost: cost)
    }

    private static func thumbnailKey(_ key: String, _ box: ThumbnailBox) -> String {
        "\(key)@\(box.pixelKey)"
    }

    private func store(_ data: Data, key: String) {
        originals.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }

    private static func key(_ file: FileReference) -> String? {
        file.url ?? file.path
    }

    private nonisolated static func thumbnail(from data: Data, box: ThumbnailBox) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            if let made = ImageThumbnail.make(from: data, box: box) { return made }
            guard let image = UIImage(data: data) else { return nil }
            return image.preparingForDisplay() ?? image
        }.value
    }

    private nonisolated static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            return image.preparingForDisplay() ?? image
        }.value
    }
}

extension FileReference {
    var isImage: Bool { (mime ?? "").hasPrefix("image/") }

    var displayName: String {
        filename ?? path.map { ($0 as NSString).lastPathComponent }
            ?? String(localized: "attachment")
    }
}
