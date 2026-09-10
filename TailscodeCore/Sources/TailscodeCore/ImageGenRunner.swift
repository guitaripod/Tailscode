import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// One render, from queue to bytes. The runner owns the whole life of a single request: hand the
/// machine the picture the render starts from if there is one, queue the graph, follow the run on
/// the machine's own socket for what it is doing, poll history on a cadence for whether it is
/// done, fetch what the run named, and hand the outcome back on whatever queue the caller chose.
/// Timing is the runner's business — a surface shows what it is told, and the clock here is the
/// honest one.
///
/// It lives in Core because a render is the same errand on every desk: the phone, the Mac and the
/// GTK pane differ only in what they draw while it runs.
public final class ImageGenRunner: @unchecked Sendable {
    public enum Outcome: Sendable {
        case picture(Data, seconds: Double, remoteName: String)
        case failure(String)
    }

    public let prompt: String
    public let engine: ImageGenEngine
    public let mode: ImageGenMode
    public let aspect: ImageGenAspect
    public let seed: UInt64
    private let client: ImageGenClient
    private var task: Task<Void, Never>?
    private let held = HeldSocket()
    private let ticket = Ticket()

    public init(
        endpoint: ImageGenEndpoint, prompt: String, engine: ImageGenEngine,
        mode: ImageGenMode, aspect: ImageGenAspect
    ) {
        client = ImageGenClient(endpoint: endpoint)
        self.prompt = prompt
        self.engine = engine
        self.mode = mode
        self.aspect = aspect
        seed = UInt64.random(in: 1...UInt64(Int64.max))
    }

    /// Stops following the render and takes it off the machine: deleted from the queue if it has
    /// not started, interrupted if it has. The callback never fires after this.
    public func cancel() {
        task?.cancel()
        held.close()
        let request = ticket.request
        let client = self.client
        Task.detached {
            guard let request else { return }
            await client.stop(request)
        }
    }

    /// Runs the request to an outcome. `progress` fires on the socket's frames, as often as the
    /// machine speaks; `done` fires exactly once. Both come from a background queue — the surface
    /// hops itself back to its own context.
    public func run(
        prompt: String, engine: ImageGenEngine, mode: ImageGenMode, aspect: ImageGenAspect,
        referencePath: String?, progress: (@Sendable (ImageGenProgress) -> Void)? = nil,
        _ done: @escaping @Sendable (Outcome) -> Void
    ) {
        run(
            prompt: prompt, engine: engine, mode: mode, aspect: aspect,
            reference: referencePath.map { ImageGenReference(path: $0) }, progress: progress, done)
    }

