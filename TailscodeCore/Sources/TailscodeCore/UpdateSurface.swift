import Foundation

/// One machine in the picture whose software can be out of date.
public enum UpdateComponent: Sendable, Hashable, Codable {
    /// This client, on the desk it is running on.
    case app
    /// A configured server, by profile.
    case server(profileID: String)

    public var key: String {
        switch self {
        case .app: return "app"
        case .server(let id): return "server:\(id)"
        }
    }

    public var isApp: Bool { self == .app }
}

/// Where a version number came from, kept beside the number itself.
///
/// An update surface is a claim about two machines, and the whole difference between a useful
/// claim and a confident lie is whether the reader can tell who said it. A number Apple published
/// and a number read out of a directory are both "the version" and they mean entirely different
/// things when they disagree — so nothing here is ever shown as a bare number.
public enum VersionProvenance: String, Sendable, Hashable, Codable, CaseIterable {
    /// The stamp written when the running binary was built. The only reading that is a fact about
    /// the *process* rather than about a directory.
    case serverBuild
    /// `git describe` in the checkout the server was built from. This describes a directory: it
    /// moves when somebody checks out a branch on that machine, and it runs ahead of the running
    /// binary for the whole stretch between a build and a restart.
    case serverCheckout
    /// The server had no checkout to read and answered with the constant it was compiled with.
    case serverConstant
    /// The server named its own version and said nothing about where the number came from — which
    /// is all a machine that has no update route of its own can offer.
    case serverReported
    /// This build's own bundle.
    case appBundle
    /// The file the installer wrote beside the binary.
    case installStamp
    /// Apple's record for this bundle identifier, in one storefront.
    case appStore
    /// The project's published releases.
    case gitHubRelease
    /// A git checkout on this machine.
    case sourceCheckout
    /// Nothing could be read.
    case unknown

    /// Who said it, in the words the surface prints under the number.
    public var sentence: String {
        switch self {
        case .serverBuild: return Localized.text("stamped when this build was made")
        case .serverCheckout:
            return Localized.text("read from the checkout on that machine, not from what is running")
        case .serverConstant:
            return Localized.text(
                "the version the server was built with — it has no checkout to read")
        case .serverReported: return Localized.text("what that server says it is")
        case .appBundle: return Localized.text("this build's own stamp")
        case .installStamp: return Localized.text("recorded when this build was installed")
        case .appStore: return Localized.text("Apple's App Store record")
        case .gitHubRelease: return Localized.text("the project's published releases")
        case .sourceCheckout: return Localized.text("the checkout this build was made from")
        case .unknown: return Localized.text("nothing said where this came from")
        }
    }

    /// Whether the number is a fact about the software that is actually running. A checkout's
    /// `describe` is not: it is a fact about a directory, and the two part company the moment
    /// somebody builds without restarting.
    public var isAuthoritative: Bool {
        switch self {
        case .serverBuild, .serverReported, .appBundle, .installStamp, .appStore, .gitHubRelease,
            .sourceCheckout:
            return true
        case .serverCheckout, .serverConstant, .unknown:
            return false
        }
    }
}

/// A version, who said it, and when — the smallest honest unit this surface deals in.
public struct VersionFact: Sendable, Hashable, Codable {
    public let text: String?
    public let provenance: VersionProvenance
    public let readAt: Date?

    public init(text: String?, provenance: VersionProvenance, readAt: Date? = nil) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.provenance = self.text == nil ? .unknown : provenance
        self.readAt = readAt
    }

    public static let unknown = VersionFact(text: nil, provenance: .unknown)

    public var isKnown: Bool { text != nil }
    public var parsed: SoftwareVersion? { text.flatMap(SoftwareVersion.init) }

    /// The number with its source, which is the only form this app shows a version in.
    public var line: String {
        guard let text else { return Localized.text("not reported") }
        return Localized.text("%@ · %@", text, provenance.sentence)
    }
}

/// An update that exists and what taking it would mean.
public struct UpdateOffer: Sendable, Equatable, Codable {
    /// What the machine would be running afterwards, when it can be named.
    public let version: String?
    /// How many commits behind, when the machine counts in commits.
    public let commits: Int?
    /// Subjects of what it would bring in, newest first.
    public let changes: [String]
    /// The line of development this is behind. Two machines on different branches are not two
    /// counts of the same thing, and a surface that folded them into one number would say so.
    public let upstream: String?
    /// Whether one press finishes the job on this machine.
    public let canInstallHere: Bool
    /// Why one press cannot finish it, when it cannot.
    public let blocked: String?

