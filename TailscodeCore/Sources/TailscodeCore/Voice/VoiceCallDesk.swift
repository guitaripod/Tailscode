import CodingAgentKit
import Foundation

/// Why a call did not start. Everything that goes wrong after the session exists arrives as the
/// snapshot's `end` instead, so a surface has one place to read it.
public enum VoiceCallStartError: Error, Sendable, Equatable, LocalizedError {
    case notReady(VoiceReach)
    case wantsPassword
    case audio(String)
    case superseded

    public var line: String {
        switch self {
        case .notReady(let reach): return reach.line
        case .wantsPassword: return VoiceReach.wantsPassword.line
        case .audio(let line): return line
        case .superseded: return VoiceCallReading.end(.replaced, client: .linux)
        }
    }

    public var asksForPassword: Bool { self == .wantsPassword }

    public var errorDescription: String? { line }
}

public struct VoiceReachChange: Sendable, Equatable {
    public let endpoint: VoiceEndpoint
    public let reach: VoiceReach

    public init(endpoint: VoiceEndpoint, reach: VoiceReach) {
        self.endpoint = endpoint
        self.reach = reach
    }
}

/// The call the process is in. Every read of `snapshots` is a subscription of its own that starts
/// from the latest snapshot and finishes after the one that carries the call's `end`, so a surface
/// that arrives late, or one that was left behind by a newer call, still learns how it ended.
public final class ActiveCall: Sendable {
    public let chat: String
    public let title: String?
    public let endpoint: VoiceEndpoint
    public let client: VoiceClientKind
    public let session: VoiceCallSession

    let feed = VoiceFeed<VoiceCallSnapshot>(replay: true, depth: 1)

    init(chat: String, title: String?, endpoint: VoiceEndpoint, client: VoiceClientKind, session: VoiceCallSession) {
        self.chat = chat
        self.title = title
        self.endpoint = endpoint
        self.client = client
        self.session = session
    }

    public var snapshots: AsyncStream<VoiceCallSnapshot> { feed.subscribe() }

    public var latest: VoiceCallSnapshot? { feed.latest }
}

