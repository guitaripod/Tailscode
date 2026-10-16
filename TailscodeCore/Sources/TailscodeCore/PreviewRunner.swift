import CodingAgentKit
import Foundation

/// Keeps one pane's preview alive on a Mac: finds the host, has its checklist ticked off, attaches
/// to the session already running for this app or starts one, and holds the picture and the news
/// as the newest value of two mailboxes that the pane drains once a frame. It never touches a
/// toolkit and never waits on a main queue.
///
/// Every failure is a state, never an end. A host that stops answering, a stream that goes quiet
/// for longer than its heartbeat allows, a session that is gone — each sends the runner round
/// again with a longer pause, and the last good picture stays where the pane can still draw it.
public final class PreviewRunner: @unchecked Sendable {
    public let pictures = LatestWins<PreviewPicture>()
    public let states = LatestWins<PreviewState>()

    public static let silenceLimit: TimeInterval = 15

    private let target: PreviewTarget
    let client: PreviewClient
    private let clock: HostClock
    private let lifetime = PaneLifetime()
    private let lock = NSLock()
    private var state = PreviewState()
    private var started = false
    private var sessionID: String?
    private var lastEventSeq = 0

    public init(target: PreviewTarget, config: ServerConfig, clock: HostClock) {
        self.target = target
        client = PreviewClient(config: config)
        self.clock = clock
    }

