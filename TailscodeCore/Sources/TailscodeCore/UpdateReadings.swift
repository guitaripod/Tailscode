import CodingAgentKit
import Foundation

/// Turning what a machine actually said into what the surface may claim.
///
/// This is where the honesty lives, and it lives in exactly one place on purpose: three clients
/// each deciding for themselves what a missing field meant is how the app ended up with three
/// different answers to "is this server too old or just unreachable". Every rule below exists
/// because some field can be absent for a reason that is not "no".
public enum UpdateReadings {
    /// How a check ended, from the caller's side. The client knows which of these happened; only
    /// this file decides what each is allowed to say.
    public enum Outcome: Sendable, Equatable {
        case answered(ServerUpdate)
        /// The machine answered, but has no `/update` route — an install older than the feature.
        case routeMissing(version: String?)
        /// Nothing answered.
        case silent(String)
        /// This backend has no self-update at all, whatever version it runs.
        case notSelfUpdating(version: String?, why: String)
    }

    public static func server(
        profileID: String, title: String, subtitle: String?, outcome: Outcome,
        checkedAt: Date = Date(), lastKnown: UpdateReading? = nil,
        installCommand: String = BridgeInstall.installCommand
    ) -> UpdateReading {
        switch outcome {
        case .answered(let status):
            return answered(
                profileID: profileID, title: title, subtitle: subtitle, status: status,
                checkedAt: checkedAt, installCommand: installCommand)
        case .routeMissing(let version):
            return UpdateReading(
                component: .server(profileID: profileID), title: title, subtitle: subtitle,
                installed: VersionFact(
                    text: version, provenance: .serverCheckout, readAt: checkedAt),
                verdict: .unverified(
                    .notReported(
                        Localized.text(
                            "This server is too old to say whether it has an update — the route "
                                + "was added after it was installed."))),
                invitation: .copyCommand(installCommand), checkedAt: checkedAt)
        case .silent(let why):
            return silent(
                profileID: profileID, title: title, subtitle: subtitle, why: why,
                lastKnown: lastKnown)
        case .notSelfUpdating(let version, let why):
            return UpdateReading(
                component: .server(profileID: profileID), title: title, subtitle: subtitle,
                installed: VersionFact(
                    text: version, provenance: .serverReported, readAt: checkedAt),
                verdict: .blocked(why), checkedAt: checkedAt)
        }
    }

    /// A machine that did not answer.
    ///
    /// Silence is not news about the software. An offer this device was already carrying survives
    /// it — a phone off the tailnet, a laptop asleep, a bridge busy with a turn all stop answering,
    /// and letting any of them clear the standing mark would mean the mark goes out for the exact
    /// reason it should not: nobody looked. The silence rides along as the row's own sentence
    /// instead, so the surface says both true things at once.
    private static func silent(
        profileID: String, title: String, subtitle: String?, why: String, lastKnown: UpdateReading?
    ) -> UpdateReading {
        let standing = lastKnown.map { $0.stands() } ?? false
        return UpdateReading(
            component: .server(profileID: profileID), title: title, subtitle: subtitle,
            installed: lastKnown?.installed ?? .unknown,
            available: lastKnown?.available ?? .unknown,
            verdict: standing ? lastKnown!.verdict : .unverified(.unreachable(why)),
            invitation: standing ? lastKnown?.invitation ?? .recheck : .recheck,
            manager: lastKnown?.manager, checkedAt: lastKnown?.checkedAt,
            note: standing ? why : nil, automation: lastKnown?.automation)
    }

    private static func answered(
        profileID: String, title: String, subtitle: String?, status: ServerUpdate,
        checkedAt: Date, installCommand: String
    ) -> UpdateReading {
        let installed = installedFact(status, checkedAt: checkedAt)
        let available = VersionFact(
            text: status.latestVersion ?? status.latestCommit,
            provenance: .serverCheckout, readAt: checkedAt)
        let verdict = self.verdict(
            for: status, installed: installed, available: available, checkedAt: checkedAt)
        return UpdateReading(
            component: .server(profileID: profileID), title: title, subtitle: subtitle,
            installed: installed, available: available, verdict: verdict,
            invitation: invitation(for: verdict, status: status, installCommand: installCommand),
            manager: status.manager, log: status.log, checkedAt: checkedAt,
            note: note(for: verdict, status: status),
            automation: automation(status, checkedAt: checkedAt))
    }