/// The one call this process may be in, and what each server's gateway says about calling, held above
/// whatever surface is drawing them: starting a call from any chat ends the one running, and a
/// surface that is left behind reads why from its snapshot. It is an actor and never main-actor, so
/// a toolkit that cannot drain the main queue can own it.
///
/// Nothing here writes a word; reasons are `VoiceCallReading`'s and the faces are the session's.
public actor VoiceCallDesk {
    public static let refreshInterval: TimeInterval = 20
    public static let releaseGrace: TimeInterval = 3
    public static let releasePoll: TimeInterval = 0.2

    private struct Watch {
        var count: Int
        let task: Task<Void, Never>
    }

    private let secrets: any SecretStore
    private let probe: VoiceReachProbe
    private let clock: any VoiceClock
    private let makeTransport: @Sendable () -> any VoiceTransport
    private var handed: [String: String] = [:]
    private var reaches: [VoiceEndpoint: VoiceReach] = [:]
    private var readAt: [VoiceEndpoint: TimeInterval] = [:]
    private var applied: [VoiceEndpoint: Int] = [:]
    private var probes = 0
    private var watches: [VoiceEndpoint: Watch] = [:]
    private var ends: [VoiceEndpoint: VoiceCallEnd] = [:]
    private var endedAt: [VoiceEndpoint: TimeInterval] = [:]
    private var running: ActiveCall?
    private var tickets = 0
    private let reachFeed = VoiceFeed<VoiceReachChange>(replay: false, depth: 16)
    private let activeFeed = VoiceFeed<ActiveCall?>(replay: true, depth: 1, initial: .some(.none))

    public init(
        secrets: any SecretStore, probe: VoiceReachProbe = VoiceReachProbe(),
        clock: any VoiceClock = SystemVoiceClock(),
        makeTransport: @escaping @Sendable () -> any VoiceTransport = { URLSessionVoiceTransport() }
    ) {
        self.secrets = secrets
        self.probe = probe
        self.clock = clock
        self.makeTransport = makeTransport
    }

    public var active: ActiveCall? { running }

    public func isActive(chat: String) -> Bool { running?.chat == chat }

    /// Every change of which call is running, starting with the one running now; `nil` is no call.
    public nonisolated func activeChanges() -> AsyncStream<ActiveCall?> { activeFeed.subscribe() }

    public func reach(for endpoint: VoiceEndpoint) -> VoiceReach {
        if endpoint.isDemo { return .ready(gateway: VoiceDemo.gatewayVersion) }
        return reaches[endpoint] ?? .unknown
    }

    /// Each time what a gateway says about calling changes, for any server this desk has asked.
    public nonisolated func reachChanges() -> AsyncStream<VoiceReachChange> { reachFeed.subscribe() }

    /// Asks the gateway again. A reading that a newer one has already replaced is dropped.
    @discardableResult
    public func refresh(_ endpoint: VoiceEndpoint) async -> VoiceReach {
        let before = reach(for: endpoint)
        if before == .unknown { store(.checking, for: endpoint) }
        probes += 1
        let stamp = probes
        let answer = await probe.read(endpoint, bearer: password(for: endpoint))
        guard !Task.isCancelled else {
            if reaches[endpoint] == .checking { store(before, for: endpoint) }
            return reach(for: endpoint)
        }
        if stamp > applied[endpoint, default: 0] {
            applied[endpoint] = stamp
            readAt[endpoint] = clock.now()
            store(answer, for: endpoint)
        }
        return reach(for: endpoint)
    }

    /// A surface that shows the call button asks to have the reach kept fresh while it is on screen.
    public func watchReach(of endpoint: VoiceEndpoint) {
        if let held = watches[endpoint] {
            watches[endpoint] = Watch(count: held.count + 1, task: held.task)
            return
        }
        let task = Task { [weak self, clock] in
            while !Task.isCancelled {
                await self?.refresh(endpoint)
                do { try await clock.sleep(for: Self.refreshInterval) } catch { return }
            }
        }
        watches[endpoint] = Watch(count: 1, task: task)
    }

    public func unwatchReach(of endpoint: VoiceEndpoint) {
        guard let held = watches[endpoint] else { return }
        if held.count > 1 {
            watches[endpoint] = Watch(count: held.count - 1, task: held.task)
        } else {
            held.task.cancel()
            watches[endpoint] = nil
        }
    }

    public func password(for endpoint: VoiceEndpoint) -> String? {
        if endpoint.isDemo { return nil }
        return handed[endpoint.host] ?? endpoint.password(in: secrets)
    }

    /// Keeps the gateway's password for a machine and asks it again straight away.
    @discardableResult
    public func remember(password: String, for endpoint: VoiceEndpoint) async -> VoiceReach {
        handed[endpoint.host] = password
        endpoint.remember(password: password, in: secrets)
        return await refresh(endpoint)
    }

    public func forgetPassword(for endpoint: VoiceEndpoint) {
        handed[endpoint.host] = nil
        endpoint.forgetPassword(in: secrets)
        reaches[endpoint] = nil
        store(.unknown, for: endpoint)
    }

    /// Starts a call for a chat, ending whichever call is running. A demo host plays its scripted call
    /// and needs neither a gateway, a password nor an audio stack; any other host must be `ready`
    /// right now, and says in its own words when it is not.
    public func start(
        chat: String, title: String?, endpoint: VoiceEndpoint, client: VoiceClientKind, app: String,
        audio: @Sendable () throws -> (VoiceAudioCapture, VoiceAudioPlayback),
        send: @escaping @Sendable (String) async -> Bool, stopTurn: @escaping @Sendable () async -> Void
    ) async -> Result<Void, VoiceCallStartError> {
        tickets += 1
        let ticket = tickets
        var gatewayHeld = false
        if !endpoint.isDemo {
            switch await ready(endpoint) {
            case .ready: break
            case .busy where holdsGateway(endpoint): gatewayHeld = true
            case .wantsPassword: return .failure(.wantsPassword)
            case let other: return .failure(.notReady(other))
            }
            guard ticket == tickets else { return .failure(.superseded) }
        }
        let seams: (any VoiceTransport, VoiceAudioCapture, VoiceAudioPlayback)
        if endpoint.isDemo {
            let stage = VoiceDemo.stage(clock: clock)
            seams = (stage.transport, stage.capture, stage.playback)
        } else {
            do {
                let (capture, playback) = try audio()
                seams = (makeTransport(), capture, playback)
            } catch {
                let end = VoiceCallSession.audioEnd(error)
                return .failure(.audio(VoiceCallReading.end(end, client: client)))
            }
        }
        let session = VoiceCallSession(
            endpoint: endpoint, bearer: password(for: endpoint), client: client, appVersion: app, title: title,
            transport: seams.0, capture: seams.1, playback: seams.2, send: send, stopTurn: stopTurn, clock: clock)
        let call = ActiveCall(chat: chat, title: title, endpoint: endpoint, client: client, session: session)
        let previous = running
        running = call
        activeFeed.yield(call)
        follow(call)
        await previous?.session.hangUp(as: .replaced)
        if gatewayHeld { await awaitRelease(of: endpoint) }
        await session.start()
        return .success(())
    }

    public func hangUp() async {
        guard let call = running else { return }
        await call.session.hangUp()
        await settle(call)
    }

    /// The agent's account goes to the session only when the call is for this chat.
    public func feed(agent: VoiceAgentSnapshot, chat: String) async {
        guard let call = running, call.chat == chat else { return }
        await call.session.update(agent: agent)
    }

    public func reportLines(for endpoint: VoiceEndpoint) -> [String] {
        VoiceCallReport.lines(endpoint: endpoint, reach: reach(for: endpoint), end: ends[endpoint])
    }

    /// A gateway holds one call, and it says `busy` until it has seen the hang up of the call this
    /// device made, which is a moment after the hang up itself. That moment is not another caller.
    private func holdsGateway(_ endpoint: VoiceEndpoint) -> Bool {
        if running?.endpoint == endpoint { return true }
        guard let at = endedAt[endpoint] else { return false }
        return clock.now() - at < Self.releaseGrace
    }

    private func awaitRelease(of endpoint: VoiceEndpoint) async {
        var waited: TimeInterval = 0
        while waited < Self.releaseGrace {
            if await refresh(endpoint) != .busy { return }
            do { try await clock.sleep(for: Self.releasePoll) } catch { return }
            waited += Self.releasePoll
        }
    }

    private func ready(_ endpoint: VoiceEndpoint) async -> VoiceReach {
        if case .ready = reaches[endpoint], let at = readAt[endpoint], clock.now() - at < Self.refreshInterval,
            !holdsGateway(endpoint)
        {
            return reaches[endpoint] ?? .unknown
        }
        return await refresh(endpoint)
    }

    private func store(_ reach: VoiceReach, for endpoint: VoiceEndpoint) {
        guard reaches[endpoint] != reach else { return }
        reaches[endpoint] = reach
        reachFeed.yield(VoiceReachChange(endpoint: endpoint, reach: reach))
    }

    private func follow(_ call: ActiveCall) {
        Task { [weak self] in
            for await snapshot in call.session.snapshots { call.feed.yield(snapshot) }
            call.feed.finish()
            await self?.settle(call)
        }
    }

    private func settle(_ call: ActiveCall) async {
        if let end = await call.session.current().end {
            ends[call.endpoint] = end
            endedAt[call.endpoint] = clock.now()
        }
        guard running === call else { return }
        running = nil
        activeFeed.yield(nil)
    }
}

