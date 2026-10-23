import Foundation

/// Everything known about one machine's software, in the form every client renders.
public struct UpdateReading: Sendable, Equatable, Codable, Identifiable {
    public let component: UpdateComponent
    public let title: String
    public let subtitle: String?
    public let installed: VersionFact
    public let available: VersionFact
    public let verdict: UpdateVerdict
    public let invitation: UpdateInvitation?
    /// What supervises a server — `systemd`, `launchd`, `manual` — read at `checkedAt` rather than
    /// now, because a machine that gained a service since is still reported the old way.
    public let manager: String?
    public let log: String?
    public let checkedAt: Date?
    /// A true thing worth saying that the verdict has no room for — a machine that is current but
    /// could not update itself if it had to, a checkout nobody should be pulling into.
    public let note: String?
    /// What this machine does about updates on its own. Absent where the question does not arise —
    /// this app, or a server too old to have an answer — and a client with no automation draws no
    /// switch rather than one that does nothing.
    public let automation: UpdateAutomation?
    /// What the update installs, named the way its project names itself — `claude-bridge`,
    /// `Tailscode` — so a card says what is new rather than only which machine.
    public let product: String?
    /// How the last job on this machine ended, whatever it is doing now.
    public let lastOutcome: UpdateOutcome?
    /// The build number beside the version, where there is one — what a bug report needs.
    public let build: String?

    public init(
        component: UpdateComponent, title: String, subtitle: String? = nil,
        installed: VersionFact, available: VersionFact = .unknown, verdict: UpdateVerdict,
        invitation: UpdateInvitation? = nil, manager: String? = nil, log: String? = nil,
        checkedAt: Date? = nil, note: String? = nil, automation: UpdateAutomation? = nil,
        product: String? = nil, lastOutcome: UpdateOutcome? = nil, build: String? = nil
    ) {
        self.build = build
        self.automation = automation
        self.component = component
        self.title = title
        self.subtitle = subtitle
        self.installed = installed
        self.available = available
        self.verdict = verdict
        self.invitation = invitation
        self.manager = manager
        self.log = log
        self.checkedAt = checkedAt
        self.note = note
        self.product = product
        self.lastOutcome = lastOutcome
    }

    public var id: String { component.key }

    /// The same reading with a different verdict, or a different note or outcome — every other fact
    /// carried across unchanged.
    public func with(
        verdict: UpdateVerdict? = nil, invitation: UpdateInvitation?? = nil, note: String?? = nil,
        lastOutcome: UpdateOutcome?? = nil, title: String? = nil, subtitle: String?? = nil,
        product: String?? = nil
    ) -> UpdateReading {
        UpdateReading(
            component: component, title: title ?? self.title,
            subtitle: subtitle ?? self.subtitle, installed: installed, available: available,
            verdict: verdict ?? self.verdict, invitation: invitation ?? self.invitation,
            manager: manager, log: log, checkedAt: checkedAt, note: note ?? self.note,
            automation: automation, product: product ?? self.product,
            lastOutcome: lastOutcome ?? self.lastOutcome, build: build)
    }

    /// The line that leads the card.
    public var headline: String { UpdateCard(self).headline }

    /// Everything under the headline in one run of text: the versions and the one sentence the
    /// card has to say about them.
    public func detail(now: Date = Date()) -> String {
        let card = UpdateCard(self, now: now)
        return [card.versionLine, card.message].compactMap { $0 }.joined(separator: " ")
    }

    /// The whole visual identity, from the one vocabulary every other state in this app answers to.
    ///
    /// Update marks hold still. An available update is a settled fact — it is not work in
    /// progress — and stillness is what tells a reader the app is not busy on their behalf. Only a
    /// running update earns motion.
    public var icon: ActivityIcon {
        switch verdict {
        case .current:
            if lastOutcome?.isNews() == true {
                return ActivityIcon(
                    symbol: "checkmark.circle.fill", glyph: "✓", tone: .live, motion: .still)
            }
            return ActivityIcon(symbol: "checkmark.circle", glyph: "=", tone: .quiet, motion: .still)
        case .behind(let offer):
            if needsOnlyRestart {
                return ActivityIcon(
                    symbol: "arrow.clockwise.circle.fill", glyph: "⟳", tone: .attention,
                    motion: .still)
            }
            return ActivityIcon(
                symbol: "arrow.down.circle.fill", glyph: "↓",
                tone: offer.canInstallHere ? .attention : .quiet, motion: .still)
        case .ahead:
            return ActivityIcon(symbol: "hammer.circle", glyph: "^", tone: .quiet, motion: .still)
        case .working:
            return .openWork
        case .failed:
            return ActivityIcon(
                symbol: "exclamationmark.triangle.fill", glyph: "✖", tone: .danger, motion: .still)
        case .blocked:
            return ActivityIcon(symbol: "lock.circle", glyph: "·", tone: .quiet, motion: .still)
        case .unverified:
            return ActivityIcon(
                symbol: "questionmark.circle", glyph: "?", tone: .quiet, motion: .still)
        }
    }

