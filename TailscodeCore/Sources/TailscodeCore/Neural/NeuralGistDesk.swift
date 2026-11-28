import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The one request a telling makes, behind a seam so a check answers it without a network.
public protocol NeuralGistTransport: Sendable {
    func post(_ url: URL, body: Data) async throws -> Data
}

/// An ephemeral session that keeps no cookies, no credentials and no cache and follows no
/// redirect, so an address that was vetted as the person's own is never sent somewhere else.
public final class NeuralGistURLTransport: NSObject, NeuralGistTransport, URLSessionTaskDelegate, @unchecked Sendable {
    public static let timeout: TimeInterval = 90
    private var session: URLSession!

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    #if canImport(FoundationNetworking)
        public func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    #else
        public func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    #endif

    public func post(_ url: URL, body: Data) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// Who tells turns in short, and when. One desk for the app: a client says which turn it is
/// showing (`want`), reads what is held for it (`reading`), and draws again when `didChange` is
/// posted. Nothing here is on a main thread and nothing waits on one.
///
/// It asks only the model the person filed as theirs, only at an address on this device or their
/// own network, only while the switch is on, and never a model its server would have to load:
/// whether the model is in memory is read from the server first and believed for five minutes.
/// One request is out at a time across every turn, the turn asked for last goes first, and a turn
/// is told again no sooner than `NeuralGistPolicy` allows, so a slow model sets its own pace.
/// What was told is kept in memory for the turns last shown and never written to disk.
public final class NeuralGistDesk: @unchecked Sendable {
    public static let shared = NeuralGistDesk()
    public static let didChange = Notification.Name("tailscode.neuralGist.didChange")
    public static let heldTurns = 48
    /// How long after a surface last showed a turn its telling may still be asked for.
    public static let fresh: TimeInterval = 120

    public enum Phase: Sendable, Equatable {
        /// Nothing is told: the switch is off, no model is filed, the turn is short, or the model
        /// is not in memory. A surface shows what it showed before there was a telling.
        case none
        /// The first telling is being written.
        case writing
        /// A telling is held; `refreshing` says whether a newer one is being written.
        case told
    }

    public struct Reading: Sendable, Equatable {
        public let phase: Phase
        public let gist: NeuralGist?
        public let writer: String
        public let place: String
        public let refreshing: Bool

        public static let none = Reading(phase: .none, gist: nil, writer: "", place: "", refreshing: false)
    }

    /// A turn as a surface last showed it. The model is held only while a telling of it is still
    /// owed, because a model holds every step of its turn and every line its tools printed:
    /// once the turn is told as it stands, or nobody has shown it for `fresh` seconds, it goes,
    /// and what is left of a turn here is its telling.
    private struct Wanted {
        var model: NeuralBrainModel?
        var answer: String?
        var prompt: String?
        var stepCount: Int
        var running: Bool
        var at: Date
    }

    private struct Entry {
        var wanted: Wanted
        var gist: NeuralGist?
        var inFlight = false
        var asking = false
        /// The telling was put here and no model is asked for another.
        var placed = false
        var failed = false
        var lastAt: Date?
        var lastTook: TimeInterval?
        var wake: Task<Void, Never>?
    }

    private let lock = NSLock()
    private let transport: any NeuralGistTransport
    private let clock: @Sendable () -> Date
    private let helper: @Sendable () -> ImageGenHelper?
    private let isOn: @Sendable () -> Bool
    private let isReady: @Sendable (ImageGenHelper) async -> Bool
    private var entries: [String: Entry] = [:]
    private var busy = false
    private var readiness: (key: String, ready: Bool, at: Date)?
    private var sent = 0
    private var writerMemo: ImageGenHelper??
    private var pinned: ImageGenHelper?
    private var muted = false
    private var settingsObserver: NSObjectProtocol?