    public init(
        version: String?, commits: Int? = nil, changes: [String] = [], upstream: String? = nil,
        canInstallHere: Bool, blocked: String? = nil
    ) {
        self.version = version
        self.commits = commits
        self.changes = changes
        self.upstream = upstream
        self.canInstallHere = canInstallHere
        self.blocked = blocked
    }

    /// What it would become, named however the machine can name it.
    public var target: String {
        if let version { return version }
        if let commits, commits > 0 {
            return Localized.text("%@ commits newer", String(commits))
        }
        return Localized.text("a newer build")
    }
}

/// An update in flight. There is no percentage to show — a fetch and a Swift build have no honest
/// fraction — so the step is the whole of the progress, and every client draws it as a step.
public struct UpdateProgress: Sendable, Equatable, Codable {
    public enum Step: String, Sendable, Equatable, Codable {
        case starting
        case building
        case installing
        case restarting
        /// Installed and answering again, but its new version has not been read back yet.
        case settling
    }

    public let step: Step
    /// Stamped by whoever is watching, on its own clock. A remote machine's `startedAt` is not
    /// comparable with this device's `Date()` — two clocks that disagree by an hour would print
    /// "started an hour ago" about a build thirty seconds old.
    public let observedAt: Date?

    public init(step: Step, observedAt: Date? = nil) {
        self.step = step
        self.observedAt = observedAt
    }

    public var word: String {
        switch step {
        case .starting: return Localized.text("Starting")
        case .building: return Localized.text("Building")
        case .installing: return Localized.text("Installing")
        case .restarting: return Localized.text("Restarting")
        case .settling: return Localized.text("Checking what it landed on")
        }
    }
}

/// An update that ran and did not finish.
public struct UpdateFailure: Sendable, Equatable, Codable {
    public let reason: String
    public let at: Date?

    public init(reason: String, at: Date? = nil) {
        self.reason = reason
        self.at = at
    }
}

/// Why something is running a build newer than anything published. The three reasons are not the
/// same fact and a surface that said "a build of your own" to a phone whose store record simply
/// has not propagated yet would be inventing a story.
public enum AheadReason: Sendable, Equatable, Codable {
    /// Built on this machine from a checkout past the last release.
    case ownBuild(published: String?)
    /// The storefront's record is older than what is installed — usually because it has not caught
    /// up with a release yet.
    case storeLagging(published: String)
    /// A TestFlight build, which is ahead by design and must never be sent to the store page.
    case testFlight(published: String?)

    public var published: String? {
        switch self {
        case .ownBuild(let value), .testFlight(let value): return value
        case .storeLagging(let value): return value
        }
    }

    public var sentence: String {
        switch self {
        case .ownBuild:
            return Localized.text("A build made here, past anything published. Nothing to install.")
        case .storeLagging:
            return Localized.text(
                "The store's record is older than what is installed — it has not caught up yet.")
        case .testFlight:
            return Localized.text("A TestFlight build, which runs ahead of the store on purpose.")
        }
    }
}

/// Why a verdict is not a verdict. Every one of these is a state with words, because the
/// alternative — printing "up to date" when nothing was actually checked — is the single failure
/// this whole surface exists to prevent.
public enum UpdateDoubt: Sendable, Equatable, Codable {
    /// Nothing has been asked yet.
    case neverChecked
    /// The machine did not answer.
    case unreachable(String)
    /// It answered and has no version, or no way to learn about a newer one.
    case notReported(String)
    /// Two numbers exist and cannot be ranked against each other.
    case notComparable(String)
    /// The last successful check is old enough that "current" is no longer a claim worth making.
    case stale(Date?)
    /// An update was under way and this process was not here to see how it ended.
    case interrupted(Date?)

    public func sentence(now: Date = Date()) -> String {
        switch self {
        case .neverChecked: return Localized.text("Not checked yet.")
        case .unreachable(let why): return why
        case .notReported(let why): return why
        case .notComparable(let why): return why
        case .stale(let when):
            guard let when, when <= now else {
                return Localized.text("Nothing here knows when this was last checked.")
            }
            return Localized.text(
                "Last checked %@ — too long ago to still call it current.",
                RelativeWhen.ago(when, now: now))
        case .interrupted(let when):
            guard let when, when <= now else {
                return Localized.text("An update was running and never reported how it ended.")
            }
            return Localized.text(
                "An update started %@ and never reported how it ended.",
                RelativeWhen.ago(when, now: now))
        }
    }
}