    public var tone: ActivityTone { icon.tone }

    /// Whether the whole remaining job is loading a build the machine already has.
    ///
    /// Not a shade of "behind": nothing is fetched and nothing is built, and — the reason no
    /// surface may read it as an ordinary update — a machine that keeps itself current will never
    /// do it on its own, because from its side there is nothing left to take.
    public var needsOnlyRestart: Bool {
        guard case .behind = verdict, case .restartHere = invitation else { return false }
        return true
    }

    /// Whether this row is a reason for the standing mark. An update that exists is, however it
    /// has to be installed; a failure the person has to see is. Nothing settled or unknowable is,
    /// because a mark that can never go out stops being read — and nagging about something this
    /// machine has no way to do is worse than saying nothing.
    ///
    /// `acknowledged` is the whole of the collapse contract: the row keeps its place and its
    /// sentence in the update surface, and stops holding the mark up.
    ///
    /// A machine that will take the update itself is the second thing that stops a row standing,
    /// and for the same reason rather than a different one: the mark is a request that somebody
    /// act, and nobody has to. The row keeps `.behind` — it *is* behind — with its target, its
    /// changes and its place in the surface.
    public func stands(acknowledged: Bool = false) -> Bool {
        guard !acknowledged else { return false }
        if needsOnlyRestart { return true }
        switch verdict {
        case .behind(let offer):
            return !(offer.canInstallHere && automation?.willTake == true)
        case .failed: return true
        case .current, .ahead, .working, .blocked, .unverified: return false
        }
    }

    /// What a person would be acknowledging, written so the acknowledgement expires exactly when
    /// the world changes in a way they could act on: a newer offer, a different obstacle, an
    /// obstacle that cleared, or a failure that is not the same corpse.
    public var acknowledgeableIdentity: String? {
        switch verdict {
        case .behind(let offer):
            let target = offer.version ?? offer.commits.map(String.init) ?? available.text ?? "-"
            return "behind|\(target)|\(offer.blocked ?? "")"
        case .failed(let failure):
            return "failed|\(installed.text ?? "-")|\(failure.reason)"
        case .current, .ahead, .working, .blocked, .unverified:
            return nil
        }
    }

    public func accessibilityLine(now: Date = Date()) -> String {
        UpdateCard(self, now: now).accessibility
    }
}

/// Every machine's answer, merged into the one mark the app wears.
public struct UpdateRollup: Sendable, Equatable {
    public let readings: [UpdateReading]
    /// Identities the person has already been shown and set aside. Keyed the way
    /// ``UpdateReading/acknowledgeableIdentity`` is written, so the set expires itself.
    public let acknowledged: [String: String]

    public init(readings: [UpdateReading], acknowledged: [String: String] = [:]) {
        self.readings = readings.sorted { Self.rank($0) < Self.rank($1) }
        self.acknowledged = acknowledged
    }

    public func isAcknowledged(_ reading: UpdateReading) -> Bool {
        guard let identity = reading.acknowledgeableIdentity else { return false }
        return acknowledged[reading.component.key] == identity
    }

    /// Rows that are a reason the mark is lit, in the order a person should deal with them.
    public var standing: [UpdateReading] {
        readings.filter { $0.stands(acknowledged: isAcknowledged($0)) }
    }

    /// Machines that landed an update recently enough that it is still news.
    public func recentlyUpdated(now: Date = Date()) -> [UpdateReading] {
        readings.filter {
            guard case .current = $0.verdict else { return false }
            return $0.lastOutcome?.isNews(now: now) == true
        }
    }

    /// Rows one press finishes, on the machines this app can drive. The app's own update is never
    /// in here: on a desktop it replaces the process that would be watching the others.
    ///
    /// A machine that only needs starting is finishable from here and is deliberately not in here:
    /// "update everything" rebuilds what it touches, and rebuilding a machine whose binary is
    /// already on its disk is minutes of work for nothing.
    public var installableServers: [UpdateReading] {
        readings.filter { reading in
            guard !reading.component.isApp, reading.verdict.offer?.canInstallHere == true else {
                return false
            }
            if case .restartHere = reading.invitation { return false }
            return true
        }
    }

