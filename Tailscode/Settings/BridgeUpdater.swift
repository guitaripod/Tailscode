import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Keeping one server current from the phone that talks to it — transport only.
///
/// The bridge runs on a machine the person holding the phone usually cannot open a terminal on, so
/// the app asks it to update itself and then watches. The watching is the hard part: the last step
/// of an update is a restart, so the server stops answering for a few seconds in the middle of the
/// job it was asked to do. A failed poll is therefore not a failure — the state lives on the
/// server's disk and is read back once it returns.
///
/// What any of it *means* is not decided here. Every answer, every refusal and every silence is
/// handed to `UpdateReadings` as an outcome and comes back as an `UpdateReading`, so three clients
/// cannot end up with three different words for a server that is merely too old for the route.
@MainActor
final class BridgeUpdater {
    /// The last verdict this updater published, seeded from the ledger. Nothing renders from it —
    /// every surface reads `UpdateLedger` and wakes on its `didChange` — it is only how this
    /// object knows whether it is already in the middle of an update.
    private var reading: UpdateReading?

    private let profileID: String
    private var title: String
    private var subtitle: String?
    private var backend: (any CodingAgentBackend)?
    private var updatable: (any SelfUpdatingBackend)?
    private var poll: Task<Void, Never>?

    init(profile: ConnectionProfile) {
        profileID = profile.id
        title = profile.name
        subtitle = Self.subtitle(for: profile)
        reading = UpdateLedger.remembered(.server(profileID: profile.id))
    }

    var component: UpdateComponent { .server(profileID: profileID) }

    /// Busy in the sense that asking again would disturb something. A machine holding a finished
    /// build until the turn on it ends is not that: it answers everything, it can hold for hours,
    /// and a sweep that skipped it would leave its row describing a wait that ended yesterday.
    var isWorking: Bool {
        reading?.verdict.isBusy == true && reading?.verdict.isHolding != true
    }

    func stop() { poll?.cancel() }

    /// A rename or a moved address changes what the row says about itself, not which machine it
    /// is: the ledger key is the profile id, so the reading is corrected in place.
    func adopt(_ profile: ConnectionProfile) {
        guard profile.id == profileID else { return }
        title = profile.name
        subtitle = Self.subtitle(for: profile)
    }

    func attach(_ backend: (any CodingAgentBackend)?) {
        self.backend = backend
        updatable = backend as? any SelfUpdatingBackend
    }

    /// `checkingRemote` costs the server a fetch, so an update being followed asks with it off and
    /// only an explicit refresh or a due check pays for it. `force` is how the watcher gets its
    /// answer: an ordinary check refuses to disturb an update in flight, and the check that ends
    /// one is made from inside it.
    func check(checkingRemote: Bool = true, force: Bool = false) async {
        if !force, isWorking { return }
        guard let backend else {
            publish(
                .silent(
                    String(
                        localized:
                            "There are no saved credentials for this server, so nothing here could ask it."
                    )))
            return
        }
        guard let updatable else {
            publish(
                .notSelfUpdating(
                    version: await reportedVersion(backend),
                    why: String(
                        localized:
                            "This server has no update route of its own, so nothing here can move it forward — update it the way you installed it."
                    )))
            return
        }
        for attempt in 0..<3 {
            do {
                let status = try await updatable.updateStatus(checkingRemote: checkingRemote)
                publish(.answered(status))
                if status.isRunning { watch() }
                return
            } catch AgentError.http(let code, _) where code == 404 {
                publish(.routeMissing(version: await reportedVersion(backend)))
                return
            } catch AgentError.unsupported {
                publish(.routeMissing(version: await reportedVersion(backend)))
                return
            } catch {
                if attempt < 2 { try? await Task.sleep(for: .seconds(3)) }
            }
        }
        await publishSilence(backend)
    }

    /// Asks the server to replace itself, then follows it all the way through its own restart. The
    /// call does not return until the job has settled, which is what lets a caller updating several
    /// machines take them one at a time.
    func update() async {
        guard let updatable else { return }
        AppLogger.connection.info("bridge update requested for \(profileID.prefix(8))")
        do {
            let status = try await updatable.startUpdate()
            publish(.answered(status))
            guard status.isRunning else { return }
            watch()
            if let poll { await poll.value }
        } catch {
            AppLogger.connection.error("bridge update refused: \(error.localizedDescription)")
            publish(
                .silent(
                    String(localized: "The server refused the update: \(error.localizedDescription)")
                ))
        }
    }

