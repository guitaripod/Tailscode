import CodingAgentKit
import Foundation

/// How long each part of following an update may take, named so a number is read rather than
/// guessed at in three clients.
public struct UpdateFollowTiming: Sendable {
    /// How often a job under way is asked where it has got to.
    public var poll: Duration = .seconds(2)
    /// How often a machine holding a finished build until it is idle is asked. It answers
    /// everything while it waits, and the wait can last hours.
    public var holdPoll: Duration = .seconds(10)
    /// How long a hold is followed before the ordinary sweep takes it over.
    public var holdFollow: TimeInterval = 20 * 60
    /// Silence tolerated from a machine that should be answering — a dropped packet, a phone
    /// changing networks — before the card says the line went quiet.
    public var silenceTolerated: TimeInterval = 60
    /// Silence tolerated once the machine has gone to restart: stopping, being started again, and
    /// reading its store back from disk.
    public var restartTolerated: TimeInterval = 240
    /// How often a machine that has gone quiet is tried.
    public var lostContactPoll: Duration = .seconds(10)
    /// How long a quiet machine is followed before the card is handed back to the next check.
    public var giveUpAfterSilence: TimeInterval = 20 * 60
    /// One question's budget. A status that consults the project waits on a `git fetch`.
    public var requestTimeout: TimeInterval = 20
    public var confirmTimeout: TimeInterval = 45
    /// A sleep that overran by this much means this process was suspended, and the silence that
    /// piled up meanwhile was nobody's but its own.
    public var suspendedGap: TimeInterval = 30

    public init() {}

    public static let standard = UpdateFollowTiming()
}

/// Keeping every machine current, the same way on every desk.
///
/// Three clients each used to own a copy of this: when to ask, how to follow a press through a
/// restart, how long to wait for a machine that went quiet, and what to conclude when it came
/// back. The copies drifted — ten minutes of patience here and twenty there, a relaunch mid-update
/// that left one client showing "Building" for three quarters of an hour — so the whole of it lives
/// here and a client only says how to reach its machines.
///
/// Everything it learns goes into ``UpdateLedger``, which is what every surface renders from; what
/// it is doing *itself* — asking, following, walking — is ``snapshot``, so a card can grey its press
/// while a job it would start is already under way. It is an ordinary class behind a lock rather than
/// an actor on the main thread, because one of the three desks never drains the main queue.
///
/// Following is a small state machine with every clock named in ``UpdateFollowTiming``: the press,
/// the machine's own steps, the silence of a restart, the confirmation once it answers again. A job
/// is followed by its identity, so a card never mistakes last week's `succeeded` for this press, and
/// a job this device did not start — another device's, or the machine's own policy's — is picked up
/// and followed the same way the moment a check finds it running. A relaunch in the middle of one
/// asks the machine where it got to rather than believing the last thing it wrote down.
public final class UpdateDriver: @unchecked Sendable {
    /// One server, and how to reach it.
    public struct Machine: Sendable {
        public let profileID: String
        public let title: String
        public let subtitle: String?
        public let agent: AgentType
        public let backend: @Sendable () async -> (any CodingAgentBackend)?

        public init(
            profileID: String, title: String, subtitle: String?, agent: AgentType,
            backend: @escaping @Sendable () async -> (any CodingAgentBackend)?
        ) {
            self.profileID = profileID
            self.title = title
            self.subtitle = subtitle
            self.agent = agent
            self.backend = backend
        }

        public var component: UpdateComponent { .server(profileID: profileID) }
        public var product: String { UpdateProduct.name(for: agent) }
        public var updateCommand: String { UpdateProduct.updateCommand(for: agent) }
    }

    /// What a client supplies: its machines, its own app's check, and — for tests — a clock.
    public struct Environment: Sendable {
        public var machines: @Sendable () async -> [Machine]
        /// Asks what this app is running and records it. `fetching` is whether it may spend a
        /// network round trip on the answer.
        public var checkApp: @Sendable (_ fetching: Bool) async -> Void
        public var log: @Sendable (String) -> Void
        public var now: @Sendable () -> Date
        public var sleep: @Sendable (Duration) async -> Void
        public var timing: UpdateFollowTiming