    public init(
        transport: any NeuralGistTransport = NeuralGistURLTransport(),
        clock: @escaping @Sendable () -> Date = { Date() },
        helper: @escaping @Sendable () -> ImageGenHelper? = { YourModelStore.current() },
        isOn: @escaping @Sendable () -> Bool = { NeuralGistSetting.isOn },
        isReady: @escaping @Sendable (ImageGenHelper) async -> Bool = NeuralGistDesk.inMemory
    ) {
        self.transport = transport
        self.clock = clock
        self.helper = helper
        self.isOn = isOn
        self.isReady = isReady
        settingsObserver = NotificationCenter.default.addObserver(
            forName: NeuralGistSetting.didChange, object: nil, queue: nil
        ) { [weak self] _ in self?.settingsChanged() }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    /// How many tellings were asked for, for a check.
    public var requests: Int { lock.withLock { sent } }

    /// The model that would write, when one may: filed, on the person's own network, and the
    /// switch on.
    /// No model is asked and the demo's telling is not set: a check or a bench is running, which
    /// must read the same on every machine. A telling placed by hand still shows.
    public var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }

    /// Names the writer for this launch whatever the device has filed: a debug launch on a phone
    /// whose own settings must not be written to. Nil gives the choice back to the settings.
    public func pinWriter(_ helper: ImageGenHelper?) {
        lock.withLock {
            pinned = helper
            writerMemo = nil
        }
        forgetAll()
    }

    public var writer: ImageGenHelper? {
        if isMuted { return nil }
        if let pinned = lock.withLock({ pinned }) { return YourModelStore.isPrivate(pinned) ? pinned : nil }
        if let held = lock.withLock({ writerMemo }) { return held }
        var found: ImageGenHelper?
        if isOn(), let helper = helper(), YourModelStore.isPrivate(helper) { found = helper }
        lock.withLock { writerMemo = .some(found) }
        return found
    }

    /// The model or the switch may have changed: the next look reads them again. A telling by a
    /// model that is no longer the person's is dropped with it.
    public func settingsChanged() {
        let before = lock.withLock { () -> ImageGenHelper?? in
            defer { writerMemo = nil }
            return writerMemo
        }
        let after = writer
        guard let before, before != after else { return }
        forgetAll()
    }

    public func reading(for key: String) -> Reading {
        let placed = lock.withLock { () -> NeuralGist? in
            guard let entry = entries[key], entry.placed else { return nil }
            return entry.gist
        }
        if let placed {
            return Reading(phase: .told, gist: placed, writer: placed.writer, place: placed.place, refreshing: false)
        }
        guard let helper = writer else { return .none }
        let name = helper.label ?? helper.model
        let place = YourModelWords.inSentence(YourModelWords.machine(of: helper))
        return lock.withLock {
            guard let entry = entries[key] else { return .none }
            if let gist = entry.gist {
                return Reading(phase: .told, gist: gist, writer: gist.writer, place: gist.place, refreshing: entry.inFlight)
            }
            guard entry.asking else { return .none }
            return Reading(phase: .writing, gist: nil, writer: name, place: place, refreshing: true)
        }
    }

    /// A surface is showing this turn and would show it told in short. Cheap enough to call each
    /// time the turn changes: it notes the turn as it stands and asks the model only when the
    /// policy says a telling is due.
    public func want(key: String, model: NeuralBrainModel, answer: String? = nil, prompt: String? = nil) {
        let stepCount = model.steps.count
        let now = clock()
        guard NeuralGistPolicy.worthTelling(stepCount: stepCount) else {
            lock.withLock { shed(now) }
            return
        }
        let running = model.turn.outcome == .running
        let state = lock.withLock { () -> (told: Bool, placed: Bool) in
            shed(now)
            guard let entry = entries[key] else { return (false, false) }
            entries[key]?.wanted.at = now
            let told = entry.gist.map { $0.stepCount == stepCount && $0.running == running } ?? false
            return (told, entry.placed)
        }
        if state.placed || state.told { return }
        guard writer != nil else { return }
        let wanted = Wanted(
            model: model, answer: answer, prompt: prompt, stepCount: stepCount, running: running, at: now)
        lock.withLock {
            if entries[key] == nil {
                entries[key] = Entry(wanted: wanted)
                evict()
            } else {
                entries[key]?.wanted = wanted
                if let told = entries[key]?.gist, told.stepCount > stepCount {
                    entries[key]?.gist = nil
                    entries[key]?.failed = false
                    entries[key]?.lastAt = nil
                }
            }
        }
        consider(key)
    }

