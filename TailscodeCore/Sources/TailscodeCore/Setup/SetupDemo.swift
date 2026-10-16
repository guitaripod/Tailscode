import CodingAgentKit
import Foundation

/// The machine a demo host pretends to be, scripted so every state of the checklist is seen in about
/// a minute with nothing behind it: a blocker that clears by itself (another job leaving the GPU), a
/// command to copy that is taken as run after a while, two downloads that fill with bytes and a time
/// left, a start, and then ready. It speaks the daemon's own wire types, so the rows, the headline and
/// the primary action are the real ones; only the machine is missing.
public actor SetupDemoSource: SetupSource {
    public nonisolated let capability = SetupCapability.voice

    public static let blockerClears: TimeInterval = 8
    public static let commandTaken: TimeInterval = 18
    public static let modelSeconds: TimeInterval = 16
    public static let imageSeconds: TimeInterval = 10
    public static let engineSeconds: TimeInterval = 4

    private struct Run {
        let fix: String
        let started: TimeInterval
        let seconds: TimeInterval
        var cancelled = false
    }

    private let clock: any VoiceClock
    private var began: TimeInterval?
    private var blockerGone: TimeInterval?
    private var runs: [String: Run] = [:]
    private var done: Set<String> = []
    private var counter = 0

    public init(clock: any VoiceClock = SystemVoiceClock()) { self.clock = clock }

    public func report(for target: SetupTarget) async -> SetupSourceAnswer {
        let now = clock.now()
        if began == nil { began = now }
        settle(now)
        let open = openRun(now)
        let checks = checks(now: now)
        return .report(
            SetupReport(
                capability: capability, available: true, ready: checks.allSatisfy { $0.state == .ok },
                checks: checks, job: open.map { snapshot(of: $0.key, run: $0.value, now: now) }))
    }

    public func start(fix: String, for target: SetupTarget) async throws -> SetupJob {
        let now = clock.now()
        settle(now)
        if let open = openRun(now), open.value.fix == fix { return snapshot(of: open.key, run: open.value, now: now) }
        counter += 1
        let id = "demo-\(counter)"
        runs[id] = Run(fix: fix, started: now, seconds: Self.seconds(of: fix))
        return snapshot(of: id, run: runs[id]!, now: now)
    }

    public func job(id: String, for target: SetupTarget) async throws -> SetupJob {
        let now = clock.now()
        settle(now)
        guard let run = runs[id] else { throw SetupSourceError.gone }
        return snapshot(of: id, run: run, now: now)
    }

    public func cancel(job id: String, for target: SetupTarget) async throws {
        runs[id]?.cancelled = true
    }

    private static func seconds(of fix: String) -> TimeInterval {
        switch fix {
        case "voice.downloadModel": return modelSeconds
        case "voice.pullImage": return imageSeconds
        default: return engineSeconds
        }
    }

    private func settle(_ now: TimeInterval) {
        if blockerGone == nil, let began, now - began >= Self.blockerClears { blockerGone = began + Self.blockerClears }
        for run in runs.values where !run.cancelled && now - run.started >= run.seconds { done.insert(run.fix) }
    }

    private func openRun(_ now: TimeInterval) -> (key: String, value: Run)? {
        runs.first { !$0.value.cancelled && now - $0.value.started < $0.value.seconds }
    }

    private func snapshot(of id: String, run: Run, now: TimeInterval) -> SetupJob {
        let elapsed = now - run.started
        if run.cancelled { return SetupJob(id: id, fix: run.fix, state: .cancelled, startedAt: run.started) }
        let fraction = min(1, max(0, elapsed / run.seconds))
        let finished = fraction >= 1
        var job = SetupJob(
            id: id, fix: run.fix, state: finished ? .succeeded : .running, step: Self.step(of: run.fix),
            fraction: fraction, startedAt: run.started)
        if let total = Self.bytes(of: run.fix) {
            job.bytesTotal = total
            job.bytesDone = Int64(Double(total) * fraction)
            job.facts["etaSeconds"] = String(Int(Double(Self.minutes(of: run.fix)) * 60 * (1 - fraction)))
        }
        return job
    }

    private static func step(of fix: String) -> String {
        switch fix {
        case "voice.downloadModel": return "download"
        case "voice.pullImage": return "pull"
        default: return "start"
        }
    }

    private static func bytes(of fix: String) -> Int64? {
        switch fix {
        case "voice.downloadModel": return VoiceRequirements.modelBytes
        case "voice.pullImage": return VoiceRequirements.imageBytes
        default: return nil
        }
    }

    private static func minutes(of fix: String) -> Int { fix == "voice.downloadModel" ? 12 : 6 }

    private func checks(now: TimeInterval) -> [SetupCheck] {
        let gone = blockerGone != nil
        let commandRun = blockerGone.map { now - $0 >= Self.commandTaken - Self.blockerClears } ?? false
        let modelRunning = isRunning("voice.downloadModel", now)
        let imageRunning = isRunning("voice.pullImage", now)
        let engineRunning = isRunning("voice.startEngine", now)
        return [
            SetupCheck(id: "voice.gateway", state: .ok, facts: ["version": VoiceDemo.gatewayVersion]),
            SetupCheck(id: "voice.gpu", state: .ok, facts: ["name": "RTX PRO 6000", "vramMB": "97887"]),
            gone
                ? SetupCheck(id: "voice.vram", state: .ok, facts: ["freeMB": "90112", "needMB": "67584"])
                : SetupCheck(id: "voice.vram", state: .todo, facts: ["freeMB": "2048", "needMB": "67584"]),
            SetupCheck(id: "voice.docker", state: .ok, facts: ["version": "28.0.1"]),
            commandRun
                ? SetupCheck(id: "voice.cdi", state: .ok)
                : SetupCheck(
                    id: "voice.cdi", state: .todo,
                    fix: SetupFix(
                        id: "voice.enableCdi", kind: .command,
                        command: "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml")),
            artifact("voice.model", fix: "voice.downloadModel", bytes: VoiceRequirements.modelBytes, minutes: 12, running: modelRunning),
            artifact("voice.image", fix: "voice.pullImage", bytes: VoiceRequirements.imageBytes, minutes: 6, running: imageRunning),
            engineRunning
                ? SetupCheck(id: "voice.engine", state: .working, facts: ["engine": VoiceEngineState.loading.rawValue])
                : done.contains("voice.startEngine")
                    ? SetupCheck(id: "voice.engine", state: .ok, facts: ["engine": VoiceEngineState.stopped.rawValue])
                    : SetupCheck(
                        id: "voice.engine", state: .todo,
                        fix: SetupFix(id: "voice.startEngine", kind: .job, minutes: 1)),
        ]
    }

    private func artifact(_ id: String, fix: String, bytes: Int64, minutes: Int, running: Bool) -> SetupCheck {
        if done.contains(fix) { return SetupCheck(id: id, state: .ok, facts: ["bytes": String(bytes)]) }
        return SetupCheck(
            id: id, state: running ? .working : .todo, facts: ["bytes": String(bytes)],
            fix: SetupFix(id: fix, bytes: bytes, minutes: minutes))
    }

    private func isRunning(_ fix: String, _ now: TimeInterval) -> Bool {
        runs.values.contains { $0.fix == fix && !$0.cancelled && now - $0.started < $0.seconds }
    }
}