    /// What the machine said about keeping itself current — never what this device last asked for.
    /// A server too old to have a policy has none, and a client with none draws no switch.
    private static func automation(_ status: ServerUpdate, checkedAt: Date) -> UpdateAutomation? {
        guard let automation = status.automation else { return nil }
        return UpdateAutomation(
            enabled: automation.enabled, lastTakenAt: automation.lastTakenAt,
            lastTarget: automation.lastTarget, nextLookAt: automation.nextLookAt,
            holdingOff: automation.holdingOff, readAt: checkedAt)
    }

    /// What the machine says it would have to wait for, or nothing when it has said it is idle. A
    /// machine that has not answered the question at all is not a machine that answered "nothing".
    private static func waitingFor(_ status: ServerUpdate) -> String? {
        guard let busy = status.busy else {
            return Localized.text("That machine has not said whether anything is running on it.")
        }
        guard !busy.quiet else { return nil }
        return busy.reason
            ?? Localized.text("Something is running on that machine.")
    }

    /// The supervisor named the way a person would say it, so a promise about who brings the bridge
    /// back is a sentence rather than a field name.
    private static func supervisor(_ manager: String) -> String {
        switch manager {
        case "systemd", "launchd": return manager
        default: return Localized.text("its service")
        }
    }

    /// What the server is *running*, preferring the stamp written when its binary was built over
    /// the checkout's own `describe` — those two part company for the whole stretch between a
    /// build and a restart, and permanently on a machine with no service to restart it.
    private static func installedFact(_ status: ServerUpdate, checkedAt: Date) -> VersionFact {
        if let running = status.running, running != "unknown" {
            return VersionFact(text: running, provenance: .serverBuild, readAt: status.builtAt)
        }
        return VersionFact(
            text: status.version == "unknown" ? nil : status.version,
            provenance: status.source == nil ? .serverConstant : .serverCheckout,
            readAt: checkedAt)
    }

    private static func verdict(
        for status: ServerUpdate, installed: VersionFact, available: VersionFact, checkedAt: Date
    ) -> UpdateVerdict {
        if status.isRunning {
            return .working(UpdateProgress(step: step(for: status.phase), observedAt: checkedAt))
        }
        if status.phase == .failed {
            return .failed(
                UpdateFailure(
                    reason: status.reason
                        ?? status.log?.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? Localized.text("The server did not say why."),
                    at: status.finishedAt ?? status.startedAt))
        }
        if status.restartRequired {
            return .behind(
                UpdateOffer(
                    version: status.version, commits: nil, changes: [],
                    upstream: status.remote?.ref, canInstallHere: status.canRestart,
                    blocked: status.canRestart
                        ? nil
                        : Localized.text(
                            "A newer build is already on that machine and nothing there would "
                                + "start it again, so it has to be started by hand.")))
        }
        if status.updateAvailable {
            return .behind(
                UpdateOffer(
                    version: status.latestVersion, commits: status.behind, changes: status.changes,
                    upstream: status.remote?.ref, canInstallHere: status.canUpdate,
                    blocked: status.canUpdate ? nil : status.reason,
                    details: status.obstacle?.items ?? [], moreDetails: status.obstacle?.more ?? 0))
        }
        guard let doubt = remoteDoubt(status) else {
            return .current(checkedAt: checkedAt, against: available)
        }
        if let reason = status.reason, !status.canUpdate, !consultedRemote(status) {
            return .blocked(reason)
        }
        return .unverified(doubt)
    }

    /// Whether this answer rests on the server having actually looked. A bridge new enough to say
    /// so is believed; an older one is read from the fields it fills only when a fetch succeeded,
    /// because on that contract "nothing newer" and "never looked" are the same three nils.
    private static func consultedRemote(_ status: ServerUpdate) -> Bool {
        if let remote = status.remote { return remote.checked && remote.ok }
        return status.behind != nil || status.latestCommit != nil || status.latestVersion != nil
    }

    private static func remoteDoubt(_ status: ServerUpdate) -> UpdateDoubt? {
        guard !consultedRemote(status) else { return nil }
        if let error = status.remote?.error {
            return .notReported(error)
        }
        return .notReported(
            Localized.text(
                "The server could not reach the project to compare against — so it does not know "
                    + "whether it is current."))
    }

    private static func step(for phase: ServerUpdate.Phase) -> UpdateProgress.Step {
        switch phase {
        case .building: return .building
        case .waiting: return .waitingForQuiet
        case .restarting: return .restarting
        case .running, .idle, .succeeded, .failed: return .starting
        }
    }

