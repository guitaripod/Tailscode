import AgentTestSupport
import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A bridge that answers from a script, of whichever kind the test needs it to be.
private final class ScriptedBridge: SelfUpdatingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let kind: AgentType
    private let mock: MockBackend
    private var polls: [Result<ServerUpdate, any Error>]
    private let press: Result<ServerUpdate, any Error>
    private(set) var restarts = 0

    init(
        _ kind: AgentType, press: Result<ServerUpdate, any Error>,
        polls: [Result<ServerUpdate, any Error>]
    ) {
        self.kind = kind
        self.mock = MockBackend(agentType: kind)
        self.press = press
        self.polls = polls
    }

    var agentType: AgentType { kind }
    var capabilities: BackendCapabilities { mock.capabilities }
    func health() async throws -> ServerHealth { ServerHealth(healthy: true, version: "fake") }
    func listSessions() async throws -> [AgentSession] { [] }
    func createSession(title: String?, directory: String?) async throws -> AgentSession {
        try await mock.createSession(title: title, directory: directory)
    }
    func messages(for sessionID: String) async throws -> [ChatMessage] { [] }
    func send(_ prompt: SendPrompt, to sessionID: String) async throws {}
    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, any Error> {
        mock.events(for: sessionID)
    }

    func updateStatus(checkingRemote: Bool) async throws -> ServerUpdate {
        try locked {
            guard polls.count > 1 else { return try polls[0].get() }
            return try polls.removeFirst().get()
        }
    }

    func startUpdate() async throws -> ServerUpdate { try locked { try press.get() } }

    func restartServer() async throws -> ServerUpdate {
        try locked {
            restarts += 1
            return try press.get()
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// An opencode server that can only be asked, and counts the times it was.
private final class CountedOpenCode: RestartableBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let mock = MockBackend(agentType: .openCode)
    private let failure: (any Error)?
    private var asked = 0

    init(failing failure: (any Error)? = nil) { self.failure = failure }

    var restarts: Int {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    var agentType: AgentType { .openCode }
    var capabilities: BackendCapabilities { mock.capabilities }
    func health() async throws -> ServerHealth { ServerHealth(healthy: true, version: "fake") }
    func listSessions() async throws -> [AgentSession] { [] }
    func createSession(title: String?, directory: String?) async throws -> AgentSession {
        try await mock.createSession(title: title, directory: directory)
    }
    func messages(for sessionID: String) async throws -> [ChatMessage] { [] }
    func send(_ prompt: SendPrompt, to sessionID: String) async throws {}
    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, any Error> {
        mock.events(for: sessionID)
    }

    func restart() async throws {
        count()
        if let failure { throw failure }
    }

    private func count() {
        lock.lock()
        asked += 1
        lock.unlock()
    }
}

/// A clock that moves only when the driver sleeps.
private final class TickingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Date

    init(_ start: Date) { time = start }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    func advance(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        lock.lock()
        time = time.addingTimeInterval(TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18)
        lock.unlock()
    }
}

/// How each kind of server is restarted, what that costs a person who is asked, and the road
/// "Restart all servers" takes through machines of every kind at once.
@Suite struct ServerRestartWordsTests {
    @Test func opencodeIsAskedAndABridgeIsFollowed() {
        #expect(ServerRestart.course(for: .openCode) == .asked)
        #expect(ServerRestart.course(for: .claudeCode) == .followed)
        #expect(ServerRestart.course(for: .omp) == .followed)
    }

    /// A bridge never takes a turn with it, so what it costs is time and never work.
    @Test func aBridgeWaitsAndOpencodeStops() {
        let idle = ServerRestart.confirmBody(for: .claudeCode, workingTurns: 0)
        #expect(idle.contains("waits"))
        #expect(!idle.contains("stops"))
        let busy = ServerRestart.confirmBody(for: .claudeCode, workingTurns: 2)
        #expect(busy.contains("2 turns"))
        #expect(busy.contains("waits"))
        #expect(
            ServerRestart.confirmBody(for: .openCode, workingTurns: 1)
                .contains("stops it where it stands"))
    }

    @Test func everythingNamesOpencodeOnlyWhenItIsThere() {
        #expect(!ServerRestart.allConfirmBody(openCodeTurns: nil).contains("opencode"))
        let counted = ServerRestart.allConfirmBody(openCodeTurns: 2)
        #expect(counted.contains("opencode"))
        #expect(counted.contains("2 turns"))
    }
}