    /// Machines whose whole remaining job is loading a build they already have.
    public var restartableServers: [UpdateReading] {
        readings.filter {
            guard case .restartHere = $0.invitation else { return false }
            return !$0.component.isApp
        }
    }

    public var busy: [UpdateReading] { readings.filter(\.verdict.isBusy) }

    public var showsMark: Bool { !standing.isEmpty || !busy.isEmpty }

    /// What the mark says. A count when there is more than one, the row's own glyph otherwise —
    /// and never more than one character wide, because the mark sits in chrome that must not
    /// re-measure when a number changes.
    public var mark: String? {
        guard showsMark else { return nil }
        if standing.isEmpty { return ActivityIcon.openWork.glyph }
        if standing.count > 1 { return String(min(standing.count, 9)) }
        return standing.first?.icon.glyph
    }

    /// The tone of the loudest thing standing — never louder than the rows it speaks for.
    public var tone: ActivityTone {
        guard let loudest = standing.map(\.tone).max(by: { Self.weight($0) < Self.weight($1) })
        else { return busy.isEmpty ? .quiet : .live }
        return loudest
    }

    public var motion: ActivityMotion { busy.isEmpty ? .still : .turning }

    public var icon: ActivityIcon {
        ActivityIcon(
            symbol: standing.first?.icon.symbol ?? "arrow.triangle.2.circlepath",
            glyph: mark ?? ActivityIcon.idle.glyph, cycle: busy.isEmpty ? [] : ActivityIcon.sweepCycle,
            tone: tone, motion: motion)
    }

    /// The mark as a small labelled control — the word beside the symbol, for chrome that has room
    /// for one: `Update`, `2 updates`, `Updating`, `Update failed`.
    ///
    /// Only the chip that says `Updating` moves. One that names something to decide holds still
    /// even while another machine is being updated: a download arrow turning reads as a download.
    public var chip: UpdateChip? {
        guard showsMark else { return nil }
        if standing.isEmpty {
            return UpdateChip(
                title: Localized.text("Updating"), symbol: "arrow.triangle.2.circlepath",
                tone: .live, motion: .turning)
        }
        let motion: ActivityMotion = .still
        if standing.count > 1 {
            return UpdateChip(
                title: Localized.text("%@ updates", String(standing.count)),
                symbol: "arrow.down.circle.fill", tone: tone, motion: motion)
        }
        let only = standing[0]
        switch UpdateCard(only).stage {
        case .failed:
            return UpdateChip(
                title: Localized.text("Update failed"), symbol: "exclamationmark.triangle.fill",
                tone: .danger, motion: motion)
        case .restartNeeded:
            return UpdateChip(
                title: Localized.text("Update"), symbol: "arrow.clockwise.circle.fill",
                tone: only.tone, motion: motion)
        default:
            return UpdateChip(
                title: Localized.text("Update"), symbol: "arrow.down.circle.fill", tone: only.tone,
                motion: motion)
        }
    }

    public var headline: String {
        if !busy.isEmpty && standing.isEmpty {
            return busy.count == 1
                ? Localized.text("Updating %@", busy[0].title)
                : Localized.text("Updating %@ machines", String(busy.count))
        }
        switch standing.count {
        case 0:
            return everythingChecked
                ? Localized.text("Everything is up to date")
                : Localized.text("Software")
        case 1:
            return UpdateCard(standing[0]).headline
        default:
            return Localized.text("%@ updates available", String(standing.count))
        }
    }

    public func detail(now: Date = Date()) -> String {
        if let only = standing.first, standing.count == 1 {
            let card = UpdateCard(only, now: now)
            return [only.title, card.versionLine].compactMap { $0 }.joined(separator: " · ")
        }
        if !standing.isEmpty { return standing.map(\.title).joined(separator: ", ") }
        if let working = busy.first, busy.count == 1, let progress = working.verdict.progress {
            return progress.activity(machine: working.title)
        }
        if let fresh = recentlyUpdated(now: now).first {
            return UpdateCard(fresh, now: now).headline + " · " + fresh.title
        }
        if let unchecked = readings.first(where: { !$0.verdict.compared }) {
            return unchecked.title + " · " + UpdateCard(unchecked, now: now).headline
        }
        return readings.map(\.title).joined(separator: ", ")
    }

