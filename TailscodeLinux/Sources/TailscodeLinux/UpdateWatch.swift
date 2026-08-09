import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The check nobody asked for, which is the point of it.
///
/// An update is a standing fact rather than a notification, so nothing here waits for somebody to
/// open a screen: every machine in the picture is asked on its own slow cadence and every answer is
/// written into ``UpdateLedger``, which is what the sidebar's mark and the update centre both read.
/// The mark is therefore on screen before any check of this launch has come back, and it survives
/// the app being closed.
///
/// Nothing in this file decides what an answer *means*. `UpdateReadings` owns that, and the reason
/// is the failure this whole surface exists to prevent: a server that never reached the project, one
/// too old for the route, and one that answered nothing are three different states, and a client
/// that classified them itself would eventually call one of them "up to date".
enum UpdateWatch {
    private static let projectURL = "https://github.com/guitaripod/Tailscode"

    /// How long a launch waits before asking again, and how quickly it retries while the server list
    /// has not been read yet. `UpdateLedger.isDue` is the real gate; this is only how often the
    /// question is put to it.
    private static let cadence = 900
    private static let unseeded = 15

    private final class Watch: @unchecked Sendable {
        var loop: Task<Void, Never>?
        var following: [String: Task<Void, Never>] = [:]
        var itself: Task<Void, Never>?
        var relaunch: (@Sendable () -> Void)?
    }

    private static let watch = Watch()

    /// - Parameter relaunch: what to do when this app's own update reaches the point of replacing
    ///   the running process. It is the window's business, not this file's, because everything typed
    ///   into a composer has to be written down before the process goes away.
    static func start(relaunch: @escaping @Sendable () -> Void) {
        watch.relaunch = relaunch
        guard watch.loop == nil else { return }
        resumeSelfUpdate()
        resumeServerUpdates()
        watch.loop = Task {
            await recordApp(fetching: false)
            while !Task.isCancelled {
                var settled = true
                if UpdateLedger.isDue() {
                    let profiles = await ServerDirectory.shared.profiles()
                    if profiles.isEmpty {
                        settled = false
                    } else {
                        await sweep(profiles)
                    }
                }
                try? await Task.sleep(for: .seconds(settled ? cadence : unseeded))
            }
        }
    }

    /// Everything asked again, because somebody asked. The only other thing that consults a remote
    /// is a check that has come due — a fetch costs every server a network round trip, and an app
    /// that spent one on every glance would be charging the fleet for a screen being opened.
    static func refresh() {
        Task {
            let profiles = await ServerDirectory.shared.profiles()
            await sweep(profiles)
        }
    }

    private static func sweep(_ profiles: [ConnectionProfile]) async {
        for profile in profiles where !profile.id.hasPrefix(DemoWorld.profilePrefix) {
            _ = await ask(profile, checkingRemote: true)
        }
        await recordApp(fetching: true)
        UpdateLedger.noteCheck()
    }