    /// Asks the server to load the build already sitting on its disk. Nothing is fetched and
    /// nothing is built, but the job still ends in the machine going away and coming back — and it
    /// may hold that back until the turn running on it finishes — so it is followed exactly the way
    /// an update is, by the one watcher this object has.
    func restart() async {
        guard let updatable else { return }
        AppLogger.connection.info("bridge restart requested for \(profileID.prefix(8))")
        do {
            let status = try await updatable.restartServer()
            publish(.answered(status))
            guard status.isRunning else { return }
            watch()
            if let poll { await poll.value }
        } catch {
            AppLogger.connection.error("bridge restart refused: \(error.localizedDescription)")
            publish(
                .silent(
                    String(
                        localized:
                            "The server refused the restart: \(error.localizedDescription)")))
        }
    }

    /// Turns unattended updating on or off on the machine itself, and publishes what the machine
    /// answered rather than what was asked of it. A request that never landed must leave every
    /// surface showing the policy the server last stated, so a failure writes nothing down and is
    /// handed back to the caller to report.
    func setAutoUpdate(_ enabled: Bool) async -> String? {
        guard let updatable else {
            return String(
                localized:
                    "There are no saved credentials for this server, so nothing here could ask it.")
        }
        do {
            let status = try await updatable.setAutoUpdate(enabled)
            publish(.answered(status))
            return nil
        } catch {
            AppLogger.connection.error(
                "bridge auto-update refused: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// Polls until the server reports the job finished. A restart in the middle answers nothing;
    /// that reads as "still working", not as a failure, until the job is far past any plausible
    /// build time.
    ///
    /// Past that, the watching stops but the asking does not: a machine holding a built binary
    /// until the turn on it finishes can outlast any deadline worth polling through, and it is
    /// still answering perfectly well — so the last thing the watcher does is ask once more and
    /// publish what came back, rather than declare a silence nobody heard.
    private func watch() {
        poll?.cancel()
        poll = Task { [weak self] in
            let deadline = Date().addingTimeInterval(20 * 60)
            var unanswered = 0
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(3))
                guard let self, let updatable = self.updatable else { return }
                guard let status = try? await updatable.updateStatus(checkingRemote: false) else {
                    unanswered += 1
                    if unanswered == 21, let backend = self.backend {
                        await self.publishSilence(backend)
                    }
                    continue
                }
                unanswered = 0
                // A machine holding a finished build until the turn on it ends can hold for hours,
                // and it answers everything while it does. Following it stops here; the ordinary
                // sweep keeps asking, because holding is not the kind of busy that must be left
                // alone.
                if status.isRunning, status.phase != .waiting {
                    self.publish(.answered(status))
                    continue
                }
                await self.check(checkingRemote: true, force: true)
                return
            }
            guard !Task.isCancelled, let self, let backend = self.backend else { return }
            guard let updatable = self.updatable,
                let status = try? await updatable.updateStatus(checkingRemote: false)
            else {
                await self.publishSilence(backend)
                return
            }
            self.publish(.answered(status))
        }
    }

    /// Nothing answered three times running. A health probe that *does* answer means the machine is
    /// there and the route is not — an install older than the feature — which is a different
    /// sentence from a machine that has gone away.
    private func publishSilence(_ backend: any CodingAgentBackend) async {
        if let health = try? await backend.health(), health.healthy {
            publish(.routeMissing(version: health.version))
            return
        }
        publish(
            .silent(
                String(
                    localized:
                        "This server didn't answer, so nothing here can say what it is running.")))
    }

    private func reportedVersion(_ backend: any CodingAgentBackend) async -> String? {
        guard let health = try? await backend.health() else { return nil }
        return health.version
    }

    private func publish(_ outcome: UpdateReadings.Outcome) {
        let reading = UpdateReadings.server(
            profileID: profileID, title: title, subtitle: subtitle, outcome: outcome,
            lastKnown: UpdateLedger.remembered(component))
        self.reading = reading
        UpdateLedger.record(reading)
    }

    private static func subtitle(for profile: ConnectionProfile) -> String? {
        let host = profile.baseURL.host
        guard let host, !host.isEmpty else { return profile.backend.displayName }
        return "\(profile.backend.displayName) · \(host)"
    }
}
