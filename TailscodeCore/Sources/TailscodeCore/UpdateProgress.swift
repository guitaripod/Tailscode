import Foundation

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
