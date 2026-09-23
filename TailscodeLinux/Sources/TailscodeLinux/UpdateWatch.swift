import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// This desktop's seat at the one ``UpdateDriver``, which does the asking, the pressing and the
/// following for all three clients the same way.
///
/// What is left here is only what the driver cannot know about a Linux box: which servers are
/// configured (the demo's are a story, not machines, and are never asked), how to reach one, and
/// what this build of the app actually is. Every answer goes through ``UpdateLedger``, which is
/// what every card renders from; a screen that wants to grey a press while a job is under way
/// reads the driver's own ``UpdateDriver/snapshot``.
enum UpdateWatch {
    private static let projectURL = "https://github.com/guitaripod/Tailscode"

    /// How long a launch waits before asking again, and how quickly it retries while the server
    /// list has not been read yet. `UpdateDriver.needsCheck` is the real gate; this is only how
    /// often the question is put to it.
    private static let cadence = 900
    private static let unseeded = 15

    private final class Watch: @unchecked Sendable {
        var loop: Task<Void, Never>?
        var itself: Task<Void, Never>?
        var relaunch: (@Sendable () -> Void)?
    }

    private static let watch = Watch()

    static let driver = UpdateDriver(
        environment: UpdateDriver.Environment(
            machines: { await machines() },
            checkApp: { fetching in await recordApp(fetching: fetching) },
            log: { AppLog.write(.update, $0) }))

    /// A debug launch that seeds every state a card can be in and asks nobody anything, so the
    /// cards can be looked at without a fleet.
    private static var fixturesRequested: Bool {
        ProcessInfo.processInfo.environment["TAILSCODE_UPDATE_FIXTURES"] != nil
    }

    /// Which fixture machines a debug launch asked for: `1` for all of them, or a list.
    private static var fixtureSelection: Set<String> {
        let value = ProcessInfo.processInfo.environment["TAILSCODE_UPDATE_FIXTURES"] ?? ""
        guard value != "1" else { return [] }
        return Set(value.split(separator: ",").map(String.init))
    }

    /// - Parameter relaunch: what to do when this app's own update reaches the point of replacing
    ///   the running process. It is the window's business, not this file's, because everything
    ///   typed into a composer has to be written down before the process goes away.
    static func start(relaunch: @escaping @Sendable () -> Void) {
        watch.relaunch = relaunch
        guard watch.loop == nil else { return }
        resumeSelfUpdate()
        guard !fixturesRequested else {
            UpdateLedger.keep([])
            UpdateLedger.record(
                UpdateFixtures.readings(
                    appTitle: Localized.text("Tailscode on this machine"), only: fixtureSelection))
            watch.loop = Task {}
            return
        }
        watch.loop = Task {
            await driver.resume()
            while !Task.isCancelled {
                await driver.checkIfDue()
                let empty = await ServerDirectory.shared.profiles().isEmpty
                try? await Task.sleep(for: .seconds(empty ? unseeded : cadence))
            }
        }
    }

    /// Everything asked again, because somebody asked. The only other thing that consults a
    /// remote is a check that has come due — a fetch costs every server a network round trip, and
    /// an app that spent one on every glance would be charging the fleet for a window being opened.
    static func refresh() {
        guard !fixturesRequested else { return }
        Task { await driver.checkAll(force: true) }
    }

    /// Keeps only the machines still configured. A server somebody removed would otherwise keep
    /// its card, and its offer would hold the mark up forever over a machine this app no longer
    /// talks to.
    ///
    /// A no-op under fixtures: this is called on an ordinary timer from the main window's own
    /// refresh cycle, which knows nothing about a debug launch, and a fixture machine has no
    /// `ConnectionProfile` behind it — so the ordinary keep would read the ledger's fixture rows
    /// as machines nobody talks to any more and prune every one of them away.
    static func keep(_ profiles: [ConnectionProfile]) {
        guard !fixturesRequested else { return }
        driver.keep(machines(from: profiles))
    }

    /// One machine asked again, because somebody pressed the button on its card.
    static func recheck(_ component: UpdateComponent) {
        guard !fixturesRequested else { return }
        Task { await driver.check(component) }
    }

    static func perform(_ component: UpdateComponent) async {
        guard !fixturesRequested else { return }
        await driver.perform(component)
    }

    static func updateEverything() async {
        guard !fixturesRequested else { return }
        await driver.updateEverything()
    }

