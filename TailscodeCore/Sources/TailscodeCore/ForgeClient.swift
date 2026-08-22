import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The one place this app talks to the renderer. Four calls and a socket is the whole surface, so
/// it is one enum: everything answers a plain dictionary, and a timeout, a refusal or an
/// unparseable body all come back as a `ForgeFailure` naming the machine rather than as a
/// Foundation error nobody can read.
///
/// Status is deliberately not thrown on. ComfyUI answers a graph it will not run with a 400 whose
/// body is the only useful thing in the exchange — which node, which field, what it wanted — so
/// the body is read on every status and the caller decides.
enum ForgeFetch {
    static let timeout: TimeInterval = 8
    /// What the first request of the day is given. The renderer is socket-activated and stops
    /// itself after fifteen idle minutes, so the connection that wakes it waits on 42GB of weights
    /// reaching a card before anything answers. Eight seconds would call a working machine dead.
    static let coldTimeout: TimeInterval = 45

    static func json(
        _ url: URL?, body: [String: Any]? = nil, host: String, timeout: TimeInterval
    ) async throws -> [String: Any] {
        guard let url else { throw ForgeFailure.unreachable(host) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw ForgeFailure.unreachable(host)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ForgeFailure.unreachable(host)
        }
        return object
    }

    /// A call whose answer nobody reads — cancelling. It either landed or the render was already
    /// over, and neither is worth a sentence on a screen.
    static func fire(_ url: URL?) async {
        guard let url else { return }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [String: Any]())
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Why the server would not take the graph, in its own words. It answers a validation failure
    /// as a per-node report rather than a sentence, and the node keys are this app's own — so the
    /// message names the field a person can actually change.
    static func complaint(in body: [String: Any]) -> String? {
        if let errors = body["node_errors"] as? [String: Any], !errors.isEmpty {
            let lines = errors.sorted { $0.key < $1.key }.compactMap { key, value -> String? in
                guard let detail = value as? [String: Any] else { return nil }
                let list = detail["errors"] as? [[String: Any]] ?? []
                let first = list.compactMap { $0["message"] as? String }.first
                guard let first else { return nil }
                return Localized.text("%@: %@", key, first)
            }
            if !lines.isEmpty { return lines.joined(separator: " · ") }
        }
        if let error = body["error"] as? [String: Any] {
            let message = error["message"] as? String ?? error["type"] as? String
            if let message, !message.isEmpty { return message }
        }
        if let error = body["error"] as? String, !error.isEmpty { return error }
        return nil
    }
}

/// The renderer, driven. A generation is a POST, a socket full of frames and a file fetched by
/// name afterwards, and the awkward parts are all here so no client has to know them: the same
/// client id must go to both the POST and the socket or the frames land on somebody else's
/// connection; the null-node `executing` frame is what "done" looks like; the file's name is only
/// in history, which lags the last frame by a beat; and the machine may be asleep when the first
/// request arrives.
///
/// The whole thing is offered as one stream of job snapshots rather than as a callback surface,
/// because all three clients want the same thing — the latest state of the render, drawn — and a
/// stream that always ends on a terminal phase is a contract a UI cannot get wrong.
public struct ForgeClient: Sendable {
    public let endpoint: ForgeEndpoint
    public let clientID: String

    /// How long the client keeps asking after the socket dies mid-render. The render is happening
    /// on the other machine either way, and a dropped Wi-Fi is not a reason to lose a clip that is
    /// two minutes from finishing.
    public static let salvageDeadline: TimeInterval = 600
    public static let salvageInterval = Duration.seconds(3)
    /// History files the output a moment after the last frame, so the first ask often misses.
    public static let collectAttempts = 8
    public static let collectInterval = Duration.milliseconds(400)

    public init(endpoint: ForgeEndpoint, clientID: String = UUID().uuidString) {
        self.endpoint = endpoint
        self.clientID = clientID
    }

    /// Wakes the machine and says whether it answered. Worth calling before the first render of a
    /// session purely so the waiting is explained while it happens rather than afterwards.
    public func warm() async -> Bool {
        let body = try? await ForgeFetch.json(
            endpoint.url("/system_stats"), host: endpoint.host, timeout: ForgeFetch.coldTimeout)
        return body != nil
    }

    public func submit(_ graph: ForgeGraph) async throws -> String {
        let body = try await ForgeFetch.json(
            endpoint.url("/prompt"),
            body: ["prompt": graph.payload, "client_id": clientID], host: endpoint.host,
            timeout: ForgeFetch.coldTimeout)
        if let complaint = ForgeFetch.complaint(in: body) {
            throw ForgeFailure.rejected(endpoint.host, complaint)
        }
        guard let promptID = body["prompt_id"] as? String, !promptID.isEmpty else {
            throw ForgeFailure.refused(
                endpoint.host, Localized.text("%@ took the render but named no job", endpoint.host))
        }
        return promptID
    }

    public func cancel() async {
        await ForgeFetch.fire(endpoint.url("/interrupt"))
    }

