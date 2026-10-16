import CodingAgentKit
import Foundation

/// The machine a demo host pretends to be, scripted so every state of the checklist is seen in about
/// a minute with nothing behind it: a command to copy that is taken as run after a while, two
/// downloads that fill with bytes and a time left, and an engine that cannot start for a few seconds
/// because another job holds the GPU, and then can. It speaks the daemon's own wire types, in the
/// shapes the real gateway reports them, so the rows, the headline and the primary action are the
/// real ones; only the machine is missing.
public actor SetupDemoSource: SetupSource {
    public nonisolated let capability = SetupCapability.voice

    public static let commandTaken: TimeInterval = 12
    public static let blockerClears: TimeInterval = 8
    public static let modelSeconds: TimeInterval = 16
    public static let imageSeconds: TimeInterval = 10

    private struct Run {
        let fix: String
        let started: TimeInterval
        let seconds: TimeInterval
        var cancelled = false
    }

    private let clock: any VoiceClock
    private var began: TimeInterval?
    private var imageDoneAt: TimeInterval?
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
        fix == "voice.downloadModel" ? modelSeconds : imageSeconds
    }

    private func settle(_ now: TimeInterval) {
        for run in runs.values where !run.cancelled && now - run.started >= run.seconds {
            done.insert(run.fix)
            if run.fix == "voice.pullImage", imageDoneAt == nil { imageDoneAt = run.started + run.seconds }
        }
    }

    private func openRun(_ now: TimeInterval) -> (key: String, value: Run)? {
        runs.first { !$0.value.cancelled && now - $0.value.started < $0.value.seconds }
    }

    private func snapshot(of id: String, run: Run, now: TimeInterval) -> SetupJob {
        let elapsed = now - run.started
        if run.cancelled { return SetupJob(id: id, fix: run.fix, state: .cancelled, startedAt: run.started) }
        let fraction = min(1, max(0, elapsed / run.seconds))
        let total = run.fix == "voice.downloadModel" ? VoiceRequirements.modelBytes : VoiceRequirements.imageBytes
        let minutes = run.fix == "voice.downloadModel" ? 12.0 : 6.0
        var job = SetupJob(
            id: id, fix: run.fix, state: fraction >= 1 ? .succeeded : .running,
            step: run.fix == "voice.downloadModel" ? "download" : "pull", fraction: fraction, startedAt: run.started)
        job.bytesTotal = total
        job.bytesDone = Int64(Double(total) * fraction)
        job.facts["etaSeconds"] = String(Int(minutes * 60 * (1 - fraction)))
        return job
    }

    private func checks(now: TimeInterval) -> [SetupCheck] {
        let commandRun = began.map { now - $0 >= Self.commandTaken } ?? false
        let modelJob = runningJob("voice.downloadModel", now)
        let imageJob = runningJob("voice.pullImage", now)
        return [
            SetupCheck(id: "voice.gpu", state: .ok, facts: ["name": "NVIDIA RTX PRO 6000 Blackwell"]),
            SetupCheck(id: "voice.vram", state: .ok, facts: ["totalMB": "97887", "needMB": "70000"]),
            SetupCheck(id: "voice.docker", state: .ok, facts: ["os": "arch"]),
            commandRun
                ? SetupCheck(id: "voice.cdi", state: .ok, facts: ["toolkit": "installed"])
                : SetupCheck(
                    id: "voice.cdi", state: .blocked, facts: ["toolkit": "installed"],
                    fix: SetupFix(
                        id: "voice.generateCDI", kind: .command,
                        command: "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml")),
            artifact("voice.model", fix: "voice.downloadModel", total: VoiceRequirements.modelBytes, minutes: 12, job: modelJob),
            artifact("voice.image", fix: "voice.pullImage", total: VoiceRequirements.imageBytes, minutes: 6, job: imageJob),
            engine(now: now),
            SetupCheck(id: "voice.gateway", state: .ok, facts: ["version": VoiceDemo.gatewayVersion]),
        ]
    }

    private func artifact(_ id: String, fix: String, total: Int64, minutes: Int, job: String?) -> SetupCheck {
        let facts = ["bytes": String(done.contains(fix) ? total : 0), "needBytes": String(total)]
        if done.contains(fix) { return SetupCheck(id: id, state: .ok, facts: facts) }
        if let job { return SetupCheck(id: id, state: .working, facts: facts.merging(["job": job]) { _, new in new }) }
        return SetupCheck(id: id, state: .todo, facts: facts, fix: SetupFix(id: fix, bytes: total, minutes: minutes))
    }

    private func engine(now: TimeInterval) -> SetupCheck {
        guard let finished = imageDoneAt, done.contains("voice.downloadModel") else {
            return SetupCheck(id: "voice.engine", state: .todo, facts: ["mode": "managed", "after": "voice.model"])
        }
        if now - finished < Self.blockerClears {
            return SetupCheck(
                id: "voice.engine", state: .blocked,
                facts: ["mode": "managed", "state": "busy", "freeMB": "2048", "needMB": "70000"])
        }
        return SetupCheck(id: "voice.engine", state: .ok, facts: ["mode": "managed", "state": "stopped"])
    }

    private func runningJob(_ fix: String, _ now: TimeInterval) -> String? {
        runs.first { $0.value.fix == fix && !$0.value.cancelled && now - $0.value.started < $0.value.seconds }?.key
    }
}