/// A restart that came back on the build it left is not news.
@Suite struct RestartOutcomeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func outcome(
        _ kind: UpdateProgress.Kind, from: String, to: String
    ) -> UpdateOutcome {
        UpdateOutcome(
            result: .succeeded, kind: kind, from: from, to: to, at: now, jobID: "J")
    }

    @Test func aRestartOntoTheSameBuildChangedNothing() {
        let same = outcome(.serverRestart, from: "1.16.0", to: "1.16.0")
        #expect(same.changedNothing)
        #expect(!same.isNews(now: now))
    }

    @Test func aRestartOntoANewBuildIsNews() {
        let moved = outcome(.serverRestart, from: "1.16.0", to: "1.17.0")
        #expect(!moved.changedNothing)
        #expect(moved.isNews(now: now))
    }

    @Test func anUpdateThatLandedOnTheSameVersionIsStillAnUpdate() {
        #expect(!outcome(.serverUpdate, from: "1.16.0", to: "1.16.0").changedNothing)
    }

    /// The card says the machine restarted, and does not call it an update.
    @Test func theCardSaysRestartedAndStaysUpToDate() {
        let status = ServerUpdate(
            version: "1.16.0", running: "1.16.0", remote: .init(checked: true, ok: true),
            latestVersion: "1.16.0", updateAvailable: false, behind: 0, canUpdate: true,
            manager: "systemd", phase: .succeeded,
            job: .init(
                id: "J", kind: .restart, step: .done, outcome: .succeeded, from: "1.16.0",
                landed: "1.16.0", startedAt: now, finishedAt: now))
        let reading = UpdateReadings.server(
            profileID: "p", title: "arch", subtitle: nil, product: "claude-bridge",
            outcome: .answered(status), checkedAt: now)
        let card = UpdateCard(reading, now: now)
        #expect(card.stage == .upToDate)
        #expect(card.facts.contains { $0.value.contains("Restarted") })
    }
}

/// Starting every server over at once is the one press that reaches a bridge, an omp bridge and
/// opencode together, so each road through it — a bridge that follows its restart home, one that
/// refuses, opencode asked, opencode that cannot be — is driven here on a clock the test owns.
extension DeviceStores {
    @Suite struct RestartEverythingTests {
        private let clock = TickingClock(Date())

        private func job(
            _ step: ServerUpdate.Job.Step, outcome: ServerUpdate.Job.Outcome? = nil,
            landed: String? = nil
        ) -> ServerUpdate.Job {
            ServerUpdate.Job(
                id: "R1", kind: .restart, step: step, outcome: outcome, from: "1.16.0",
                landed: landed, startedAt: clock.now, finishedAt: outcome == nil ? nil : clock.now)
        }

        private var current: ServerUpdate {
            ServerUpdate(
                version: "1.16.0", running: "1.16.0", remote: .init(checked: true, ok: true),
                latestVersion: "1.16.0", updateAvailable: false, behind: 0, canUpdate: true,
                manager: "systemd", canRestart: true)
        }

        private func restarting(_ step: ServerUpdate.Job.Step, phase: ServerUpdate.Phase)
            -> ServerUpdate
        {
            ServerUpdate(
                version: "1.16.0", running: "1.16.0", manager: "systemd", phase: phase,
                busy: .init(quiet: false, turns: 1, reason: "A turn is running on that machine."),
                job: job(step))
        }

        private var back: ServerUpdate {
            ServerUpdate(
                version: "1.16.0", running: "1.16.0", remote: .init(checked: true, ok: true),
                latestVersion: "1.16.0", updateAvailable: false, behind: 0, canUpdate: true,
                manager: "systemd", phase: .succeeded,
                job: job(.done, outcome: .succeeded, landed: "1.16.0"))
        }