    public func run(
        prompt: String, engine: ImageGenEngine, mode: ImageGenMode, aspect: ImageGenAspect,
        reference: ImageGenReference?, progress: (@Sendable (ImageGenProgress) -> Void)? = nil,
        _ done: @escaping @Sendable (Outcome) -> Void
    ) {
        let started = Date()
        task = Task.detached { [client, seed, held, ticket] in
            do {
                if let reference, reference.machineName == nil {
                    progress?(ImageGenProgress(stage: .sendingReference))
                }
                let handed = try await Self.hand(reference, to: client)
                let socket = Self.open(client: client, held: held)
                let request = try await client.queue(
                    ImageGenClient.graph(
                        prompt: prompt, engine: engine, mode: mode, aspect: aspect, seed: seed,
                        referenceName: handed))
                ticket.request = request
                progress?(ImageGenProgress(stage: .queued(ahead: 0)))
                let verdict = SocketVerdict()
                let listener = Task.detached {
                    await Self.listen(
                        socket, for: request, verdict: verdict, progress: progress)
                }
                defer {
                    listener.cancel()
                    held.close()
                }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: verdict.settled ? 400_000_000 : 1_500_000_000)
                    guard !Task.isCancelled else { return }
                    if let outcome = await client.poll(request) {
                        switch outcome {
                        case .success:
                            let (data, name) = try await client.fetch(request: request)
                            done(
                                .picture(
                                    data, seconds: Date().timeIntervalSince(started),
                                    remoteName: name))
                        case .failure(let failure):
                            done(.failure(failure.reason))
                        }
                        return
                    }
                }
            } catch let failure as ImageGenFailure {
                guard !Task.isCancelled else { return }
                done(.failure(failure.reason))
            } catch {
                guard !Task.isCancelled else { return }
                done(.failure(Localized.text("ComfyUI is not answering")))
            }
        }
    }

    /// A reference is a file on *this* device and the graph names a file on the *machine's* own
    /// input directory, so the bytes are put there first and the name that comes back is what the
    /// graph is given. A picture the machine already keeps is named where it is and nothing
    /// travels. A path handed over raw only ever worked when both were the same computer.
    private static func hand(_ reference: ImageGenReference?, to client: ImageGenClient)
        async throws -> String?
    {
        guard let reference else { return nil }
        if let name = reference.machineName { return name }
        return try await client.upload(fileAt: reference.path)
    }

    /// The machine's socket, opened before the graph is queued so the first frame is not missed.
    /// A socket that cannot be opened costs nothing: the poll decides the outcome either way, and
    /// the stage simply has fewer words.
    private static func open(client: ImageGenClient, held: HeldSocket) -> URLSessionWebSocketTask? {
        guard let url = client.endpoint.socketURL(clientID: ImageGenClient.clientID) else {
            return nil
        }
        let socket = URLSession.shared.webSocketTask(with: url)
        held.hold(socket)
        socket.resume()
        return socket
    }

    /// Reads frames until the run is over or the socket is. The node census gives the bar its
    /// honest fraction; the node's class gives the stage its words; the sampler's step gives the
    /// painting stage its count. Nothing here decides success — history does.
    private static func listen(
        _ socket: URLSessionWebSocketTask?, for request: ImageGenRequest, verdict: SocketVerdict,
        progress: (@Sendable (ImageGenProgress) -> Void)?
    ) async {
        guard let socket else { return }
        var current = ImageGenProgress(stage: .queued(ahead: 0))
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                return
            }
            guard case .string(let text) = message else { continue }
            let event = ForgeEvent.read(text)
            if let id = event.promptID, !id.isEmpty, id != request.id { continue }
            switch event {
            case .status(let queued):
                guard case .queued = current.stage else { continue }
                current.stage = .queued(ahead: max(0, queued - 1))
            case .started:
                current.stage = .loading
            case .progressed(_, let census):
                current.fraction = census.fraction
                if let running = census.running, let type = request.nodeClasses[running],
                    let stage = ImageGenProgress.stage(forNodeClass: type)
                {
                    current.stage = stage
                }
            case .executing(_, let node):
                if let type = request.nodeClasses[node],
                    let stage = ImageGenProgress.stage(forNodeClass: type)
                {
                    if stage != current.stage {
                        current.step = nil
                        current.steps = nil
                    }
                    current.stage = stage
                }
            case .sampling(_, _, let step, let steps):
                current.stage = .painting
                current.step = step
                current.steps = steps
            case .finished, .succeeded, .failed, .interrupted:
                verdict.settled = true
                return
            case .cached, .executed, .ignored:
                continue
            }
            progress?(current)
        }
    }
}

/// What the socket has concluded, read by the poll loop to tighten its cadence the moment the
/// machine says the run is over rather than a second and a half later.
final class SocketVerdict: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    var settled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return done
        }
        set {
            lock.lock()
            done = newValue
            lock.unlock()
        }
    }
}

/// The queued request, kept where a cancel arriving from another thread can find it.
final class Ticket: @unchecked Sendable {
    private let lock = NSLock()
    private var held: ImageGenRequest?

    var request: ImageGenRequest? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return held
        }
        set {
            lock.lock()
            held = newValue
            lock.unlock()
        }
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
