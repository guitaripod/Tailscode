import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore
import UIKit

/// This phone's seat at `UpdateDriver`, which does the asking, the pressing and the following for
/// all three clients the same way.
///
/// What is left here is only what the driver cannot know about a phone: which servers are
/// configured (the demo's are a story, not machines, and are never asked), how to reach one, and
/// what the App Store says about this app. Every answer goes through `UpdateLedger`, which is what
/// the cards render from; a screen that wants to grey a press while a job is under way listens to
/// the driver's own `didChange`.
@MainActor
enum UpdateMonitor {
    /// Posted on the main thread whenever a card could have changed — an answer landed, or this
    /// device started or stopped asking. The driver works off the main thread and the ledger posts
    /// from whichever thread wrote it; screens listen here and never have to ask which.
    nonisolated static let didChange = Notification.Name("UpdateMonitor.didChange")

    /// A server consulting its remote costs it a `git fetch` before it can answer, which is a long
    /// way past the eight seconds a health probe is given.
    private static let policy = ConnectionPolicy(
        requestTimeout: .seconds(25), resourceTimeout: .seconds(40))

    private static let projectURL = "https://github.com/guitaripod/Tailscode"

    private static var connectionsObserver: (any NSObjectProtocol)?
    private static var relays: [any NSObjectProtocol] = []

    static let driver = UpdateDriver(
        environment: UpdateDriver.Environment(
            machines: { await machines() },
            checkApp: { _ in await checkApp() },
            log: { AppLogger.connection.info("\($0)") }))

    static var snapshot: UpdateDriver.Snapshot { driver.snapshot }

    /// A debug launch that seeds every state a card can be in and asks nobody anything, so the
    /// cards can be looked at without a fleet.
    private static let fixtures: Bool = {
        #if DEBUG
            return ProcessInfo.processInfo.environment["TAILSCODE_UPDATE_FIXTURES"] != nil
        #else
            return false
        #endif
    }()

    /// Which fixture machines a debug launch asked for: `1` for all of them, or a list.
    private static var fixtureSelection: Set<String> {
        let value = ProcessInfo.processInfo.environment["TAILSCODE_UPDATE_FIXTURES"] ?? ""
        guard value != "1" else { return [] }
        return Set(value.split(separator: ",").map(String.init))
    }

    /// Starts watching the profile list, and picks up any job the last run of this app was
    /// following when it stopped — a relaunch mid-update asks the machine where it got to.
    static func start() {
        guard connectionsObserver == nil else { return }
        relays = [UpdateLedger.didChange, UpdateDriver.didChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                NotificationCenter.default.post(name: didChange, object: nil)
            }
        }
        guard !fixtures else {
            UpdateLedger.keep([])
            UpdateLedger.record(
                UpdateFixtures.readings(
                    appTitle: String(localized: "This \(UIDevice.current.model)"),
                    only: fixtureSelection))
            connectionsObserver = relays.first
            return
        }
        connectionsObserver = NotificationCenter.default.addObserver(
            forName: ConnectionController.didChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in driver.keep(machines()) }
        }
        driver.keep(machines())
        Task { await driver.resume() }
    }

    /// Asks once, if it is due. Launch and every foreground call this, so returning to the app
    /// twice in a minute costs nothing.
    static func checkIfDue() {
        guard !fixtures else { return }
        Task { await driver.checkIfDue() }
    }

    static func checkAll() async {
        guard !fixtures else { return }
        await driver.checkAll(force: true)
    }

    static func check(_ component: UpdateComponent) async {
        guard !fixtures else { return }
        await driver.check(component)
    }

    static func perform(_ component: UpdateComponent) async {
        guard !fixtures else { return }
        await driver.perform(component)
    }

    static func updateEverything() async {
        guard !fixtures else { return }
        await driver.updateEverything()
    }

    static func setAutoUpdate(_ component: UpdateComponent, _ enabled: Bool) async -> String? {
        guard !fixtures else { return "Fixture launch — nothing is asked." }
        return await driver.setAutoUpdate(component, enabled)
    }

    /// This app's own answer: what the bundle says it is, against what Apple publishes for it.
    ///
    /// A simulator is not asked. Its verdict is settled by what it *is* — whatever was last built
    /// for it — so a store record could not change the answer.
    private static func checkApp() async {
        let install = AppInstallProbe.current()
        let now = Date()
        var release: AppRelease?
        var failure: String?
        if install.kind != .simulator {
            switch await AppStoreLookup.newest(now: now) {
            case .release(let value): release = value
            case .failure(let why): failure = why
            }
        }
        UpdateLedger.record(
            UpdateReadings.app(
                install: install, release: release, failure: failure,
                storeURL: AppStoreLookup.storeURL, projectURL: projectURL, checkedAt: now,
                title: String(localized: "This \(UIDevice.current.model)"),
                lastKnown: UpdateLedger.remembered(.app)),
            restamp: true)
    }

    /// The demo's servers are a story, not machines: asking them what they run would put an
    /// invented verdict in a ledger that outlives the demo.
    private static func machines() -> [UpdateDriver.Machine] {
        ConnectionController.shared.profiles
            .filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }
            .map { profile in
                UpdateDriver.Machine(
                    profileID: profile.id, title: profile.name, subtitle: subtitle(for: profile),
                    agent: profile.backend,
                    backend: {
                        await MainActor.run {
                            ConnectionController.shared.makeBackend(for: profile, policy: policy)
                        }
                    })
            }
    }

    private static func subtitle(for profile: ConnectionProfile) -> String? {
        guard let host = profile.baseURL.host, !host.isEmpty else {
            return profile.backend.displayName
        }
        return "\(profile.backend.displayName) · \(host)"
    }
}