/// Relative time, written once. Every date in this surface came off some other machine's clock or
/// out of a file written weeks ago, so the arithmetic is guarded rather than trusted.
public enum RelativeWhen {
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return Localized.text("just now") }
        if seconds < 90 { return Localized.text("just now") }
        if seconds < 3600 {
            return Localized.text("%@ minutes ago", String(Int(seconds / 60)))
        }
        if seconds < 86400 {
            return Localized.text("%@ hours ago", String(Int(seconds / 3600)))
        }
        return Localized.text("%@ days ago", String(Int(seconds / 86400)))
    }
}

/// What is true about one machine's software right now.
public enum UpdateVerdict: Sendable, Equatable, Codable {
    /// Checked against something, and there is nothing newer. The proof rides in the case: a
    /// client cannot spell "up to date" without saying when it looked and what it looked at.
    case current(checkedAt: Date, against: VersionFact)
    case behind(UpdateOffer)
    case ahead(AheadReason)
    case working(UpdateProgress)
    case failed(UpdateFailure)
    /// Nothing newer is known, and this machine could not take one anyway.
    case blocked(String)
    case unverified(UpdateDoubt)

    public var isBusy: Bool {
        if case .working = self { return true }
        return false
    }

    public var offer: UpdateOffer? {
        if case .behind(let offer) = self { return offer }
        return nil
    }

    /// Whether this verdict rests on an actual comparison against something published. Only these
    /// three do; everything else knows nothing about what exists elsewhere.
    public var compared: Bool {
        switch self {
        case .current, .behind, .ahead: return true
        case .working, .failed, .blocked, .unverified: return false
        }
    }
}

/// The one press. Named by what it does rather than by a button label, so three clients can draw
/// the same offer with their own idioms and none of them can quietly promise more than it does.
public enum UpdateInvitation: Sendable, Equatable, Codable {
    /// This app performs the update end to end.
    case installHere
    /// The platform installs it; we can only open the page that starts that.
    case openStore(url: String)
    /// Nobody here can install it; the exact command is handed over instead.
    case copyCommand(String)
    /// Somewhere to read about it.
    case openPage(url: String)
    /// Ask again.
    case recheck

    public var label: String {
        switch self {
        case .installHere: return Localized.text("Update")
        case .openStore: return Localized.text("Open the App Store")
        case .copyCommand: return Localized.text("Copy the install command")
        case .openPage: return Localized.text("Open")
        case .recheck: return Localized.text("Check again")
        }
    }

    /// What the press will actually accomplish, said before it is pressed. An offer that ends in
    /// another app's hands says so; anything else would be this app taking credit for a job it
    /// cannot finish.
    public var promise: String? {
        switch self {
        case .installHere: return nil
        case .openStore:
            return Localized.text("The App Store installs it — this app cannot update itself.")
        case .copyCommand:
            return Localized.text("Run this on that machine; nothing here can install it for you.")
        case .openPage, .recheck: return nil
        }
    }

