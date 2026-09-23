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
/// things when they disagree — so the exact number and its source are always one tap away, in the
/// details under every card, even where the card itself leads with the short form.
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

    /// Who said it, in the words the details print beside the number.
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

    /// The version as a person reads it — the release it descends from — for the line a card leads
    /// with. The exact string and its source are ``line``.
    public var short: String? { VersionLabel.short(text) }

    /// The number with its source, which is the form the details show it in.
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
    /// The obstacle itself, named rather than merely summarised — the files that are dirty, the
    /// commits that are in the way, the places a toolchain was looked for.
    ///
    /// Deliberately outside ``UpdateReading/acknowledgeableIdentity``: an agent writing one more
    /// file on that machine changes this list, and an acknowledgement that expired every time the
    /// obstacle grew by a path would put the standing mark back for something nobody can act on
    /// any differently.
    public let details: [String]
    /// How many more there are than `details` carries.
    public let moreDetails: Int
    /// What the update brings, in the project's own words, newest release first.
    public let notes: [ReleaseNote]

    public init(
        version: String?, commits: Int? = nil, changes: [String] = [], upstream: String? = nil,
        canInstallHere: Bool, blocked: String? = nil, details: [String] = [], moreDetails: Int = 0,
        notes: [ReleaseNote] = []
    ) {
        self.version = version
        self.commits = commits
        self.changes = changes
        self.upstream = upstream
        self.canInstallHere = canInstallHere
        self.blocked = blocked
        self.details = details
        self.moreDetails = moreDetails
        self.notes = notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        commits = try container.decodeIfPresent(Int.self, forKey: .commits)
        changes = try container.decodeIfPresent([String].self, forKey: .changes) ?? []
        upstream = try container.decodeIfPresent(String.self, forKey: .upstream)
        canInstallHere = try container.decodeIfPresent(Bool.self, forKey: .canInstallHere) ?? false
        blocked = try container.decodeIfPresent(String.self, forKey: .blocked)
        details = try container.decodeIfPresent([String].self, forKey: .details) ?? []
        moreDetails = try container.decodeIfPresent(Int.self, forKey: .moreDetails) ?? 0
        notes = (try? container.decodeIfPresent([ReleaseNote].self, forKey: .notes)) ?? []
    }

    /// The obstacle's own list, with the tail it left out stated rather than dropped.
    public var detailLines: [String] {
        guard moreDetails > 0 else { return details }
        return details + [Localized.text("and %@ more", String(moreDetails))]
    }

    /// What it would become, named however the machine can name it.
    public var target: String {
        if let version { return VersionLabel.short(version) ?? version }
        if let commits, commits > 0 {
            return Localized.text("%@ commits newer", String(commits))
        }
        return Localized.text("a newer build")
    }

    /// What is new, as a person reads it: the project's notes where it sent them, and the headlines
    /// of its commits where it did not.
    public var whatsNew: [ReleaseNote] {
        guard notes.isEmpty else { return notes }
        return ReleaseNote.fromSubjects(changes)
    }
}

/// An update in flight, as a sequence of steps. There is no percentage to show — a fetch and a
/// Swift build have no honest fraction — so the step is the whole of the progress, drawn as a
/// list every client lays out the same way: what is done, what is under way, what is still to come.
public struct UpdateProgress: Sendable, Equatable, Codable {
    public enum Step: String, Sendable, Equatable, Codable, CaseIterable {
        /// The press has been made and the machine has not answered it yet.
        case requesting
        /// Getting the new code.
        case starting
        case building
        case installing
        /// Built, and holding until nothing is running that the restart would stop. It is a step
        /// rather than a silence because it can outlast the build that produced it.
        case waitingForQuiet
        case restarting
        /// Answering again, and being asked what it landed on.
        case settling
    }

    /// What kind of job the steps belong to, which decides which steps there are.
    public enum Kind: String, Sendable, Equatable, Codable {
        case serverUpdate
        case serverRestart
        case appUpdate
    }

    public let step: Step
    /// When this device first saw the current step, on its own clock. A remote machine's stamps
    /// are not comparable with this device's — two clocks that disagree by an hour would print
    /// "an hour" about a build thirty seconds old — so every duration is measured here.
    public let observedAt: Date?
    public let kind: Kind?
    /// What the job set out to install.
    public let target: String?
    public let jobID: String?
    /// What the machine says it is waiting for, while it waits.
    public let waitingFor: String?
    /// When this device first saw the job.
    public let startedAt: Date?
    /// When the machine stopped answering, while this device is still following it. It may well
    /// still be working; this is a fact about the line, not about the job.
    public let lostContactSince: Date?
    /// What the update brings, carried from the offer that was taken so it can still be read while
    /// the job runs and once it has landed.
    public let notes: [ReleaseNote]

