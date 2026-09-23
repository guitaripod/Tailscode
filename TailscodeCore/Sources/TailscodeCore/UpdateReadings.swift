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
        profileID: String, title: String, subtitle: String?, product: String? = nil,
        outcome: Outcome, checkedAt: Date = Date(), lastKnown: UpdateReading? = nil,
        installCommand: String = BridgeInstall.installCommand
    ) -> UpdateReading {
        switch outcome {
        case .answered(let status):
            return answered(
                profileID: profileID, title: title, subtitle: subtitle, product: product,
                status: status, checkedAt: checkedAt, lastKnown: lastKnown,
                installCommand: installCommand)
        case .routeMissing(let version):
            return UpdateReading(
                component: .server(profileID: profileID), title: title, subtitle: subtitle,
                installed: VersionFact(
                    text: version, provenance: .serverCheckout, readAt: checkedAt),
                verdict: .unverified(
                    .notReported(
                        Localized.text(
                            "This version is too old to update itself from here. Run the command "
                                + "on that machine once — after that, updates happen from this app."
                        ))),
                invitation: .copyCommand(installCommand), checkedAt: checkedAt, product: product,
                lastOutcome: lastKnown?.lastOutcome)
        case .silent(let why):
            return silent(
                profileID: profileID, title: title, subtitle: subtitle, product: product, why: why,
                lastKnown: lastKnown)
        case .notSelfUpdating(let version, let why):
            return UpdateReading(
                component: .server(profileID: profileID), title: title, subtitle: subtitle,
                installed: VersionFact(
                    text: version, provenance: .serverReported, readAt: checkedAt),
                verdict: .blocked(why), invitation: .copyCommand(installCommand),
                checkedAt: checkedAt, product: product)
        }
    }

    /// The moment of the press, before the machine has said anything about it.
    ///
    /// A press that changes nothing on screen until a round trip comes back reads as a press that
    /// did nothing, and gets pressed again. So the card moves to its first step at once — asking —
    /// carrying the version it set out for and what that version brings, and the machine's own
    /// answer replaces it a moment later. If the process dies here, the next launch finds a job
    /// under way and asks the machine how it really stands.
    public static func requesting(
        _ reading: UpdateReading, kind: UpdateProgress.Kind, at now: Date = Date()
    ) -> UpdateReading {
        let offer = reading.verdict.offer
        let progress = UpdateProgress(
            step: .requesting, observedAt: now, kind: kind,
            target: offer?.version ?? reading.available.text, startedAt: now,
            notes: offer?.whatsNew ?? reading.verdict.failureNotes)
        return reading.with(verdict: .working(progress), invitation: .some(nil))
    }

    /// A machine that stopped answering while this device followed a job on it. The job goes on
    /// being what it was — it may well still be building — and the card says the line went quiet.
    public static func lostContact(_ reading: UpdateReading, since: Date) -> UpdateReading {
        guard let progress = reading.verdict.progress, progress.lostContactSince == nil else {
            return reading
        }
        return reading.with(verdict: .working(progress.with(lostContactSince: .some(since))))
    }

    /// A machine that stopped answering the moment it was asked to load the build it was waiting to
    /// load. A bridge that has begun its restart refuses every connection until the new process is
    /// listening, so the silence is the restart itself — the same thing a refused connection means
    /// in the middle of a job this device is following — and it is followed back rather than
    /// reported as a press that never arrived.
    public static func restartUnderWay(_ reading: UpdateReading, at now: Date = Date())
        -> UpdateReading
    {
        guard let progress = reading.verdict.progress else { return reading }
        return reading.with(
            verdict: .working(
                progress.with(
                    step: .restarting, observedAt: .some(now), lostContactSince: .some(nil))))
    }

    /// A machine back from its restart, being asked what it landed on.
    public static func settling(_ reading: UpdateReading, at now: Date = Date()) -> UpdateReading {
        guard let progress = reading.verdict.progress else { return reading }
        guard progress.step != .settling else { return reading }
        return reading.with(
            verdict: .working(
                progress.with(
                    step: .settling, observedAt: .some(now), lostContactSince: .some(nil))))
    }

    /// A machine that did not answer.
    ///
    /// Silence is not news about the software. An offer this device was already carrying survives
    /// it — a phone off the tailnet, a laptop asleep, a bridge busy with a turn all stop answering,
    /// and letting any of them clear the standing mark would mean the mark goes out for the exact
    /// reason it should not: nobody looked. The silence rides along as the row's own sentence
    /// instead, so the surface says both true things at once.
    private static func silent(
        profileID: String, title: String, subtitle: String?, product: String?, why: String,
        lastKnown: UpdateReading?
    ) -> UpdateReading {
        let standing = lastKnown.map { $0.stands() } ?? false
        return UpdateReading(
            component: .server(profileID: profileID), title: title, subtitle: subtitle,
            installed: lastKnown?.installed ?? .unknown,
            available: lastKnown?.available ?? .unknown,
            verdict: standing ? lastKnown!.verdict : .unverified(.unreachable(why)),
            invitation: standing ? lastKnown?.invitation ?? .recheck : .recheck,
            manager: lastKnown?.manager, checkedAt: lastKnown?.checkedAt,
            note: standing ? why : nil, automation: lastKnown?.automation,
            product: product ?? lastKnown?.product, lastOutcome: lastKnown?.lastOutcome)
    }

    private static func answered(
        profileID: String, title: String, subtitle: String?, product: String?,
        status: ServerUpdate, checkedAt: Date, lastKnown: UpdateReading?, installCommand: String
    ) -> UpdateReading {
        let installed = installedFact(status, checkedAt: checkedAt)
        let available = VersionFact(
            text: status.release?.version.flatMap { tag in
                (status.release?.commitsPastTag ?? 0) == 0 ? tag : nil
            } ?? status.latestVersion ?? status.latestCommit,
            provenance: .serverCheckout, readAt: checkedAt)
        let verdict = self.verdict(
            for: status, installed: installed, available: available, checkedAt: checkedAt,
            lastKnown: lastKnown)
        return UpdateReading(
            component: .server(profileID: profileID), title: title, subtitle: subtitle,
            installed: installed, available: available, verdict: verdict,
            invitation: invitation(for: verdict, status: status, installCommand: installCommand),
            manager: status.manager, log: status.log, checkedAt: checkedAt,
            note: note(for: verdict, status: status),
            automation: automation(status, checkedAt: checkedAt),
            product: product ?? lastKnown?.product,
            lastOutcome: outcome(of: status, lastKnown: lastKnown) ?? lastKnown?.lastOutcome)
    }

    /// How the machine's last job ended, with what it brought carried across from whatever this
    /// device last knew was on offer — the machine reports the job, and the notes were read before
    /// it started.
    private static func outcome(of status: ServerUpdate, lastKnown: UpdateReading?)
        -> UpdateOutcome?
    {
        guard let job = status.job, job.isFinished else { return nil }
        let result: UpdateOutcome.Result
        switch job.outcome {
        case .succeeded: result = .succeeded
        case .failed: result = .failed
        case .deferred: result = .deferred
        case nil:
            guard job.step == .done else { return nil }
            result = .succeeded
        }
        let notes: [ReleaseNote]
        if let known = lastKnown?.lastOutcome, known.jobID == job.id {
            notes = known.notes
        } else {
            notes =
                lastKnown?.verdict.progress?.notes ?? lastKnown?.verdict.offer?.whatsNew ?? []
        }
        return UpdateOutcome(
            result: result, kind: job.kind == .restart ? .serverRestart : .serverUpdate,
            automatic: job.automatic, from: job.from,
            to: result == .succeeded ? job.landed ?? job.target : job.target,
            reason: job.reason, at: job.finishedAt, jobID: job.id, notes: notes)
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
        for status: ServerUpdate, installed: VersionFact, available: VersionFact, checkedAt: Date,
        lastKnown: UpdateReading?
    ) -> UpdateVerdict {
        if status.isRunning {
            return .working(progress(status, checkedAt: checkedAt, lastKnown: lastKnown))
        }
        if status.phase == .failed {
            let job = status.job.flatMap { $0.outcome == .failed ? $0 : nil }
            return .failed(
                UpdateFailure(
                    reason: job?.reason ?? status.reason
                        ?? status.log?.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? Localized.text("The server did not say why."),
                    at: job?.finishedAt ?? status.finishedAt ?? status.startedAt,
                    step: job?.step.map(step(for:)),
                    kind: job.map { $0.kind == .restart ? .serverRestart : .serverUpdate },
                    notes: status.updateAvailable
                        ? (status.release?.notes ?? []).map(ReleaseNote.init)
                            + (status.release == nil ? ReleaseNote.fromSubjects(status.changes) : [])
                        : carriedNotes(lastKnown)))
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
                    version: available.text ?? status.latestVersion, commits: status.behind,
                    changes: status.changes, upstream: status.remote?.ref,
                    canInstallHere: status.canUpdate,
                    blocked: status.canUpdate ? nil : status.reason,
                    details: status.obstacle?.items ?? [], moreDetails: status.obstacle?.more ?? 0,
                    notes: (status.release?.notes ?? []).map(ReleaseNote.init)))
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

    /// What the job this reading followed set out to bring, from whichever stage it was last seen
    /// in — offered, under way, or already failed once.
    private static func carriedNotes(_ reading: UpdateReading?) -> [ReleaseNote] {
        guard let verdict = reading?.verdict else { return [] }
        if let offer = verdict.offer { return offer.whatsNew }
        if let progress = verdict.progress { return progress.notes }
        return verdict.failureNotes
    }

    /// A job in flight, read into the steps the card draws — and continuous with what this device
    /// already knew about it.
    ///
    /// The clock on each step is this device's, started the first time it saw the step, so a poll
    /// every two seconds does not restart it; the version the job set out for and what it brings
    /// were read before it began and are carried along, because the machine is not asked for them
    /// again until it is done.
    private static func progress(
        _ status: ServerUpdate, checkedAt: Date, lastKnown: UpdateReading?
    ) -> UpdateProgress {
        let job = status.job.flatMap { $0.isFinished ? nil : $0 }
        let step = job?.step.map(step(for:)) ?? step(for: status.phase)
        let previous = lastKnown?.verdict.progress
        let continuing =
            previous.map { prior in
                guard let id = job?.id, let known = prior.jobID else { return true }
                return id == known
            } ?? false
        let kind: UpdateProgress.Kind =
            job.map { $0.kind == .restart ? .serverRestart : .serverUpdate }
            ?? (continuing ? previous?.kind : nil)
            ?? (lastKnown?.needsOnlyRestart == true ? .serverRestart : .serverUpdate)
        return UpdateProgress(
            step: step,
            observedAt: continuing && previous?.step == step
                ? previous?.observedAt ?? checkedAt : checkedAt,
            kind: kind,
            target: job?.target ?? (continuing ? previous?.target : nil)
                ?? lastKnown?.verdict.offer?.version ?? status.latestVersion,
            jobID: job?.id ?? (continuing ? previous?.jobID : nil),
            waitingFor: step == .waitingForQuiet ? waitingFor(status) : nil,
            startedAt: continuing ? previous?.startedAt ?? checkedAt : checkedAt,
            notes: continuing
                ? previous?.notes ?? []
                : lastKnown?.verdict.offer?.whatsNew ?? lastKnown?.verdict.failureNotes ?? [])
    }

    private static func step(for phase: ServerUpdate.Phase) -> UpdateProgress.Step {
        switch phase {
        case .building: return .building
        case .waiting: return .waitingForQuiet
        case .restarting: return .restarting
        case .running, .idle, .succeeded, .failed: return .starting
        }
    }

    private static func step(for step: ServerUpdate.Job.Step) -> UpdateProgress.Step {
        switch step {
        case .download: return .starting
        case .build: return .building
        case .waitForIdle: return .waitingForQuiet
        case .restart: return .restarting
        case .done: return .settling
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
        note: String? = nil, product: String = "Tailscode", lastKnown: UpdateReading? = nil
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
            note: appNote(verdict: verdict, note: note), product: product,
            lastOutcome: lastKnown?.lastOutcome, build: install.build)
    }

    /// What to do is worth saying only where there is something to do: a copy a package manager
    /// owns spells out its whole procedure beside an offer, and stays quiet while it is current.
    private static func appNote(verdict: UpdateVerdict, note: String?) -> String? {
        switch verdict {
        case .behind, .failed: return note
        default: return nil
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
                return .working(
                    UpdateProgress(
                        step: running.step, observedAt: running.startedAt, kind: .appUpdate,
                        startedAt: running.startedAt))
            case .failed:
                return .failed(
                    UpdateFailure(
                        reason: running.message ?? Localized.text("The update did not finish."),
                        at: running.finishedAt ?? running.startedAt, kind: .appUpdate))
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
            let lines = release.notes.map(noteLines) ?? []
            return .behind(
                UpdateOffer(
                    version: release.version, commits: nil, changes: lines, canInstallHere: false,
                    notes: lines.isEmpty ? [] : [ReleaseNote(version: release.version, items: lines)]))
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

    /// A release's own notes as lines, without the section headings that group them — a heading
    /// read as one more thing that changed is a line that says nothing.
    private static func noteLines(_ notes: String) -> [String] {
        notes.split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*#")) }
            .filter { !$0.isEmpty && !$0.hasSuffix(":") && !$0.hasSuffix("：") }
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