    static func setAutoUpdate(_ component: UpdateComponent, _ enabled: Bool) async -> String? {
        guard !fixturesRequested else { return nil }
        return await driver.setAutoUpdate(component, enabled)
    }

    private static func machines() async -> [UpdateDriver.Machine] {
        machines(from: await ServerDirectory.shared.profiles())
    }

    private static func machines(from profiles: [ConnectionProfile]) -> [UpdateDriver.Machine] {
        profiles.filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }.map { profile in
            UpdateDriver.Machine(
                profileID: profile.id, title: profile.name,
                subtitle: "\(ServerLabel.agent(profile.backend)) · \(ServerLabel.address(profile))",
                agent: profile.backend,
                backend: { await ServerDirectory.shared.backend(for: profile) })
        }
    }

    /// This app, on this machine. Local and cheap unless `fetching`, which is the only part of the
    /// reading that costs anything or goes stale — so a launch that is not due carries the moment
    /// of the last fetch forward rather than claiming a fresh one, and lets `UpdateFreshness`
    /// decide when that stops being worth believing.
    static func appReading(
        fetching: Bool, release: AppRelease?, failure: String?
    ) -> UpdateReading {
        let install = LinuxAppInstall.read()
        let packaging = Packaging.current()
        let running = LinuxAppInstall.updateState()
        let checkout = LinuxAppInstall.checkout(of: install, fetching: fetching)
        let obstacle = LinuxAppInstall.obstacle(for: install)
        return UpdateReadings.app(
            install: install, release: release, checkout: checkout, running: running,
            failure: failure, obstacle: obstacle,
            command: handCommand(obstacle: obstacle, checkout: checkout, packaging: packaging),
            projectURL: projectURL,
            checkedAt: fetching ? Date() : UpdateLedger.remembered(.app)?.checkedAt,
            title: Localized.text("Tailscode on this machine"), note: packaging?.instructions)
    }

    /// The line to hand over, and only for the rows where no press here can finish the job — a
    /// command offered beside a button that works is Core's cue to stop offering the button, and
    /// this desk really can update itself.
    ///
    /// A copy a package manager owns is the other case: no press here can ever finish that job, so
    /// the manager's own line is the only thing to offer, and it is offered whatever the checkout
    /// evidence says.
    private static func handCommand(
        obstacle: String?, checkout: CheckoutState?, packaging: Packaging.Reading?
    ) -> String? {
        if let packaging { return packaging.command }
        guard let checkout, obstacle != nil || checkout.blocker != nil else { return nil }
        return LinuxAppInstall.handCommand(of: checkout)
    }

    private static func recordApp(fetching: Bool) async {
        let (release, failure) = await LatestRelease.reading(fetching: fetching)
        let reading = await Task.detached {
            appReading(fetching: fetching, release: release, failure: failure)
        }.value
        UpdateLedger.record(reading)
    }

    /// The app replacing itself. Answers nil once the work has been handed off, and the sentence to
    /// show otherwise — a build directory, a checkout that has gone, no toolchain to rebuild with.
    ///
    /// Nothing quits here. The script runs detached and this process keeps rendering its phase out
    /// of the state file, so a build that fails leaves the person exactly where they were; only the
    /// restart itself takes the window away.
    static func beginSelfUpdate() -> String? {
        if let refusal = LinuxAppInstall.selfUpdate() { return refusal }
        follow()
        return nil
    }

    /// A launch that comes up while an update is still running joins it rather than starting a
    /// second one — the script outlives the process that spawned it, and the state file is how the
    /// next launch learns what it was in the middle of.
    private static func resumeSelfUpdate() {
        guard LinuxAppInstall.updateState()?.isRunning == true else { return }
        follow()
    }

    private static func follow() {
        watch.itself?.cancel()
        watch.itself = Task {
            var last: SourceUpdatePlan.State.Phase?
            let deadline = Date().addingTimeInterval(45 * 60)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(1))
                guard let state = LinuxAppInstall.updateState() else { continue }
                if state.phase != last {
                    last = state.phase
                    await recordApp(fetching: false)
                }
                switch state.phase {
                case .running, .building, .installing:
                    continue
                case .restarting, .succeeded:
                    Gtk.onMain { watch.relaunch?() }
                    return
                case .failed:
                    return
                }
            }
        }
    }
}