    public init(
        step: Step, observedAt: Date? = nil, kind: Kind? = nil, target: String? = nil,
        jobID: String? = nil, waitingFor: String? = nil, startedAt: Date? = nil,
        lostContactSince: Date? = nil, notes: [ReleaseNote] = []
    ) {
        self.step = step
        self.observedAt = observedAt
        self.kind = kind
        self.target = target
        self.jobID = jobID
        self.waitingFor = waitingFor
        self.startedAt = startedAt
        self.lostContactSince = lostContactSince
        self.notes = notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        step = try container.decode(Step.self, forKey: .step)
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
        kind = try? container.decodeIfPresent(Kind.self, forKey: .kind)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
        waitingFor = try container.decodeIfPresent(String.self, forKey: .waitingFor)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        lostContactSince = try container.decodeIfPresent(Date.self, forKey: .lostContactSince)
        notes = (try? container.decodeIfPresent([ReleaseNote].self, forKey: .notes)) ?? []
    }

    public func with(
        step: Step? = nil, observedAt: Date?? = nil, waitingFor: String?? = nil,
        lostContactSince: Date?? = nil
    ) -> UpdateProgress {
        UpdateProgress(
            step: step ?? self.step, observedAt: observedAt ?? self.observedAt, kind: kind,
            target: target, jobID: jobID, waitingFor: waitingFor ?? self.waitingFor,
            startedAt: startedAt, lostContactSince: lostContactSince ?? self.lostContactSince,
            notes: notes)
    }

    /// The steps a job of this kind passes through, in order. Asking is not among them: it is the
    /// first step still waiting to begin.
    public static func plan(for kind: Kind) -> [Step] {
        switch kind {
        case .serverUpdate: return [.starting, .building, .waitingForQuiet, .restarting, .settling]
        case .serverRestart: return [.waitingForQuiet, .restarting, .settling]
        case .appUpdate: return [.starting, .building, .installing, .restarting]
        }
    }

    public var plan: [Step] { Self.plan(for: kind ?? .serverUpdate) }

    /// The name a step wears in the list, in the imperative a person would give it.
    public static func title(_ step: Step, kind: Kind) -> String {
        switch step {
        case .requesting, .starting: return Localized.text("Download")
        case .building: return Localized.text("Build")
        case .installing: return Localized.text("Install")
        case .waitingForQuiet: return Localized.text("Wait until idle")
        case .restarting:
            return kind == .appUpdate ? Localized.text("Relaunch") : Localized.text("Restart")
        case .settling: return Localized.text("Confirm")
        }
    }

    /// What the step under way is doing, in one line.
    public func activity(machine: String) -> String {
        switch step {
        case .requesting: return Localized.text("Asking %@ to start…", machine)
        case .starting: return Localized.text("Getting the new code")
        case .building: return Localized.text("Compiling — usually a few minutes")
        case .installing: return Localized.text("Putting the new build in place")
        case .waitingForQuiet:
            return waitingFor ?? Localized.text("Waiting until nothing is running on it")
        case .restarting:
            return kind == .appUpdate
                ? Localized.text("Relaunching")
                : Localized.text("%@ is restarting — back in a few seconds", machine)
        case .settling: return Localized.text("Checking what it landed on")
        }
    }

    /// The step's one word, for surfaces with room for nothing else.
    public var word: String {
        switch step {
        case .requesting: return Localized.text("Asking")
        case .starting: return Localized.text("Downloading")
        case .building: return Localized.text("Building")
        case .installing: return Localized.text("Installing")
        case .waitingForQuiet: return Localized.text("Waiting until idle")
        case .restarting:
            return kind == .appUpdate ? Localized.text("Relaunching") : Localized.text("Restarting")
        case .settling: return Localized.text("Confirming")
        }
    }
}

/// An update that ran and did not finish.
public struct UpdateFailure: Sendable, Equatable, Codable {
    public let reason: String
    public let at: Date?
    /// The step it stopped on, when the machine said.
    public let step: UpdateProgress.Step?
    public let kind: UpdateProgress.Kind?
    /// What the next try would bring, when the machine said — a failed update is still an offer,
    /// and "Try again" is only worth pressing when it says what for.
    public let notes: [ReleaseNote]

