import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Fetches page metadata and icon bytes for link cards, deduplicated and cached.
///
/// This is the one place an address's face is asked for, so a row re-rendered on every streamed
/// arrival — or scrolled away and back — costs one request per address, not one per appearance.
/// It vends bytes and values only; turning an icon into a picture stays with each client's own
/// toolkit. The debounce that keeps an address still being streamed from firing a request at all
/// is ``LinkEmbedPolicy/settle(debounce:isWanted:)``, which every client runs before it asks.
public actor LinkPreviewFetcher {
    public static let shared = LinkPreviewFetcher()

    public static let bodyLimit = 256 * 1024
    public static let imageLimit = 1024 * 1024
    static let cacheLimit = 512
    static let imageCacheLimit = 64

    private let downloader: BoundedDownloader
    private let failureMemory: TimeInterval
    private let now: @Sendable () -> Date
    private let reach: @Sendable (URL) -> Bool

    private enum Verdict {
        case page(LinkPreviewMetadata?)
        case failed(Date)
    }

    private var metadataCache: [String: Verdict] = [:]
    private var metadataOrder: [String] = []
    private var iconCache: [String: Data] = [:]
    private var iconOrder: [String] = []
    private var failedIcons: [String: Date] = [:]
    private var inflightMetadata: [String: Task<Verdict, Never>] = [:]
    private var inflightIcons: [String: Task<Data?, Never>] = [:]
    private var requests = 0

    /// - Parameter configuration: how the session reaches the network; tests hand one whose
    ///   `protocolClasses` serve pages from memory.
    /// - Parameter failureMemory: how long a fetch that could not be made is remembered as a
    ///   failure before it is tried again. A page that loaded but declares nothing is remembered
    ///   for the life of the process, since asking again would only get the same answer.
    /// - Parameter reach: which addresses may be asked at all — the public web (``LinkReach``),
    ///   which also decides whether a redirect is followed. Tests that serve pages from memory
    ///   under made-up names hand one that allows them.
    public init(
        configuration: URLSessionConfiguration = LinkPreviewFetcher.defaultConfiguration(),
        failureMemory: TimeInterval = 600,
        reach: @escaping @Sendable (URL) -> Bool = LinkReach.allows,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.downloader = BoundedDownloader(configuration: configuration, reach: reach)
        self.failureMemory = failureMemory
        self.reach = reach
        self.now = now
    }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        return configuration
    }

    /// How many requests have gone out, for the tests that prove a repeated ask costs one.
    public var requestCount: Int { requests }

    private nonisolated let faces = FaceMemory()

    /// The face an address already earned, read without waiting for anything. A card built again —
    /// a chat opened for the second time, a row rebuilt after a setting changed — paints this at
    /// once instead of standing as a placeholder through the whole debounce for an answer the
    /// process already holds.
    public nonisolated func cachedFace(for urlString: String) -> LinkCardFace? {
        faces.face(for: urlString)
    }

    /// The page's title and icon address — nil when the page cannot be read at all, or declares
    /// neither, and in both cases nobody is asked to fetch it again soon.
    public func metadata(for urlString: String) async -> LinkPreviewMetadata? {
        guard let url = Self.webURL(urlString), reach(url) else { return nil }
        if let cached = metadataCache[urlString] {
            switch cached {
            case .page(let metadata): return metadata
            case .failed(let at) where now().timeIntervalSince(at) < failureMemory: return nil
            case .failed: metadataCache[urlString] = nil
            }
        }
        if let task = inflightMetadata[urlString] {
            return Self.metadata(of: await task.value)
        }
        requests += 1
        let downloader = downloader
        let stamp = now()
        let task = Task<Verdict, Never> {
            let fetched = await downloader.fetch(
                url, limit: Self.bodyLimit, overflow: .truncate,
                accepts: { Self.isHTML($0.mimeType ?? "") })
            guard let fetched else { return .failed(stamp) }
            let charset = LinkPreviewParser.charset(ofContentType: fetched.contentType)
            return .page(
                LinkPreviewParser.parse(
                    fetched.data, finalURL: fetched.finalURL ?? url, charset: charset))
        }
        inflightMetadata[urlString] = task
        let verdict = await task.value
        inflightMetadata[urlString] = nil
        remember(verdict, for: urlString)
        return Self.metadata(of: verdict)
    }

    /// The bytes of the page's icon. A page without a declared icon gets its root `/favicon.ico` as
    /// the one guess; a failure is remembered so a card scrolled back over does not retry it.
    public func faviconData(for urlString: String) async -> Data? {
        if let cached = iconCache[urlString] {
            touchIcon(urlString)
            return cached
        }
        if let failed = failedIcons[urlString] {
            if now().timeIntervalSince(failed) < failureMemory { return nil }
            failedIcons[urlString] = nil
        }
        guard let metadata = await metadata(for: urlString),
            let iconURL = metadata.faviconURL ?? Self.defaultFavicon(for: urlString),
            Self.isWeb(iconURL), reach(iconURL)
        else { return nil }
        if let task = inflightIcons[urlString] { return await task.value }
        requests += 1
        let downloader = downloader
        let task = Task<Data?, Never> {
            let fetched = await downloader.fetch(
                iconURL, limit: Self.imageLimit, overflow: .fail,
                accepts: { Self.isImage($0.mimeType ?? "") })
            return fetched?.data
        }
        inflightIcons[urlString] = task
        let result = await task.value
        inflightIcons[urlString] = nil
        if let result, !result.isEmpty {
            keep(icon: result, for: urlString)
            return result
        }
        if failedIcons.count >= Self.cacheLimit { failedIcons.removeAll(keepingCapacity: true) }
        failedIcons[urlString] = now()
        return nil
    }

    private func remember(_ verdict: Verdict, for key: String) {
        if metadataCache[key] == nil { metadataOrder.append(key) }
        metadataCache[key] = verdict
        if let url = URL(string: key) {
            faces.remember(.settled(for: url, metadata: Self.metadata(of: verdict)), for: key)
        }
        while metadataOrder.count > Self.cacheLimit {
            metadataCache[metadataOrder.removeFirst()] = nil
        }
    }

    private func keep(icon: Data, for key: String) {
        if iconCache[key] == nil { iconOrder.append(key) }
        iconCache[key] = icon
        while iconOrder.count > Self.imageCacheLimit {
            iconCache[iconOrder.removeFirst()] = nil
        }
    }

    private func touchIcon(_ key: String) {
        guard let index = iconOrder.firstIndex(of: key) else { return }
        iconOrder.remove(at: index)
        iconOrder.append(key)
    }

    private static func metadata(of verdict: Verdict) -> LinkPreviewMetadata? {
        if case .page(let metadata) = verdict { return metadata }
        return nil
    }

    static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), isWeb(url), url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func isHTML(_ type: String) -> Bool {
        let lower = type.lowercased()
        return lower.hasPrefix("text/") || lower.contains("html") || lower.contains("xml")
    }

    static func isImage(_ type: String) -> Bool {
        type.lowercased().hasPrefix("image/")
    }

    static func defaultFavicon(for urlString: String) -> URL? {
        guard let url = URL(string: urlString), let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = host
        components.port = url.port
        components.path = "/favicon.ico"
        return components.url
    }
}