    /// Puts a telling in that no model here wrote: the demo world's, where no server answers, and
    /// a check's, which must read the same on every run. It is shown as it is and never told again.
    public func place(_ gist: NeuralGist, for key: String, model: NeuralBrainModel) {
        let wanted = Wanted(
            model: nil, answer: nil, prompt: nil, stepCount: model.steps.count,
            running: model.turn.outcome == .running, at: clock())
        lock.withLock {
            entries[key]?.wake?.cancel()
            var entry = Entry(wanted: wanted)
            entry.gist = gist
            entry.placed = true
            entries[key] = entry
            evict()
        }
        StoreNotice.post(Self.didChange)
    }

    /// Takes one turn's telling away, placed or written.
    public func forget(_ key: String) {
        let wake = lock.withLock { entries.removeValue(forKey: key)?.wake }
        wake?.cancel()
        StoreNotice.post(Self.didChange)
    }

    /// Forgets everything told, so the next look asks again: the model or the switch changed.
    public func forgetAll() {
        let wakes = lock.withLock { () -> [Task<Void, Never>] in
            let held = entries.values.compactMap(\.wake)
            entries.removeAll()
            readiness = nil
            return held
        }
        for wake in wakes { wake.cancel() }
        StoreNotice.post(Self.didChange)
    }

    /// Whether the filed model is one its server holds in memory, or serves without loading:
    /// the same reading the Your model page shows, for the one door the model is behind.
    public static let inMemory: @Sendable (ImageGenHelper) async -> Bool = { helper in
        guard let parts = URLComponents(string: helper.address), let host = parts.host else { return false }
        let port = parts.port ?? (parts.scheme == "https" ? 443 : 80)
        let server = await YourModelSurvey.server(
            host: host, port: port, machine: YourModelSurvey.machineName(host), session: .shared)
        guard let server, let found = YourModelPick.find(helper, in: [server]) else { return false }
        return YourModelPick.asksOnItsOwn(found)
    }

    /// Lets go of every model nobody has shown for `fresh` seconds. Called with the lock held.
    private func shed(_ now: Date) {
        for (key, entry) in entries where entry.wanted.model != nil && !entry.inFlight {
            if now.timeIntervalSince(entry.wanted.at) > Self.fresh { entries[key]?.wanted.model = nil }
        }
    }

    /// Lets go of every turn's model at once: the system asked for memory back. A telling still
    /// owed is asked for again the next time its turn is shown.
    public func relieve() {
        lock.withLock {
            for (key, entry) in entries where !entry.inFlight { entries[key]?.wanted.model = nil }
        }
    }

    /// How many turns' models are held, for a check.
    public var heldModels: Int { lock.withLock { entries.values.filter { $0.wanted.model != nil }.count } }

    private func evict() {
        guard entries.count > Self.heldTurns else { return }
        let oldest = entries.filter { !$0.value.inFlight }.min { $0.value.wanted.at < $1.value.wanted.at }
        guard let oldest else { return }
        oldest.value.wake?.cancel()
        entries.removeValue(forKey: oldest.key)
    }

