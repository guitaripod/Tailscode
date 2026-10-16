import CodingAgentKit
import Foundation

/// How long a job has left, from the daemon's own estimate when it gives one (`etaSeconds` among the
/// job's facts) and otherwise from the rate this device has watched it run at. A rate needs two
/// readings a few seconds apart, so a job just begun has no estimate and says none, rather than a
/// guess that jumps.
public struct SetupPace: Sendable, Equatable {
    public static let window: TimeInterval = 30
    public static let minimumSpan: TimeInterval = 3

    private struct Sample: Sendable, Equatable {
        let at: TimeInterval
        let done: Double
    }

    private var jobID: String?
    private var samples: [Sample] = []

    public init() {}

    public mutating func note(_ job: SetupJob, at time: TimeInterval) {
        if jobID != job.id {
            jobID = job.id
            samples = []
        }
        guard let progress = Self.progress(of: job) else { return }
        samples.append(Sample(at: time, done: progress))
        samples.removeAll { time - $0.at > Self.window }
    }

    public mutating func reset() {
        jobID = nil
        samples = []
    }

    public func remaining(of job: SetupJob) -> TimeInterval? {
        if let told = SetupFacts(job.facts).number("etaSeconds"), told >= 0 { return told }
        guard let first = samples.first, let last = samples.last, let progress = Self.progress(of: job) else {
            return nil
        }
        let span = last.at - first.at
        let gained = last.done - first.done
        guard span >= Self.minimumSpan, gained > 0 else { return nil }
        let left = max(0, 1 - progress)
        return left / (gained / span)
    }

    private static func progress(of job: SetupJob) -> Double? {
        if let done = job.bytesDone, let total = job.bytesTotal, total > 0 {
            return min(1, Double(done) / Double(total))
        }
        return job.fraction
    }
}

/// Everything the desk knows about one capability on one machine at one instant, and the checklist
/// that is drawn from it. A value, so a surface that arrives late is handed the latest whole.
public struct SetupSnapshot: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case checking
        case loaded
        case absent
        case unreachable(String)
        case wantsPassword
    }

    public var target: SetupTarget
    public var phase: Phase
    public var report: SetupReport?
    public var job: SetupJob?
    public var failed: SetupJob?
    public var eta: TimeInterval?
    public var running: Bool

    public init(
        target: SetupTarget, phase: Phase = .checking, report: SetupReport? = nil, job: SetupJob? = nil,
        failed: SetupJob? = nil, eta: TimeInterval? = nil, running: Bool = false
    ) {
        self.target = target
        self.phase = phase
        self.report = report
        self.job = job
        self.failed = failed
        self.eta = eta
        self.running = running
    }

    public func checklist(locale: Locale = .current, focus: SetupFocus? = nil) -> SetupChecklist {
        SetupChecklist(snapshot: self, locale: locale, focus: focus)
    }

    /// Whether the machine has nothing that answers for this capability yet, so a capabilities
    /// section offers to add it rather than to finish it.
    public var isAbsent: Bool { phase == .absent }

    public var isUnavailable: Bool { report.map { !$0.available } ?? false }
}

public struct SetupChange: Sendable, Equatable {
    public let snapshot: SetupSnapshot

    public var target: SetupTarget { snapshot.target }
}
