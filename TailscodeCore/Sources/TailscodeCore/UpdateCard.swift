import Foundation

/// One machine's software, arranged as the card every client draws.
///
/// The reading is the truth; the card is what a person sees of it, decided once so that three
/// clients cannot draw three different answers. It leads with the one thing a person wants to know
/// — is there something new, and what is it — in the plainest words the state allows: which
/// version, what it brings, one press to take it. Everything the reading knows beyond that — the
/// exact `git describe`, who reported each number, the branch, the supervisor — is kept in `facts`,
/// one tap away, rather than spoken over the headline.
///
/// While an update runs the card is a list of steps rather than a sentence, because a job that
/// takes minutes on somebody else's machine is only bearable when it is visible where it has got
/// to. Every step is decided here, from the kind of job and the step the machine last reported, so
/// the list is a function of the reading and nothing else: the same answer draws the same list on
/// every desk, and a card rebuilt from memory after a relaunch looks exactly like the one that was
/// on screen before it.
public struct UpdateCard: Sendable, Equatable, Identifiable {
    public enum Stage: String, Sendable, Equatable {
        /// Being asked, with nothing known yet.
        case checking
        case upToDate
        /// Current, and it got there recently enough that saying so is news.
        case updated
        case available
        /// The new build is on the machine and only needs loading.
        case restartNeeded
        case updating
        case failed
        /// Something stands between this card and a verdict — a machine that did not answer, one
        /// too old to say, one that cannot update itself.
        case attention
        case ahead
    }

    public struct Step: Sendable, Equatable, Identifiable {
        public enum State: String, Sendable, Equatable {
            case done
            case active
            case pending
            case failed
        }

        public let id: String
        public let title: String
        public let state: State
        /// What the step under way is doing.
        public let detail: String?
        /// When this device first saw the step under way. A client runs its clock from here.
        public let since: Date?
    }

