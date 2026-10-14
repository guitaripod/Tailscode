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

    /// The first byte of a file, which is the cheapest question that distinguishes a clip that is
    /// still there from one that has been cleaned up. A range is asked for rather than a HEAD
    /// because every server answers a range and not every server routes a HEAD.
    static func peek(_ url: URL, host: String) async throws -> Int {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw ForgeFailure.unreachable(host)
        }
    }

    static func bytes(_ url: URL, host: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: coldTimeout)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 404 || status == 410 { throw ForgeFailure.missingFile(host) }
            guard status < 400, !data.isEmpty else { throw ForgeFailure.unreachable(host) }
            return data
        } catch let failure as ForgeFailure {
            throw failure
        } catch {
            throw ForgeFailure.unreachable(host)
        }
    }

    /// Puts a picture in the machine's own input directory and hands back the name a graph must
    /// call it by. A start picture chosen on this device is a file the renderer cannot open, so
    /// the bytes travel and the name comes back — the same road the image studio's references
    /// take, because it is the same machine.
    static func upload(_ data: Data, named name: String, to endpoint: ForgeEndpoint) async throws -> String {
        guard let url = endpoint.url("/upload/image") else { throw ForgeFailure.unreachable(endpoint.host) }
        let boundary = "tailscode-" + UUID().uuidString
        var request = URLRequest(url: url, timeoutInterval: coldTimeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart(data, named: name, boundary: boundary)
        let answer: Data
        let response: URLResponse
        do {
            (answer, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ForgeFailure.unreachable(endpoint.host)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
            let stored = object["name"] as? String, !stored.isEmpty
        else {
            throw ForgeFailure.refused(
                endpoint.host, Localized.text("%@ would not take the start picture", endpoint.host))
        }
        let subfolder = object["subfolder"] as? String ?? ""
        return subfolder.isEmpty ? stored : subfolder + "/" + stored
    }

    private static func multipart(_ data: Data, named name: String, boundary: String) -> Data {
        var body = Data()
        func write(_ text: String) { body.append(Data(text.utf8)) }
        write("--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"image\"; filename=\"\(name)\"\r\n")
        write("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        write("\r\n--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"overwrite\"\r\n\r\n")
        write("true\r\n")
        write("--\(boundary)--\r\n")
        return body
    }

    /// A call whose answer nobody reads — cancelling. It either landed or the render was already
    /// over, and neither is worth a sentence on a screen.
    static func fire(_ url: URL?, body: [String: Any] = [:]) async {
        guard let url else { return }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
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

    /// How long the client keeps asking after the machine stops answering mid-render. The render
    /// is happening on the other machine either way, and a dropped Wi-Fi is not a reason to lose a
    /// clip that is two minutes from finishing. The clock runs from the last time the machine
    /// *answered*: while it says the job is running or waiting, there is nothing to give up on.
    public static let salvageDeadline: TimeInterval = 600
    public static let salvageInterval = Duration.seconds(3)
    /// History files the output a moment after the last frame, so the first ask often misses.
    public static let collectAttempts = 25
    public static let collectInterval = Duration.milliseconds(400)
    /// How often the machine is asked where the job stands while the socket is quiet, so a finish
    /// frame the socket never delivered cannot leave a bar standing at the end for ever.
    public static let watchInterval = Duration.seconds(15)

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

    /// Puts the start picture on the machine when it is a file on this device, and hands back the
    /// name the graph must use. Nil when the recipe needs no upload.
    public func place(_ frame: ForgeFrame?) async throws -> String? {
        guard case .file(let path) = frame else { return nil }
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            throw ForgeFailure.refused(
                endpoint.host, Localized.text("The start picture could not be read"))
        }
        return try await ForgeFetch.upload(
            data, named: (path as NSString).lastPathComponent, to: endpoint)
    }

    /// Posts the graph under the id this device chose for it. A machine that takes a client's id
    /// keeps the job under it from the first instant, which is what lets a render be found again
    /// even when the answer to this post never arrived; one that ignores it answers with its own,
    /// and that one is used.
    public func submit(_ graph: ForgeGraph, promptID: String? = nil) async throws -> String {
        var body: [String: Any] = ["prompt": graph.payload, "client_id": clientID]
        if let promptID { body["prompt_id"] = promptID }
        let answer = try await ForgeFetch.json(
            endpoint.url("/prompt"), body: body, host: endpoint.host,
            timeout: ForgeFetch.coldTimeout)
        if let complaint = ForgeFetch.complaint(in: answer) {
            throw ForgeFailure.rejected(endpoint.host, complaint)
        }
        guard let accepted = answer["prompt_id"] as? String, !accepted.isEmpty else {
            throw ForgeFailure.refused(
                endpoint.host, Localized.text("%@ took the render but named no job", endpoint.host))
        }
        return accepted
    }

    /// Stops one job, and only that job. The machine is shared — an image render, another desk's
    /// clip — and `/interrupt` with no name stops whatever happens to be running, so a Stop on a
    /// job still waiting its turn used to kill somebody else's render and leave this one queued.
    /// The machine is asked where the job stands first: a running one is interrupted by name, a
    /// waiting one is taken out of the queue, and one that is already over is left alone. The
    /// answer is handed back because a job caught finishing has a clip, and that clip is worth
    /// filing even though the person asked for it to stop.
    @discardableResult
    public func cancel(_ promptID: String) async -> ForgeStanding? {
        guard let standing = try? await standing(of: promptID) else { return nil }
        switch standing {
        case .running:
            await ForgeFetch.fire(endpoint.url("/interrupt"), body: ["prompt_id": promptID])
        case .waiting:
            await ForgeFetch.fire(endpoint.url("/queue"), body: ["delete": [promptID]])
        case .finished, .failed, .stopped, .unknown:
            break
        }
        return standing
    }

    /// Where to point a player, confirmed before it is pointed there. A kept clip is a receipt for
    /// a file on somebody else's disk, and `/view` answers a file that has been cleaned up with a
    /// 404 — which a video player reports in its own words, none of which are about this machine
    /// or tell anybody whether to wait. Asking first is what lets the clip say it is gone.
    public func locate(_ asset: ForgeAsset) async throws -> URL {
        guard let url = asset.url(on: endpoint) else {
            throw ForgeFailure.unreachable(endpoint.host)
        }
        let status = try await ForgeFetch.peek(url, host: endpoint.host)
        if status == 404 || status == 410 { throw ForgeFailure.missingFile(endpoint.host) }
        guard status < 400 else { throw ForgeFailure.unreachable(endpoint.host) }
        return url
    }

    /// The clip itself, for the places a URL is not enough — the photo library, a share sheet.
    /// The bytes are the file the renderer wrote, fetched by the same three fields a player uses,
    /// so what gets saved is never a re-encode of what a preview happened to decode.
    public func fetch(_ asset: ForgeAsset) async throws -> Data {
        guard let url = asset.url(on: endpoint) else {
            throw ForgeFailure.unreachable(endpoint.host)
        }
        return try await ForgeFetch.bytes(url, host: endpoint.host)
    }

    /// Where a job stands on the machine, from the machine's own account: the history it files
    /// once a job is over, and the queue while it is not. This is the one question that does not
    /// need the socket, which is what makes a render survivable — a phone that locked its screen,
    /// a desktop that was closed and reopened, an app that was reinstalled mid-clip.
    public func standing(of promptID: String) async throws -> ForgeStanding {
        let history = try await ForgeFetch.json(
            endpoint.url("/history/\(promptID)"), host: endpoint.host,
            timeout: ForgeFetch.timeout)
        if let entry = history[promptID] as? [String: Any] {
            return ForgeStanding.ending(of: entry, host: endpoint.host)
        }
        let queue = try await ForgeFetch.json(
            endpoint.url("/queue"), host: endpoint.host, timeout: ForgeFetch.timeout)
        return ForgeStanding.place(of: promptID, in: queue)
    }

    /// One render, start to finish, as the states a screen draws. The last snapshot is always a
    /// terminal phase — done, failed or cancelled — so a client that renders every element and
    /// stops when the stream ends can never be left showing a bar that will not move.
    public func render(_ recipe: ForgeRecipe, expecting: TimeInterval? = nil) -> AsyncStream<ForgeJob> {
        stream { continuation, held in
            await drive(recipe, expecting: expecting, into: continuation, held: held)
        }
    }

    /// A render the app lost track of — closed, killed or reinstalled while the machine carried
    /// on — found again by the id it was filed under, and followed to its end exactly as a render
    /// started here is. Nil only when the post never reached the machine and there is nothing to
    /// report; every other outcome, including the machine having forgotten the job, is a stream
    /// that ends on a terminal snapshot.
    public func recover(_ pending: ForgePending, expecting: TimeInterval? = nil) async -> AsyncStream<ForgeJob>? {
        let first = try? await standing(of: pending.promptID)
        if !pending.confirmed, first == nil || first == .unknown {
            ForgeStore.clearPending(pending.promptID)
            return nil
        }
        return stream { continuation, held in
            await reattach(pending, first: first, expecting: expecting, into: continuation, held: held)
        }
    }

    private func stream(
        _ body: @escaping @Sendable (AsyncStream<ForgeJob>.Continuation, HeldSocket) async -> Void
    ) -> AsyncStream<ForgeJob> {
        let (stream, continuation) = AsyncStream<ForgeJob>.makeStream()
        let held = HeldSocket()
        let work = Task {
            await withTaskCancellationHandler {
                await body(continuation, held)
            } onCancel: {
                held.close()
            }
        }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    private func drive(
        _ recipe: ForgeRecipe, expecting: TimeInterval?,
        into continuation: AsyncStream<ForgeJob>.Continuation, held: HeldSocket
    ) async {
        var job = ForgeJob(recipe: recipe, expected: expecting)
        job.submitting()
        continuation.yield(job)

        let placed: String?
        do {
            placed = try await place(recipe.frame)
        } catch {
            return end(&job, error, continuation)
        }
        let graph = ForgeGraph(recipe: recipe, uploadedFrame: placed)
        let problems = graph.problems
        guard problems.isEmpty else {
            return end(&job, ForgeFailure.rejected(endpoint.host, problems.joined(separator: " · ")), continuation)
        }
        guard let socketURL = endpoint.socketURL(clientID: clientID) else {
            return end(&job, ForgeFailure.unreachable(endpoint.host), continuation)
        }

        let socket = URLSession.shared.webSocketTask(with: socketURL)
        held.hold(socket)
        socket.resume()
        defer { held.close() }

        let minted = UUID().uuidString.lowercased()
        let intent = ForgePending(
            promptID: minted, clientID: clientID, endpoint: endpoint, recipe: recipe,
            startedAt: job.startedAt ?? Date(), nodes: graph.nodes.count)
        ForgeStore.remember(pending: intent)
        job.announce(minted)
        continuation.yield(job)

        let promptID: String
        do {
            promptID = try await submit(graph, promptID: minted)
        } catch {
            if !Self.mightHaveLanded(error) || Task.isCancelled { ForgeStore.clearPending(minted) }
            if Task.isCancelled { retract(minted) }
            return end(&job, error, continuation)
        }
        var taken = intent
        taken.confirmed = true
        ForgeStore.remember(
            pending: ForgePending(
                promptID: promptID, clientID: clientID, endpoint: endpoint, recipe: recipe,
                startedAt: taken.startedAt, nodes: taken.nodes, confirmed: true))
        job.accepted(promptID: promptID, nodes: graph.nodes.count)
        continuation.yield(job)

        await follow(&job, promptID: promptID, socket: socket, held: held, into: continuation)
    }

    /// Picks a render back up: the same job, the same socket id, the clock the person's wait
    /// actually started on. The machine is asked where the job stands before anything is promised,
    /// because the render may have finished, failed or been forgotten while nobody was looking.
    private func reattach(
        _ pending: ForgePending, first: ForgeStanding?, expecting: TimeInterval?,
        into continuation: AsyncStream<ForgeJob>.Continuation, held: HeldSocket
    ) async {
        var job = ForgeJob(recipe: pending.recipe, expected: expecting)
        job.submitting(at: pending.startedAt)
        job.announce(pending.promptID)
        job.recovered()
        continuation.yield(job)
        let promptID = pending.promptID

        switch first {
        case .finished(let asset)?:
            job.delivered(asset)
            continuation.yield(job)
            continuation.finish()
        case .failed(let reason)?:
            ForgeStore.clearPending(promptID)
            job.failed(reason)
            continuation.yield(job)
            continuation.finish()
        case .stopped?:
            ForgeStore.clearPending(promptID)
            job.cancelled()
            continuation.yield(job)
            continuation.finish()
        case .unknown?:
            ForgeStore.clearPending(promptID)
            job.failed(ForgeFailure.forgotten(endpoint.host).description)
            continuation.yield(job)
            continuation.finish()
        case .running?, .waiting?:
            if case .waiting(let ahead)? = first {
                job.accepted(promptID: promptID, queued: ahead, nodes: pending.nodes, at: pending.startedAt)
            } else {
                job.accepted(promptID: promptID, nodes: pending.nodes, at: pending.startedAt)
                job.saw(.started(promptID))
            }
            continuation.yield(job)
            guard let url = endpoint.socketURL(clientID: pending.clientID) else {
                return await conclude(&job, promptID: promptID, lost: true, into: continuation)
            }
            let socket = URLSession.shared.webSocketTask(with: url)
            held.hold(socket)
            socket.resume()
            defer { held.close() }
            await follow(&job, promptID: promptID, socket: socket, held: held, into: continuation)
        case nil:
            await conclude(&job, promptID: promptID, lost: true, into: continuation)
        }
    }

    /// Listens to a render's socket until it says the job is over, then settles how it ended.
    /// A watchdog asks the machine where the job stands while the socket is quiet and closes the
    /// socket when the answer is "over", because a socket can go silent without ever failing — and
    /// a client that trusts it alone waits for a frame that already went by.
    private func follow(
        _ job: inout ForgeJob, promptID: String, socket: URLSessionWebSocketTask,
        held: HeldSocket, into continuation: AsyncStream<ForgeJob>.Continuation
    ) async {
        let watchdog = Task { await watch(promptID, held: held) }
        var lost = false
        var sketches = ImageGenPreviewAssembler()
        listening: while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                lost = true
                break listening
            }
            let event: ForgeEvent
            switch message {
            case .string(let text):
                event = ForgeEvent.read(text)
            case .data(let chunk):
                guard let frame = sketches.feed(chunk) else { continue }
                event = .sketched(frame)
            @unknown default:
                continue
            }
            if let id = event.promptID, !id.isEmpty, id != promptID { continue }
            job.saw(event)
            continuation.yield(job)
            switch event {
            case .failed, .interrupted:
                watchdog.cancel()
                ForgeStore.clearPending(promptID)
                continuation.finish()
                return
            case .finished, .succeeded:
                break listening
            default:
                continue
            }
        }
        watchdog.cancel()
        await conclude(&job, promptID: promptID, lost: lost, into: continuation)
    }

    /// The end of a render: cancelled, delivered, or failed in a sentence — and the one place the
    /// pending record is let go of for any of the ways a render is over for good. A delivered clip
    /// leaves it standing on purpose: filing the clip is what settles it, so a quit between the
    /// last frame and the filing still finds the clip next time.
    private func conclude(
        _ job: inout ForgeJob, promptID: String, lost: Bool,
        into continuation: AsyncStream<ForgeJob>.Continuation
    ) async {
        if Task.isCancelled {
            ForgeStore.clearPending(promptID)
            job.cancelled()
            continuation.yield(job)
            continuation.finish()
            retract(promptID)
            return
        }
        do {
            let asset = try await (lost ? salvage(promptID) : gather(promptID))
            guard let asset else {
                ForgeStore.clearPending(promptID)
                return end(&job, ForgeFailure.noOutput(endpoint.host), continuation)
            }
            job.delivered(asset)
            continuation.yield(job)
            continuation.finish()
        } catch is CancellationError {
            ForgeStore.clearPending(promptID)
            job.cancelled()
            continuation.yield(job)
            continuation.finish()
        } catch {
            if (error as? ForgeFailure).map({ Self.isFinal($0) }) ?? true {
                ForgeStore.clearPending(promptID)
            }
            end(&job, error, continuation)
        }
    }

    /// Asks the machine, off the render's own task, to drop a job this render was stopped for. The
    /// render's task is already cancelled by then and a request made from it would be too.
    private func retract(_ promptID: String) {
        let client = self
        Task.detached { await client.cancel(promptID) }
    }

    /// A post that failed to be answered may still have landed, and the render is then on the
    /// machine with nobody to follow it. Only that kind of failure leaves the job on file.
    private static func mightHaveLanded(_ error: Error) -> Bool {
        guard let failure = error as? ForgeFailure else { return true }
        if case .unreachable = failure { return true }
        return false
    }

    /// Whether a failure means the job is over for good. Losing contact does not: the render goes
    /// on, and the next look may find the clip.
    private static func isFinal(_ failure: ForgeFailure) -> Bool {
        if case .disconnected = failure { return false }
        return true
    }

    private func watch(_ promptID: String, held: HeldSocket) async {
        var absent = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.watchInterval)
            guard !Task.isCancelled, let standing = try? await standing(of: promptID) else { continue }
            switch standing {
            case .running, .waiting:
                absent = 0
            case .unknown:
                absent += 1
                if absent >= 2 { return held.close() }
            case .finished, .failed, .stopped:
                return held.close()
            }
        }
    }

    /// The file, asked for until the machine says how the job ended. History is written a moment
    /// after the last frame goes out, so the first ask genuinely misses on a fast clip — and one
    /// that cannot be reached for a breath is asked again rather than turned into a failure.
    private func gather(_ promptID: String) async throws -> ForgeAsset? {
        for attempt in 0..<Self.collectAttempts {
            if attempt > 0 { try? await Task.sleep(for: Self.collectInterval) }
            guard let standing = try? await standing(of: promptID) else { continue }
            switch standing {
            case .finished(let asset): return asset
            case .failed(let reason): throw ForgeFailure.renderFailed(endpoint.host, reason)
            case .stopped: throw CancellationError()
            case .running, .waiting, .unknown: continue
            }
        }
        return nil
    }

    /// What happens when contact is lost while the card is still working. The render does not care
    /// that this app stopped watching, so the job is followed by asking the machine instead — a
    /// phone that locked its screen mid-render still gets its clip. The patience is for the
    /// machine's silence, not for the render: a job the machine says is still running or queued
    /// is waited for as long as it takes, and only a machine that stops answering, or one that
    /// has no record of the job, ends the wait.
    private func salvage(_ promptID: String) async throws -> ForgeAsset? {
        var lastAnswer = Date()
        var absent = 0
        while !Task.isCancelled {
            do {
                switch try await standing(of: promptID) {
                case .finished(let asset):
                    return asset
                case .failed(let reason):
                    throw ForgeFailure.renderFailed(endpoint.host, reason)
                case .stopped:
                    throw CancellationError()
                case .running, .waiting:
                    lastAnswer = Date()
                    absent = 0
                case .unknown:
                    lastAnswer = Date()
                    absent += 1
                    if absent >= 3 { throw ForgeFailure.forgotten(endpoint.host) }
                }
            } catch let failure as ForgeFailure {
                guard case .unreachable = failure else { throw failure }
                if Date().timeIntervalSince(lastAnswer) > Self.salvageDeadline {
                    throw ForgeFailure.disconnected(endpoint.host)
                }
            }
            try? await Task.sleep(for: Self.salvageInterval)
        }
        throw CancellationError()
    }

    /// Every way out of a render is one sentence and one terminal snapshot. A foreign error never
    /// reaches a client: it is named here or it is the machine not answering.
    private func end(
        _ job: inout ForgeJob, _ error: Error, _ continuation: AsyncStream<ForgeJob>.Continuation
    ) {
        if Task.isCancelled || error is CancellationError {
            job.cancelled()
        } else {
            job.failed(Self.reason(error, host: endpoint.host))
        }
        continuation.yield(job)
        continuation.finish()
    }

    public static func reason(_ error: Error, host: String) -> String {
        if let failure = error as? ForgeFailure { return failure.description }
        return ForgeFailure.unreachable(host).description
    }

    static func reason(in status: [String: Any]) -> String {
        let messages = status["messages"] as? [Any] ?? []
        for message in messages {
            guard let pair = message as? [Any], pair.count >= 2 else { continue }
            guard let payload = pair[1] as? [String: Any] else { continue }
            if let text = payload["exception_message"] as? String, !text.isEmpty { return text }
        }
        return Localized.text("The render failed and said nothing about why")
    }
}

