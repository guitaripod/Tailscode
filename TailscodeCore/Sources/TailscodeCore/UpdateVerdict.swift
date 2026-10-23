import Foundation

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