/// The faces addresses have already earned, readable from any thread without waiting on the
/// fetcher.
private final class FaceMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var faces: [String: LinkCardFace] = [:]
    private var order: [String] = []

    func face(for key: String) -> LinkCardFace? {
        lock.lock()
        defer { lock.unlock() }
        return faces[key]
    }

    func remember(_ face: LinkCardFace, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if faces[key] == nil { order.append(key) }
        faces[key] = face
        while order.count > LinkPreviewFetcher.cacheLimit {
            faces[order.removeFirst()] = nil
        }
    }
}

/// A size-bounded GET. `URLSession.bytes(for:)` does not exist on Linux, and `data(for:)` would
/// download a whole page to look at its first quarter-megabyte, so the body is read through the
/// session delegate and the task is cancelled the moment the limit is passed.
///
/// The delegate also answers every authentication challenge by declining it: a page that wants a
/// password has no card to give, and on Linux an unanswered Basic challenge never returns at all.
final class BoundedDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Overflow: Sendable {
        case truncate
        case fail
    }

    struct Fetched: Sendable {
        let data: Data
        let finalURL: URL?
        let contentType: String?
    }

    private struct Job {
        var data = Data()
        var response: HTTPURLResponse?
        var rejected = false
        var overflowed = false
        let limit: Int
        let overflow: Overflow
        let accepts: @Sendable (HTTPURLResponse) -> Bool
        let finish: (Fetched?) -> Void
    }

    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private var session: URLSession!
    private let reach: @Sendable (URL) -> Bool

    init(configuration: URLSessionConfiguration, reach: @escaping @Sendable (URL) -> Bool) {
        self.reach = reach
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func fetch(
        _ url: URL, limit: Int, overflow: Overflow,
        accepts: @escaping @Sendable (HTTPURLResponse) -> Bool
    ) async -> Fetched? {
        var request = URLRequest(url: url)
        request.setValue("Tailscode link preview", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                jobs[task.taskIdentifier] = Job(
                    limit: limit, overflow: overflow, accepts: accepts,
                    finish: { continuation.resume(returning: $0) })
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard var job = jobs[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, job.accepts(http)
        else {
            job.rejected = true
            jobs[dataTask.taskIdentifier] = job
            completionHandler(.cancel)
            return
        }
        job.response = http
        jobs[dataTask.taskIdentifier] = job
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var job = jobs[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        let room = job.limit - job.data.count
        var cancel = false
        if data.count > room {
            job.overflowed = true
            if job.overflow == .truncate, room > 0 { job.data.append(data.prefix(room)) }
            cancel = true
        } else {
            job.data.append(data)
        }
        jobs[dataTask.taskIdentifier] = job
        lock.unlock()
        if cancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let job = jobs.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let job else { return }
        guard let response = job.response, !job.rejected else {
            job.finish(nil)
            return
        }
        let cutOnPurpose = job.overflowed && job.overflow == .truncate
        guard error == nil || cutOnPurpose, !(job.overflowed && job.overflow == .fail) else {
            job.finish(nil)
            return
        }
        job.finish(
            Fetched(
                data: job.data, finalURL: response.url,
                contentType: response.value(forHTTPHeaderField: "Content-Type")))
    }

    /// A public page may send the request on to somewhere private; the redirect is followed only
    /// while it stays on the public web.
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(reach) == true ? request : nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        Self.answer(challenge, completionHandler)
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        Self.answer(challenge, completionHandler)
    }

    /// A transport check (the certificate) is the system's to make; a request for somebody's
    /// credentials is declined, because a card has no password to offer.
    private static func answer(
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == "NSURLAuthenticationMethodServerTrust" {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
