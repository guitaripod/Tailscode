import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore
import os

/// This Mac's seat at the one `UpdateDriver` every client shares.
///
/// The asking, the following through a restart, and every clock that decides how long to wait for
/// a quiet machine now live in Core, asked once instead of three times. What is left here is only
/// what a Mac alone can answer: which servers are configured, how to reach one, and what this
/// bundle is actually running — plus the main-thread relay AppKit needs, since the driver and the
/// ledger both post from whatever thread happened to learn something.
@MainActor
final class MacUpdateWatch {
    static let shared = MacUpdateWatch()

    /// Posted on the main queue whenever a card could have changed. `UpdateLedger` and
    /// `UpdateDriver` each post their own notification from arbitrary threads; every AppKit
    /// observer of an update listens here instead; so a view is never touched off the main thread.
    nonisolated static let didChange = Notification.Name("tailscode.mac.updates.didChange")

    private nonisolated static let log = Logger(
        subsystem: "com.guitaripod.tailscode", category: "updates")
    /// How often the loop wakes to *ask whether* a check is due. Whether it is remains
    /// `UpdateFreshness`'s answer, never this timer's: a Mac asleep for a day checks when it wakes
    /// rather than at the next multiple of half an hour.
    private static let wake: Duration = .seconds(1800)
    private static let fixtureEnv = "TAILSCODE_UPDATE_FIXTURES"

    let driver: UpdateDriver

    private var relays: [any NSObjectProtocol] = []
    private var loop: Task<Void, Never>?
    private var started = false

    private init() {
        driver = UpdateDriver(
            environment: UpdateDriver.Environment(
                machines: { await Self.machines() },
                checkApp: { _ in await Self.checkApp() },
                log: { Self.log.info("\($0)") }))
    }

    var snapshot: UpdateDriver.Snapshot { driver.snapshot }

    /// A debug launch that seeds every state a card can be in and asks nobody anything, so the
    /// board can be looked at without a fleet. Compiled out of a release build entirely, the same
    /// way the iPhone's own fixture switch is.
    private static var fixtures: Bool {
        #if DEBUG
            return ProcessInfo.processInfo.environment[fixtureEnv] != nil
        #else
            return false
        #endif
    }

    /// Which fixture machines a debug launch asked for: `1` for all of them, or a comma list of
    /// ids among `arch,mini,studio,pi,box,old`.
    private static var fixtureSelection: Set<String> {
        let value = ProcessInfo.processInfo.environment[fixtureEnv] ?? ""
        guard value != "1" else { return [] }
        return Set(value.split(separator: ",").map(String.init))
    }

    /// Starts watching every configured machine, and picks up any job the last run of this app was
    /// following when it stopped — a relaunch mid-update asks the machine where it got to rather
    /// than believing the last thing this process wrote down before it quit.
    func start() {
        guard !started else { return }
        started = true
        relays = [UpdateLedger.didChange, UpdateDriver.didChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            }
        }
        guard !Self.fixtures else {
            UpdateLedger.keep([])
            UpdateLedger.record(
                UpdateFixtures.readings(
                    appTitle: Localized.text("Tailscode on this Mac"), only: Self.fixtureSelection))
            return
        }
        let driver = driver
        loop = Task {
            await driver.resume()
            while !Task.isCancelled {
                await driver.checkIfDue()
                try? await Task.sleep(for: Self.wake)
            }
        }
    }

    /// Asks once, if it is due. Opening a window that shows updates calls this rather than forcing
    /// a sweep, so looking at the board twice in a minute costs nothing.
    func checkIfDue() {
        guard !Self.fixtures else { return }
        Task { await driver.checkIfDue() }
    }

    func checkAll() async {
        guard !Self.fixtures else { return }
        await driver.checkAll(force: true)
    }

    func check(_ component: UpdateComponent) async {
        await driver.check(component)
    }

    func perform(_ component: UpdateComponent) async {
        await driver.perform(component)
    }

    func updateEverything() async {
        await driver.updateEverything()
    }

    func setAutoUpdate(_ component: UpdateComponent, _ enabled: Bool) async -> String? {
        await driver.setAutoUpdate(component, enabled)
    }

    /// A server removed must stop holding the mark up, and one just added is worth asking about
    /// before the next due check comes round.
    func noteProfilesChanged() {
        guard !Self.fixtures else { return }
        Task {
            let machines = await Self.machines()
            driver.keep(machines)
            for machine in machines where UpdateLedger.remembered(machine.component) == nil {
                await driver.check(machine.component)
            }
        }
    }

    private static func checkApp() async {
        let lastKnown = UpdateLedger.remembered(.app)
        let reading = await Task.detached(priority: .utility) {
            MacAppInstall.reading(lastKnown: lastKnown)
        }.value
        UpdateLedger.record(reading)
    }

    /// The demo's servers are a story, not machines: asking one what it runs would write an
    /// invented verdict into a ledger that outlives the demo.
    private static func machines() async -> [UpdateDriver.Machine] {
        await MainActor.run { ServerDirectory.shared.profiles }
            .filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }
            .map { profile in
                UpdateDriver.Machine(
                    profileID: profile.id, title: profile.name,
                    subtitle:
                        "\(ServerLabel.agent(profile.backend)) · \(ServerLabel.address(profile))",
                    agent: profile.backend,
                    backend: { await MainActor.run { ServerDirectory.shared.backend(for: profile) } }
                )
            }
    }
}
