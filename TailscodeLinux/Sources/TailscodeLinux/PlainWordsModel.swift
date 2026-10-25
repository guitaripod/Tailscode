import Foundation
import TailscodeCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The two requests a model on this machine or this network is ever sent, behind a seam so a check
/// can answer them without a network.
protocol PlainWordsTransport: Sendable {
    func get(_ url: URL) async throws -> Data
    func post(_ url: URL, body: Data) async throws -> Data
}

enum PlainWordsError: Error {
    case refused
    case notAnswered
    case timedOut
    case noModel
}

/// Refuses every redirect, so an address that was vetted as private is never sent somewhere else.
private final class PlainWordsRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// An ephemeral session that keeps no cookies, no credentials and no cache, and follows no redirect.
final class PlainWordsURLTransport: PlainWordsTransport, @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = PlainWordsModel.timeout
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: PlainWordsRedirects(), delegateQueue: nil)
    }

    func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: PlainWordsModel.timeout)
        request.httpMethod = "GET"
        return try await run(request)
    }

    func post(_ url: URL, body: Data) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: PlainWordsModel.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await run(request)
    }

    private func run(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw PlainWordsError.notAnswered
        }
        return data
    }
}

/// The opt-in way an unusual command gets better words on the Linux wall: a model the person runs
/// themselves, on this machine or their own network, says it in one line. It is asked for a raw
/// command only when Core marked the tile as one no rule could read, one request at a time, a few
/// waiting at most; what it says is kept in memory only, vetted by `PlainModel.reply` before it is
/// shown, and never kept across a restart. It is built only while the setting is on and the wall is
/// open, and nothing here logs a command, only counts and outcomes.
final class PlainWordsModel: @unchecked Sendable {
    static let timeout: TimeInterval = 8
    static let retryAfter: TimeInterval = 60
    static let cacheLimit = 256
    static let queueLimit = 6
    static let marker = " ✦"

    private let endpoint: URL
    private let transport: any PlainWordsTransport
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var model: String
    private var answers: [String: String] = [:]
    private var order: [String] = []
    private var failedAt: [String: Date] = [:]
    private var queue: [String] = []
    private var busy = false
    private var inFlight: String?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var _requests = 0

    /// Called on the GTK main thread whenever a line lands, so the wall can show it.
    var onReady: @Sendable () -> Void = {}

    init(
        endpoint: URL, model: String, transport: any PlainWordsTransport = PlainWordsURLTransport(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
        self.clock = clock
    }

    /// The model for what the person typed, or nil when the address is not on this machine or
    /// their network, which is the same as the setting being off.
    static func make(
        address: String, model: String, transport: any PlainWordsTransport = PlainWordsURLTransport(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> PlainWordsModel? {
        guard let endpoint = PlainModel.endpoint(address) else { return nil }
        return PlainWordsModel(endpoint: endpoint, model: model, transport: transport, clock: clock)
    }

    /// How many chat requests have been sent, for a check.
    var requests: Int { lock.withLock { _requests } }

    func said(for raw: String) -> String? {
        lock.withLock { answers[raw] }
    }

    func ask(_ raw: String) {
        let due = lock.withLock { () -> Bool in
            if answers[raw] != nil || queue.contains(raw) || inFlight == raw { return false }
            if let failed = failedAt[raw], clock().timeIntervalSince(failed) < Self.retryAfter { return false }
            queue.append(raw)
            if queue.count > Self.queueLimit { queue.removeFirst(queue.count - Self.queueLimit) }
            return true
        }
        if due { pump() }
    }

    /// Ends whatever is in flight and forgets what was waiting, so nothing runs while the wall is
    /// closed or the setting is off. What was already said stays, and the model can be asked again.
    func halt() {
        let running = lock.withLock { () -> Task<Void, Never>? in
            generation += 1
            queue.removeAll()
            busy = false
            inFlight = nil
            defer { task = nil }
            return task
        }
        running?.cancel()
    }

    private func pump() {
        let work = lock.withLock { () -> (String, Int, String)? in
            guard !busy, !queue.isEmpty else { return nil }
            busy = true
            let next = queue.removeFirst()
            inFlight = next
            return (next, generation, model)
        }
        guard let (raw, mine, named) = work else { return }
        let running = Task { [self] in
            let outcome: Result<String, Error>
            do {
                outcome = .success(try await converse(raw: raw, model: named, generation: mine))
            } catch {
                outcome = .failure(error)
            }
            Gtk.onMain { [self] in finish(raw, outcome, generation: mine) }
        }
        let current = lock.withLock { () -> Bool in
            guard generation == mine else { return false }
            task = running
            return true
        }
        if !current { running.cancel() }
    }

    private func converse(raw: String, model named: String, generation mine: Int) async throws -> String {
        guard let vetted = PlainModel.endpoint(endpoint.absoluteString) else { throw PlainWordsError.refused }
        var name = named
        if name.isEmpty {
            name = try await Self.firstModel(at: vetted, transport: transport)
            lock.withLock { if generation == mine { model = name } }
        }
        let url = vetted.appendingPathComponent("chat").appendingPathComponent("completions")
        lock.withLock { _requests += 1 }
        let body = PlainModel.request(model: name, raw: raw)
        let transport = transport
        let data = try await Self.bounded { try await transport.post(url, body: body) }
        guard let line = PlainModel.reply(from: data) else { throw PlainWordsError.notAnswered }
        return line
    }

    private func finish(_ raw: String, _ outcome: Result<String, Error>, generation mine: Int) {
        let landed = lock.withLock { () -> Bool? in
            guard generation == mine else { return nil }
            busy = false
            inFlight = nil
            task = nil
            switch outcome {
            case .success(let line):
                answers[raw] = line
                order.removeAll { $0 == raw }
                order.append(raw)
                while order.count > Self.cacheLimit { answers[order.removeFirst()] = nil }
                failedAt[raw] = nil
                return true
            case .failure:
                failedAt[raw] = clock()
                if failedAt.count > Self.cacheLimit, let oldest = failedAt.min(by: { $0.value < $1.value })?.key {
                    failedAt[oldest] = nil
                }
                return false
            }
        }
        guard let landed else { return }
        AppLog.write(.connection, landed ? "plain words: a line was written" : "plain words: no line this time")
        if landed { onReady() }
        pump()
    }

    private static func firstModel(at endpoint: URL, transport: any PlainWordsTransport) async throws -> String {
        let url = endpoint.appendingPathComponent("models")
        let data = try await bounded { try await transport.get(url) }
        guard let first = ids(from: data).first else { throw PlainWordsError.noModel }
        return first
    }

    /// The model names a server lists, for the Check button and for the default.
    static func ids(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = object["data"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
    }

    /// Asks the server at `endpoint` what it serves; never sends a command.
    static func check(
        endpoint: URL, transport: any PlainWordsTransport = PlainWordsURLTransport()
    ) async -> Result<[String], Error> {
        guard let vetted = PlainModel.endpoint(endpoint.absoluteString) else { return .failure(PlainWordsError.refused) }
        let url = vetted.appendingPathComponent("models")
        do {
            let data = try await bounded { try await transport.get(url) }
            return .success(ids(from: data))
        } catch {
            return .failure(error)
        }
    }

    private static func bounded(_ work: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw PlainWordsError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PlainWordsError.timedOut }
            return first
        }
    }
}