    /// Starts a telling when one is due and nothing else is out; when it is only the wait that
    /// is not over, wakes itself once it is.
    private func consider(_ key: String) {
        let now = clock()
        enum Verdict {
            case start
            case wake(TimeInterval)
            case nothing
        }
        let verdict = lock.withLock { () -> Verdict in
            guard var entry = entries[key], !entry.inFlight else { return .nothing }
            guard entry.wanted.model != nil, now.timeIntervalSince(entry.wanted.at) <= Self.fresh else {
                entries[key]?.wanted.model = nil
                return .nothing
            }
            let since = entry.lastAt.map { now.timeIntervalSince($0) }
            let told = entry.gist.map { (stepCount: $0.stepCount, running: $0.running) }
            let due = NeuralGistPolicy.isDue(
                told: told, stepCount: entry.wanted.stepCount, running: entry.wanted.running,
                sinceLast: since, lastTook: entry.lastTook, failed: entry.failed)
            if due {
                guard !busy else { return .nothing }
                busy = true
                entry.inFlight = true
                entry.wake?.cancel()
                entry.wake = nil
                entries[key] = entry
                return .start
            }
            guard entry.wake == nil, let since else { return .nothing }
            let later = NeuralGistPolicy.isDue(
                told: told, stepCount: entry.wanted.stepCount, running: entry.wanted.running,
                sinceLast: .greatestFiniteMagnitude, lastTook: entry.lastTook, failed: entry.failed)
            guard later else { return .nothing }
            let wait = entry.failed ? NeuralGistPolicy.afterFailure : NeuralGistPolicy.wait(afterTaking: entry.lastTook ?? 0)
            return .wake(max(0.5, wait - since))
        }
        switch verdict {
        case .start:
            Task.detached { [self] in await tell(key) }
        case .wake(let seconds):
            let task = Task.detached { [self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                lock.withLock { entries[key]?.wake = nil }
                consider(key)
            }
            lock.withLock {
                if entries[key] != nil, entries[key]?.wake == nil { entries[key]?.wake = task } else { task.cancel() }
            }
        case .nothing:
            break
        }
    }

    private func tell(_ key: String) async {
        let started = clock()
        let gist = await write(key)
        let finished = clock()
        lock.withLock {
            busy = false
            guard var entry = entries[key] else { return }
            entry.inFlight = false
            entry.asking = false
            entry.lastAt = finished
            entry.lastTook = finished.timeIntervalSince(started)
            if let gist {
                entry.gist = gist
                entry.failed = false
                if gist.stepCount == entry.wanted.stepCount, gist.running == entry.wanted.running {
                    entry.wanted.model = nil
                }
            } else {
                entry.failed = true
            }
            entries[key] = entry
        }
        StoreNotice.post(Self.didChange)
        let waiting = lock.withLock {
            entries.filter { !$0.value.inFlight }.sorted { $0.value.wanted.at > $1.value.wanted.at }.map(\.key)
        }
        for next in waiting { consider(next) }
    }

    private func write(_ key: String) async -> NeuralGist? {
        guard let helper = writer, await ready(helper), let ask = ask(for: key),
            let url = URL(string: helper.address + "/v1/chat/completions")
        else { return nil }
        lock.withLock {
            sent += 1
            entries[key]?.asking = true
        }
        StoreNotice.post(Self.didChange)
        guard let data = try? await transport.post(url, body: ask.body(model: helper.model)) else { return nil }
        return ask.read(
            completion: data, writer: helper.label ?? helper.model,
            place: YourModelWords.inSentence(YourModelWords.machine(of: helper)), at: clock())
    }

    /// What the model is asked for a turn as it was last shown. The turn's model is read here and
    /// let go of before the request is out, so nothing of the transcript is held while a slow
    /// model writes.
    private func ask(for key: String) -> NeuralGistAsk? {
        let held = lock.withLock { () -> (wanted: Wanted, told: NeuralGist?)? in
            entries[key].map { ($0.wanted, $0.gist) }
        }
        guard let held, let model = held.wanted.model else { return nil }
        return NeuralGistAsk.make(
            account: model.account(answer: held.wanted.answer, prompt: held.wanted.prompt),
            stepCount: held.wanted.stepCount, running: held.wanted.running, prompt: held.wanted.prompt,
            answer: held.wanted.answer, told: held.told)
    }

    private func ready(_ helper: ImageGenHelper) async -> Bool {
        let key = helper.address + "|" + helper.model
        let now = clock()
        let held = lock.withLock { () -> Bool? in
            guard let readiness, readiness.key == key,
                now.timeIntervalSince(readiness.at) < NeuralGistPolicy.readinessHolds
            else { return nil }
            return readiness.ready
        }
        if let held { return held }
        let answer = await isReady(helper)
        lock.withLock { readiness = (key, answer, now) }
        return answer
    }
}