/// Where a job stands on the machine that was asked to make it. The machine files a finished job
/// in its history the instant it ends, and until then the job is either the one running or one
/// of those waiting, so these six are every answer there is.
public enum ForgeStanding: Sendable, Equatable {
    case finished(ForgeAsset)
    case failed(String)
    /// Interrupted or taken out of the queue, by this device or another.
    case stopped
    case running
    /// How many jobs are in front of it, the running one included.
    case waiting(ahead: Int)
    /// In neither the history nor the queue: never heard of, or forgotten by a restart.
    case unknown

    /// A history entry read as an ending. Public because the shape is the server's — an interrupted
    /// job is filed as an error with an interruption message beside it, and the difference
    /// between a clip somebody stopped and one that broke is exactly what a client should pin.
    public static func ending(of entry: [String: Any], host: String) -> ForgeStanding {
        if let status = entry["status"] as? [String: Any],
            status["status_str"] as? String == "error"
        {
            return interrupted(status)
                ? .stopped : .failed(ForgeClient.reason(in: status))
        }
        if let outputs = entry["outputs"], let asset = ForgeAsset.read(outputs: outputs) {
            return .finished(asset)
        }
        return .failed(ForgeFailure.noOutput(host).description)
    }

    /// A job's place in the queue the machine reported. The pending list is a heap in the
    /// server, not a sorted list, so it is put in order before anybody is counted ahead.
    public static func place(of promptID: String, in queue: [String: Any]) -> ForgeStanding {
        func identity(_ item: Any) -> String? {
            guard let fields = item as? [Any], fields.count > 1 else { return nil }
            return fields[1] as? String
        }
        func number(_ item: Any) -> Double {
            guard let first = (item as? [Any])?.first else { return 0 }
            if let value = first as? Double { return value }
            if let value = first as? Int { return Double(value) }
            return (first as? NSNumber)?.doubleValue ?? 0
        }
        let running = queue["queue_running"] as? [Any] ?? []
        if running.contains(where: { identity($0) == promptID }) { return .running }
        let pending = (queue["queue_pending"] as? [Any] ?? []).sorted { number($0) < number($1) }
        if let index = pending.firstIndex(where: { identity($0) == promptID }) {
            return .waiting(ahead: running.count + index)
        }
        return .unknown
    }

    private static func interrupted(_ status: [String: Any]) -> Bool {
        let messages = status["messages"] as? [Any] ?? []
        return messages.contains { message in
            (message as? [Any])?.first as? String == "execution_interrupted"
        }
    }
}

/// The render's websocket, held where a cancellation handler can reach it.
///
/// `URLSessionWebSocketTask.receive()` is the completion-handler form bridged into async, and it
/// installs no cancellation handler of its own: cancelling the task that awaits it only sets a
/// flag, and the await stays parked until a frame happens to arrive. A render stopped while the
/// server has gone quiet would therefore never tear its socket down and never reach the cancelled
/// snapshot the screen is waiting for. Closing the socket from outside is what makes `receive()`
/// return, so the socket has to outlive the scope that created it.
final class HeldSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?

    func hold(_ task: URLSessionWebSocketTask) {
        lock.lock()
        defer { lock.unlock() }
        socket = task
    }

    func close() {
        lock.lock()
        let task = socket
        socket = nil
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
    }
}