    public init(
        reason: String, at: Date? = nil, step: UpdateProgress.Step? = nil,
        kind: UpdateProgress.Kind? = nil, notes: [ReleaseNote] = []
    ) {
        self.reason = reason
        self.at = at
        self.step = step
        self.kind = kind
        self.notes = notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = try container.decode(String.self, forKey: .reason)
        at = try container.decodeIfPresent(Date.self, forKey: .at)
        step = try? container.decodeIfPresent(UpdateProgress.Step.self, forKey: .step)
        kind = try? container.decodeIfPresent(UpdateProgress.Kind.self, forKey: .kind)
        notes = (try? container.decodeIfPresent([ReleaseNote].self, forKey: .notes)) ?? []
    }
}

/// How the last job on a machine ended, kept beside whatever the machine is doing now.
///
/// A machine that updated itself at two in the morning is simply current by breakfast, and "up to
/// date" is true and tells nobody that anything happened. The outcome is what lets the card say
/// what it became, from what, whether anybody pressed anything, and what came with it.
public struct UpdateOutcome: Sendable, Equatable, Codable {
    public enum Result: String, Sendable, Equatable, Codable {
        case succeeded
        case failed
        /// Built, and the loading of it is owed.
        case deferred
    }

    public let result: Result
    public let kind: UpdateProgress.Kind
    /// Taken by the machine's own policy rather than by a press.
    public let automatic: Bool
    public let from: String?
    public let to: String?
    public let reason: String?
    public let at: Date?
    public let jobID: String?
    /// What came with it, carried from the offer that was taken.
    public let notes: [ReleaseNote]

    public init(
        result: Result, kind: UpdateProgress.Kind = .serverUpdate, automatic: Bool = false,
        from: String? = nil, to: String? = nil, reason: String? = nil, at: Date? = nil,
        jobID: String? = nil, notes: [ReleaseNote] = []
    ) {
        self.result = result
        self.kind = kind
        self.automatic = automatic
        self.from = from
        self.to = to
        self.reason = reason
        self.at = at
        self.jobID = jobID
        self.notes = notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decode(Result.self, forKey: .result)
        kind = (try? container.decodeIfPresent(UpdateProgress.Kind.self, forKey: .kind)) ?? .serverUpdate
        automatic = try container.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        from = try container.decodeIfPresent(String.self, forKey: .from)
        to = try container.decodeIfPresent(String.self, forKey: .to)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        at = try container.decodeIfPresent(Date.self, forKey: .at)
        jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
        notes = (try? container.decodeIfPresent([ReleaseNote].self, forKey: .notes)) ?? []
    }

    /// How long a landed update is news. Past this the card is simply current.
    public static let newsFor: TimeInterval = 24 * 3600

