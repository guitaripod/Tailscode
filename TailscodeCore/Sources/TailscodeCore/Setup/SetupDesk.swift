import CodingAgentKit
import Foundation

/// Every machine checklist this process holds, above whatever surface is drawing one. A report is
/// fetched from the daemon that owns the capability (or from a source the client registered, or from
/// the scripted demo), refreshed while a surface watches it and not otherwise, and a fix is started
/// and followed here by its job's id, so closing the checklist and coming back, or the app
/// restarting, finds the same job in the next report. It is an actor and never main-actor, so a
/// toolkit that cannot drain the main queue can own it.
///
/// Nothing here writes a word: `SetupChecklist` reads a snapshot into rows and a headline.
public actor SetupDesk {
    public static let idleInterval: TimeInterval = 8
    public static let jobInterval: TimeInterval = 1
    public static let failuresBeforeUnreachable = 3
    public static let jobFailuresBeforeGivingUp = 20
    public static let chainLimit = 12

    private struct Entry {
        var snapshot: SetupSnapshot
        var watchers = 0
        var watcher: Task<Void, Never>?
        var follower: Task<SetupJob?, Never>?
        var chain: Task<Void, Never>?
        var pace = SetupPace()
        var failures = 0
        var stamp = 0
        var applied = 0
    }

    private let clock: any VoiceClock
    private var sources: [String: any SetupSource]
    private var demo: SetupDemoSource?
    private var entries: [SetupTarget: Entry] = [:]
    private let feed = VoiceFeed<SetupChange>(replay: false, depth: 16)
    private let secrets: any SecretStore

    public init(
        secrets: any SecretStore, http: any SetupHTTPFetching = URLSessionSetupHTTP(),
        clock: any VoiceClock = SystemVoiceClock(), sources: [any SetupSource] = []
    ) {
        self.secrets = secrets
        self.clock = clock
        let voice = VoiceSetupSource(http: http) { endpoint in endpoint.password(in: secrets) }
        let media = MediaSetupSource()
        var table: [String: any SetupSource] = [voice.capability: voice, media.capability: media]
        for source in sources { table[source.capability] = source }
        self.sources = table
    }

    public func register(source: any SetupSource) { sources[source.capability] = source }

    public nonisolated func changes() -> AsyncStream<SetupChange> { feed.subscribe() }

    public func snapshot(for target: SetupTarget) -> SetupSnapshot {
        entries[target]?.snapshot ?? SetupSnapshot(target: target)
    }

    /// Keeps the gateway's password for a machine, as the call does, and asks it again.
    @discardableResult
    public func remember(password: String, for target: SetupTarget) async -> SetupSnapshot {
        VoiceSetupSource.endpoint(of: target).remember(password: password, in: secrets)
        return await refresh(target)
    }

    @discardableResult
    public func refresh(_ target: SetupTarget) async -> SetupSnapshot {
        var entry = entries[target] ?? Entry(snapshot: SetupSnapshot(target: target))
        entry.stamp += 1
        let stamp = entry.stamp
        entries[target] = entry
        guard let source = source(for: target) else {
            return apply(.unreachable(Localized.text("nothing here can check this")), stamp: stamp, to: target)
        }
        let answer = await source.report(for: target)
        guard !Task.isCancelled else { return snapshot(for: target) }
        return apply(answer, stamp: stamp, to: target)
    }

    /// A surface that shows a checklist asks to have it kept fresh while it is on screen.
    public func watch(_ target: SetupTarget) {
        var entry = entries[target] ?? Entry(snapshot: SetupSnapshot(target: target))
        entry.watchers += 1
        if entry.watcher == nil {
            entry.watcher = Task { [weak self, clock] in
                while !Task.isCancelled {
                    await self?.poll(target)
                    do { try await clock.sleep(for: SetupDesk.idleInterval) } catch { return }
                }
            }
        }
        entries[target] = entry
    }

    /// The last surface to leave stops everything this desk was doing for the checklist; a job the
    /// machine is running goes on, and the next surface to watch finds it in the report.
    public func unwatch(_ target: SetupTarget) {
        guard var entry = entries[target], entry.watchers > 0 else { return }
        entry.watchers -= 1
        if entry.watchers == 0 {
            entry.watcher?.cancel()
            entry.follower?.cancel()
            entry.chain?.cancel()
            entry.watcher = nil
            entry.follower = nil
            entry.chain = nil
            entry.snapshot.running = false
        }
        entries[target] = entry
        if entry.watchers == 0 { publish(target) }
    }

    /// Starts one fix, or follows the job the machine already has for it, and returns once the job
    /// is under way; the snapshots that follow carry its progress.
    @discardableResult
    public func start(fix: String, for target: SetupTarget) async -> SetupSnapshot {
        _ = await begin(fix: fix, for: target)
        return snapshot(for: target)
    }

    private func begin(fix: String, for target: SetupTarget) async -> Task<SetupJob?, Never>? {
        guard let source = source(for: target) else { return nil }
        if let open = openJob(for: target), open.fix == fix { return follow(open, target: target) }
        do {
            let job = try await source.start(fix: fix, for: target)
            update(target) { $0.snapshot.failed = nil }
            return follow(job, target: target)
        } catch let error as SetupSourceError {
            fail(target, error)
        } catch {
            fail(target, .unreachable(error.localizedDescription))
        }
        return nil
    }

    /// Does every job fix in order until a command, a blocker or a failure is reached, and returns
    /// when the chain ends. One chain runs per checklist.
    public func runAll(_ target: SetupTarget) async {
        if let running = entries[target]?.chain {
            await running.value
            return
        }
        let chain = Task { [weak self] in
            guard let self else { return }
            await self.walk(target)
        }
        update(target) {
            $0.chain = chain
            $0.snapshot.running = true
        }
        publish(target)
        await chain.value
        update(target) {
            $0.chain = nil
            $0.snapshot.running = false
        }
        publish(target)
    }

    /// Stops the chain and asks the machine to cancel the job it is following.
    public func cancel(_ target: SetupTarget) async {
        guard let entry = entries[target] else { return }
        entry.chain?.cancel()
        let job = openJob(for: target)
        entry.follower?.cancel()
        update(target) {
            $0.chain = nil
            $0.follower = nil
            $0.snapshot.job = nil
            $0.snapshot.running = false
        }
        if let job, let source = source(for: target) {
            try? await source.cancel(job: job.id, for: target)
        }
        await refresh(target)
    }

    private func walk(_ target: SetupTarget) async {
        var steps = 0
        while !Task.isCancelled, steps < Self.chainLimit {
            let current = await refresh(target)
            guard let report = current.report, report.available, !Task.isCancelled else { return }
            guard let next = report.checks.first(where: { $0.state != .ok }) else { return }
            switch next.state {
            case .unavailable, .blocked, .ok:
                return
            case .working:
                do { try await clock.sleep(for: Self.jobInterval) } catch { return }
                continue
            case .todo:
                guard let fix = next.fix, fix.kind == .job else { return }
                guard let running = await begin(fix: fix.id, for: target),
                    let settled = await running.value, settled.state == .succeeded
                else { return }
                steps += 1
            }
        }
    }

    private func poll(_ target: SetupTarget) async {
        guard entries[target]?.follower == nil else { return }
        await refresh(target)
    }

    private func source(for target: SetupTarget) -> (any SetupSource)? {
        if target.isDemo, target.capability == SetupCapability.voice {
            if let demo { return demo }
            let made = SetupDemoSource(clock: clock)
            demo = made
            return made
        }
        return sources[target.capability]
    }

    private func openJob(for target: SetupTarget) -> SetupJob? {
        guard let snapshot = entries[target]?.snapshot else { return nil }
        let job = snapshot.job ?? snapshot.report?.job
        return job.flatMap { $0.state.isSettled ? nil : $0 }
    }

    private func follow(_ job: SetupJob, target: SetupTarget) -> Task<SetupJob?, Never> {
        if let running = entries[target]?.follower { return running }
        update(target) {
            $0.snapshot.job = job
            $0.pace.reset()
            $0.pace.note(job, at: clock.now())
            $0.snapshot.eta = $0.pace.remaining(of: job)
        }
        publish(target)
        let task = Task { [weak self] in await self?.watchJob(job, target: target) }
        update(target) { $0.follower = task }
        return task
    }

    private func watchJob(_ first: SetupJob, target: SetupTarget) async -> SetupJob? {
        var job = first
        var misses = 0
        while !Task.isCancelled, !job.state.isSettled {
            do { try await clock.sleep(for: Self.jobInterval) } catch { return nil }
            guard let source = source(for: target) else { return nil }
            do {
                job = try await source.job(id: job.id, for: target)
                misses = 0
            } catch SetupSourceError.gone {
                break
            } catch {
                misses += 1
                if misses >= Self.jobFailuresBeforeGivingUp { break }
                continue
            }
            let now = clock.now()
            update(target) {
                $0.pace.note(job, at: now)
                $0.snapshot.job = job
                $0.snapshot.eta = $0.pace.remaining(of: job)
            }
            publish(target)
        }
        guard !Task.isCancelled else { return nil }
        update(target) {
            $0.follower = nil
            $0.snapshot.eta = nil
            $0.snapshot.job = job
            if job.state == .failed { $0.snapshot.failed = job }
        }
        publish(target)
        let after = await refresh(target)
        update(target) { $0.snapshot.job = nil }
        publish(target)
        return job.state.isSettled ? job : Self.resolved(job, by: after.report)
    }

    private static func resolved(_ job: SetupJob, by report: SetupReport?) -> SetupJob {
        var closed = job
        let stillOpen = report?.checks.contains { $0.fix?.id == job.fix && $0.state != .ok } ?? true
        closed.state = stillOpen ? .cancelled : .succeeded
        return closed
    }

    private func apply(_ answer: SetupSourceAnswer, stamp: Int, to target: SetupTarget) -> SetupSnapshot {
        var entry = entries[target] ?? Entry(snapshot: SetupSnapshot(target: target))
        guard stamp >= entry.applied else { return entry.snapshot }
        entry.applied = stamp
        switch answer {
        case .report(let report):
            entry.failures = 0
            entry.snapshot.phase = .loaded
            entry.snapshot.report = report
        case .absent(let report):
            entry.failures = 0
            entry.snapshot.phase = .absent
            entry.snapshot.report = report
        case .wantsPassword:
            entry.snapshot.phase = .wantsPassword
            entry.snapshot.report = nil
        case .unreachable(let why):
            entry.failures += 1
            if entry.snapshot.report == nil || entry.failures >= Self.failuresBeforeUnreachable {
                entry.snapshot.phase = .unreachable(why)
            }
        }
        entries[target] = entry
        publish(target)
        if case .report(let report) = answer, entry.follower == nil, let job = report.job, !job.state.isSettled {
            _ = follow(job, target: target)
        }
        return entries[target]?.snapshot ?? entry.snapshot
    }

    private func fail(_ target: SetupTarget, _ error: SetupSourceError) {
        switch error {
        case .wantsPassword:
            update(target) { $0.snapshot.phase = .wantsPassword }
        case .unreachable(let why), .refused(let why):
            update(target) { $0.snapshot.phase = .unreachable(why) }
        case .gone:
            break
        }
        publish(target)
    }

    private func update(_ target: SetupTarget, _ change: (inout Entry) -> Void) {
        var entry = entries[target] ?? Entry(snapshot: SetupSnapshot(target: target))
        change(&entry)
        entries[target] = entry
    }

    private func publish(_ target: SetupTarget) {
        guard let snapshot = entries[target]?.snapshot else { return }
        feed.yield(SetupChange(snapshot: snapshot))
    }
}
