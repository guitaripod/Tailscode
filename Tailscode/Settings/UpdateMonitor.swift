import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// What every machine in the picture is running, kept alive across screens.
///
/// An update is a standing fact, so the asking cannot belong to the screen that shows it: the mark
/// on the Home chrome has to be right before anyone opens anything, and it has to survive a
/// relaunch. Every answer is written through `UpdateLedger`, which is what the surfaces render
/// from — this type only decides *when* to ask and hands what came back to Core to be judged.
///
/// Its own `didChange` is about the asking, not the answers: a screen that wants to spin while a
/// sweep is out listens here, and a screen that wants the verdicts listens to `UpdateLedger`.
@MainActor
enum UpdateMonitor {
    static let didChange = Notification.Name("UpdateMonitor.didChange")

    /// A server consulting its remote costs it a `git fetch` before it can answer, which is a long
    /// way past the eight seconds a health probe is given.
    private static let policy = ConnectionPolicy(
        requestTimeout: .seconds(20), resourceTimeout: .seconds(30))

    /// A debounce against two explicit refreshes landing on top of each other, and nothing more.
    /// Whether asking again is worth a `git fetch` on every server is `UpdateLedger.isDue`, which
    /// survives a relaunch — this one is process-local and would let every cold start sweep.
    private static let freshness: TimeInterval = 60

    private static let projectURL = "https://github.com/guitaripod/Tailscode"

    private static var updaters: [String: BridgeUpdater] = [:]
    private static var sweeping = false
    private static var walking = false
    private static var lastSweep: Date?
    private static var connectionsObserver: (any NSObjectProtocol)?

    /// True while answers are being collected, which is the only thing a client may draw a spinner
    /// for. An update in flight is a verdict, not a spinner, and it lives in the reading.
    static var isChecking: Bool { sweeping }

    /// True while `updateEverything` is walking the servers, so the row that started it can say so
    /// rather than looking like it did nothing.
    static var isUpdatingEverything: Bool { walking }