        public init(
            machines: @escaping @Sendable () async -> [Machine],
            checkApp: @escaping @Sendable (_ fetching: Bool) async -> Void = { _ in },
            log: @escaping @Sendable (String) -> Void = { _ in },
            now: @escaping @Sendable () -> Date = { Date() },
            sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
            timing: UpdateFollowTiming = .standard
        ) {
            self.machines = machines
            self.checkApp = checkApp
            self.log = log
            self.now = now
            self.sleep = sleep
            self.timing = timing
        }
    }

    /// What this device is doing about updates right now.
    public struct Snapshot: Sendable, Equatable {
        public struct Walk: Sendable, Equatable {
            public var done: Int
            public var total: Int
            public var current: String?
        }

        /// A sweep is out asking every machine.
        public var checking = false
        /// Machines being asked or followed, by component key.
        public var busy: Set<String> = []
        /// "Update everything", while it walks.
        public var walk: Walk?

        public func isBusy(_ component: UpdateComponent) -> Bool { busy.contains(component.key) }
    }

    public enum Press: Sendable, Equatable {
        case update
        case restart

        var kind: UpdateProgress.Kind { self == .update ? .serverUpdate : .serverRestart }
    }

    public static let didChange = Notification.Name("tailscode.updates.driver.didChange")

    private let environment: Environment
    private let lock = NSLock()
    private var state = Snapshot()
    private var asking: Set<String> = []
    private var followers: [String: (id: UUID, task: Task<UpdateReading, Never>)] = [:]
    private var lastSweep: Date?

    public init(environment: Environment) {
        self.environment = environment
    }

    public var snapshot: Snapshot { locked { state } }

    public func isBusy(_ component: UpdateComponent) -> Bool { snapshot.isBusy(component) }

    /// Whether anything is missing, or old enough that asking again is worth every server's fetch.
    ///
    /// A machine with no reading at all is asked whatever the clock says — a blank card is the one
    /// thing the ledger cannot render honestly. Past that the six-hour policy decides, and it
    /// survives a relaunch.
    public func needsCheck() async -> Bool {
        guard !snapshot.checking else { return false }
        let now = environment.now()
        let remembered = Set(UpdateLedger.remembered(now: now).map(\.id))
        if !remembered.contains(UpdateComponent.app.key) { return true }
        let machines = await environment.machines()
        if machines.contains(where: { !remembered.contains($0.component.key) }) { return true }
        guard UpdateLedger.isDue(now: now) else { return false }
        guard let last = locked({ lastSweep }) else { return true }
        return now.timeIntervalSince(last) > 60
    }

    /// The question every foreground and every idle tick asks. A sweep when one is due; otherwise
    /// only the jobs the ledger shows under way that nothing here is following — a machine holding
    /// its build until it is idle is not left describing a wait that ended an hour ago.
    public func checkIfDue() async {
        guard await needsCheck() else {
            await resume()
            return
        }
        await checkAll()
    }