    private static func invitation(
        for verdict: UpdateVerdict, status: ServerUpdate, installCommand: String
    ) -> UpdateInvitation? {
        switch verdict {
        case .behind where status.restartRequired && status.canRestart:
            // Nothing to fetch and nothing to build: the software is already there. Offering an
            // update here would rebuild a machine that only needed starting.
            return .restartHere(
                supervisor: supervisor(status.manager), waitingFor: waitingFor(status))
        case .behind(let offer):
            return offer.canInstallHere ? .installHere : .copyCommand(installCommand)
        case .failed:
            return status.canUpdate ? .installHere : .copyCommand(installCommand)
        case .blocked:
            return .copyCommand(installCommand)
        case .unverified(.unreachable):
            return .recheck
        case .unverified:
            return .copyCommand(installCommand)
        case .current, .ahead, .working:
            return nil
        }
    }

    /// A server that is current but could not update itself is worth saying so *before* the day it
    /// has something to install.
    private static func note(for verdict: UpdateVerdict, status: ServerUpdate) -> String? {
        switch verdict {
        case .current where !status.canUpdate:
            return status.reason
        case .behind where status.canUpdate && status.manager == "manual":
            return status.reason
        default:
            return nil
        }
    }

    /// This app, on this machine.
    ///
    /// - Parameters:
    ///   - obstacle: what stands between this build and a press, when the client knows something
    ///     the checkout cannot say — a bundle whose rebuild would overwrite the executable it is
    ///     running is a perfectly clean checkout with a perfectly good toolchain, and inventing a
    ///     missing toolchain to produce a refusal would be a false sentence in service of a true
    ///     verdict.
    ///   - command: the line that actually does the job on this platform, for the same reason: a
    ///     `git pull` finishes the job on a checkout the app installs itself from, and does not
    ///     come close to it for an app bundle.
    public static func app(
        install: AppInstall, release: AppRelease?, checkout: CheckoutState? = nil,
        running: SourceUpdatePlan.State? = nil, failure: String? = nil, obstacle: String? = nil,
        command: String? = nil, storeURL: String? = nil, projectURL: String? = nil,
        checkedAt: Date? = nil, title: String = Localized.text("Tailscode"), subtitle: String? = nil,
        note: String? = nil
    ) -> UpdateReading {
        let verdict = appVerdict(
            install: install, release: release, checkout: checkout, running: running,
            failure: failure, obstacle: obstacle, checkedAt: checkedAt)
        return UpdateReading(
            component: .app, title: title, subtitle: subtitle ?? install.kind.sentence,
            installed: install.fact,
            available: release?.fact ?? checkoutFact(checkout, checkedAt: checkedAt),
            verdict: verdict,
            invitation: appInvitation(
                for: verdict, install: install, checkout: checkout, command: command,
                storeURL: storeURL, projectURL: projectURL, releaseURL: release?.url),
            checkedAt: checkedAt,
            note: appNote(install: install, verdict: verdict, note: note))
    }

    /// What to do is worth saying only where there is something to do: a copy a package manager
    /// owns spells out its whole procedure beside an offer, and stays quiet while it is current.
    private static func appNote(install: AppInstall, verdict: UpdateVerdict, note: String?)
        -> String?
    {
        let build = install.build.map { Localized.text("Build %@.", $0) }
        switch verdict {
        case .behind, .failed:
            let joined = [build, note].compactMap { $0 }.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        default:
            return build
        }
    }

    private static func checkoutFact(_ checkout: CheckoutState?, checkedAt: Date?) -> VersionFact {
        guard let checkout, checkout.behind > 0 else { return .unknown }
        return VersionFact(
            text: Localized.text("%@ commits newer", String(checkout.behind)),
            provenance: .sourceCheckout, readAt: checkedAt)
    }

