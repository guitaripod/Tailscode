import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for key: String) throws -> String? { lock.withLock { values[key] } }
    func setValue(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
    func removeValue(for key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

private final class FakeDaemon: SetupSource, @unchecked Sendable {
    let capability = SetupCapability.voice
    private let lock = NSLock()
    private var checks: [SetupCheck]
    private var jobs: [String: SetupJob] = [:]
    private var counter = 0
    private var reachable = true
    private var starts: [String] = []
    private var cancels: [String] = []
    private var failing: Set<String> = []
    private var perPoll = 0.5

    init(checks: [SetupCheck]) { self.checks = checks }

    var started: [String] { lock.withLock { starts } }
    var cancelled: [String] { lock.withLock { cancels } }

    func setReachable(_ value: Bool) { lock.withLock { reachable = value } }
    func failFix(_ id: String) { lock.withLock { _ = failing.insert(id) } }
    func setPerPoll(_ value: Double) { lock.withLock { perPoll = value } }

    func complete(check id: String) {
        lock.withLock {
            if let index = checks.firstIndex(where: { $0.id == id }) {
                checks[index].state = .ok
                checks[index].fix = nil
            }
        }
    }

    func report(for target: SetupTarget) async -> SetupSourceAnswer {
        lock.withLock {
            guard reachable else { return .unreachable("down") }
            let open = jobs.values.first { !$0.state.isSettled }
            return .report(
                SetupReport(capability: capability, ready: checks.allSatisfy { $0.state == .ok }, checks: checks, job: open))
        }
    }

    func start(fix: String, for target: SetupTarget) async throws -> SetupJob {
        try lock.withLock {
            guard reachable else { throw SetupSourceError.unreachable("down") }
            starts.append(fix)
            counter += 1
            let job = SetupJob(
                id: "job\(counter)", fix: fix, state: .running, step: "download", fraction: 0, bytesDone: 0,
                bytesTotal: 10_000_000_000, startedAt: 0)
            jobs[job.id] = job
            return job
        }
    }

    func job(id: String, for target: SetupTarget) async throws -> SetupJob {
        try lock.withLock {
            guard var job = jobs[id] else { throw SetupSourceError.gone }
            guard reachable else { throw SetupSourceError.unreachable("down") }
            if job.state == .running {
                job.fraction = min(1, (job.fraction ?? 0) + perPoll)
                job.bytesDone = Int64(Double(job.bytesTotal ?? 0) * (job.fraction ?? 0))
                if (job.fraction ?? 0) >= 1 {
                    if failing.contains(job.fix) {
                        job.state = .failed
                        job.failure = "network"
                    } else {
                        job.state = .succeeded
                        if let index = checks.firstIndex(where: { $0.fix?.id == job.fix }) {
                            checks[index].state = .ok
                            checks[index].fix = nil
                        }
                    }
                }
                jobs[id] = job
            }
            return job
        }
    }

    func cancel(job id: String, for target: SetupTarget) async throws {
        lock.withLock {
            cancels.append(id)
            jobs[id]?.state = .cancelled
        }
    }
}

private func fix(_ id: String) -> SetupFix { SetupFix(id: id, bytes: 10_000_000_000, minutes: 5) }

private func checks() -> [SetupCheck] {
    [
        SetupCheck(id: "voice.gateway", state: .ok),
        SetupCheck(id: "voice.model", state: .todo, fix: fix("voice.downloadModel")),
        SetupCheck(id: "voice.image", state: .todo, fix: fix("voice.pullImage")),
        SetupCheck(
            id: "voice.cdi", state: .todo,
            fix: SetupFix(id: "voice.enableCdi", kind: .command, command: "sudo nvidia-ctk cdi generate")),
        SetupCheck(id: "voice.engine", state: .todo, fix: SetupFix(id: "voice.startEngine")),
    ]
}

private let target = SetupTarget(host: "box.tailnet.ts.net", capability: SetupCapability.voice)

private func desk(_ daemon: FakeDaemon, clock: ManualVoiceClock) -> SetupDesk {
    SetupDesk(secrets: MemorySecrets(), clock: clock, sources: [daemon])
}

@Suite("Setup desk")
struct SetupDeskTests {
    @Test("A refresh reads the report into a snapshot and tells whoever is listening")
    func refreshPublishes() async throws {
        let clock = ManualVoiceClock()
        let daemon = FakeDaemon(checks: checks())
        let desk = desk(daemon, clock: clock)
        let heard = Heard()
        let listening = heard.collect(desk.changes())
        defer { listening.cancel() }
        let snapshot = await desk.refresh(target)
        #expect(snapshot.phase == .loaded)
        #expect(snapshot.report?.checks.count == 5)
        #expect(await eventually { heard.snapshots.contains { $0.phase == .loaded } })
        #expect(await desk.snapshot(for: target) == snapshot)
    }

    @Test("A surface that watches keeps the report fresh, and the last one to leave stops the polling")
    func watching() async throws {
        let clock = ManualVoiceClock()
        let daemon = FakeDaemon(checks: checks())
        let desk = desk(daemon, clock: clock)
        await desk.watch(target)
        await desk.watch(target)
        #expect(await eventually { await desk.snapshot(for: target).phase == .loaded })
        daemon.complete(check: "voice.cdi")
        await clock.advance(by: SetupDesk.idleInterval + 1)
        #expect(await eventually {
            await desk.snapshot(for: target).report?.checks.first { $0.id == "voice.cdi" }?.state == .ok
        })
        await desk.unwatch(target)
        #expect(clock.sleepers > 0)
        await desk.unwatch(target)
        await clock.settle()
        #expect(clock.sleepers == 0)
    }

    @Test("A fix is started and followed by its job until the check passes")
    func fixFollowsItsJob() async throws {
        let clock = ManualVoiceClock()
        let daemon = FakeDaemon(checks: checks())
        let desk = desk(daemon, clock: clock)
        await desk.watch(target)
        _ = await desk.refresh(target)
        _ = await desk.start(fix: "voice.downloadModel", for: target)
        let started = await desk.snapshot(for: target)
        #expect(started.job?.fix == "voice.downloadModel")
        let list = started.checklist(locale: Locale(identifier: "en_US"))
        #expect(list.status == .working)
        await clock.advance(by: 1)
        #expect(await eventually { await desk.snapshot(for: target).job?.fraction == 0.5 })
        await clock.advance(by: 1)
        #expect(await eventually {
            await desk.snapshot(for: target).report?.checks.first { $0.id == "voice.model" }?.state == .ok
        })
        #expect(await eventually { await desk.snapshot(for: target).job == nil })
        await desk.unwatch(target)
    }

    @Test("A time left comes from the rate watched, and from the daemon's own figure when it gives one")
    func paceAndTold() {
        var pace = SetupPace()
        var job = SetupJob(id: "j", fix: "f", state: .running, bytesDone: 0, bytesTotal: 1_000)
        pace.note(job, at: 0)
        #expect(pace.remaining(of: job) == nil)
        job.bytesDone = 100
        pace.note(job, at: 1)
        #expect(pace.remaining(of: job) == nil)
        job.bytesDone = 400
        pace.note(job, at: 4)
        #expect(abs((pace.remaining(of: job) ?? 0) - 6) < 0.001)
        job.facts["etaSeconds"] = "90"
        #expect(pace.remaining(of: job) == 90)
        var other = job
        other.id = "k"
        other.facts = [:]
        pace.note(other, at: 5)
        #expect(pace.remaining(of: other) == nil)
    }

    @Test("A relaunch finds the job the machine is already running and follows it")
    func relaunchFindsTheJob() async throws {
        let clock = ManualVoiceClock()
        let daemon = FakeDaemon(checks: checks())
        let first = desk(daemon, clock: clock)
        _ = await first.start(fix: "voice.downloadModel", for: target)
        let second = desk(daemon, clock: clock)
        let snapshot = await second.refresh(target)
        #expect(snapshot.report?.job?.fix == "voice.downloadModel")
        #expect(await eventually { await second.snapshot(for: target).job?.fix == "voice.downloadModel" })
        await second.watch(target)
        await clock.advance(by: 1)
        await clock.advance(by: 1)
        #expect(await eventually {
            await second.snapshot(for: target).report?.checks.first { $0.id == "voice.model" }?.state == .ok
        })
        #expect(daemon.started == ["voice.downloadModel"])
        await second.unwatch(target)
    }

    @Test("Starting the fix a job already runs follows that job and starts nothing")
    func startIsIdempotent() async throws {
        let clock = ManualVoiceClock()
        let daemon = FakeDaemon(checks: checks())
        let desk = desk(daemon, clock: clock)
        _ = await desk.start(fix: "voice.downloadModel", for: target)
        _ = await desk.start(fix: "voice.downloadModel", for: target)
        #expect(daemon.started == ["voice.downloadModel"])
        await desk.cancel(target)
    }

    @Test("Run all does every job in order and stops at the first command")
    func chainStopsAtACommand() async throws {
        let clock = ManualVoiceClock()
        let daemon = FakeDaemon(checks: checks())
        let desk = desk(daemon, clock: clock)
        await desk.watch(target)
        let ticking = Task {
            for _ in 0..<40 {
                await clock.advance(by: 1)
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        await desk.runAll(target)
        ticking.cancel()
        #expect(daemon.started == ["voice.downloadModel", "voice.pullImage"])
        let snapshot = await desk.snapshot(for: target)
        let list = snapshot.checklist(locale: Locale(identifier: "en_US"))
        #expect(!snapshot.running)
        #expect(list.primary == .copy(command: "sudo nvidia-ctk cdi generate", label: "Copy command"))
        #expect(list.rows.first { $0.id == "voice.engine" }?.state == .todo)
        await desk.unwatch(target)
    }

    @Test("Run all stops at a failure and the row says why")
    func chainStopsAtAFailure() async throws {
        let clock = ManualVoiceClock()
        let daemon = FakeDaemon(checks: checks())
        daemon.failFix("voice.downloadModel")
        let desk = desk(daemon, clock: clock)
        await desk.watch(target)
        let ticking = Task {
            for _ in 0..<30 {
                await clock.advance(by: 1)
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        await desk.runAll(target)
        ticking.cancel()
        #expect(daemon.started == ["voice.downloadModel"])
        let snapshot = await desk.snapshot(for: target)
        #expect(snapshot.failed?.failure == "network")
        let row = snapshot.checklist(locale: Locale(identifier: "en_US")).rows.first { $0.id == "voice.model" }
        #expect(row?.state == .failed)
        #expect(row?.failure == "The download was interrupted. Trying again picks up where it stopped.")
        await desk.unwatch(target)
    }

    @Test("Cancel stops the chain and asks the machine to cancel the job it is following")
    func cancelStops() async throws {
        let clock = ManualVoiceClock()
        let daemon = FakeDaemon(checks: checks())
        daemon.setPerPoll(0.1)
        let desk = desk(daemon, clock: clock)
        await desk.watch(target)
        let chain = Task { await desk.runAll(target) }
        #expect(await eventually { await desk.snapshot(for: target).job != nil })
        await clock.advance(by: 1)
        await desk.cancel(target)
        await chain.value
        #expect(daemon.cancelled == ["job1"])
        #expect(daemon.started == ["voice.downloadModel"])
        #expect(await desk.snapshot(for: target).job == nil)
        #expect(!(await desk.snapshot(for: target).running))
        await desk.unwatch(target)
    }

    @Test("A machine that stops answering is kept as it was twice and unreachable the third time")
    func unreachableNeedsThreeMisses() async throws {
        let clock = ManualVoiceClock()
        let daemon = FakeDaemon(checks: checks())
        let desk = desk(daemon, clock: clock)
        _ = await desk.refresh(target)
        daemon.setReachable(false)
        var snapshot = await desk.refresh(target)
        #expect(snapshot.phase == .loaded && snapshot.report != nil)
        snapshot = await desk.refresh(target)
        #expect(snapshot.phase == .loaded)
        snapshot = await desk.refresh(target)
        #expect(snapshot.phase == .unreachable("down"))
        daemon.setReachable(true)
        snapshot = await desk.refresh(target)
        #expect(snapshot.phase == .loaded)
    }

    @Test("A host nobody has registered a source for is said to be unreachable, never a crash")
    func unknownCapability() async {
        let desk = SetupDesk(secrets: MemorySecrets(), clock: ManualVoiceClock())
        let snapshot = await desk.refresh(SetupTarget(host: "box", capability: "nothing"))
        guard case .unreachable = snapshot.phase else {
            Issue.record("expected unreachable, got \(snapshot.phase)")
            return
        }
    }
}

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [SetupSnapshot] = []

    var snapshots: [SetupSnapshot] { lock.withLock { held } }

    func collect(_ stream: AsyncStream<SetupChange>) -> Task<Void, Never> {
        Task {
            for await change in stream { lock.withLock { held.append(change.snapshot) } }
        }
    }
}

private final class ScriptedHTTP: SetupHTTPFetching, @unchecked Sendable {
    typealias Handler = @Sendable (SetupHTTPRequest) throws -> VoiceHTTPAnswer
    private let lock = NSLock()
    private var seen: [SetupHTTPRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    var requests: [SetupHTTPRequest] { lock.withLock { seen } }

    func send(_ request: SetupHTTPRequest) async throws -> VoiceHTTPAnswer {
        lock.withLock { seen.append(request) }
        return try handler(request)
    }
}

@Suite("Voice setup source")
struct VoiceSetupSourceTests {
    private func source(_ http: ScriptedHTTP, password: String? = nil) -> VoiceSetupSource {
        VoiceSetupSource(http: http) { _ in password }
    }

    private func json<T: Encodable>(_ value: T, status: Int = 200) -> VoiceHTTPAnswer {
        VoiceHTTPAnswer(status: status, body: (try? SetupCodec.encode(value)) ?? Data())
    }

    private let report = SetupReport(
        capability: "voice", ready: false, checks: [SetupCheck(id: "voice.gpu", state: .ok)])

    @Test("The report is read from the gateway's own port with the password it was given")
    func reads() async {
        let http = ScriptedHTTP { _ in self.json([self.report]) }
        let answer = await source(http, password: "s3cret").report(for: target)
        #expect(answer == .report(report))
        #expect(http.requests.first?.url.absoluteString == "http://box.tailnet.ts.net:4102/setup")
        #expect(http.requests.first?.bearer == "s3cret")
        let single = ScriptedHTTP { _ in self.json(self.report) }
        #expect(await source(single).report(for: target) == .report(report))
    }

    @Test("A development endpoint's port is kept")
    func port() async {
        let http = ScriptedHTTP { _ in self.json([self.report]) }
        _ = await source(http).report(for: SetupTarget(host: "127.0.0.1", port: 5102, capability: "voice"))
        #expect(http.requests.first?.url.absoluteString == "http://127.0.0.1:5102/setup")
    }

    @Test("Nothing listening is a machine with no gateway, and the report is the command that installs it")
    func absent() async {
        let http = ScriptedHTTP { _ in throw URLError(.cannotConnectToHost) }
        guard case .absent(let report) = await source(http).report(for: target) else {
            Issue.record("expected absent")
            return
        }
        #expect(report.checks.map(\.id) == ["voice.gateway"])
        #expect(report.checks[0].fix?.kind == .command)
        #expect(report.checks[0].fix?.command == "curl -fsSL https://raw.githubusercontent.com/guitaripod/voice-bridge/master/install.sh | bash")
    }

    @Test("A gateway older than the checklist answers health but not setup, and is told to update")
    func older() async {
        let http = ScriptedHTTP { request in
            if request.url.path == "/setup" { return VoiceHTTPAnswer(status: 404, body: Data()) }
            let health = VoiceHealth(gateway: "0.2.0", engine: .ready)
            return VoiceHTTPAnswer(status: 200, body: (try? JSONEncoder().encode(health)) ?? Data())
        }
        guard case .absent(let report) = await source(http).report(for: target) else {
            Issue.record("expected absent")
            return
        }
        #expect(report.checks[0].facts["version"] == "0.2.0")
        let both404 = ScriptedHTTP { _ in VoiceHTTPAnswer(status: 404, body: Data()) }
        guard case .absent(let bare) = await source(both404).report(for: target) else {
            Issue.record("expected absent")
            return
        }
        #expect(bare.checks[0].facts.isEmpty)
    }

    @Test("A password wanted, a timeout and a machine off the tailnet each have their own answer")
    func failures() async {
        let wants = ScriptedHTTP { _ in VoiceHTTPAnswer(status: 401, body: Data()) }
        #expect(await source(wants).report(for: target) == .wantsPassword)
        let slow = ScriptedHTTP { _ in throw URLError(.timedOut) }
        #expect(await source(slow).report(for: target) == .unreachable("it did not answer in time"))
        let off = ScriptedHTTP { _ in throw URLError(.notConnectedToInternet) }
        #expect(await source(off).report(for: target) == .unreachable(SetupReading.unreachableAdvice))
        let broken = ScriptedHTTP { _ in VoiceHTTPAnswer(status: 500, body: Data()) }
        #expect(await source(broken).report(for: target) == .unreachable("it answered with status 500"))
        let garbage = ScriptedHTTP { _ in VoiceHTTPAnswer(status: 200, body: Data("nope".utf8)) }
        #expect(await source(garbage).report(for: target) == .unreachable("it answered with status 200"))
    }

    @Test("Starting, following and cancelling a fix are the daemon's three routes")
    func jobRoutes() async throws {
        let job = SetupJob(id: "j1", fix: "voice.pullImage", state: .running, fraction: 0.5, startedAt: 3)
        let http = ScriptedHTTP { _ in self.json(job) }
        let voice = source(http)
        #expect(try await voice.start(fix: "voice.pullImage", for: target) == job)
        #expect(try await voice.job(id: "j1", for: target) == job)
        try await voice.cancel(job: "j1", for: target)
        let requests = http.requests
        #expect(requests.map(\.method) == [.post, .get, .delete])
        #expect(requests.map(\.url.path) == ["/setup/fix", "/setup/jobs/j1", "/setup/jobs/j1"])
        #expect(requests[0].body.map { String(decoding: $0, as: UTF8.self) } == #"{"fix":"voice.pullImage"}"#)
    }

    @Test("A job the daemon has forgotten is gone, and a refusal says what it answered")
    func jobErrors() async {
        let gone = ScriptedHTTP { _ in VoiceHTTPAnswer(status: 404, body: Data()) }
        await #expect(throws: SetupSourceError.gone) { try await self.source(gone).job(id: "j", for: target) }
        let refused = ScriptedHTTP { _ in VoiceHTTPAnswer(status: 409, body: Data()) }
        await #expect(throws: SetupSourceError.refused("it answered with status 409")) {
            try await self.source(refused).start(fix: "f", for: target)
        }
        let wants = ScriptedHTTP { _ in VoiceHTTPAnswer(status: 401, body: Data()) }
        await #expect(throws: SetupSourceError.wantsPassword) { try await self.source(wants).start(fix: "f", for: target) }
    }

    @Test("A remembered password is the one the next request carries")
    func rememberedPassword() async {
        let secrets = MemorySecrets()
        let http = ScriptedHTTP { request in
            request.bearer == "hunter2" ? self.json([self.report]) : VoiceHTTPAnswer(status: 401, body: Data())
        }
        let desk = SetupDesk(secrets: secrets, http: http, clock: ManualVoiceClock())
        var snapshot = await desk.refresh(target)
        #expect(snapshot.phase == .wantsPassword)
        #expect(snapshot.checklist(locale: Locale(identifier: "en_US")).primary == .askPassword(label: "Add the password"))
        snapshot = await desk.remember(password: "hunter2", for: target)
        #expect(snapshot.phase == .loaded)
        #expect(VoiceEndpoint(host: target.host).password(in: secrets) == "hunter2")
    }
}

@Suite("Setup demo")
struct SetupDemoTests {
    @Test("A demo host walks every state with no machine: a blocker, a command, two downloads, a start, ready")
    func walksEveryState() async throws {
        let clock = ManualVoiceClock()
        let desk = SetupDesk(secrets: MemorySecrets(), clock: clock)
        let demo = SetupTarget(host: "studio.tailnet-demo.ts.net", capability: SetupCapability.voice)
        #expect(demo.isDemo)
        let english = Locale(identifier: "en_US")
        var list = (await desk.refresh(demo)).checklist(locale: english)
        #expect(list.rows.first { $0.id == "voice.vram" }?.state == .needsYou)
        #expect(list.primary == nil)

        await clock.advance(by: SetupDemoSource.blockerClears + 1)
        list = (await desk.refresh(demo)).checklist(locale: english)
        #expect(list.rows.first { $0.id == "voice.vram" }?.state == .done)
        #expect(list.rows.first { $0.id == "voice.cdi" }?.fix?.kind == .command)
        guard case .copy = list.primary else {
            Issue.record("expected a command to copy, got \(String(describing: list.primary))")
            return
        }

        await clock.advance(by: SetupDemoSource.commandTaken)
        list = (await desk.refresh(demo)).checklist(locale: english)
        #expect(list.rows.first { $0.id == "voice.cdi" }?.state == .done)
        #expect(list.primary == .setUp(label: "Set up voice"))

        await desk.watch(demo)
        let chain = Task { await desk.runAll(demo) }
        #expect(await eventually { await desk.snapshot(for: demo).job?.fix == "voice.downloadModel" })
        await clock.advance(by: 4)
        #expect(await eventually {
            let mid = await desk.snapshot(for: demo).checklist(locale: english)
            return mid.jobRow?.job?.line?.contains(" left") == true && mid.headline.hasPrefix("Working:")
        })
        for _ in 0..<40 {
            await clock.advance(by: 1)
            if (await desk.snapshot(for: demo)).report?.ready == true { break }
        }
        await chain.value
        list = (await desk.snapshot(for: demo)).checklist(locale: english)
        #expect(list.status == .ready)
        #expect(list.primary == .finish(label: "Try a call"))
        await desk.unwatch(demo)
    }
}