    /// Every machine asked at once, each answer written as it lands — one unreachable server must
    /// not hold up the verdict of the two that answered at once.
    public func checkAll(force: Bool = false) async {
        if !force {
            guard await needsCheck() else { return }
        }
        guard mutate({ state in
            guard !state.checking else { return false }
            state.checking = true
            return true
        }) else { return }
        let machines = await environment.machines()
        keep(machines)
        environment.log("update sweep: \(machines.count) server(s) and this app")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.environment.checkApp(true) }
            for machine in machines where !self.isFollowing(machine.component) {
                group.addTask { _ = await self.check(machine, remote: true) }
            }
        }
        UpdateLedger.noteCheck(at: environment.now())
        let finished = environment.now()
        locked { lastSweep = finished }
        mutate { state in
            state.checking = false
            return true
        }
    }

    /// One machine asked again, because somebody asked — so the machine fetches the project now
    /// rather than answering from a fetch made a few minutes ago, which is exactly what somebody
    /// pressing Check now after a release went out is looking past.
    public func check(_ component: UpdateComponent) async {
        switch component {
        case .app:
            await environment.checkApp(true)
        case .server:
            guard let machine = await machine(for: component) else {
                UpdateLedger.forget(component)
                return
            }
            _ = await check(machine, remote: true, fetchingNow: true)
        }
    }

    /// Asks one machine and writes down what it said. A job found running — another device's, or
    /// the machine's own — is followed from here on, exactly as if this device had started it.
    @discardableResult
    func check(_ machine: Machine, remote: Bool, fetchingNow: Bool = false) async -> UpdateReading? {
        guard !isFollowing(machine.component) else { return remembered(machine) }
        guard beginAsking(machine.component) else { return remembered(machine) }
        let outcome = await outcome(for: machine, remote: remote, fetchingNow: fetchingNow)
        let reading = record(machine, outcome, restamp: true)
        endAsking(machine.component)
        if reading.verdict.isBusy { follow(machine, press: nil) }
        return reading
    }

    /// Keeps only the machines still configured. A server somebody removed would otherwise keep
    /// its card, and its offer would hold the mark up forever over a machine nobody talks to.
    public func keep(_ machines: [Machine]) {
        UpdateLedger.keep([.app] + machines.map(\.component))
        let live = Set(machines.map(\.component.key))
        let gone = locked {
            let gone = followers.filter { !live.contains($0.key) }
            for (key, follower) in gone {
                follower.task.cancel()
                followers.removeValue(forKey: key)
                state.busy.remove(key)
            }
            return gone
        }
        if !gone.isEmpty { post() }
    }

    /// Takes whatever one press on this machine's card finishes here — an update, or the restart
    /// onto a build it already has — and follows it to the end.
    public func perform(_ component: UpdateComponent) async {
        guard let reading = UpdateLedger.remembered(component, now: environment.now()) else {
            return
        }
        switch reading.invitation {
        case .installHere: await update(component)
        case .restartHere: await restart(component)
        default: return
        }
    }

    /// Asks the machine to update itself and follows the job through its own restart. Returns once
    /// the job has settled, which is what lets a walk take machines one at a time.
    public func update(_ component: UpdateComponent) async {
        guard let machine = await machine(for: component) else { return }
        environment.log("update requested for \(machine.profileID.prefix(8))")
        _ = await follow(machine, press: .update).value
    }

    /// Asks the machine to load the build already on its disk, followed the same way.
    public func restart(_ component: UpdateComponent) async {
        guard let machine = await machine(for: component) else { return }
        environment.log("restart requested for \(machine.profileID.prefix(8))")
        _ = await follow(machine, press: .restart).value
    }

    /// Every server this device can rebuild, one at a time: a bridge serialises its own fetch, and
    /// two updates started together queue behind each other anyway while both cards claim to be
    /// working. A machine that only needs starting is not in the walk, and neither is this app.
    public func updateEverything() async {
        let order = UpdateLedger.rollup(now: environment.now()).updateOrder
        guard !order.isEmpty, mutate({ state in
            guard state.walk == nil else { return false }
            state.walk = Snapshot.Walk(done: 0, total: order.count, current: order.first?.key)
            return true
        }) else { return }
        for component in order {
            mutate { state in
                state.walk?.current = component.key
                return true
            }
            await update(component)
            mutate { state in
                state.walk?.done += 1
                return true
            }
        }
        mutate { state in
            state.walk = nil
            return true
        }
    }

    /// Sets the machine's own policy, and publishes what the machine answered rather than what was
    /// asked of it. Answers with why it could not be set, when it could not — and then nothing is
    /// written, so every surface goes on showing the policy the machine last stated.
    public func setAutoUpdate(_ component: UpdateComponent, _ enabled: Bool) async -> String? {
        guard let machine = await machine(for: component),
            let updating = await machine.backend() as? any SelfUpdatingBackend
        else { return Localized.text("This server has no update policy to set.") }
        switch await attempt(environment.timing.requestTimeout, {
            try await updating.setAutoUpdate(enabled)
        }) {
        case .success(let status)?:
            record(machine, .answered(status))
            return nil
        case .failure(let error)?:
            return Self.words(for: error) ?? Localized.text("%@ didn't answer.", machine.title)
        case nil:
            return Localized.text("%@ didn't answer in time.", machine.title)
        }
    }

    /// Picks up every job the ledger last saw under way. A process that was not here to see how one
    /// ended asks the machine rather than believing the last word it wrote down.
    public func resume() async {
        let working = UpdateLedger.remembered(now: environment.now())
            .filter { $0.verdict.isBusy && !$0.component.isApp }
        guard !working.isEmpty else { return }
        let machines = await environment.machines()
        for reading in working {
            guard let machine = machines.first(where: { $0.component == reading.component }) else {
                continue
            }
            follow(machine, press: nil)
        }
    }

    @discardableResult
    private func follow(_ machine: Machine, press: Press?) -> Task<UpdateReading, Never> {
        let key = machine.component.key
        let id = UUID()
        let (task, fresh) = locked { () -> (Task<UpdateReading, Never>, Bool) in
            if let existing = followers[key] { return (existing.task, false) }
            let task = Task { await self.run(machine, press: press) }
            followers[key] = (id, task)
            state.busy.insert(key)
            return (task, true)
        }
        guard fresh else { return task }
        post()
        Task {
            let last = await task.value
            self.locked {
                if self.followers[key]?.id == id {
                    self.followers.removeValue(forKey: key)
                    if !self.asking.contains(key) { self.state.busy.remove(key) }
                }
            }
            self.post()
            if last.verdict.isBusy, !last.verdict.isHolding, !task.isCancelled {
                self.follow(machine, press: nil)
            }
        }
        return task
    }

    /// The press, then the machine's steps, then the silence of its restart, then the question of
    /// what it landed on. Returns the reading that ends it, whatever happens — a caller walking
    /// several machines needs a last word it can rely on arriving.
    private func run(_ machine: Machine, press: Press?) async -> UpdateReading {
        let timing = environment.timing
        let before = remembered(machine)
        guard let updating = await machine.backend() as? any SelfUpdatingBackend else {
            return record(
                machine,
                .silent(
                    Localized.text(
                        "There are no saved credentials for %@, so nothing here could ask it.",
                        machine.title)))
        }
        var jobID: String?
        var last: ServerUpdate?
        if let press {
            if let before {
                UpdateLedger.record(
                    UpdateReadings.requesting(before, kind: press.kind, at: environment.now()))
            }
            switch await attempt(timing.requestTimeout, {
                press == .update ? try await updating.startUpdate() : try await updating.restartServer()
            }) {
            case .success(let status)?:
                last = status
                jobID = status.job?.id
                guard status.isRunning else {
                    environment.log("\(machine.profileID.prefix(8)) refused the \(press)")
                    return refused(machine, status: status, press: press)
                }
                record(machine, .answered(status))
            case let failure:
                let check = await attempt(timing.requestTimeout, {
                    try await updating.updateStatus(checkingRemote: false)
                })
                if case .success(let status)? = check, status.isRunning {
                    last = status
                    jobID = status.job?.id
                    record(machine, .answered(status))
                } else if press == .restart, Self.neverReached(failure), Self.neverReached(check),
                    let asking = remembered(machine)
                {
                    environment.log(
                        "\(machine.profileID.prefix(8)) stopped answering its restart; following it back")
                    UpdateLedger.record(UpdateReadings.restartUnderWay(asking, at: environment.now()))
                } else {
                    let why = Self.words(for: failure) ?? Localized.text("it isn't answering")
                    environment.log("\(machine.profileID.prefix(8)) could not be asked: \(why)")
                    return unasked(machine, before: before, press: press, why: why)
                }
            }
        }

        var lastAnswer = environment.now()
        var restarting = remembered(machine)?.verdict.progress?.step == .restarting
        var holdingSince: Date?
        var lostSince: Date?
        while !Task.isCancelled {
            let step = remembered(machine)?.verdict.progress?.step
            let interval =
                lostSince != nil
                ? timing.lostContactPoll : step == .waitingForQuiet ? timing.holdPoll : timing.poll
            let slept = environment.now()
            await environment.sleep(interval)
            if environment.now().timeIntervalSince(slept) > interval.seconds + timing.suspendedGap {
                lastAnswer = environment.now()
            }
            guard
                case .success(let status)? = await attempt(timing.requestTimeout, {
                    try await updating.updateStatus(checkingRemote: false)
                })
            else {
                let silence = environment.now().timeIntervalSince(lastAnswer)
                if silence > (restarting ? timing.restartTolerated : timing.silenceTolerated),
                    lostSince == nil, let current = remembered(machine)
                {
                    lostSince = lastAnswer
                    environment.log("\(machine.profileID.prefix(8)) went quiet mid-update")
                    UpdateLedger.record(UpdateReadings.lostContact(current, since: lastAnswer))
                }
                if silence > timing.giveUpAfterSilence {
                    environment.log("\(machine.profileID.prefix(8)) never came back; giving up")
                    return abandoned(machine, since: lastAnswer)
                }
                continue
            }
            lastAnswer = environment.now()
            lostSince = nil
            last = status
            if let id = status.job?.id { jobID = id }
            guard status.isRunning else { break }
            let reading = record(machine, .answered(status))
            let now = reading.verdict.progress?.step
            if now == .restarting { restarting = true }
            if now == .waitingForQuiet {
                holdingSince = holdingSince ?? environment.now()
                if let since = holdingSince,
                    environment.now().timeIntervalSince(since) > timing.holdFollow
                {
                    return reading
                }
            } else {
                holdingSince = nil
            }
        }
        if Task.isCancelled { return remembered(machine) ?? placeholder(machine) }
        return await confirm(
            machine, updating: updating, before: before, last: last, jobID: jobID,
            pressed: press != nil)
    }

    /// The machine answering again, asked — against the project this time — what it landed on.
    /// A bridge old enough to have no jobs is given the outcome its versions prove. A job that
    /// ended on the machine itself — a failed build, a build left for a restart — never shows the
    /// confirming step: nothing restarted, so there is nothing to confirm.
    private func confirm(
        _ machine: Machine, updating: any SelfUpdatingBackend, before: UpdateReading?,
        last: ServerUpdate?, jobID: String?, pressed: Bool
    ) async -> UpdateReading {
        let ended = last?.phase == .failed || last?.job?.outcome == .failed
            || last?.job?.outcome == .deferred
        if !ended, let current = remembered(machine) {
            UpdateLedger.record(UpdateReadings.settling(current, at: environment.now()))
        }
        let status: ServerUpdate?
        if case .success(let fresh)? = await attempt(environment.timing.confirmTimeout, {
            try await updating.updateStatus(checkingRemote: true)
        }) {
            status = fresh
        } else {
            status = last
        }
        guard let status else {
            return record(machine, .silent(Localized.text("%@ didn't answer.", machine.title)))
        }
        var landed = reading(machine, .answered(status))
        if status.job == nil, let before, let installed = landed.installed.text {
            let from = before.installed.text
            let moved = from != installed
            let kind: UpdateProgress.Kind =
                before.verdict.progress?.kind ?? (before.needsOnlyRestart ? .serverRestart : .serverUpdate)
            if moved || (pressed && kind == .serverRestart && !landed.needsOnlyRestart) {
                landed = landed.with(
                    lastOutcome: .some(
                        UpdateOutcome(
                            result: .succeeded, kind: kind, from: from, to: installed,
                            at: environment.now(), jobID: jobID,
                            notes: before.verdict.progress?.notes
                                ?? before.verdict.offer?.whatsNew ?? [])))
            }
        }
        UpdateLedger.record(landed)
        environment.log(
            "\(machine.profileID.prefix(8)) settled: \(UpdateCard(landed, now: environment.now()).stage.rawValue)"
        )
        return landed
    }

    /// A press the machine answered and did not take. The card goes back to what it was, and says
    /// why nothing happened — an offer that sits there unchanged reads as a button that is broken.
    private func refused(_ machine: Machine, status: ServerUpdate, press: Press) -> UpdateReading {
        let reading = reading(machine, .answered(status))
        let why =
            status.reason
            ?? Localized.text("%@ didn't take it and gave no reason.", machine.title)
        let refused = reading.with(
            note: .some(
                press == .update
                    ? Localized.text("It didn't start the update: %@", why)
                    : Localized.text("It didn't restart: %@", why)))
        UpdateLedger.record(refused)
        return refused
    }

    /// A press that never reached the machine. Nothing started, so the card is what it was before
    /// the press, with the reason under it.
    private func unasked(
        _ machine: Machine, before: UpdateReading?, press: Press, why: String
    ) -> UpdateReading {
        let note =
            press == .update
            ? Localized.text("Couldn't ask %@ to update: %@", machine.title, why)
            : Localized.text("Couldn't ask %@ to restart: %@", machine.title, why)
        guard let before else {
            return record(machine, .silent(note))
        }
        let restored = before.with(note: .some(note))
        UpdateLedger.record(restored)
        return restored
    }

    /// A machine that stopped answering mid-job and never came back while this device watched.
    private func abandoned(_ machine: Machine, since: Date) -> UpdateReading {
        let current = remembered(machine)
        let reading = UpdateReading(
            component: machine.component, title: machine.title, subtitle: machine.subtitle,
            installed: current?.installed ?? .unknown, available: current?.available ?? .unknown,
            verdict: .unverified(
                .unreachable(
                    Localized.text(
                        "%@ stopped answering in the middle of the update, %@. Check again once it "
                            + "is back.", machine.title,
                        RelativeWhen.ago(since, now: environment.now())))),
            invitation: .recheck, manager: current?.manager, checkedAt: current?.checkedAt,
            automation: current?.automation, product: machine.product,
            lastOutcome: current?.lastOutcome)
        UpdateLedger.record(reading)
        return reading
    }

    private func outcome(for machine: Machine, remote: Bool, fetchingNow: Bool = false) async
        -> UpdateReadings.Outcome
    {
        guard let backend = await machine.backend() else {
            return .silent(
                Localized.text(
                    "There are no saved credentials for %@, so nothing here could ask it.",
                    machine.title))
        }
        guard let updating = backend as? any SelfUpdatingBackend else {
            let health = await attempt(10) { try await backend.health() }
            let version: String?
            if case .success(let answer)? = health { version = answer.version } else { version = nil }
            return .notSelfUpdating(
                version: version,
                why: Localized.text(
                    "%@ updates itself with its own command, run on that machine.", machine.product))
        }
        var failure: (any Error)?
        for attempt in 0..<2 {
            switch await self.attempt(environment.timing.requestTimeout, {
                fetchingNow
                    ? try await updating.updateStatusFetchingNow()
                    : try await updating.updateStatus(checkingRemote: remote)
            }) {
            case .success(let status)?:
                return .answered(status)
            case .failure(let error)? where Self.isMissingRoute(error):
                let health = await self.attempt(10) { try await backend.health() }
                if case .success(let answer)? = health { return .routeMissing(version: answer.version) }
                return .routeMissing(version: nil)
            case .failure(let error)?:
                failure = error
            case nil:
                failure = nil
            }
            if attempt == 0 { await environment.sleep(.seconds(3)) }
        }
        if case .success? = await attempt(10, { try await backend.health() }) {
            return .silent(
                Localized.text(
                    "%@ is up but didn't answer about updates in time — it may be busy.",
                    machine.title))
        }
        guard let failure, let words = Self.words(for: failure) else {
            return .silent(Localized.text("%@ didn't answer.", machine.title))
        }
        return .silent(Localized.text("%@ didn't answer — %@", machine.title, words))
    }

    /// What a failed request says, in words somebody can act on — or nil when it never reached the
    /// machine at all. Underneath a request that never arrived is a dump of error domains and
    /// user-info keys, the whole of it on Linux, and none of it says more than that the machine
    /// did not answer, which the sentence around it already does.
    private static func words(for error: any Error) -> String? {
        if let agent = error as? AgentError, case .connection = agent { return nil }
        return AgentErrorText.readable(error)
    }

    private static func words(for result: Result<ServerUpdate, any Error>?) -> String? {
        switch result {
        case .failure(let error)?: return words(for: error)
        case nil: return Localized.text("it didn't answer in time")
        case .success?: return nil
        }
    }

    /// A request whose connection itself failed, as opposed to one the machine answered or one
    /// that ran out of time.
    private static func neverReached(_ result: Result<ServerUpdate, any Error>?) -> Bool {
        guard case .failure(let error)? = result, let agent = error as? AgentError,
            case .connection = agent
        else { return false }
        return true
    }

    private static func isMissingRoute(_ error: any Error) -> Bool {
        guard let agent = error as? AgentError else { return false }
        switch agent {
        case .http(let status, _): return status == 404
        case .unsupported: return true
        default: return false
        }
    }

    /// A reading for a machine being let go of, written nowhere: a follower cancelled because its
    /// server was removed must not put the row back.
    private func placeholder(_ machine: Machine) -> UpdateReading {
        UpdateReading(
            component: machine.component, title: machine.title, subtitle: machine.subtitle,
            installed: .unknown, verdict: .unverified(.neverChecked), product: machine.product)
    }

    private func machine(for component: UpdateComponent) async -> Machine? {
        await environment.machines().first { $0.component == component }
    }

    private func remembered(_ machine: Machine) -> UpdateReading? {
        UpdateLedger.remembered(machine.component, now: environment.now())
    }

    private func reading(_ machine: Machine, _ outcome: UpdateReadings.Outcome) -> UpdateReading {
        UpdateReadings.server(
            profileID: machine.profileID, title: machine.title, subtitle: machine.subtitle,
            product: machine.product, outcome: outcome, checkedAt: environment.now(),
            lastKnown: remembered(machine), installCommand: machine.updateCommand)
    }

    @discardableResult
    private func record(
        _ machine: Machine, _ outcome: UpdateReadings.Outcome, restamp: Bool = false
    ) -> UpdateReading {
        let reading = reading(machine, outcome)
        UpdateLedger.record(reading, restamp: restamp)
        return reading
    }

    private func isFollowing(_ component: UpdateComponent) -> Bool {
        locked { followers[component.key] != nil }
    }

    private func beginAsking(_ component: UpdateComponent) -> Bool {
        let began = locked { () -> Bool in
            guard asking.insert(component.key).inserted else { return false }
            state.busy.insert(component.key)
            return true
        }
        if began { post() }
        return began
    }

    private func endAsking(_ component: UpdateComponent) {
        locked {
            asking.remove(component.key)
            if followers[component.key] == nil { state.busy.remove(component.key) }
        }
        post()
    }

    @discardableResult
    private func mutate(_ change: (inout Snapshot) -> Bool) -> Bool {
        let (applied, changed) = locked { () -> (Bool, Bool) in
            let before = state
            let applied = change(&state)
            return (applied, state != before)
        }
        if changed { post() }
        return applied
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func post() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// One question, raced against its budget. Nil is the budget running out, which is an answer
    /// of its own: a machine that is merely busy answers late, and nothing here may wait forever.
    private func attempt<T: Sendable>(
        _ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T
    ) async -> Result<T, any Error>? {
        await withTaskGroup(of: Result<T, any Error>?.self) { group in
            group.addTask {
                do { return .success(try await work()) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

extension Duration {
    fileprivate var seconds: TimeInterval {
        let (whole, fraction) = components
        return TimeInterval(whole) + TimeInterval(fraction) / 1e18
    }
}