/// A fan-out of a stream that has one reader. Each subscription is its own latest-wins stream, and
/// one that arrives after the feed finished is given the last element and then finished.
final class VoiceFeed<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let replay: Bool
    private let depth: Int
    private var subscribers: [Int: AsyncStream<Element>.Continuation] = [:]
    private var counter = 0
    private var held: Element?
    private var finished = false

    init(replay: Bool, depth: Int, initial: Element? = nil) {
        self.replay = replay
        self.depth = depth
        self.held = initial
    }

    var latest: Element? { lock.withLock { held } }

    func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(depth))
        let id = lock.withLock { () -> Int in
            counter += 1
            return counter
        }
        continuation.onTermination = { [weak self] _ in self?.drop(id) }
        let snapshot = lock.withLock { () -> (replayed: Element?, closed: Bool) in
            let closed = finished
            if !closed { subscribers[id] = continuation }
            return (replay ? held : nil, closed)
        }
        if let replayed = snapshot.replayed { continuation.yield(replayed) }
        if snapshot.closed { continuation.finish() }
        return stream
    }

    func yield(_ element: Element) {
        let targets = lock.withLock { () -> [AsyncStream<Element>.Continuation] in
            guard !finished else { return [] }
            held = element
            return Array(subscribers.values)
        }
        for continuation in targets { continuation.yield(element) }
    }

    func finish() {
        let targets = lock.withLock { () -> [AsyncStream<Element>.Continuation] in
            finished = true
            defer { subscribers = [:] }
            return Array(subscribers.values)
        }
        for continuation in targets { continuation.finish() }
    }

    private func drop(_ id: Int) {
        lock.withLock { subscribers[id] = nil }
    }
}