    public var isOneClickInstall: Bool { self == .installHere }
}

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

    public init(
        component: UpdateComponent, title: String, subtitle: String? = nil,
        installed: VersionFact, available: VersionFact = .unknown, verdict: UpdateVerdict,
        invitation: UpdateInvitation? = nil, manager: String? = nil, log: String? = nil,
        checkedAt: Date? = nil, note: String? = nil
    ) {
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
    }

    public var id: String { component.key }

    /// The line that leads the row.
    public var headline: String {
        switch verdict {
        case .current: return Localized.text("Up to date")
        case .behind(let offer): return Localized.text("Update to %@", offer.target)
        case .ahead: return Localized.text("Newer than anything published")
        case .working(let progress): return progress.word
        case .failed: return Localized.text("The last update failed")
        case .blocked: return Localized.text("Cannot update itself")
        case .unverified(.neverChecked): return Localized.text("Not checked yet")
        case .unverified(.stale): return Localized.text("Checked a while ago")
        case .unverified(.unreachable): return Localized.text("Couldn't check")
        case .unverified(.notReported): return Localized.text("Can't say")
        case .unverified(.notComparable): return Localized.text("Can't compare")
        case .unverified(.interrupted): return Localized.text("The last update didn't finish")
        }
    }

    /// The honest sentence under it: what is running, where the number came from, what it was
    /// compared against, and what is doubtful about any of that.
    public func detail(now: Date = Date()) -> String {
        guard let note else { return verdictDetail(now: now) }
        return verdictDetail(now: now) + " " + note
    }

    private func verdictDetail(now: Date) -> String {
        switch verdict {
        case .current(let checkedAt, let against):
            let compared = against.isKnown
                ? Localized.text("Compared against %@.", against.line)
                : Localized.text("Nothing newer was published.")
            return Localized.text("Running %@.", installed.line) + " " + compared + " "
                + Localized.text("Checked %@.", RelativeWhen.ago(checkedAt, now: now))
        case .behind(let offer):
            var line = Localized.text("Running %@.", installed.line)
            if let commits = offer.commits, commits > 0 {
                line += " " + Localized.text("%@ commits behind", String(commits))
                    + (offer.upstream.map { " " + Localized.text("of %@", $0) } ?? "") + "."
            }
            if let blocked = offer.blocked { line += " " + blocked }
            return line
        case .ahead(let reason):
            var line = Localized.text("Running %@.", installed.line)
            if let published = reason.published {
                line += " " + Localized.text("The newest published is %@.", published)
            }
            return line + " " + reason.sentence
        case .working(let progress):
            guard let observedAt = progress.observedAt, observedAt <= now else {
                return progress.word
            }
            return Localized.text(
                "%@ · started %@", progress.word, RelativeWhen.ago(observedAt, now: now))
        case .failed(let failure):
            guard let at = failure.at, at <= now else { return failure.reason }
            return Localized.text(
                "%@ (%@)", failure.reason, RelativeWhen.ago(at, now: now))
        case .blocked(let why):
            return Localized.text("Running %@. %@", installed.line, why)
        case .unverified(let doubt):
            let head = installed.isKnown
                ? Localized.text("Running %@.", installed.line)
                : Localized.text("This machine did not report a version.")
            return head + " " + doubt.sentence(now: now)
        }
    }

    /// The whole visual identity, from the one vocabulary every other state in this app answers to.
    ///
    /// Update marks hold still. An available update is a settled fact — it is not work in
    /// progress — and stillness is what tells a reader the app is not busy on their behalf. Only a
    /// running update earns motion.
    public var icon: ActivityIcon {
        switch verdict {
        case .current:
            return ActivityIcon(symbol: "checkmark.circle", glyph: "=", tone: .quiet, motion: .still)
        case .behind(let offer):
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

    /// Whether this row is a reason for the standing mark. An update that exists is, however it
    /// has to be installed; a failure the person has to see is. Nothing settled or unknowable is,
    /// because a mark that can never go out stops being read — and nagging about something this
    /// machine has no way to do is worse than saying nothing.
    ///
    /// `acknowledged` is the whole of the collapse contract: the row keeps its place and its
    /// sentence in the update surface, and stops holding the mark up.
    public func stands(acknowledged: Bool = false) -> Bool {
        guard !acknowledged else { return false }
        switch verdict {
        case .behind, .failed: return true
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
        Localized.text("%@ — %@. %@", title, headline, detail(now: now))
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

    /// Rows one press finishes, on the machines this app can drive. The app's own update is never
    /// in here: on a desktop it replaces the process that would be watching the others.
    public var installableServers: [UpdateReading] {
        readings.filter { !$0.component.isApp && $0.verdict.offer?.canInstallHere == true }
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
            return Localized.text("%@ has an update", standing[0].title)
        default:
            return Localized.text("%@ updates available", String(standing.count))
        }
    }

    public func detail(now: Date = Date()) -> String {
        if let only = standing.first, standing.count == 1 { return only.detail(now: now) }
        if !standing.isEmpty { return standing.map(\.title).joined(separator: ", ") }
        if let unchecked = readings.first(where: { !$0.verdict.compared }) {
            return unchecked.detail(now: now)
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

    private static func rank(_ reading: UpdateReading) -> Int {
        switch reading.verdict {
        case .failed: return 0
        case .working: return 1
        case .behind(let offer): return offer.canInstallHere ? 2 : 3
        case .blocked: return 4
        case .unverified: return 5
        case .ahead: return 6
        case .current: return 7
        }
    }
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
            guard let at = progress.observedAt ?? checkedAt, at <= now else {
                return .unverified(.interrupted(nil))
            }
            guard now.timeIntervalSince(at) > workExpiresAfter else { return verdict }
            return .unverified(.interrupted(at))
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