    public var snapshot: PreviewState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        let task = Task { [weak self] in await self?.run() }
        lifetime.add { task.cancel() }
    }

    /// Stops watching. The session on the Mac is left running on purpose, so another pane, or this
    /// one opened again, attaches to the same app instead of waiting for a build.
    public func stop() {
        lifetime.cancelAll()
        lock.lock()
        started = false
        lock.unlock()
    }

    public func endSession() {
        guard let id = currentSession else { return }
        let client = client
        Task { try? await client.stop(id) }
    }

    public func runFix(_ fix: String) {
        let task = Task { [weak self] in await self?.follow(fix: fix) }
        lifetime.add { task.cancel() }
    }

    public func rebuild() {
        guard let id = currentSession else { return }
        let client = client
        Task { try? await client.rebuild(id) }
    }

    public func setAppearance(_ appearance: String) {
        guard let id = currentSession else { return }
        let client = client
        Task { try? await client.setAppearance(id, appearance) }
    }

    public func setContentSize(_ size: String) {
        guard let id = currentSession else { return }
        let client = client
        Task { try? await client.setContentSize(id, size) }
    }

    public func relaunch(arguments: [String]?) {
        guard let id = currentSession else { return }
        let client = client
        Task { try? await client.relaunch(id, arguments: arguments) }
    }

    private func remember(session id: String?) {
        lock.lock()
        sessionID = id
        lock.unlock()
    }

    var currentSession: String? {
        lock.lock()
        defer { lock.unlock() }
        return sessionID
    }

    private func update(_ change: (inout PreviewState) -> Void) {
        lock.lock()
        change(&state)
        let copy = state
        lock.unlock()
        if states.post(copy) { clock.requestDrain() }
    }

    private func run() async {
        var pause = 1.0
        while !Task.isCancelled {
            do {
                update { $0.phase = $0.session == nil ? .connecting : .reconnecting }
                let status = try await client.status()
                update {
                    $0.hostVersion = status.version
                    $0.acceptsTouch = status.streaming.touch
                    $0.needsPassword = false
                }
                try await untilReady()
                let info = try await attach(to: status)
                pause = 1
                remember(session: info.id)
                try await follow(session: info.id)
            } catch is CancellationError {
                return
            } catch {
                let words = PreviewReading.reachFailure(error)
                let passwordWanted = Self.wantsPassword(error)
                update {
                    $0.needsPassword = passwordWanted
                    $0.phase = $0.session == nil ? .failed(words) : .reconnecting
                }
                try? await Task.sleep(for: .seconds(pause))
                pause = min(10, pause * 2)
            }
        }
    }

    static func wantsPassword(_ error: Error) -> Bool {
        if case AgentError.http(let code, _) = error { return code == 401 || code == 403 }
        return false
    }

    private func untilReady() async throws {
        while true {
            try Task.checkCancellation()
            let checks = try await client.doctor()
            update {
                $0.checks = checks
                if !PreviewReading.isReady(checks) { $0.phase = .settingUp }
            }
            if PreviewReading.isReady(checks) { return }
            try await Task.sleep(for: .seconds(2))
        }
    }

    private func follow(fix: String) async {
        guard let job = try? await client.startFix(fix) else { return }
        var current = job
        while !Task.isCancelled {
            let seen = current
            update { $0.fixes[fix] = seen }
            if current.state != .running { return }
            try? await Task.sleep(for: .milliseconds(1500))
            guard let next = try? await client.fix(current.id) else { continue }
            current = next
        }
    }

    static func chooseDevice(_ status: PreviewStatus) -> String? {
        let runtimes = status.runtimes.filter { $0.available && $0.platform == "iOS" }
        let types = runtimes.flatMap(\.deviceTypes)
        if let favourite = types.first(where: { $0.name == "iPhone 17 Pro" }) { return favourite.identifier }
        return types.first(where: { $0.name.hasPrefix("iPhone") })?.identifier
    }

    private func attach(to status: PreviewStatus) async throws -> SessionInfo {
        let wanted = target.deviceType ?? Self.chooseDevice(status)
        guard let deviceType = wanted else { throw PreviewRunnerError.noDevice }
        let existing = try await client.sessions().first {
            $0.project.path == target.project && $0.device.deviceType == deviceType
                && $0.state != .stopped && $0.state != .failed
        }
        if let existing { return existing }
        let arguments = target.screen.map { ["--screen", $0] } ?? []
        let request = SessionRequest(
            project: ProjectRef(path: target.project), deviceType: deviceType, launchArguments: arguments)
        return try await client.createSession(request)
    }

    private func follow(session id: String) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.readPictures(id) }
            group.addTask { try await self.readEvents(id) }
            group.addTask { try await self.pollInfo(id) }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func pollInfo(_ id: String) async throws {
        while true {
            try Task.checkCancellation()
            do {
                let info = try await client.session(id)
                apply(info)
            } catch AgentError.http(let code, _) where code == 404 {
                remember(session: nil)
                throw PreviewRunnerError.sessionGone
            }
            let settled = snapshot.phase == .live
            try await Task.sleep(for: .milliseconds(settled ? 1200 : 500))
        }
    }

    private func apply(_ info: SessionInfo) {
        update { state in
            state.session = info
            switch info.state {
            case .preparing, .building, .installing, .launching:
                if state.phase != .reconnecting { state.phase = .starting }
            case .live:
                if state.phase != .reconnecting { state.phase = .live }
            case .failed:
                state.phase = .failed(info.step ?? Localized.text("The app would not start"))
            case .stopped:
                state.phase = .failed(Localized.text("Stopped"))
            }
        }
    }

    private func readEvents(_ id: String) async throws {
        while true {
            try Task.checkCancellation()
            do {
                for try await event in client.events(of: id, since: lastEventSeq) {
                    lastEventSeq = max(lastEventSeq, event.seq)
                    update {
                        $0.recent.append(event)
                        if $0.recent.count > 24 { $0.recent.removeFirst($0.recent.count - 24) }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await Task.sleep(for: .seconds(1))
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func readPictures(_ id: String) async throws {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let heard = Heard()
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        var sequence = 0
                        for try await record in self.client.frames(of: id) {
                            heard.touch()
                            switch record {
                            case .frame(let microseconds, let jpeg):
                                sequence += 1
                                if self.pictures.post(
                                    PreviewPicture(sequence: sequence, microseconds: microseconds, jpeg: jpeg))
                                {
                                    self.clock.requestDrain()
                                }
                            case .event(let data):
                                if let info = try? PreviewJSON.decoder.decode(SessionInfo.self, from: data) {
                                    self.apply(info)
                                }
                            case .heartbeat:
                                break
                            }
                            self.recovered()
                        }
                        throw PreviewRunnerError.streamEnded
                    }
                    group.addTask {
                        while true {
                            try await Task.sleep(for: .seconds(3))
                            if heard.age > Self.silenceLimit { throw PreviewRunnerError.silent }
                        }
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if heard.touches == 0 { attempt += 1 } else { attempt = 1 }
                update { if $0.phase == .live { $0.phase = .reconnecting } }
                try await Task.sleep(for: .seconds(min(5, 0.4 * pow(2, Double(attempt - 1)))))
            }
        }
    }

    private func recovered() {
        lock.lock()
        let needed = state.phase == .reconnecting && state.session?.state == .live
        lock.unlock()
        if needed { update { $0.phase = .live } }
    }
}

enum PreviewRunnerError: Error {
    case noDevice
    case sessionGone
    case streamEnded
    case silent
}

/// When the picture stream was last heard from, by anything it sends: a still screen sends only
/// heartbeats, and a heartbeat is enough to know the link is alive.
final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var count = 0

    func touch() {
        lock.lock()
        last = Date()
        count += 1
        lock.unlock()
    }

    var age: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(last)
    }

    var touches: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