/// Every state of the voice checklist as a value, so a harness, a screenshot and a test can put any of
/// them on screen without a machine or a clock: the same reports a daemon would send, read by the
/// same `SetupChecklist`. Each name is a state a person can meet.
public enum SetupFixtures {
    public static let names = [
        "ready", "command", "blocker", "downloading", "starting", "failed", "unavailable", "unreachable",
        "absent", "checking", "password",
    ]

    public static let host = "fixture.tailnet.ts.net"

    public static func snapshot(named name: String, capability: String = SetupCapability.voice) -> SetupSnapshot? {
        let target = SetupTarget(host: host, capability: capability)
        switch name {
        case "ready":
            return SetupSnapshot(target: target, phase: .loaded, report: report(checks: allGood(), ready: true))
        case "command":
            var checks = allGood()
            checks[4] = SetupCheck(
                id: "voice.cdi", state: .todo,
                fix: SetupFix(
                    id: "voice.enableCdi", kind: .command,
                    command: "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"))
            checks[5] = pending("voice.model", fix: "voice.downloadModel", bytes: VoiceRequirements.modelBytes, minutes: 12)
            checks[6] = pending("voice.image", fix: "voice.pullImage", bytes: VoiceRequirements.imageBytes, minutes: 6)
            return SetupSnapshot(target: target, phase: .loaded, report: report(checks: checks, ready: false))
        case "blocker":
            var checks = allGood()
            checks[2] = SetupCheck(id: "voice.vram", state: .todo, facts: ["freeMB": "2048", "needMB": "67584"])
            checks[5] = pending("voice.model", fix: "voice.downloadModel", bytes: VoiceRequirements.modelBytes, minutes: 12)
            return SetupSnapshot(target: target, phase: .loaded, report: report(checks: checks, ready: false))
        case "downloading":
            var checks = allGood()
            checks[5] = SetupCheck(
                id: "voice.model", state: .working, facts: ["bytes": String(VoiceRequirements.modelBytes)],
                fix: SetupFix(id: "voice.downloadModel", bytes: VoiceRequirements.modelBytes, minutes: 12))
            checks[6] = pending("voice.image", fix: "voice.pullImage", bytes: VoiceRequirements.imageBytes, minutes: 6)
            let job = SetupJob(
                id: "fixture-1", fix: "voice.downloadModel", state: .running, step: "download", fraction: 0.31,
                bytesDone: Int64(Double(VoiceRequirements.modelBytes) * 0.31), bytesTotal: VoiceRequirements.modelBytes,
                facts: ["etaSeconds": "498"], startedAt: 0)
            return SetupSnapshot(
                target: target, phase: .loaded, report: report(checks: checks, ready: false, job: job), job: job,
                eta: 498, running: true)
        case "starting":
            var checks = allGood()
            checks[7] = SetupCheck(id: "voice.engine", state: .working, facts: ["engine": VoiceEngineState.loading.rawValue])
            return SetupSnapshot(target: target, phase: .loaded, report: report(checks: checks, ready: false))
        case "failed":
            var checks = allGood()
            checks[5] = pending("voice.model", fix: "voice.downloadModel", bytes: VoiceRequirements.modelBytes, minutes: 12)
            let job = SetupJob(
                id: "fixture-2", fix: "voice.downloadModel", state: .failed, failure: "diskFull",
                facts: ["freeMB": "9216", "needMB": "44700"], startedAt: 0)
            return SetupSnapshot(
                target: target, phase: .loaded, report: report(checks: checks, ready: false), failed: job)
        case "unavailable":
            let checks = [
                SetupCheck(id: "voice.gateway", state: .ok, facts: ["version": VoiceDemo.gatewayVersion]),
                SetupCheck(id: "voice.gpu", state: .unavailable),
            ]
            return SetupSnapshot(
                target: target, phase: .loaded, report: report(checks: checks, ready: false, available: false))
        case "unreachable":
            return SetupSnapshot(target: target, phase: .unreachable(SetupReading.unreachableAdvice))
        case "absent":
            return SetupSnapshot(target: target, phase: .absent, report: VoiceSetupSource.absentReport())
        case "checking":
            return SetupSnapshot(target: target)
        case "password":
            return SetupSnapshot(target: target, phase: .wantsPassword)
        default:
            return nil
        }
    }