/// Every state of the voice checklist as a value, so a harness, a screenshot and a test can put any of
/// them on screen without a machine or a clock: the same reports a daemon would send, read by the
/// same `SetupChecklist`. Each name is a state a person can meet.
public enum SetupFixtures {
    public static let names = [
        "ready", "command", "blocker", "downloading", "starting", "failed", "unavailable", "smallgpu",
        "unreachable", "absent", "checking", "password",
    ]

    public static let host = "fixture.tailnet.ts.net"

    public static func snapshot(named name: String, capability: String = SetupCapability.voice) -> SetupSnapshot? {
        let target = SetupTarget(host: host, capability: capability)
        switch name {
        case "ready":
            return SetupSnapshot(target: target, phase: .loaded, report: report(checks: allGood(), ready: true))
        case "command":
            var checks = allGood()
            checks[3] = SetupCheck(
                id: "voice.cdi", state: .blocked, facts: ["toolkit": "installed"],
                fix: SetupFix(
                    id: "voice.generateCDI", kind: .command,
                    command: "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"))
            checks[4] = pending("voice.model", fix: "voice.downloadModel", bytes: VoiceRequirements.modelBytes, minutes: 12)
            checks[5] = pending("voice.image", fix: "voice.pullImage", bytes: VoiceRequirements.imageBytes, minutes: 6)
            checks[6] = SetupCheck(id: "voice.engine", state: .todo, facts: ["mode": "managed", "after": "voice.cdi"])
            return SetupSnapshot(target: target, phase: .loaded, report: report(checks: checks, ready: false))
        case "blocker":
            var checks = allGood()
            checks[6] = SetupCheck(
                id: "voice.engine", state: .blocked,
                facts: ["mode": "managed", "state": "busy", "freeMB": "2048", "needMB": "70000", "holders": "ollama"])
            return SetupSnapshot(target: target, phase: .loaded, report: report(checks: checks, ready: false))
        case "downloading":
            var checks = allGood()
            checks[4] = SetupCheck(
                id: "voice.model", state: .working,
                facts: ["bytes": "0", "needBytes": String(VoiceRequirements.modelBytes), "job": "fixture-1", "progress": "0.31"])
            checks[5] = SetupCheck(
                id: "voice.image", state: .todo, facts: ["needBytes": String(VoiceRequirements.imageBytes)],
                fix: SetupFix(id: "voice.pullImage", bytes: VoiceRequirements.imageBytes, minutes: 6))
            let job = SetupJob(
                id: "fixture-1", fix: "voice.downloadModel", state: .running, step: "download", fraction: 0.31,
                bytesDone: Int64(Double(VoiceRequirements.modelBytes) * 0.31), bytesTotal: VoiceRequirements.modelBytes,
                facts: ["etaSeconds": "498"], startedAt: 0)
            return SetupSnapshot(
                target: target, phase: .loaded, report: report(checks: checks, ready: false, job: job), job: job,
                eta: 498, running: true)
        case "starting":
            var checks = allGood()
            checks[6] = SetupCheck(
                id: "voice.engine", state: .working, facts: ["mode": "managed", "state": "loading", "progress": "0.40"])
            return SetupSnapshot(target: target, phase: .loaded, report: report(checks: checks, ready: false))
        case "failed":
            var checks = allGood()
            checks[4] = SetupCheck(
                id: "voice.model", state: .todo,
                facts: ["bytes": "9663676416", "needBytes": String(VoiceRequirements.modelBytes), "lastFailure": "noDisk", "lastJob": "fixture-2"],
                fix: SetupFix(id: "voice.downloadModel", bytes: VoiceRequirements.modelBytes - 9_663_676_416, minutes: 9))
            checks[6] = SetupCheck(id: "voice.engine", state: .todo, facts: ["mode": "managed", "after": "voice.model"])
            let job = SetupJob(
                id: "fixture-2", fix: "voice.downloadModel", state: .failed, failure: "noDisk",
                facts: ["freeMB": "9216", "needMB": "44700"], startedAt: 0)
            return SetupSnapshot(
                target: target, phase: .loaded, report: report(checks: checks, ready: false), failed: job)
        case "unavailable":
            let checks =
                [SetupCheck(id: "voice.gpu", state: .unavailable, detail: "No NVIDIA GPU was found on this machine.")]
                + ["voice.vram", "voice.docker", "voice.cdi", "voice.model", "voice.image", "voice.engine"]
                    .map { SetupCheck(id: $0, state: .unavailable) }
                + [SetupCheck(id: "voice.gateway", state: .ok, facts: ["version": "0.4.0"])]
            return SetupSnapshot(
                target: target, phase: .loaded, report: report(checks: checks, ready: false, available: false))
        case "smallgpu":
            let checks =
                [
                    SetupCheck(id: "voice.gpu", state: .ok, facts: ["name": "NVIDIA GeForce RTX 4090"]),
                    SetupCheck(id: "voice.vram", state: .unavailable, facts: ["totalMB": "24564", "needMB": "70000"]),
                ]
                + ["voice.docker", "voice.cdi", "voice.model", "voice.image", "voice.engine"]
                    .map { SetupCheck(id: $0, state: .unavailable) }
                + [SetupCheck(id: "voice.gateway", state: .ok, facts: ["version": "0.4.0"])]
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
            id: id, state: .todo, facts: ["bytes": "0", "needBytes": String(bytes)],
            fix: SetupFix(id: fix, bytes: bytes, minutes: minutes))
    }

    private static func allGood() -> [SetupCheck] {
        [
            SetupCheck(id: "voice.gpu", state: .ok, facts: ["name": "NVIDIA RTX PRO 6000 Blackwell"]),
            SetupCheck(id: "voice.vram", state: .ok, facts: ["totalMB": "97887", "needMB": "70000"]),
            SetupCheck(id: "voice.docker", state: .ok, facts: ["os": "arch"]),
            SetupCheck(id: "voice.cdi", state: .ok, facts: ["toolkit": "installed"]),
            SetupCheck(
                id: "voice.model", state: .ok,
                facts: ["bytes": String(VoiceRequirements.modelBytes + 45_192_085), "needBytes": String(VoiceRequirements.modelBytes)]),
            SetupCheck(
                id: "voice.image", state: .ok,
                facts: ["bytes": String(VoiceRequirements.imageBytes), "needBytes": String(VoiceRequirements.imageBytes)]),
            SetupCheck(id: "voice.engine", state: .ok, facts: ["mode": "managed", "state": "stopped", "freeMB": "87892", "needMB": "70000"]),
            SetupCheck(id: "voice.gateway", state: .ok, facts: ["version": "0.4.0"]),
        ]
    }
}
