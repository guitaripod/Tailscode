import AgentTestSupport
import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A bridge that answers from a script, on a clock the test owns.
private final class FakeBridge: SelfUpdatingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let mock = MockBackend(agentType: .claudeCode)
    private var polls: [Result<ServerUpdate, any Error>]
    private let press: Result<ServerUpdate, any Error>
    private let remote: ServerUpdate?
    private(set) var presses = 0
    private(set) var remoteChecks = 0

    init(
        press: Result<ServerUpdate, any Error> = .failure(AgentError.unsupported("no")),
        polls: [Result<ServerUpdate, any Error>], remote: ServerUpdate? = nil
    ) {
        self.press = press
        self.polls = polls
        self.remote = remote
    }

    var agentType: AgentType { .claudeCode }
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
            if checkingRemote, let remote {
                remoteChecks += 1
                return remote
            }
            guard polls.count > 1 else { return try polls[0].get() }
            return try polls.removeFirst().get()
        }
    }

    func startUpdate() async throws -> ServerUpdate {
        try locked {
            presses += 1
            return try press.get()
        }
    }

    func restartServer() async throws -> ServerUpdate {
        try locked {
            presses += 1
            return try press.get()
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// A clock that moves only when the driver sleeps.
private final class VirtualClock: @unchecked Sendable {
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

/// Following an update is the part that used to differ between the three desks, and the part a
/// person watches: so every road through it — a press that lands, one refused, one that never
/// reached the machine, a bridge too old for jobs, a machine that goes quiet and never returns, and
/// a job this device did not start — is driven here on a clock the test owns.
extension DeviceStores {
    @Suite struct UpdateDriverTests {
        private let clock = VirtualClock(Date())

        private func driver(_ bridge: FakeBridge, id: String) -> UpdateDriver {
            let clock = self.clock
            let machine = UpdateDriver.Machine(
                profileID: id, title: "arch", subtitle: nil, agent: .claudeCode,
                backend: { bridge })
            return UpdateDriver(
                environment: UpdateDriver.Environment(
                    machines: { [machine] }, now: { clock.now },
                    sleep: { duration in
                        clock.advance(duration)
                        await Task.yield()
                    }))
        }

        private func seed(_ id: String, _ status: ServerUpdate) {
            UpdateLedger.record(
                UpdateReadings.server(
                    profileID: id, title: "arch", subtitle: nil, product: "claude-bridge",
                    outcome: .answered(status), checkedAt: clock.now))
        }

        private func card(_ id: String) -> UpdateCard? {
            UpdateLedger.remembered(.server(profileID: id), now: clock.now).map {
                UpdateCard($0, now: clock.now)
            }
        }

        private func job(
            _ step: ServerUpdate.Job.Step, outcome: ServerUpdate.Job.Outcome? = nil,
            reason: String? = nil, landed: String? = nil
        ) -> ServerUpdate.Job {
            ServerUpdate.Job(
                id: "J1", kind: .update, step: step, outcome: outcome, from: "1.9.2",
                target: "1.10.0", landed: landed, reason: reason, startedAt: clock.now,
                finishedAt: outcome == nil ? nil : clock.now)
        }

        private var behind: ServerUpdate {
            ServerUpdate(
                version: "1.9.2", running: "1.9.2", remote: .init(checked: true, ok: true),
                latestVersion: "1.10.0", updateAvailable: true, behind: 3,
                changes: ["A thing that matters: long argument"], canUpdate: true, manager: "systemd",
                canRestart: false,
                release: .init(
                    version: "1.10.0", commitsPastTag: 0,
                    notes: [.init(version: "1.10.0", items: ["Live Activities stay"])]))
        }

        private func running(_ phase: ServerUpdate.Phase, _ job: ServerUpdate.Job?)
            -> ServerUpdate
        {
            ServerUpdate(
                version: "1.10.0", running: "1.9.2", manager: "systemd", phase: phase,
                busy: .init(quiet: false, turns: 1, reason: "A turn is running on that machine."),
                job: job)
        }

        private var landed: ServerUpdate {
            ServerUpdate(
                version: "1.10.0", running: "1.10.0", remote: .init(checked: true, ok: true),
                latestVersion: "1.10.0", updateAvailable: false, behind: 0, canUpdate: true,
                manager: "systemd", phase: .succeeded,
                job: job(.done, outcome: .succeeded, landed: "1.10.0"))
        }

        /// The whole road: a press, the machine's own steps, the silence of its restart, and the
        /// answer once it is back — ending on what it became and what came with it.
        @Test func aPressIsFollowedToWhatItLandedOn() async {
            let id = "driver-\(UUID().uuidString)"
            defer { UpdateLedger.forget(.server(profileID: id)) }
            seed(id, behind)
            #expect(card(id)?.stage == .available)
            #expect(card(id)?.notes.first?.items == ["Live Activities stay"])

            let bridge = FakeBridge(
                press: .success(running(.running, job(.download))),
                polls: [
                    .success(running(.building, job(.build))),
                    .success(running(.waiting, job(.waitForIdle))),
                    .success(running(.restarting, job(.restart))),
                    .failure(AgentError.connection("refused")),
                    .failure(AgentError.connection("refused")),
                    .success(landed),
                ], remote: landed)
            let driver = driver(bridge, id: id)
            await driver.update(.server(profileID: id))

            #expect(bridge.presses == 1)
            #expect(bridge.remoteChecks == 1)
            let done = card(id)
            #expect(done?.stage == .updated)
            #expect(done?.headline == "Updated to 1.10.0")
            #expect(done?.versionLine == "claude-bridge 1.10.0")
            #expect(done?.notes.first?.items == ["Live Activities stay"])
            let outcome = UpdateLedger.remembered(.server(profileID: id), now: clock.now)?.lastOutcome
            #expect(outcome?.from == "1.9.2")
            #expect(outcome?.jobID == "J1")
        }

        /// A job's steps are drawn in order, the one under way carries its own clock from the
        /// first time this device saw it, and a poll that finds the same step does not restart it.
        @Test func stepsKeepTheirClockAcrossPolls() {
            let id = "driver-\(UUID().uuidString)"
            defer { UpdateLedger.forget(.server(profileID: id)) }
            seed(id, behind)
            let first = clock.now
            UpdateLedger.record(
                UpdateReadings.server(
                    profileID: id, title: "arch", subtitle: nil, product: "claude-bridge",
                    outcome: .answered(running(.building, job(.build))), checkedAt: first,
                    lastKnown: UpdateLedger.remembered(.server(profileID: id), now: first)))
            clock.advance(.seconds(30))
            UpdateLedger.record(
                UpdateReadings.server(
                    profileID: id, title: "arch", subtitle: nil, product: "claude-bridge",
                    outcome: .answered(running(.building, job(.build))), checkedAt: clock.now,
                    lastKnown: UpdateLedger.remembered(.server(profileID: id), now: clock.now)))
            let card = card(id)
            #expect(card?.stage == .updating)
            #expect(card?.headline == "Updating to 1.10.0")
            #expect(card?.steps.map(\.state) == [.done, .active, .pending, .pending, .pending])
            #expect(card?.steps[1].since == first)
            #expect(card?.notes.first?.items == ["Live Activities stay"])
        }

        /// A press the machine answers and does not take leaves the card where it was, saying why
        /// — an offer that sits there unchanged reads as a broken button.
        @Test func aRefusedPressSaysWhy() async {
            let id = "driver-\(UUID().uuidString)"
            defer { UpdateLedger.forget(.server(profileID: id)) }
            seed(id, behind)
            var refusal = behind
            refusal.reason = "The checkout has 2 uncommitted changes."
            let bridge = FakeBridge(press: .success(refusal), polls: [.success(behind)])
            await driver(bridge, id: id).update(.server(profileID: id))
            let card = card(id)
            #expect(card?.stage == .available)
            #expect(card?.message?.contains("It didn't start the update") == true)
        }

        /// A press that never reached the machine started nothing, and says so.
        @Test func anUnreachedPressRestoresTheCard() async {
            let id = "driver-\(UUID().uuidString)"
            defer { UpdateLedger.forget(.server(profileID: id)) }
            seed(id, behind)
            let bridge = FakeBridge(
                press: .failure(AgentError.connection("offline")),
                polls: [.failure(AgentError.connection("offline"))])
            await driver(bridge, id: id).update(.server(profileID: id))
            let card = card(id)
            #expect(card?.stage == .available)
            #expect(card?.message?.contains("Couldn't ask arch to update") == true)
        }

        /// A bridge from before jobs is followed by its phases, and given the outcome its versions
        /// prove once it is back.
        @Test func aBridgeWithoutJobsIsJudgedByItsVersions() async {
            let id = "driver-\(UUID().uuidString)"
            defer { UpdateLedger.forget(.server(profileID: id)) }
            var old = behind
            old.release = nil
            seed(id, old)
            #expect(card(id)?.notes.first?.items == ["A thing that matters"])
            var back = landed
            back.job = nil
            let bridge = FakeBridge(
                press: .success(running(.running, nil)),
                polls: [
                    .success(running(.building, nil)),
                    .success(running(.restarting, nil)),
                    .failure(AgentError.connection("refused")),
                    .success(back),
                ], remote: back)
            await driver(bridge, id: id).update(.server(profileID: id))
            let done = card(id)
            #expect(done?.stage == .updated)
            #expect(done?.headline == "Updated to 1.10.0")
            #expect(done?.notes.first?.items == ["A thing that matters"])
        }

        /// A machine that goes quiet in the middle of a build is said to have gone quiet — it may
        /// still be building — and one that never comes back is handed to the next check rather
        /// than followed forever.
        @Test func aMachineThatGoesQuietIsNotFollowedForever() async {
            let id = "driver-\(UUID().uuidString)"
            defer { UpdateLedger.forget(.server(profileID: id)) }
            seed(id, behind)
            let bridge = FakeBridge(
                press: .success(running(.building, job(.build))),
                polls: [.failure(AgentError.connection("gone"))])
            await driver(bridge, id: id).update(.server(profileID: id))
            let card = card(id)
            #expect(card?.stage == .attention)
            #expect(card?.headline == "Couldn't reach arch")
            #expect(card?.primary?.kind == .invitation(.recheck))
        }

        /// The job ended in failure on a step the machine named, and the card says which.
        @Test func aFailureNamesTheStepItStoppedOn() async {
            let id = "driver-\(UUID().uuidString)"
            defer { UpdateLedger.forget(.server(profileID: id)) }
            seed(id, behind)
            var failed = behind
            failed.phase = .failed
            failed.log = "…"
            failed.job = job(.build, outcome: .failed, reason: "Only 900 MB free")
            let bridge = FakeBridge(
                press: .success(running(.running, job(.download))),
                polls: [.success(running(.building, job(.build))), .success(failed)],
                remote: failed)
            await driver(bridge, id: id).update(.server(profileID: id))
            let card = card(id)
            #expect(card?.stage == .failed)
            #expect(card?.message == "Only 900 MB free")
            #expect(card?.steps.map(\.state) == [.done, .failed, .pending, .pending, .pending])
            #expect(card?.primary?.title == "Try again")
            #expect(card?.secondary.contains { $0.kind == .showLog } == true)
            #expect(card?.notes.first?.items == ["Live Activities stay"])
        }

        /// A relaunch in the middle of a job asks the machine where it got to, instead of believing
        /// the last thing it wrote down for three quarters of an hour.
        @Test func aRelaunchPicksUpTheJobItWasFollowing() async {
            let id = "driver-\(UUID().uuidString)"
            defer { UpdateLedger.forget(.server(profileID: id)) }
            seed(id, behind)
            seed(id, running(.building, job(.build)))
            #expect(card(id)?.stage == .updating)
            let bridge = FakeBridge(polls: [.success(landed)], remote: landed)
            let driver = driver(bridge, id: id)
            await driver.resume()
            for _ in 0..<200 where card(id)?.stage == .updating { await Task.yield() }
            #expect(card(id)?.stage == .updated)
            #expect(bridge.presses == 0)
        }

        /// A job this device did not start — another device's, or the machine's own — is followed
        /// the moment a check finds it.
        @Test func aCheckThatFindsAJobFollowsIt() async {
            let id = "driver-\(UUID().uuidString)"
            defer { UpdateLedger.forget(.server(profileID: id)) }
            var automatic = job(.build)
            automatic.automatic = true
            let bridge = FakeBridge(
                polls: [.success(running(.building, automatic)), .success(landed)], remote: landed)
            let driver = driver(bridge, id: id)
            await driver.check(.server(profileID: id))
            for _ in 0..<200 where card(id)?.stage != .updated { await Task.yield() }
            #expect(card(id)?.stage == .updated)
        }
    }
}

/// The card is the whole of what a person sees, so what each state draws — and what it refuses to
/// draw — is pinned here.
@Suite struct UpdateCardTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func server(_ status: ServerUpdate, product: String? = "claude-bridge") -> UpdateReading {
        UpdateReadings.server(
            profileID: "p", title: "arch", subtitle: nil, product: product,
            outcome: .answered(status), checkedAt: now)
    }

    @Test func anOfferLeadsWithTheVersionsAndWhatIsNew() {
        let reading = server(
            ServerUpdate(
                version: "1.9.2-1-ge877732", running: "1.9.2-1-ge877732",
                remote: .init(checked: true, ok: true), latestVersion: "1.10.0",
                updateAvailable: true, behind: 4, canUpdate: true, manager: "systemd",
                release: .init(
                    version: "1.10.0", commitsPastTag: 0,
                    notes: [.init(version: "1.10.0", items: ["One", "Two"])])))
        let card = UpdateCard(reading, now: now)
        #expect(card.stage == .available)
        #expect(card.headline == "Update available")
        #expect(card.versionLine == "claude-bridge 1.9.2+1 → 1.10.0")
        #expect(card.notesTitle == "What's new in 1.10.0")
        #expect(card.primary?.title == "Update")
        #expect(card.primary?.prominent == true)
        #expect(card.primary?.confirmation?.title == "Update arch?")
        #expect(card.secondary.map(\.kind) == [.setAside])
        #expect(card.facts.first?.value.contains("1.9.2-1-ge877732") == true)
    }

    /// Setting an offer aside keeps the press and drops the argument for it.
    @Test func anAcknowledgedOfferKeepsItsPress() {
        let reading = server(
            ServerUpdate(
                version: "1.9.2", running: "1.9.2", remote: .init(checked: true, ok: true),
                latestVersion: "1.10.0", updateAvailable: true, behind: 1, changes: ["Thing"],
                canUpdate: true, manager: "systemd"))
        let card = UpdateCard(reading, acknowledged: true, now: now)
        #expect(card.notes.isEmpty)
        #expect(card.primary != nil)
        #expect(!card.secondary.contains { $0.kind == .setAside })
        #expect(card.message?.contains("Set aside") == true)
    }

    @Test func aPressIsGreyedWhileTheMachineIsBusy() {
        let reading = server(
            ServerUpdate(
                version: "1.9.2", running: "1.9.2", remote: .init(checked: true, ok: true),
                latestVersion: "1.10.0", updateAvailable: true, behind: 1, canUpdate: true,
                manager: "systemd"))
        #expect(UpdateCard(reading, busy: true, now: now).primary?.enabled == false)
    }

    /// An update that landed is news for a day, and then it is simply current.
    @Test func aLandedUpdateIsNewsForADay() {
        let reading = server(
            ServerUpdate(
                version: "1.10.0", running: "1.10.0", remote: .init(checked: true, ok: true),
                updateAvailable: false, behind: 0, canUpdate: true, manager: "systemd",
                job: .init(
                    id: "J", automatic: true, step: .done, outcome: .succeeded, from: "1.9.2",
                    target: "1.10.0", landed: "1.10.0", finishedAt: now.addingTimeInterval(-600))))
        let fresh = UpdateCard(reading, now: now)
        #expect(fresh.stage == .updated)
        #expect(fresh.message == "Installed on its own 10 minutes ago.")
        #expect(UpdateCard(reading, now: now.addingTimeInterval(2 * 86400)).stage != .updated)
    }

    @Test func aServerTooOldForUpdatesIsHandedTheCommand() {
        let reading = UpdateReadings.server(
            profileID: "p", title: "arch", subtitle: nil, product: "claude-bridge",
            outcome: .routeMissing(version: "1.2.0"), checkedAt: now)
        let card = UpdateCard(reading, now: now)
        #expect(card.stage == .attention)
        #expect(card.headline == "Can't check for updates")
        #expect(card.primary?.kind == .invitation(.copyCommand(BridgeInstall.installCommand)))
    }

    @Test func opencodeIsHandedItsOwnCommand() {
        let reading = UpdateReadings.server(
            profileID: "p", title: "box", subtitle: nil, product: "opencode",
            outcome: .notSelfUpdating(version: "1.2.3", why: "opencode updates itself."),
            checkedAt: now, installCommand: UpdateProduct.updateCommand(for: .openCode))
        let card = UpdateCard(reading, now: now)
        #expect(card.headline == "Can't update from here")
        #expect(card.versionLine == "opencode 1.2.3")
        #expect(card.primary?.kind == .invitation(.copyCommand("opencode upgrade")))
    }

    @Test func versionsReadAsReleases() {
        #expect(VersionLabel.short("1.9.2-1-ge877732") == "1.9.2+1")
        #expect(VersionLabel.short("v1.10.0") == "1.10.0")
        #expect(VersionLabel.short("1.9.2-3-gabcdef1-dirty") == "1.9.2+3")
        #expect(VersionLabel.short("e877732") == "e877732")
        #expect(VersionLabel.short(nil) == nil)
    }

    @Test func aCommitSubjectIsCutToItsClaim() {
        #expect(
            ChangeHeadline.short("A Live Activity outlives its turn: a turn that ends settles")
                == "A Live Activity outlives its turn")
        #expect(ChangeHeadline.short("tiny") == "Tiny")
    }

    /// The chip names the state in a word, for chrome that has room for one.
    @Test func theChipSaysOneWord() {
        let offer = server(
            ServerUpdate(
                version: "1.9.2", running: "1.9.2", remote: .init(checked: true, ok: true),
                latestVersion: "1.10.0", updateAvailable: true, behind: 1, canUpdate: true,
                manager: "systemd"))
        #expect(UpdateRollup(readings: [offer]).chip?.title == "Update")
        let working = server(
            ServerUpdate(version: "1.10.0", running: "1.9.2", manager: "systemd", phase: .building))
        #expect(UpdateRollup(readings: [working]).chip?.title == "Updating")
        #expect(UpdateRollup(readings: [working]).chip?.motion == .turning)
    }
}
