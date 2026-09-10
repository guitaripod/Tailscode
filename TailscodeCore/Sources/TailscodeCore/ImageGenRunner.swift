import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// One render, from queue to bytes. The runner owns the whole life of a single request: hand the
/// machine the picture the render starts from if there is one, queue the graph, poll on a cadence,
/// fetch what the run named, and hand the outcome back on whatever queue the caller chose. Timing
/// is the runner's business — a surface shows what it is told, and the clock here is the honest
/// one.
///
/// It lives in Core because a render is the same errand on every desk: the phone, the Mac and the
/// GTK pane differ only in what they draw while it runs.
public final class ImageGenRunner: @unchecked Sendable {
    public enum Outcome: Sendable {
        case picture(Data, seconds: Double)
        case failure(String)
    }

    public let prompt: String
    public let engine: ImageGenEngine
    public let mode: ImageGenMode
    public let aspect: ImageGenAspect
    public let seed: UInt64
    private let client: ImageGenClient
    private var task: Task<Void, Never>?

    public init(
        endpoint: ImageGenEndpoint, prompt: String, engine: ImageGenEngine,
        mode: ImageGenMode, aspect: ImageGenAspect
    ) {
        client = ImageGenClient(endpoint: endpoint)
        self.prompt = prompt
        self.engine = engine
        self.mode = mode
        self.aspect = aspect
        seed = UInt64.random(in: 1...UInt64.max)
    }

    public func cancel() {
        task?.cancel()
    }

    /// Runs the request to an outcome, polling every two seconds. The callback fires exactly
    /// once, from a background queue — the surface hops itself back to its own context.
    public func run(
        prompt: String, engine: ImageGenEngine, mode: ImageGenMode, aspect: ImageGenAspect,
        referencePath: String?, _ done: @escaping @Sendable (Outcome) -> Void
    ) {
        let started = Date()
        task = Task.detached { [client, seed] in
            do {
                let handed = try await Self.hand(referencePath, to: client)
                let request = try await client.queue(
                    prompt: prompt, engine: engine, mode: mode, aspect: aspect, seed: seed,
                    referencePath: handed)
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if let verdict = await client.poll(request) {
                        switch verdict {
                        case .success:
                            let (data, _) = try await client.fetch(request: request)
                            done(.picture(data, seconds: Date().timeIntervalSince(started)))
                        case .failure(let failure):
                            done(.failure(failure.reason))
                        }
                        return
                    }
                }
            } catch let failure as ImageGenFailure {
                done(.failure(failure.reason))
            } catch {
                done(.failure(Localized.text("ComfyUI is not answering")))
            }
        }
    }

    /// A reference is a file on *this* device and the graph names a file on the *machine's* own
    /// input directory, so the bytes are put there first and the name that comes back is what the
    /// graph is given. A path handed over raw only ever worked when both were the same computer.
    private static func hand(_ path: String?, to client: ImageGenClient) async throws -> String? {
        guard let path else { return nil }
        return try await client.upload(fileAt: path)
    }
}

/// Where finished pictures live on this device: one directory per engine under the platform's own
/// place for them, named by the moment they were made. A picture is written once and read many
/// times — a thumbnail decodes from the same bytes a viewer opens and a save hands over.
public enum ImageGenFiles {
    /// A picture is a document on a desktop and app data on a phone: iOS has no Pictures folder,
    /// and a render that landed in the caches directory is one the system may delete while its
    /// author is still looking at it.
    private static var home: FileManager.SearchPathDirectory {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            return .applicationSupportDirectory
        #else
            return .picturesDirectory
        #endif
    }

    public static func directory(for engine: ImageGenEngine) -> URL {
        let base = FileManager.default.urls(for: home, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Tailscode", isDirectory: true)
            .appendingPathComponent(engine.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func write(_ data: Data, engine: ImageGenEngine) -> String {
        let stamp = Int(Date().timeIntervalSince1970)
        let url = directory(for: engine).appendingPathComponent("draw-\(stamp).png")
        try? data.write(to: url)
        return url.path
    }

    /// A picture handed in from somewhere with no path of its own — a phone's photo library, a
    /// paste — given one, because a reference is addressed by file everywhere else.
    public static func stage(_ data: Data, named name: String) -> String? {
        let base = FileManager.default.urls(for: home, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Tailscode", isDirectory: true)
            .appendingPathComponent("references", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let stem = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension.isEmpty
            ? "png" : (name as NSString).pathExtension
        let url = directory.appendingPathComponent(
            "\(stem.isEmpty ? "reference" : stem)-\(stamp).\(suffix)")
        do {
            try data.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }
}