    public func isNews(now: Date = Date()) -> Bool {
        guard result == .succeeded, let at else { return false }
        let age = now.timeIntervalSince(at)
        return age >= -300 && age < Self.newsFor
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
            let minutes = Int(seconds / 60)
            return minutes == 1
                ? Localized.text("a minute ago") : Localized.text("%@ minutes ago", String(minutes))
        }
        if seconds < 86400 {
            let hours = Int(seconds / 3600)
            return hours == 1
                ? Localized.text("an hour ago") : Localized.text("%@ hours ago", String(hours))
        }
        let days = Int(seconds / 86400)
        return days == 1 ? Localized.text("a day ago") : Localized.text("%@ days ago", String(days))
    }

    /// A duration on a clock that is running, as a stepper shows it: `0:42`, `3:05`, `1:02:10`.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        guard hours == 0 else {
            return String(format: "%d:%02d:%02d", hours, minutes, rest)
        }
        return String(format: "%d:%02d", minutes, rest)
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

    public var progress: UpdateProgress? {
        if case .working(let progress) = self { return progress }
        return nil
    }

    /// Work that is deliberately holding rather than progressing.
    ///
    /// A machine that built a binary and is waiting for the turn on it to end answers every
    /// question perfectly well and can hold for hours. It must therefore keep being asked, and it
    /// must never expire into "an update started and never reported how it ended", which is a
    /// sentence about a machine that stopped talking rather than one telling you exactly what it is
    /// doing.
    public var isHolding: Bool {
        guard case .working(let progress) = self else { return false }
        return progress.step == .waitingForQuiet
    }

    public var offer: UpdateOffer? {
        if case .behind(let offer) = self { return offer }
        return nil
    }

    /// What a failed update would bring on its next try, when the machine said.
    public var failureNotes: [ReleaseNote] {
        if case .failed(let failure) = self { return failure.notes }
        return []
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

/// What a machine does about updates when nobody is asking it to.
///
/// The trust is the machine's rather than the device's: a phone that sets this and is never opened
/// again must not be what decides whether a server stays current, and two clients must never
/// disagree about it. So it is asked of the server and read back from the server — never drawn from
/// what this device last sent, which would show a switch on for a request the bridge never received.
public struct UpdateAutomation: Sendable, Equatable, Codable {
    public let enabled: Bool
    /// When it last replaced itself unattended, and with what.
    public let lastTakenAt: Date?
    public let lastTarget: String?
    public let nextLookAt: Date?
    /// What it is holding off for right now, in the machine's own words. Absent when nothing is in
    /// the way — which is exactly when the switch being on means the update will simply happen.
    public let holdingOff: String?
    /// When the machine said all this. A switch is a reading like any other and shows its age.
    public let readAt: Date?

    public init(
        enabled: Bool, lastTakenAt: Date? = nil, lastTarget: String? = nil,
        nextLookAt: Date? = nil, holdingOff: String? = nil, readAt: Date? = nil
    ) {
        self.enabled = enabled
        self.lastTakenAt = lastTakenAt
        self.lastTarget = lastTarget
        self.nextLookAt = nextLookAt
        self.holdingOff = holdingOff
        self.readAt = readAt
    }

    /// Whether the update in front of this machine will be taken without anybody pressing anything.
    public var willTake: Bool { enabled && holdingOff == nil }

    /// The line under the switch: what the machine will do, what it is holding off for, and what it
    /// last did.
    public func sentence(now: Date = Date()) -> String {
        guard enabled else {
            return Localized.text("Off — new versions wait for you.")
        }
        if let holdingOff { return holdingOff }
        var line = Localized.text("On — installs new versions when nothing is running.")
        if let lastTakenAt, lastTakenAt <= now {
            line += " "
                + Localized.text("Last updated %@.", RelativeWhen.ago(lastTakenAt, now: now))
        }
        return line
    }
}

/// The one press. Named by what it does rather than by a button label, so three clients can draw
/// the same offer with their own idioms and none of them can quietly promise more than it does.
public enum UpdateInvitation: Sendable, Equatable, Codable {
    /// This app performs the update end to end.
    case installHere
    /// A build is already on that machine and only needs loading. Carries what brings the bridge
    /// back, and — in the machine's own words rather than a count this end interprets — whatever it
    /// would have to wait for first. Both change what the press means.
    case restartHere(supervisor: String, waitingFor: String?)
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
        case .restartHere: return Localized.text("Restart")
        case .openStore: return Localized.text("Open App Store")
        case .copyCommand: return Localized.text("Copy command")
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
        case .restartHere(let supervisor, let waitingFor):
            guard let waitingFor else {
                return Localized.text(
                    "Nothing is running on it, so %@ brings it straight back on the new build — a "
                        + "few seconds.", supervisor)
            }
            return Localized.text(
                "%@ It restarts on the new build as soon as that finishes.", waitingFor)
        case .openStore:
            return Localized.text("The App Store installs it — this app cannot update itself.")
        case .copyCommand:
            return Localized.text("Run it in a terminal on that machine.")
        case .openPage, .recheck: return nil
        }
    }

    /// Whether pressing it hands this app a job it finishes itself, restart and all. Distinct from
    /// ``isOneClickInstall``, which means specifically *installing software* — a walk that rebuilds
    /// every machine must not include one that only needed starting.
    public var finishesHere: Bool {
        switch self {
        case .installHere, .restartHere: return true
        case .openStore, .copyCommand, .openPage, .recheck: return false
        }
    }

    public var isOneClickInstall: Bool { self == .installHere }

    public var symbol: String {
        switch self {
        case .installHere: return "arrow.down.circle"
        case .restartHere: return "arrow.clockwise.circle"
        case .openStore: return "arrow.up.forward.app"
        case .copyCommand: return "doc.on.doc"
        case .openPage: return "safari"
        case .recheck: return "arrow.clockwise"
        }
    }
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