    /// Keeps only the machines still configured. A server somebody removed would otherwise keep its
    /// row, and its offer would hold the mark up forever over a machine this app no longer talks to.
    static func keep(_ profiles: [ConnectionProfile]) {
        let servers = profiles.filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }
            .map { UpdateComponent.server(profileID: $0.id) }
        UpdateLedger.keep([.app] + servers)
    }

    /// One server, asked and remembered. The three ways a check can end are handed to Core as an
    /// outcome rather than as words: an unanswered `/update` means a bridge too old for the route
    /// only when the machine answers `/health`, and telling someone to reinstall a server that is
    /// merely asleep would be worse than saying nothing.
    @discardableResult
    static func ask(_ profile: ConnectionProfile, checkingRemote: Bool) async -> UpdateReading {
        let reading = UpdateReadings.server(
            profileID: profile.id, title: profile.name, subtitle: Self.subtitle(profile),
            outcome: await outcome(for: profile, checkingRemote: checkingRemote),
            checkedAt: Date(),
            lastKnown: UpdateLedger.remembered(.server(profileID: profile.id)))
        UpdateLedger.record(reading)
        return reading
    }

    private static func subtitle(_ profile: ConnectionProfile) -> String {
        "\(ServerLabel.agent(profile.backend)) · \(ServerLabel.address(profile))"
    }

    private static func outcome(for profile: ConnectionProfile, checkingRemote: Bool) async
        -> UpdateReadings.Outcome
    {
        guard let backend = await ServerDirectory.shared.backend(for: profile) else {
            return .silent(
                Localized.text(
                    "Nothing here could open a connection to %@.", ServerLabel.address(profile)))
        }
        guard let updating = backend as? any SelfUpdatingBackend else {
            let health = await within(10) { try? await backend.health() }
            return .notSelfUpdating(
                version: health?.version,
                why: Localized.text(
                    "%@ has no update route of its own — it is updated the way it was installed on "
                        + "that machine.", ServerLabel.agent(profile.backend)))
        }
        if let status = await within(
            20, { try? await updating.updateStatus(checkingRemote: checkingRemote) })
        {
            return .answered(status)
        }
        if let health = await within(10, { try? await backend.health() }) {
            return .routeMissing(version: health.version)
        }
        return .silent(
            Localized.text(
                "Twenty seconds and nothing came back from %@ — asleep, or busy with a turn.",
                ServerLabel.address(profile)))
    }

    /// One press on a server, followed to the end rather than to the first heartbeat: the old
    /// process keeps answering `/health` through the whole fetch and build, so the loop watches the
    /// update's own phase and treats a refused connection as the restart doing its job. Only a
    /// settled phase — or ten minutes of silence — ends it, and the last word is a fresh check
    /// against the remote, so "up to date" afterwards is a comparison rather than a hope.
    static func updateServer(
        _ profile: ConnectionProfile, onReading: @escaping @Sendable (UpdateReading) -> Void
    ) {
        let id = profile.id
        watch.following[id]?.cancel()
        watch.following[id] = Task {
            let settled = await run(profile, onReading: onReading)
            UpdateLedger.record(settled)
            Gtk.onMain { onReading(settled) }
        }
    }

    /// The walk itself, which answers with the reading that ends it whatever happens — a server that
    /// cannot be reached at all, a phase that settled, or ten minutes of silence. A caller waiting
    /// on one machine before starting the next needs a last word it can rely on arriving.
    private static func run(
        _ profile: ConnectionProfile, onReading: @escaping @Sendable (UpdateReading) -> Void
    ) async -> UpdateReading {
        guard
            let backend = await ServerDirectory.shared.backend(for: profile)
                as? any SelfUpdatingBackend
        else {
            return silent(
                profile,
                Localized.text(
                    "Nothing here could open a connection to %@.", ServerLabel.address(profile)))
        }
        if let started = try? await backend.startUpdate() {
            publish(started, for: profile, onReading: onReading)
        }
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(3))
            guard let status = try? await backend.updateStatus(checkingRemote: false) else {
                continue
            }
            publish(status, for: profile, onReading: onReading)
            guard !status.isRunning else { continue }
            return await ask(profile, checkingRemote: true)
        }
        return silent(
            profile,
            Localized.text(
                "The update did not settle within ten minutes — check that machine over ssh."))
    }

    private static func silent(_ profile: ConnectionProfile, _ why: String) -> UpdateReading {
        UpdateReadings.server(
            profileID: profile.id, title: profile.name, subtitle: Self.subtitle(profile),
            outcome: .silent(why),
            lastKnown: UpdateLedger.remembered(.server(profileID: profile.id)))
    }

    private static func publish(
        _ status: ServerUpdate, for profile: ConnectionProfile,
        onReading: @escaping @Sendable (UpdateReading) -> Void
    ) {
        let reading = UpdateReadings.server(
            profileID: profile.id, title: profile.name, subtitle: Self.subtitle(profile),
            outcome: .answered(status), checkedAt: Date())
        UpdateLedger.record(reading)
        Gtk.onMain { onReading(reading) }
    }

    /// One machine asked again, because somebody pressed the button on its row.
    static func recheck(_ component: UpdateComponent) {
        switch component {
        case .app:
            Task { await recordApp(fetching: true) }
        case .server(let profileID):
            Task {
                guard
                    let profile = await ServerDirectory.shared.profiles()
                        .first(where: { $0.id == profileID })
                else { return }
                await ask(profile, checkingRemote: true)
            }
        }
    }

    /// This app, on this machine. Local and cheap unless `fetching`, which is the only part of the
    /// reading that costs anything or goes stale — so a launch that is not due carries the moment of
    /// the last fetch forward rather than claiming a fresh one, and lets `UpdateFreshness` decide
    /// when that stops being worth believing.
    static func appReading(fetching: Bool) -> UpdateReading {
        let install = LinuxAppInstall.read()
        let running = LinuxAppInstall.updateState()
        let checkout = LinuxAppInstall.checkout(of: install, fetching: fetching)
        let obstacle = LinuxAppInstall.obstacle(for: install)
        return UpdateReadings.app(
            install: install, release: nil, checkout: checkout, running: running,
            obstacle: obstacle, command: handCommand(obstacle: obstacle, checkout: checkout),
            projectURL: projectURL,
            checkedAt: fetching ? Date() : UpdateLedger.remembered(.app)?.checkedAt,
            title: Localized.text("Tailscode on this machine"))
    }

    /// The line to hand over, and only for the rows where no press here can finish the job — a
    /// command offered beside a button that works is Core's cue to stop offering the button, and
    /// this desk really can update itself.
    private static func handCommand(obstacle: String?, checkout: CheckoutState?) -> String? {
        guard let checkout, obstacle != nil || checkout.blocker != nil else { return nil }
        return LinuxAppInstall.handCommand(of: checkout)
    }

    private static func recordApp(fetching: Bool) async {
        let reading = await Task.detached { appReading(fetching: fetching) }.value
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

    /// Every machine the ledger last saw mid-update, asked again on the way up.
    ///
    /// A remembered `working` is believed for as long as a cold Swift build could honestly take,
    /// which is what stops a restart from reading a live build as an abandoned one — and it means
    /// nothing on its own ever settles a row this process was not here to watch. So the rows that
    /// still claim to be busy are re-asked once at launch: an update that finished while the app was
    /// closed reads back as finished, and the mark stops turning over work nobody is following.
    private static func resumeServerUpdates() {
        let busy = UpdateLedger.rollup().busy.compactMap { reading -> String? in
            guard case .server(let profileID) = reading.component else { return nil }
            return profileID
        }
        guard !busy.isEmpty else { return }
        Task {
            for profile in await ServerDirectory.shared.profiles() where busy.contains(profile.id) {
                await ask(profile, checkingRemote: true)
            }
        }
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

    /// Nothing here may wait forever. A machine that is merely busy answers late, and a bridge in
    /// the middle of a turn may not answer at all until it finishes — so every ask is raced against
    /// a deadline and its silence becomes a state with words rather than a row that never resolves.
    private static func within<T: Sendable>(
        _ seconds: Int, _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
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
