import CAdw
import CGtkShim
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The pictures a watch board shows: stream previews and box art, off the public CDNs those two
/// sites already serve them from. Nothing here goes through the bridge — these are not a
/// conversation's files, they are somebody else's thumbnails, and they are fetched, cached and
/// forgotten on their own terms.
///
/// A preview is a live frame, so it goes stale in minutes rather than never: the disk copy is used
/// while it is fresh and re-fetched once it is not, which is the difference between a board that
/// shows what is on and a board that shows what was on this morning.
final class MediaImageCache: @unchecked Sendable {
    static let shared = MediaImageCache()

    /// The long side a thumbnail is decoded at. A board row draws it at 96 points wide; decoding
    /// the CDN's full 320-wide preview and letting the compositor shrink it costs nothing extra and
    /// keeps the picture sharp on a scaled display.
    static let maxDimension: Int32 = 320
    private static let freshness: TimeInterval = 240
    private static let maxFiles = 400
    private static let textureCap = 120

    private var textures: [String: UInt] = [:]
    private var order: [String] = []
    private var inFlight: Set<String> = []

    private var observers: [ObjectIdentifier: @Sendable () -> Void] = [:]

    /// Told whenever a picture lands, so a board redraws rather than polling for pictures it
    /// cannot know are coming. Keyed by the watcher, because a grid can hold more than one empty
    /// slot and the second one must not silence the first.
    func observe(_ owner: AnyObject, _ handler: @escaping @Sendable () -> Void) {
        observers[ObjectIdentifier(owner)] = handler
    }

    func stopObserving(_ owner: AnyObject) {
        observers.removeValue(forKey: ObjectIdentifier(owner))
    }

    private var directory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map {
            URL(fileURLWithPath: $0)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return base.appendingPathComponent("tailscode/thumbs", isDirectory: true)
    }

    /// The texture for an address if it is already decoded, as a bit pattern the way the transcript
    /// carries its own. Zero means nothing is there yet and `fetch` has not finished.
    func texture(for address: String) -> UInt {
        guard let bits = textures[address] else { return 0 }
        touch(address)
        return bits
    }

    /// Asks for a picture once. A second ask while the first is in the air is dropped, so a board
    /// that re-renders forty times while somebody types does not fetch the same preview forty
    /// times.
    func fetch(_ address: String) {
        guard textures[address] == nil, !inFlight.contains(address) else { return }
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { return }
        inFlight.insert(address)
        Task { [weak self] in
            guard let self else { return }
            let data = await Self.load(url, from: self.file(for: address))
            guard let data else {
                Gtk.onMain { [weak self] in self?.inFlight.remove(address) }
                return
            }
            let bits = Self.decode(data)
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.inFlight.remove(address)
                guard bits != 0 else { return }
                self.store(bits, for: address)
                for handler in self.observers.values { handler() }
            }
        }
    }

    /// A picture widget over a decoded texture, sized to the box a row gives it. The row asks for a
    /// fixed size so its height never changes when the picture arrives — a board that reflows as
    /// thumbnails land is a board whose rows move under the pointer.
    func picture(_ bits: UInt, width: Int32, height: Int32) -> UnsafeMutablePointer<GtkWidget>? {
        guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return nil }
        guard let widget = tailscode_picture_for_texture(OpaquePointer(raw)) else { return nil }
        gtk_picture_set_content_fit(op(widget), GTK_CONTENT_FIT_COVER)
        gtk_widget_set_size_request(widget, width, height)
        gtk_widget_set_halign(widget, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        return widget
    }

    private func store(_ bits: UInt, for address: String) {
        textures[address] = bits
        order.removeAll { $0 == address }
        order.append(address)
        while order.count > Self.textureCap, let oldest = order.first {
            order.removeFirst()
            if let stale = textures.removeValue(forKey: oldest),
                let raw = UnsafeMutableRawPointer(bitPattern: stale)
            {
                g_object_unref(raw)
            }
        }
    }

    private func touch(_ address: String) {
        guard let index = order.firstIndex(of: address) else { return }
        order.remove(at: index)
        order.append(address)
    }

    private func file(for address: String) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in address.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return directory.appendingPathComponent(String(hash, radix: 16))
    }

    private static func decode(_ data: Data) -> UInt {
        data.withUnsafeBytes { buffer -> UInt in
            guard let base = buffer.baseAddress else { return 0 }
            var width: Int32 = 0
            var height: Int32 = 0
            let texture = tailscode_texture_scaled(
                base, gsize(buffer.count), maxDimension, &width, &height)
            guard let texture else { return 0 }
            return UInt(bitPattern: UnsafeMutableRawPointer(texture))
        }
    }

    private static func load(_ url: URL, from file: URL) async -> Data? {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
            let modified = attributes[.modificationDate] as? Date,
            Date().timeIntervalSince(modified) < freshness,
            let cached = try? Data(contentsOf: file)
        {
            return cached
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            !data.isEmpty
        else { return try? Data(contentsOf: file) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return try? Data(contentsOf: file)
        }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        prune(file.deletingLastPathComponent())
        return data
    }

    private static func prune(_ directory: URL) {
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
