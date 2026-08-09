import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The check behind the standing mark: every machine in the picture asked on its own slow cadence,
/// every answer written through `UpdateLedger` so the mark is on screen before the next launch has
/// asked anybody anything.
///
/// The classification is never this file's. It decides only which of the four things happened —
/// the server answered, it is too old to have the route, it answered nothing, or it has no
/// self-update at all — and `UpdateReadings` decides what each of those is allowed to say. The
/// distinction that matters most is between a bridge too old to answer and a machine that is
/// merely asleep: telling somebody to reinstall a server that is napping is worse than saying
/// nothing.
@MainActor
final class MacUpdateWatch {
    static let shared = MacUpdateWatch()

    /// How often the loop wakes to *ask whether* a check is due. Whether it is remains
    /// `UpdateFreshness`'s answer, never this timer's: a Mac that slept for a day checks when it
    /// wakes rather than at the next multiple of half an hour.
    private static let wake: Duration = .seconds(1800)
    private static let followDeadline: TimeInterval = 600
    private static let followInterval: Duration = .seconds(3)

    private var loop: Task<Void, Never>?
    private var sweeping = false
    /// Profiles whose update this window is following through its restart, so a second press
    /// cannot start a build on top of one already running.
    private var installing: Set<String> = []

    private init() {}

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if UpdateLedger.isDue() { await self.sweep(checkingRemote: true) }
                try? await Task.sleep(for: Self.wake)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One pass over this app and every configured server. `checkingRemote` is what it costs: it
    /// makes each bridge fetch, so it is spent on a due check or somebody actually asking, and
    /// never on the poll that follows an update through its restart.
    ///
    /// Each answer is recorded as it lands rather than at the end, so a machine that takes fifteen
    /// seconds to reply does not hold the whole surface blank.
    func sweep(checkingRemote: Bool) async {
        guard !sweeping else { return }
        sweeping = true
        defer { sweeping = false }
        let profiles = Self.checkableProfiles()
        let components: [UpdateComponent] = [.app] + profiles.map { .server(profileID: $0.id) }
        UpdateLedger.keep(components)
        await checkApp()
        for profile in profiles {
            await check(profile, checkingRemote: checkingRemote)
        }
        UpdateLedger.noteCheck()
    }

    @discardableResult
    func checkApp() async -> UpdateReading {
        let reading = await Task.detached(priority: .utility) { MacAppInstall.reading() }.value
        UpdateLedger.record(reading)
        return reading
    }

    @discardableResult
    func check(_ profile: ConnectionProfile, checkingRemote: Bool) async -> UpdateReading {
        let reading = await Self.reading(for: profile, checkingRemote: checkingRemote)
        UpdateLedger.record(reading)
        return reading
    }

    func recheck(_ component: UpdateComponent) async {
        switch component {
        case .app:
            await checkApp()
        case .server(let profileID):
            guard let profile = Self.profile(profileID) else { return }
            await check(profile, checkingRemote: true)
        }
    }

    /// A server removed must stop holding the mark up, and one just added is worth asking about
    /// before the next due check comes round.
    func noteProfilesChanged() {
        let profiles = Self.checkableProfiles()
        let components: [UpdateComponent] = [.app] + profiles.map { .server(profileID: $0.id) }
        UpdateLedger.keep(components)
        Task {
            for profile in profiles
            where UpdateLedger.remembered(.server(profileID: profile.id)) == nil {
                await self.check(profile, checkingRemote: true)
            }
        }
    }

    func isInstalling(_ component: UpdateComponent) -> Bool {
        guard case .server(let profileID) = component else { return false }
        return installing.contains(profileID)
    }

