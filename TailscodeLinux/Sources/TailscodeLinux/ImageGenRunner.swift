import Foundation
import TailscodeCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// One render, from queue to bytes. The runner owns the whole life of a single request: queue it
/// against the endpoint, poll on a cadence, fetch the picture when the run names one, and hand
/// the outcome back on whatever queue the caller chose. Timing is the runner's business — the
/// pane shows what it is told, and the clock here is the honest one.
final class ImageGenRunner: @unchecked Sendable {
    enum Outcome: Sendable {
        case picture(Data, seconds: Double)
        case failure(String)
    }

    let prompt: String
    let engine: ImageGenEngine
    let mode: ImageGenMode
    let aspect: ImageGenAspect
    let seed: UInt64
    private let client: ImageGenClient
    private var task: Task<Void, Never>?

    init(
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

    func cancel() {
        task?.cancel()
    }

    /// Runs the request to an outcome, polling every two seconds. The callback fires exactly
    /// once, from a background queue — the pane hops itself back to the main context.
    func run(
        prompt: String, engine: ImageGenEngine, mode: ImageGenMode, aspect: ImageGenAspect,
        referencePath: String?, _ done: @escaping @Sendable (Outcome) -> Void
    ) {
        let started = Date()
        task = Task.detached { [client, seed] in
            do {
                let request = try await client.queue(
                    prompt: prompt, engine: engine, mode: mode, aspect: aspect, seed: seed,
                    referencePath: referencePath)
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
}

/// Where finished pictures live on this machine: one directory per engine under the app's own
/// pictures cache, named by the moment they were made. A picture is written once and read many
/// times — the tile decodes from the same bytes the viewer opens.
enum ImageGenFiles {
    static func directory(for engine: ImageGenEngine) -> URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Tailscode", isDirectory: true)
            .appendingPathComponent(engine.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(_ data: Data, engine: ImageGenEngine) -> String {
        let stamp = Int(Date().timeIntervalSince1970)
        let url = directory(for: engine).appendingPathComponent("draw-\(stamp).png")
        try? data.write(to: url)
        return url.path
    }
}