    /// The file a finished job left behind, or nothing if history does not have it yet. Nothing is
    /// a normal answer for the first second after the last frame, which is why the caller retries.
    public func collect(_ promptID: String) async throws -> ForgeAsset? {
        let body = try await ForgeFetch.json(
            endpoint.url("/history/\(promptID)"), host: endpoint.host, timeout: ForgeFetch.timeout)
        guard let entry = body[promptID] as? [String: Any] else { return nil }
        if let status = entry["status"] as? [String: Any],
            let text = status["status_str"] as? String, text == "error"
        {
            throw ForgeFailure.renderFailed(endpoint.host, Self.reason(in: status))
        }
        guard let outputs = entry["outputs"] else { return nil }
        return ForgeAsset.read(outputs: outputs)
    }

    /// One render, start to finish, as the states a screen draws. The last snapshot is always a
    /// terminal phase — done, failed or cancelled — so a client that renders every element and
    /// stops when the stream ends can never be left showing a bar that will not move.
    public func render(_ recipe: ForgeRecipe) -> AsyncStream<ForgeJob> {
        let (stream, continuation) = AsyncStream<ForgeJob>.makeStream()
        let work = Task { await drive(recipe, into: continuation) }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    private func drive(_ recipe: ForgeRecipe, into continuation: AsyncStream<ForgeJob>.Continuation) async {
        var job = ForgeJob(recipe: recipe)
        job.submitting()
        continuation.yield(job)

        let graph = ForgeGraph(recipe: recipe)
        let problems = graph.problems
        guard problems.isEmpty else {
            return end(&job, ForgeFailure.rejected(endpoint.host, problems.joined(separator: " · ")), continuation)
        }
        guard let socketURL = endpoint.socketURL(clientID: clientID) else {
            return end(&job, ForgeFailure.unreachable(endpoint.host), continuation)
        }

        let socket = URLSession.shared.webSocketTask(with: socketURL)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        let promptID: String
        do {
            promptID = try await submit(graph)
        } catch {
            return end(&job, error, continuation)
        }
        job.accepted(promptID: promptID)
        continuation.yield(job)

        var lost = false
        listening: while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                lost = true
                break listening
            }
            guard case .string(let text) = message else { continue }
            let event = ForgeEvent.read(text)
            if let id = event.promptID, !id.isEmpty, id != promptID { continue }
            job.saw(event)
            continuation.yield(job)
            switch event {
            case .failed, .interrupted:
                continuation.finish()
                return
            case .finished, .succeeded:
                break listening
            default:
                continue
            }
        }

        if Task.isCancelled {
            job.cancelled()
            continuation.yield(job)
            continuation.finish()
            return
        }

        do {
            let asset = try await (lost ? salvage(promptID) : gather(promptID))
            guard let asset else {
                return end(&job, ForgeFailure.noOutput(endpoint.host), continuation)
            }
            job.delivered(asset)
            continuation.yield(job)
            continuation.finish()
        } catch {
            end(&job, error, continuation)
        }
    }

    /// The file, asked for a few times in quick succession. History is written a moment after the
    /// last frame goes out, so the first ask genuinely misses on a fast clip.
    private func gather(_ promptID: String) async throws -> ForgeAsset? {
        for attempt in 0..<Self.collectAttempts {
            if attempt > 0 { try? await Task.sleep(for: Self.collectInterval) }
            if let asset = try await collect(promptID) { return asset }
        }
        return nil
    }

    /// What happens when the socket dies while the card is still working. The render does not care
    /// that this app stopped watching, so the job is followed by asking history instead — a phone
    /// that locked its screen mid-render still gets its clip.
    private func salvage(_ promptID: String) async throws -> ForgeAsset? {
        let deadline = Date().addingTimeInterval(Self.salvageDeadline)
        while Date() < deadline, !Task.isCancelled {
            if let asset = try await collect(promptID) { return asset }
            try? await Task.sleep(for: Self.salvageInterval)
        }
        throw ForgeFailure.disconnected(endpoint.host)
    }

    /// Every way out of a render is one sentence and one terminal snapshot. A foreign error never
    /// reaches a client: it is named here or it is the machine not answering.
    private func end(
        _ job: inout ForgeJob, _ error: Error, _ continuation: AsyncStream<ForgeJob>.Continuation
    ) {
        job.failed(Self.reason(error, host: endpoint.host))
        continuation.yield(job)
        continuation.finish()
    }

    public static func reason(_ error: Error, host: String) -> String {
        if let failure = error as? ForgeFailure { return failure.description }
        return ForgeFailure.unreachable(host).description
    }

    private static func reason(in status: [String: Any]) -> String {
        let messages = status["messages"] as? [Any] ?? []
        for message in messages {
            guard let pair = message as? [Any], pair.count >= 2 else { continue }
            guard let payload = pair[1] as? [String: Any] else { continue }
            if let text = payload["exception_message"] as? String, !text.isEmpty { return text }
        }
        return Localized.text("The render failed and said nothing about why")
    }
}