        private var occupied: ServerUpdate {
            var status = current
            status.phase = .idle
            status.reason = "An update is already under way on that machine."
            return status
        }

        private func seed(_ id: String, title: String, product: String) {
            UpdateLedger.record(
                UpdateReadings.server(
                    profileID: id, title: title, subtitle: nil, product: product,
                    outcome: .answered(current), checkedAt: clock.now))
        }

        private func reading(_ id: String) -> UpdateReading? {
            UpdateLedger.remembered(.server(profileID: id), now: clock.now)
        }

        private func driver(_ machines: [UpdateDriver.Machine]) -> UpdateDriver {
            let clock = self.clock
            return UpdateDriver(
                environment: UpdateDriver.Environment(
                    machines: { machines }, now: { clock.now },
                    sleep: { duration in
                        clock.advance(duration)
                        await Task.yield()
                    }))
        }

        private func machine(
            _ id: String, _ title: String, _ agent: AgentType, _ backend: any CodingAgentBackend
        ) -> UpdateDriver.Machine {
            UpdateDriver.Machine(
                profileID: id, title: title, subtitle: nil, agent: agent, backend: { backend })
        }

        private func claudeBridge() -> ScriptedBridge {
            ScriptedBridge(
                .claudeCode, press: .success(restarting(.waitForIdle, phase: .waiting)),
                polls: [
                    .success(restarting(.restart, phase: .restarting)),
                    .failure(AgentError.connection("refused")),
                    .success(back),
                ])
        }

        private func ompBridge() -> ScriptedBridge {
            ScriptedBridge(.omp, press: .success(occupied), polls: [.success(occupied)])
        }

        /// A bridge followed home reads as a restart that changed nothing, one that refused says
        /// why on its own card, opencode is asked once, and only the refusal is named back.
        @Test func everyServerIsAskedAndOnlyTheRefusalIsNamed() async {
            let suffix = UUID().uuidString
            let claudeID = "restart-all-\(suffix)-claude"
            let ompID = "restart-all-\(suffix)-omp"
            let openID = "restart-all-\(suffix)-opencode"
            defer {
                for id in [claudeID, ompID, openID] { UpdateLedger.forget(.server(profileID: id)) }
            }
            seed(claudeID, title: "arch-claude", product: "claude-bridge")
            seed(ompID, title: "arch-omp", product: "omp-bridge")
            let claude = claudeBridge()
            let omp = ompBridge()
            let open = CountedOpenCode()
            let driver = driver([
                machine(claudeID, "arch-claude", .claudeCode, claude),
                machine(ompID, "arch-omp", .omp, omp),
                machine(openID, "arch-opencode", .openCode, open),
            ])

            let refused = await driver.restartEverything()

            #expect(refused == ["arch-omp"])
            #expect(open.restarts == 1)
            #expect(claude.restarts == 1)
            #expect(omp.restarts == 1)
            let followed = reading(claudeID)
            #expect(followed.map { UpdateCard($0, now: clock.now).stage } == .upToDate)
            #expect(followed?.lastOutcome?.changedNothing == true)
            #expect(reading(ompID)?.note?.contains("didn't restart") == true)
            #expect(driver.snapshot.restartWalk == nil)
        }

        /// opencode that cannot be asked is named, and a refusal is never silent.
        @Test func anOpencodeThatCannotBeAskedIsNamed() async {
            let id = "restart-all-\(UUID().uuidString)"
            defer { UpdateLedger.forget(.server(profileID: id)) }
            let open = CountedOpenCode(failing: AgentError.unsupported("no"))
            let driver = driver([machine(id, "arch-opencode", .openCode, open)])

            let refused = await driver.restartEverything()

            #expect(refused == ["arch-opencode"])
            #expect(open.restarts == 1)
            #expect(driver.snapshot.restartWalk == nil)
        }
    }
}