    /// True only when every machine was actually compared against something published. It is what
    /// stands between the app and telling someone everything is current on the strength of two
    /// servers that never answered and one that has no way to look.
    public var everythingChecked: Bool {
        !readings.isEmpty && readings.allSatisfy { $0.verdict.compared }
    }

    public var canUpdateEverything: Bool { installableServers.count > 1 }

    /// The order to take them in, and it is one at a time: a bridge serialises its own fetch, and
    /// two updates started together queue behind each other anyway while both surfaces claim to be
    /// working.
    public var updateOrder: [UpdateComponent] { installableServers.map(\.component) }

    public func accessibilityLine(now: Date = Date()) -> String {
        Localized.text("%@. %@", headline, detail(now: now))
    }

    private static func weight(_ tone: ActivityTone) -> Int {
        switch tone {
        case .danger: return 3
        case .attention: return 2
        case .live: return 1
        case .quiet: return 0
        }
    }

    /// The order a person deals with them in: what broke, what is moving, what can be taken, what
    /// just landed, and only then what needs nothing.
    private static func rank(_ reading: UpdateReading) -> Int {
        switch reading.verdict {
        case .failed: return 0
        case .working: return 1
        case .behind(let offer): return offer.canInstallHere ? 2 : 3
        case .current where reading.lastOutcome?.isNews() == true: return 4
        case .blocked: return 5
        case .unverified: return 6
        case .ahead: return 7
        case .current: return 8
        }
    }
}

/// The mark as a labelled control.
public struct UpdateChip: Sendable, Equatable {
    public let title: String
    public let symbol: String
    public let tone: ActivityTone
    public let motion: ActivityMotion
}

/// How long a "nothing newer" answer is worth anything.
///
/// The asymmetry is the point: *behind* never expires, because a release that exists does not stop
/// existing while nobody looks. *Current* does, because it is a claim about the world at the moment
/// it was made, and the world publishes things. And a *failure* expires into history, because a
/// mark that stays red forever over a build that failed last month is a mark nobody reads.
public enum UpdateFreshness {
    public static let recheckAfter: TimeInterval = 6 * 3600
    public static let expiresAfter: TimeInterval = 24 * 3600
    /// How long a build is allowed to be in flight before an unfinished one is read as abandoned.
    /// Generous, because it covers a cold Swift build on a small machine.
    public static let workExpiresAfter: TimeInterval = 45 * 60

    /// How long past a self-taking machine's own next look an offer is still worth showing.
    public static let selfTakingSlack: TimeInterval = 30 * 60

    /// What a remembered *reading* is still allowed to claim.
    ///
    /// The asymmetry above holds only while a person is the only one who can take an update. A
    /// machine that takes its own stops being behind while nobody is looking, so an offer it said
    /// it would take expires the way `current` does — otherwise the app spends the morning offering
    /// a version that machine installed at two in the morning.
    public static func decayed(_ reading: UpdateReading, now: Date = Date()) -> UpdateVerdict {
        let verdict = decayed(reading.verdict, checkedAt: reading.checkedAt, now: now)
        guard case .behind = verdict, reading.automation?.willTake == true,
            let next = reading.automation?.nextLookAt ?? reading.checkedAt,
            now > next.addingTimeInterval(selfTakingSlack)
        else { return verdict }
        return .unverified(.stale(reading.checkedAt.map { $0 <= now ? $0 : nil } ?? nil))
    }

    public static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        if lastCheck > now { return true }
        return now.timeIntervalSince(lastCheck) >= recheckAfter
    }

    /// What a remembered verdict is still allowed to claim. A clock that moved backwards makes
    /// every stored date look like the future; that is treated as "no idea when", not as fresh.
    public static func decayed(_ verdict: UpdateVerdict, checkedAt: Date?, now: Date = Date())
        -> UpdateVerdict
    {
        switch verdict {
        case .working(let progress):
            guard progress.step != .waitingForQuiet else { return verdict }
            guard let at = checkedAt ?? progress.observedAt, at <= now else {
                return .unverified(.interrupted(nil))
            }
            guard now.timeIntervalSince(at) > workExpiresAfter else { return verdict }
            return .unverified(.interrupted(progress.startedAt ?? at))
        case .current(let at, _):
            guard at <= now, now.timeIntervalSince(at) < expiresAfter else {
                return .unverified(.stale(at <= now ? at : nil))
            }
            return verdict
        case .failed(let failure):
            guard let at = failure.at, at <= now, now.timeIntervalSince(at) >= expiresAfter else {
                return verdict
            }
            return .unverified(.interrupted(at))
        case .behind, .ahead, .blocked, .unverified:
            return verdict
        }
    }
}