    private static func report(checks: [SetupCheck], ready: Bool, job: SetupJob? = nil, available: Bool = true)
        -> SetupReport
    {
        SetupReport(capability: SetupCapability.voice, available: available, ready: ready, checks: checks, job: job)
    }

    private static func pending(_ id: String, fix: String, bytes: Int64, minutes: Int) -> SetupCheck {
        SetupCheck(
            id: id, state: .todo, facts: ["bytes": String(bytes)], fix: SetupFix(id: fix, bytes: bytes, minutes: minutes))
    }

    private static func allGood() -> [SetupCheck] {
        [
            SetupCheck(id: "voice.gateway", state: .ok, facts: ["version": "0.4.0"]),
            SetupCheck(id: "voice.gpu", state: .ok, facts: ["name": "RTX PRO 6000", "vramMB": "97887"]),
            SetupCheck(id: "voice.vram", state: .ok, facts: ["freeMB": "90112", "needMB": "67584"]),
            SetupCheck(id: "voice.docker", state: .ok, facts: ["version": "28.0.1"]),
            SetupCheck(id: "voice.cdi", state: .ok),
            SetupCheck(id: "voice.model", state: .ok, facts: ["bytes": String(VoiceRequirements.modelBytes)]),
            SetupCheck(id: "voice.image", state: .ok, facts: ["bytes": String(VoiceRequirements.imageBytes)]),
            SetupCheck(id: "voice.engine", state: .ok, facts: ["engine": VoiceEngineState.stopped.rawValue]),
        ]
    }
}
