import CGtkShim
import Foundation
import TailscodeCore

/// A clip's poster: the machine's own last sketch of it, kept when the render landed. A clip is a
/// file on another machine and nothing on this device can draw a still of it, but the sketch the
/// machine streamed while it rendered is exactly that — the picture the clip was becoming — so it
/// is written down once, when the clip is delivered, and the shelf shows it in the clip's tile. A
/// clip made before this existed, or on another desk, has no poster and wears a glyph instead:
/// nothing is invented.
enum ForgePosters {
    private static var directory: URL {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("Tailscode", isDirectory: true)
            .appendingPathComponent("posters", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The key a clip's poster is filed under: its place on the machine, flattened.
    static func key(for asset: ForgeAsset) -> String {
        let id = asset.subfolder.isEmpty ? asset.filename : asset.subfolder + "/" + asset.filename
        return id.replacingOccurrences(of: "/", with: "__")
    }

    static func url(for key: String) -> URL { directory.appendingPathComponent(key + ".img") }

    static func write(_ frame: ImageGenPreviewFrame, for asset: ForgeAsset) {
        try? frame.bytes.write(to: url(for: key(for: asset)), options: .atomic)
        prune()
    }

    static func read(key: String) -> Data? {
        FileManager.default.contents(atPath: url(for: key).path)
    }

    /// Posters are small and few, and the oldest go once more than a few hundred are held.
    private static func prune(keeping limit: Int = 400) {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
            urls.count > limit
        else { return }
        let dated = urls.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url, date)
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(urls.count - limit) { try? FileManager.default.removeItem(at: url) }
    }
}

/// The posters the shelf is showing, decoded off the main loop and only for the tiles near the
/// eye: the same discipline as the picture library's thumbnails, for clips.
final class ForgePosterLibrary: @unchecked Sendable {
    private(set) var textures: [String: UInt] = [:]
    private var wanted: Set<String> = []
    private var decoding: Set<String> = []
    var onChange: (@Sendable () -> Void)?

    func want(_ keys: [String]) {
        wanted = Set(keys)
        for (key, bits) in textures where !wanted.contains(key) {
            textures.removeValue(forKey: key)
            if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
        }
        for key in keys where textures[key] == nil && decoding.insert(key).inserted {
            Task.detached { [weak self] in
                let bits: UInt = {
                    guard let data = ForgePosters.read(key: key) else { return 0 }
                    return data.withUnsafeBytes { buffer in
                        guard let base = buffer.baseAddress else { return 0 }
                        var width: Int32 = 0
                        var height: Int32 = 0
                        guard
                            let texture = tailscode_texture_scaled(
                                base, gsize(data.count), 176, &width, &height)
                        else { return 0 }
                        return UInt(bitPattern: UnsafeMutableRawPointer(texture))
                    }
                }()
                Gtk.onMain { [weak self] in
                    guard let self else {
                        if bits != 0, let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
                        return
                    }
                    self.decoding.remove(key)
                    guard bits != 0, self.wanted.contains(key), self.textures[key] == nil else {
                        if bits != 0, let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
                        return
                    }
                    self.textures[key] = bits
                    self.onChange?()
                }
            }
        }
    }

    func release() {
        for bits in textures.values {
            if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
        }
        textures = [:]
        wanted = []
    }
}