    /// Starts watching the profile list. A removed server that kept its row would keep its mark
    /// forever, so the ledger is pruned wherever the list changes rather than wherever it is read.
    static func start() {
        guard connectionsObserver == nil else { return }
        connectionsObserver = NotificationCenter.default.addObserver(
            forName: ConnectionController.didChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in profilesChanged() }
        }
        profilesChanged()
    }

    /// Whether anything is missing, or old enough that asking again is worth the round trip.
    ///
    /// A machine with no reading at all is asked whatever the clock says — a blank row is the one
    /// thing the ledger cannot render honestly. Past that, `UpdateLedger.isDue` decides, and it is
    /// the only thing that may: it is the six-hour policy, it survives a relaunch, and every other
    /// gate here is process-local, so leaving any of them able to say yes on their own is how a
    /// foreground costs every server a `git fetch` and Apple a round trip several times an hour.
    static func needsCheck() -> Bool {
        guard !sweeping else { return false }
        let remembered = Set(UpdateLedger.remembered().map(\.id))
        if !remembered.contains(UpdateComponent.app.key) { return true }
        if checkableProfiles().contains(where: {
            !remembered.contains(UpdateComponent.server(profileID: $0.id).key)
        }) { return true }
        guard UpdateLedger.isDue() else { return false }
        guard let lastSweep else { return true }
        return Date().timeIntervalSince(lastSweep) > freshness
    }

    /// Asks once, if it is due. The launch path and every foreground call this rather than
    /// `checkAll`, so returning to the app twice in a minute costs nothing.
    static func checkIfDue() {
        guard needsCheck() else { return }
        Task { await checkAll() }
    }

    /// Asks every machine at once, publishing each answer as it lands rather than at the end — one
    /// unreachable server must not hold up the verdict of the two that answered instantly.
    static func checkAll(force: Bool = false) async {
        guard !sweeping else { return }
        guard force || needsCheck() else { return }
        sweeping = true
        NotificationCenter.default.post(name: didChange, object: nil)
        defer {
            sweeping = false
            lastSweep = Date()
            UpdateLedger.noteCheck()
            NotificationCenter.default.post(name: didChange, object: nil)
        }
        profilesChanged()
        let profiles = checkableProfiles()
        AppLogger.connection.info("update sweep starting for \(profiles.count) server(s) + this app")
        let pending = profiles.compactMap { profile -> BridgeUpdater? in
            let updater = updater(for: profile)
            return updater.isWorking ? nil : updater
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await checkApp() }
            for updater in pending {
                group.addTask { await updater.check(checkingRemote: true) }
            }
        }
    }

    /// One machine, asked again because somebody pressed "Check again".
    static func check(_ component: UpdateComponent, force: Bool = false) async {
        switch component {
        case .app:
            await checkApp()
        case .server(let id):
            guard let profile = checkableProfiles().first(where: { $0.id == id }) else {
                UpdateLedger.forget(component)
                return
            }
            await updater(for: profile).check(checkingRemote: true, force: force)
        }
    }

    /// This app's own answer: what the bundle says it is, against what Apple publishes for it.
    ///
    /// A simulator is skipped rather than asked. Its verdict is settled by what it *is* — whatever
    /// was last built for it — so a store record could not change the answer, and spending a
    /// request to learn something unusable is how a surface teaches itself to distrust its own
    /// numbers.
    static func checkApp() async {
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
                storeURL: AppStoreLookup.storeURL, projectURL: projectURL, checkedAt: now))
    }

    /// Takes one machine's update and follows it through its own restart. The app is never one of
    /// them: the App Store installs this app, and nothing here could watch a process it replaced.
    static func update(_ component: UpdateComponent) async {
        guard case .server(let id) = component,
            let profile = checkableProfiles().first(where: { $0.id == id })
        else { return }
        await updater(for: profile).update()
    }

    /// Takes one machine's restart and follows it through, the same way and by the same watcher an
    /// update is followed: the software is already on its disk, so the whole job is the machine
    /// going quiet, going away, and answering again.
    static func restart(_ component: UpdateComponent) async {
        guard case .server(let id) = component,
            let profile = checkableProfiles().first(where: { $0.id == id })
        else { return }
        await updater(for: profile).restart()
    }

    /// Sets one machine's own update policy, and answers with why it could not be set when it could
    /// not. Nothing is recorded on the strength of the asking — the reading comes back from the
    /// server through the same ledger a check writes to, so every surface agrees with the machine.
    static func setAutoUpdate(_ component: UpdateComponent, _ enabled: Bool) async -> String? {
        guard case .server(let id) = component,
            let profile = checkableProfiles().first(where: { $0.id == id })
        else {
            return String(localized: "This server is no longer configured on this device.")
        }
        return await updater(for: profile).setAutoUpdate(enabled)
    }

    /// Every server this app can rebuild, one at a time. A bridge serialises its own fetch, so two
    /// started together queue behind each other anyway while both surfaces claim to be working —
    /// and a machine whose whole remaining job is starting a binary it has is deliberately not
    /// among them, which is why the order comes from Core rather than from every readable row.
    static func updateEverything() async {
        guard !walking else { return }
        walking = true
        NotificationCenter.default.post(name: didChange, object: nil)
        defer {
            walking = false
            NotificationCenter.default.post(name: didChange, object: nil)
        }
        for component in UpdateLedger.rollup().updateOrder {
            await update(component)
        }
    }

    private static func profilesChanged() {
        let live = checkableProfiles()
        UpdateLedger.keep([.app] + live.map { UpdateComponent.server(profileID: $0.id) })
        let ids = Set(live.map(\.id))
        for (id, updater) in updaters where !ids.contains(id) {
            updater.stop()
            updaters.removeValue(forKey: id)
        }
    }

    /// The demo's servers are a story, not machines: asking them what they run would put an
    /// invented verdict in a ledger that outlives the demo.
    private static func checkableProfiles() -> [ConnectionProfile] {
        ConnectionController.shared.profiles.filter {
            !$0.id.hasPrefix(DemoWorld.profilePrefix)
        }
    }

    private static func updater(for profile: ConnectionProfile) -> BridgeUpdater {
        let updater = updaters[profile.id] ?? make(for: profile)
        guard !updater.isWorking else { return updater }
        updater.adopt(profile)
        updater.attach(ConnectionController.shared.makeBackend(for: profile, policy: policy))
        return updater
    }

    private static func make(for profile: ConnectionProfile) -> BridgeUpdater {
        let updater = BridgeUpdater(profile: profile)
        updaters[profile.id] = updater
        return updater
    }
}