    private static func appVerdict(
        install: AppInstall, release: AppRelease?, checkout: CheckoutState?,
        running: SourceUpdatePlan.State?, failure: String?, obstacle: String?, checkedAt: Date?
    ) -> UpdateVerdict {
        if let running {
            switch running.phase {
            case .running, .building, .installing, .restarting:
                return .working(UpdateProgress(step: running.step, observedAt: running.startedAt))
            case .failed:
                return .failed(
                    UpdateFailure(
                        reason: running.message ?? Localized.text("The update did not finish."),
                        at: running.finishedAt ?? running.startedAt))
            case .succeeded:
                break
            }
        }
        switch install.kind {
        case .simulator:
            return .blocked(Localized.text("A simulator runs whatever was last built for it."))
        case .developerBuild:
            return .blocked(
                Localized.text(
                    "This is running straight out of a build directory — install it before asking "
                        + "it to update itself."))
        case .appStore, .testFlight, .sourceBuild, .standalone, .packaged, .unknown:
            break
        }
        if let checkout {
            let blocker = obstacle ?? checkout.blocker
            if checkout.behind > 0 {
                return .behind(
                    UpdateOffer(
                        version: nil, commits: checkout.behind, changes: checkout.changes,
                        upstream: checkout.upstream, canInstallHere: blocker == nil,
                        blocked: blocker))
            }
            if let blocker { return .blocked(blocker) }
            guard let checkedAt else { return .unverified(.neverChecked) }
            return .current(
                checkedAt: checkedAt,
                against: VersionFact(
                    text: checkout.upstream, provenance: .sourceCheckout, readAt: checkedAt))
        }
        guard let release else {
            if let failure { return .unverified(.unreachable(failure)) }
            if install.kind == .packaged {
                return .unverified(
                    .notReported(
                        install.packager.map {
                            Localized.text("%@ is what says when a newer one exists.", $0)
                        } ?? Localized.text("The package manager that installed this says when a "
                            + "newer one exists.")))
            }
            if install.kind == .sourceBuild || install.kind == .standalone {
                return .unverified(
                    .notReported(
                        Localized.text("Nothing on this machine can say what the newest build is.")))
            }
            return .unverified(.neverChecked)
        }
        switch VersionComparison.between(installed: install.version, available: release.version) {
        case .same:
            guard let checkedAt = checkedAt ?? release.readAt else {
                return .unverified(.neverChecked)
            }
            return .current(checkedAt: checkedAt, against: release.fact)
        case .newerAvailable:
            return .behind(
                UpdateOffer(
                    version: release.version, commits: nil,
                    changes: release.notes.map(noteLines) ?? [], canInstallHere: false))
        case .installedIsNewer:
            return .ahead(ahead(for: install, release: release))
        case .notComparable:
            return .unverified(
                .notComparable(
                    Localized.text(
                        "This build is stamped %@ and the newest published is %@, which cannot be "
                            + "ranked against each other.",
                        install.version ?? Localized.text("nothing"), release.version)))
        }
    }

    /// Being ahead is three different facts wearing one number, and the wrong one is a small lie
    /// told confidently: a phone whose storefront record simply has not propagated is not running
    /// "a build of its own".
    private static func ahead(for install: AppInstall, release: AppRelease) -> AheadReason {
        switch install.kind {
        case .testFlight: return .testFlight(published: release.version)
        case .appStore, .packaged: return .storeLagging(published: release.version)
        case .sourceBuild, .developerBuild, .standalone, .simulator, .unknown:
            return .ownBuild(published: release.version)
        }
    }

    private static func noteLines(_ notes: String) -> [String] {
        notes.split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*")) }
            .filter { !$0.isEmpty }
    }

    private static func appInvitation(
        for verdict: UpdateVerdict, install: AppInstall, checkout: CheckoutState?,
        command: String?, storeURL: String?, projectURL: String?, releaseURL: String? = nil
    ) -> UpdateInvitation? {
        switch verdict {
        case .behind(let offer) where offer.canInstallHere && command == nil
            && install.kind.installsItself:
            return .installHere
        case .behind, .failed:
            if let command { return .copyCommand(command) }
            if let checkout, checkout.blocker == nil, install.kind.installsItself {
                return .installHere
            }
            if let checkout { return .copyCommand("cd \(checkout.path) && git pull") }
            if install.kind == .testFlight { return projectURL.map(UpdateInvitation.openPage) }
            if let storeURL { return .openStore(url: storeURL) }
            return (releaseURL ?? projectURL).map(UpdateInvitation.openPage)
        case .unverified(.unreachable), .unverified(.neverChecked):
            return .recheck
        case .unverified, .blocked:
            return projectURL.map(UpdateInvitation.openPage)
        case .current, .ahead, .working:
            return nil
        }
    }
}

extension UpdateInvitation {
    fileprivate static func openPage(_ url: String) -> UpdateInvitation { .openPage(url: url) }
}