    public struct Action: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case invitation(UpdateInvitation)
            case setAside
            case showLog
            case checkNow
        }

        public let kind: Kind
        public let title: String
        public let symbol: String
        /// The one press the card is about, drawn as the primary control.
        public let prominent: Bool
        public let enabled: Bool
        /// What to ask before the press is taken, when it restarts somebody's machine.
        public let confirmation: Confirmation?
    }

    public struct Confirmation: Sendable, Equatable {
        public let title: String
        public let message: String
        public let confirm: String
    }

    public struct Fact: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let value: String
    }

    public struct Automation: Sendable, Equatable {
        public let title: String
        public let isOn: Bool
        public let status: String
    }

    public let id: String
    public let component: UpdateComponent
    public let stage: Stage
    public let icon: ActivityIcon
    /// The machine, by the name the person gave it.
    public let machine: String
    public let subtitle: String?
    public let headline: String
    /// What it runs and what it would run, short: `claude-bridge 1.9.2 → 1.10.0`.
    public let versionLine: String?
    /// The one sentence the state needs, when it needs one.
    public let message: String?
    /// What the step under way is doing, for surfaces with room for one line rather than a list.
    public let activity: String?
    public let notesTitle: String?
    public let notes: [ReleaseNote]
    public let steps: [Step]
    public let primary: Action?
    public let secondary: [Action]
    public let facts: [Fact]
    public let automation: Automation?
    public let footnote: String?
    public let log: String?
    public let accessibility: String

    /// - Parameters:
    ///   - acknowledged: the person set this exact offer aside. The card keeps its press and loses
    ///     the argument for it.
    ///   - busy: this device is asking or following the machine right now, so a press would be a
    ///     second job on top of the first.
    public init(
        _ reading: UpdateReading, acknowledged: Bool = false, busy: Bool = false,
        now: Date = Date()
    ) {
        let stage = Self.stage(reading, busy: busy, now: now)
        let named = Named(product: reading.product)
        id = reading.id
        component = reading.component
        self.stage = stage
        icon = busy && stage == .checking ? .openWork : reading.icon
        machine = reading.title
        subtitle = reading.subtitle
        headline = Self.headline(reading, stage: stage)
        versionLine = Self.versionLine(reading, stage: stage, named: named)
        message = Self.message(reading, stage: stage, acknowledged: acknowledged, now: now)
        activity = reading.verdict.progress.map { progress in
            progress.lostContactSince != nil
                ? Localized.text("Lost touch with %@ — it may still be working.", reading.title)
                : progress.activity(machine: reading.title)
        }
        let notes = acknowledged ? [] : Self.notes(reading, stage: stage)
        self.notes = notes
        notesTitle = ReleaseNote.title(for: notes)
        steps = Self.steps(reading, now: now)
        let actions = Self.actions(
            reading, stage: stage, acknowledged: acknowledged, busy: busy)
        primary = actions.primary
        secondary = actions.secondary
        facts = Self.facts(reading, now: now)
        automation = reading.automation.map {
            Automation(
                title: Localized.text("Update automatically"), isOn: $0.enabled,
                status: $0.sentence(now: now))
        }
        footnote = Self.footnote(reading, stage: stage, now: now)
        if case .failed = reading.verdict { log = reading.log } else { log = nil }
        accessibility = [
            reading.title, headline, versionLine, message ?? activity,
        ].compactMap { $0 }.joined(separator: ". ")
    }

    /// The product's name in front of a version, where there is a product to name.
    private struct Named {
        let product: String?

        func callAsFunction(_ version: String) -> String {
            guard let product else { return version }
            return Localized.text("%@ %@", product, version)
        }
    }

    static func stage(_ reading: UpdateReading, busy: Bool, now: Date) -> Stage {
        switch reading.verdict {
        case .working: return .updating
        case .failed: return .failed
        case .behind: return reading.needsOnlyRestart ? .restartNeeded : .available
        case .current: return reading.lastOutcome?.isNews(now: now) == true ? .updated : .upToDate
        case .ahead: return .ahead
        case .blocked: return .attention
        case .unverified(.neverChecked): return busy ? .checking : .attention
        case .unverified: return .attention
        }
    }

    private static func headline(_ reading: UpdateReading, stage: Stage) -> String {
        switch stage {
        case .checking: return Localized.text("Checking for updates…")
        case .upToDate: return Localized.text("Up to date")
        case .updated:
            guard let to = reading.lastOutcome?.to.flatMap(VersionLabel.short) else {
                return Localized.text("Updated")
            }
            return Localized.text("Updated to %@", to)
        case .available: return Localized.text("Update available")
        case .restartNeeded: return Localized.text("Restart to finish updating")
        case .updating:
            guard let progress = reading.verdict.progress else { return Localized.text("Updating") }
            if progress.kind == .serverRestart { return Localized.text("Restarting") }
            guard let target = progress.target.flatMap(VersionLabel.short) else {
                return Localized.text("Updating")
            }
            return Localized.text("Updating to %@", target)
        case .failed:
            if case .failed(let failure) = reading.verdict, failure.kind == .serverRestart {
                return Localized.text("Restart didn't finish")
            }
            return Localized.text("Update failed")
        case .ahead: return Localized.text("Newer than the latest release")
        case .attention:
            switch reading.verdict {
            case .blocked: return Localized.text("Can't update from here")
            case .unverified(.unreachable): return Localized.text("Couldn't reach %@", reading.title)
            case .unverified(.notReported): return Localized.text("Can't check for updates")
            case .unverified(.notComparable): return Localized.text("Can't compare versions")
            case .unverified(.stale): return Localized.text("Not checked recently")
            case .unverified(.interrupted): return Localized.text("Didn't hear how it ended")
            case .unverified(.neverChecked): return Localized.text("Not checked yet")
            default: return Localized.text("Can't say")
            }
        }
    }

    private static func versionLine(_ reading: UpdateReading, stage: Stage, named: Named)
        -> String?
    {
        let from = reading.installed.short
        switch stage {
        case .available, .restartNeeded, .updating:
            let target: String? =
                reading.verdict.offer.map(\.target)
                ?? reading.verdict.progress?.target.flatMap(VersionLabel.short)
            guard let to = target else { return from.map(named.callAsFunction) }
            guard let from, from != to else { return named(to) }
            return named(Localized.text("%@ → %@", from, to))
        case .updated:
            return (reading.lastOutcome?.to.flatMap(VersionLabel.short) ?? from).map(named.callAsFunction)
        case .upToDate, .failed, .ahead, .attention, .checking:
            return from.map(named.callAsFunction)
        }
    }

    private static func message(
        _ reading: UpdateReading, stage: Stage, acknowledged: Bool, now: Date
    ) -> String? {
        var lines: [String] = []
        switch reading.verdict {
        case .behind(let offer):
            if let last = reading.lastOutcome, last.result == .failed, let reason = last.reason,
                let at = last.at, now.timeIntervalSince(at) < UpdateOutcome.newsFor
            {
                lines.append(Localized.text("The last try didn't land: %@", reason))
            }
            if acknowledged {
                lines.append(
                    Localized.text("Set aside. You'll hear about it again when something changes."))
            } else if stage == .restartNeeded {
                if let promise = reading.invitation?.promise { lines.append(promise) }
                if let blocked = offer.blocked { lines.append(blocked) }
            } else if offer.canInstallHere {
                lines.append(
                    reading.automation?.willTake == true
                        ? Localized.text(
                            "It installs this on its own the next time nothing is running.")
                        : Localized.text(
                            "Takes a few minutes. It restarts only once nothing is running on it."))
            } else if let blocked = offer.blocked {
                lines.append(blocked)
            } else if let promise = reading.invitation?.promise {
                lines.append(promise)
            }
        case .working(let progress):
            if progress.lostContactSince != nil {
                lines.append(
                    Localized.text(
                        "Lost touch with %@ — it may still be working.", reading.title))
            }
        case .current:
            if stage == .updated, let outcome = reading.lastOutcome, let at = outcome.at {
                lines.append(
                    outcome.automatic
                        ? Localized.text("Installed on its own %@.", RelativeWhen.ago(at, now: now))
                        : Localized.text("Installed %@.", RelativeWhen.ago(at, now: now)))
            }
        case .failed(let failure):
            lines.append(failure.reason)
        case .ahead(let reason):
            if let published = reason.published {
                lines.append(Localized.text("The newest published is %@.", published))
            }
            lines.append(reason.sentence)
        case .blocked(let why):
            lines.append(why)
        case .unverified(let doubt):
            if doubt != .neverChecked || stage != .checking { lines.append(doubt.sentence(now: now)) }
        }
        if let note = reading.note, !lines.contains(note) { lines.append(note) }
        let text = lines.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private static func notes(_ reading: UpdateReading, stage: Stage) -> [ReleaseNote] {
        switch stage {
        case .available, .restartNeeded: return reading.verdict.offer?.whatsNew ?? []
        case .updating: return reading.verdict.progress?.notes ?? []
        case .updated: return reading.lastOutcome?.notes ?? []
        case .failed: return reading.verdict.failureNotes
        case .checking, .upToDate, .attention, .ahead: return []
        }
    }

    /// The job's steps, each marked done, under way, still to come — or, for a job that failed on a
    /// step the machine named, where it stopped.
    static func steps(_ reading: UpdateReading, now: Date) -> [Step] {
        switch reading.verdict {
        case .working(let progress):
            let kind = progress.kind ?? (reading.component.isApp ? .appUpdate : .serverUpdate)
            let plan = UpdateProgress.plan(for: kind)
            let current = position(of: progress.step, in: plan)
            return plan.enumerated().map { index, step in
                let state: Step.State =
                    index < current ? .done : index == current ? .active : .pending
                return Step(
                    id: step.rawValue, title: UpdateProgress.title(step, kind: kind), state: state,
                    detail: state == .active
                        ? (progress.lostContactSince != nil
                            ? Localized.text("Lost touch — it may still be working")
                            : progress.activity(machine: reading.title)) : nil,
                    since: state == .active ? progress.observedAt : nil)
            }
        case .failed(let failure):
            guard let step = failure.step else { return [] }
            let kind = failure.kind ?? (reading.component.isApp ? .appUpdate : .serverUpdate)
            let plan = UpdateProgress.plan(for: kind)
            let stopped = position(of: step, in: plan)
            return plan.enumerated().map { index, step in
                let state: Step.State =
                    index < stopped ? .done : index == stopped ? .failed : .pending
                return Step(
                    id: step.rawValue, title: UpdateProgress.title(step, kind: kind), state: state,
                    detail: nil, since: nil)
            }
        default:
            return []
        }
    }

    /// Where a step falls in a plan that may not name it — asking is the first step not yet begun,
    /// and a step from a longer plan lands on the last one before it.
    private static func position(of step: UpdateProgress.Step, in plan: [UpdateProgress.Step])
        -> Int
    {
        if let index = plan.firstIndex(of: step) { return index }
        if step == .requesting { return 0 }
        let order = UpdateProgress.Step.allCases
        let rank = order.firstIndex(of: step) ?? 0
        return plan.lastIndex(where: { (order.firstIndex(of: $0) ?? 0) <= rank }) ?? 0
    }

    private static func actions(
        _ reading: UpdateReading, stage: Stage, acknowledged: Bool, busy: Bool
    ) -> (primary: Action?, secondary: [Action]) {
        var secondary: [Action] = []
        var primary: Action?
        let standing = reading.stands(acknowledged: acknowledged)
        switch stage {
        case .available, .restartNeeded, .failed, .attention:
            if let invitation = reading.invitation {
                primary = action(for: invitation, reading: reading, stage: stage, busy: busy)
            }
        case .upToDate, .updated:
            secondary.append(
                Action(
                    kind: .checkNow, title: Localized.text("Check now"), symbol: "arrow.clockwise",
                    prominent: false, enabled: !busy, confirmation: nil))
        case .checking, .updating, .ahead:
            break
        }
        if stage == .failed, reading.log != nil {
            secondary.append(
                Action(
                    kind: .showLog, title: Localized.text("Show log"), symbol: "text.alignleft",
                    prominent: false, enabled: true, confirmation: nil))
        }
        if standing {
            secondary.append(
                Action(
                    kind: .setAside, title: Localized.text("Not now"),
                    symbol: "clock.arrow.circlepath", prominent: false, enabled: true,
                    confirmation: nil))
        }
        return (primary, secondary)
    }

    private static func action(
        for invitation: UpdateInvitation, reading: UpdateReading, stage: Stage, busy: Bool
    ) -> Action {
        switch invitation {
        case .installHere:
            let target = reading.verdict.offer?.target
            return Action(
                kind: .invitation(invitation),
                title: stage == .failed ? Localized.text("Try again") : invitation.label,
                symbol: invitation.symbol, prominent: true, enabled: !busy,
                confirmation: Confirmation(
                    title: Localized.text("Update %@?", reading.title),
                    message: target.map {
                        Localized.text(
                            "%@ downloads and builds %@, then restarts once nothing is running on "
                                + "it. Chats reconnect by themselves.", reading.title, $0)
                    }
                        ?? Localized.text(
                            "%@ downloads and builds the new version, then restarts once nothing "
                                + "is running on it. Chats reconnect by themselves.", reading.title),
                    confirm: Localized.text("Update")))
        case .restartHere:
            return Action(
                kind: .invitation(invitation), title: invitation.label, symbol: invitation.symbol,
                prominent: true, enabled: !busy,
                confirmation: Confirmation(
                    title: Localized.text("Restart %@?", reading.title),
                    message: invitation.promise ?? "", confirm: Localized.text("Restart")))
        case .recheck:
            return Action(
                kind: .invitation(invitation), title: invitation.label, symbol: invitation.symbol,
                prominent: false, enabled: !busy, confirmation: nil)
        case .openStore, .copyCommand, .openPage:
            return Action(
                kind: .invitation(invitation), title: invitation.label, symbol: invitation.symbol,
                prominent: stage != .attention, enabled: true, confirmation: nil)
        }
    }

    /// Every number the card rests on, with who said it — the exact version strings, the line it
    /// is measured against, what keeps it running, when it was asked, and what is in the way.
    private static func facts(_ reading: UpdateReading, now: Date) -> [Fact] {
        var facts: [Fact] = []
        if reading.installed.isKnown {
            facts.append(
                Fact(id: "running", label: Localized.text("Running"), value: reading.installed.line))
        }
        if let build = reading.build {
            facts.append(Fact(id: "build", label: Localized.text("Build"), value: build))
        }
        if reading.available.isKnown {
            facts.append(
                Fact(id: "latest", label: Localized.text("Latest"), value: reading.available.line))
        }
        if let upstream = reading.verdict.offer?.upstream {
            facts.append(Fact(id: "tracks", label: Localized.text("Tracks"), value: upstream))
        }
        if let manager = reading.manager, !manager.isEmpty {
            facts.append(
                Fact(id: "supervisor", label: Localized.text("Kept running by"), value: manager))
        }
        if let outcome = reading.lastOutcome {
            facts.append(
                Fact(
                    id: "lastUpdate", label: Localized.text("Last update"),
                    value: Self.describe(outcome, now: now)))
        }
        if let checkedAt = reading.checkedAt {
            facts.append(
                Fact(
                    id: "checked", label: Localized.text("Checked"),
                    value: RelativeWhen.ago(checkedAt, now: now)))
        }
        let obstacle = reading.verdict.offer?.detailLines ?? []
        if !obstacle.isEmpty {
            facts.append(
                Fact(
                    id: "obstacle", label: Localized.text("In the way"),
                    value: obstacle.joined(separator: "\n")))
        }
        return facts
    }

    private static func describe(_ outcome: UpdateOutcome, now: Date) -> String {
        var parts: [String] = []
        switch outcome.result {
        case .succeeded:
            if let from = outcome.from.flatMap(VersionLabel.short),
                let to = outcome.to.flatMap(VersionLabel.short), from != to
            {
                parts.append(Localized.text("%@ → %@", from, to))
            } else {
                parts.append(Localized.text("Landed"))
            }
        case .failed: parts.append(Localized.text("Failed"))
        case .deferred: parts.append(Localized.text("Built, waiting for a restart"))
        }
        if let at = outcome.at { parts.append(RelativeWhen.ago(at, now: now)) }
        if outcome.automatic { parts.append(Localized.text("on its own")) }
        return parts.joined(separator: " · ")
    }

    private static func footnote(_ reading: UpdateReading, stage: Stage, now: Date) -> String? {
        guard let checkedAt = reading.checkedAt else { return nil }
        switch stage {
        case .upToDate, .available, .restartNeeded, .ahead:
            return Localized.text("Checked %@", RelativeWhen.ago(checkedAt, now: now))
        case .checking, .updated, .updating, .failed, .attention:
            return nil
        }
    }
}
