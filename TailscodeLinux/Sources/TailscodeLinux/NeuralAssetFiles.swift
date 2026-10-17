import CGdkPixbuf
import Foundation
import TailscodeCore

/// Where the head's nine layers live on this machine and how they reach the compositor.
///
/// Core never reads a file: it asks a loader for a layer by name and takes the raw hand-over format
/// back. This is that loader. It finds the PNG set the packaging script writes (`share/tailscode/
/// neural/` of an installed copy, `Resources/Neural/png` of a checkout, `TAILSCODE_NEURAL_DIR` for
/// anyone who keeps them elsewhere), decodes a layer with gdk-pixbuf only when the compositor asks
/// for it, and hands over RGBA8 rows from the top. The set is looked for once and the answer kept:
/// a machine that has none keeps the Lines style and says so once in the log.
enum NeuralAssetFiles {
    static let variable = "TAILSCODE_NEURAL_DIR"
    private static let installedName = "tailscode/neural"
    private static let checkoutName = "Resources/Neural/png"

    private nonisolated(unsafe) static var found: URL??
    private static let lock = NSLock()
    private nonisolated(unsafe) static var reported = false

    /// The folder holding every layer, or nil on a machine that has no complete set.
    static var directory: URL? {
        lock.lock()
        defer { lock.unlock() }
        if let found { return found }
        let located = candidates().first(where: isComplete)
        found = .some(located)
        return located
    }

    static var isAvailable: Bool { directory != nil }

    /// How many cores a frame that changes a little is spread over. A delta frame is a few
    /// milliseconds of arithmetic, and measured on the harness every core woken for it cost more
    /// than it saved: one worker used 24% of a core for a live turn, two 28%, four 34%.
    /// `TAILSCODE_NEURAL_WORKERS` overrides it for a harness that is measuring exactly that.
    static let deltaWorkers =
        ProcessInfo.processInfo.environment["TAILSCODE_NEURAL_WORKERS"].flatMap(Int.init) ?? 1

    /// How many cores the whole picture is spread over: drawn on open, on a resize and on every
    /// frame of a dive, where one worker would hold the main loop for seventeen milliseconds.
    static let fullWorkers = 4

    /// Wires the shared store to the files, once, at launch.
    static func install() {
        NeuralAssetStore.shared.configure(loader: loader)
        NeuralParallelism.maximumWorkers = deltaWorkers
        NeuralParallelism.minimumRows = 16
    }

    /// Forgets what was found, for a harness that changes the folder between looks.
    static func forget() {
        lock.lock()
        found = nil
        lock.unlock()
    }

    /// Says once that the head cannot be drawn here and why the transcript keeps its lines.
    static func reportMissingOnce() {
        lock.lock()
        let first = !reported
        reported = true
        lock.unlock()
        guard first else { return }
        AppLog.write(
            .ui,
            "neural trace: no layer set found (looked in \(candidates().count) places, set "
                + "\(variable) to override); the transcript keeps the Lines style")
    }

    static var loader: NeuralAssetLoader {
        { name in
            guard let directory = NeuralAssetFiles.directory else { return nil }
            return decode(directory.appendingPathComponent(name + ".png").path)
        }
    }

    /// Every place a layer set may be, most specific first: an explicit folder, the person's data
    /// directory, the prefix the binary was installed under, the system prefixes, then a checkout
    /// found by walking up from the binary and the one the install record names.
    static func candidates() -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        var list: [URL] = []
        func add(_ path: String) { list.append(URL(fileURLWithPath: path, isDirectory: true)) }
        if let explicit = environment[variable], !explicit.isEmpty { add(explicit) }
        let dataHome =
            environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
            .path
        add("\(dataHome)/\(installedName)")
        let executable = URL(fileURLWithPath: DesktopGuard.executablePath)
        let prefix = executable.deletingLastPathComponent().deletingLastPathComponent()
        add(prefix.appendingPathComponent("share/\(installedName)").path)
        let dataDirs =
            (environment["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 }
                ?? "/usr/local/share:/usr/share")
            .split(separator: ":")
        for directory in dataDirs { add("\(directory)/\(installedName)") }
        add("/app/share/\(installedName)")
        var walk = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            add(walk.appendingPathComponent(checkoutName).path)
            let parent = walk.deletingLastPathComponent()
            if parent == walk { break }
            walk = parent
        }
        if let source = installedSource() { add("\(source)/\(checkoutName)") }
        var seen = Set<String>()
        return list.filter { seen.insert($0.path).inserted }
    }

    /// The checkout the install script recorded, which is how an installed development build finds
    /// the layers its checkout carries before a packaged copy exists.
    private static func installedSource() -> String? {
        let url = AppLog.directory.appendingPathComponent("install.json")
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let source = object["source"] as? [String: Any], let path = source["path"] as? String
        else { return nil }
        return path
    }

    private static func isComplete(_ directory: URL) -> Bool {
        NeuralAssetName.allCases.allSatisfy {
            FileManager.default.isReadableFile(
                atPath: directory.appendingPathComponent($0.fileName + ".png").path)
        }
    }

    /// One PNG as the hand-over format: `NTRG`, width and height little-endian, then RGBA8 rows.
    static func decode(_ path: String) -> Data? {
        var error: UnsafeMutablePointer<GError>?
        guard let pixbuf = gdk_pixbuf_new_from_file(path, &error) else {
            if let error { g_error_free(error) }
            return nil
        }
        defer { g_object_unref(UnsafeMutableRawPointer(pixbuf)) }
        let width = Int(gdk_pixbuf_get_width(pixbuf))
        let height = Int(gdk_pixbuf_get_height(pixbuf))
        let channels = Int(gdk_pixbuf_get_n_channels(pixbuf))
        let stride = Int(gdk_pixbuf_get_rowstride(pixbuf))
        guard width > 0, height > 0, channels >= 3, let source = gdk_pixbuf_get_pixels(pixbuf)
        else { return nil }
        var data = Data(count: 12 + width * height * 4)
        data.replaceSubrange(0..<4, with: Array("NTRG".utf8))
        for (offset, value) in [UInt32(width), UInt32(height)].enumerated() {
            withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(4 + offset * 4..<8 + offset * 4, with: $0) }
        }
        data.withUnsafeMutableBytes { out in
            guard let base = out.baseAddress else { return }
            let pixels = base.advanced(by: 12).assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                let from = source + row * stride
                let to = pixels + row * width * 4
                if channels == 4 {
                    memcpy(to, from, width * 4)
                } else {
                    for column in 0..<width {
                        to[column * 4] = from[column * channels]
                        to[column * 4 + 1] = from[column * channels + 1]
                        to[column * 4 + 2] = from[column * channels + 2]
                        to[column * 4 + 3] = 255
                    }
                }
            }
        }
        return data
    }
}