    /// An update followed to the end rather than to the first heartbeat.
    ///
    /// The old process keeps answering `/health` through the whole fetch and build, and then stops
    /// answering anything at all while it restarts — so a refused connection here is the restart
    /// doing its job, not a failure, and the loop simply asks again. Only a settled phase, or ten
    /// minutes of silence, ends it.
    ///
    /// The last word is a fresh comparison against the remote rather than the phase that settled.
    /// The poll asks with `checkingRemote: false` throughout — a server mid-build must not be made
    /// to fetch every three seconds — and a machine whose whole update was watched with that off
    /// would come to rest on "Can't say" about the very build it just installed.
    func install(
        _ component: UpdateComponent, onStep: (@MainActor (UpdateReading) -> Void)? = nil
    ) async {
        guard case .server(let profileID) = component, let profile = Self.profile(profileID),
            let backend = ServerDirectory.shared.backend(for: profile) as? any SelfUpdatingBackend,
            installing.insert(profileID).inserted
        else { return }
        defer { installing.remove(profileID) }
        if let started = try? await backend.startUpdate() {
            record(.answered(started), for: profile, onStep: onStep)
        }
        let deadline = Date().addingTimeInterval(Self.followDeadline)
        while Date() < deadline {
            try? await Task.sleep(for: Self.followInterval)
            guard let status = try? await backend.updateStatus(checkingRemote: false) else {
                continue
            }
            record(.answered(status), for: profile, onStep: onStep)
            guard status.isRunning else {
                onStep?(await check(profile, checkingRemote: true))
                return
            }
        }
        record(
            .silent(
                Localized.text(
                    "The update did not settle within ten minutes — check %@ over ssh.",
                    profile.name)),
            for: profile, onStep: onStep)
    }

    /// One at a time, in the order Core gives them: a bridge serialises its own fetch, and two
    /// updates started together queue behind each other anyway while both surfaces claim to be
    /// working. This app is never in that order — updating it would replace the process doing the
    /// watching.
    func installEverything() async {
        for component in UpdateLedger.rollup().updateOrder {
            await install(component)
        }
    }

    @discardableResult
    private func record(
        _ outcome: UpdateReadings.Outcome, for profile: ConnectionProfile,
        onStep: (@MainActor (UpdateReading) -> Void)?
    ) -> UpdateReading {
        let reading = UpdateReadings.server(
            profileID: profile.id, title: profile.name, subtitle: Self.subtitle(for: profile),
            outcome: outcome, lastKnown: UpdateLedger.remembered(.server(profileID: profile.id)))
        UpdateLedger.record(reading)
        onStep?(reading)
        return reading
    }

    private static func reading(for profile: ConnectionProfile, checkingRemote: Bool) async
        -> UpdateReading
    {
        UpdateReadings.server(
            profileID: profile.id, title: profile.name, subtitle: subtitle(for: profile),
            outcome: await outcome(for: profile, checkingRemote: checkingRemote),
            lastKnown: UpdateLedger.remembered(.server(profileID: profile.id)))
    }

    private static func outcome(for profile: ConnectionProfile, checkingRemote: Bool) async
        -> UpdateReadings.Outcome
    {
        guard let backend = ServerDirectory.shared.backend(for: profile) else {
            return .silent(
                Localized.text("This Mac holds no way to reach %@.", profile.name))
        }
        guard let updating = backend as? any SelfUpdatingBackend else {
            guard let health = try? await ServerProbe.health(of: backend) else {
                return .silent(Localized.text("%@ did not answer.", profile.name))
            }
            return .notSelfUpdating(
                version: health.version,
                why: Localized.text(
                    "%@ does not update itself — whatever installed it on that machine is what "
                        + "replaces it.", ServerLabel.agent(profile.backend)))
        }
        do {
            return .answered(try await updating.updateStatus(checkingRemote: checkingRemote))
        } catch {
            let health = try? await ServerProbe.health(of: backend)
            guard health != nil || isMissingRoute(error) else {
                return .silent(why(error, on: profile))
            }
            return .routeMissing(version: health?.version)
        }
    }

    /// A bridge older than the route answers 404 — or, on an install old enough to predate the
    /// whole feature, says outright that it does not know what is being asked of it.
    private static func isMissingRoute(_ error: any Error) -> Bool {
        guard let agent = error as? AgentError else { return false }
        switch agent {
        case .http(let status, _): return status == 404
        case .unsupported: return true
        case .decoding, .invalidURL, .server, .connection: return false
        }
    }

    private static func why(_ error: any Error, on profile: ConnectionProfile) -> String {
        let detail = (error as? AgentError)?.errorDescription ?? error.localizedDescription
        return Localized.text("%@ did not answer — %@", profile.name, detail)
    }

    private static func subtitle(for profile: ConnectionProfile) -> String {
        "\(ServerLabel.agent(profile.backend)) · \(ServerLabel.address(profile))"
    }

    private static func profile(_ id: String) -> ConnectionProfile? {
        checkableProfiles().first { $0.id == id }
    }

    /// The demo's servers are a story, not machines: asking one what it runs would write an
    /// invented verdict into a ledger that outlives the demo, and the mark it held up would be
    /// about a machine that never existed.
    private static func checkableProfiles() -> [ConnectionProfile] {
        ServerDirectory.shared.profiles.filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }
    }
}
