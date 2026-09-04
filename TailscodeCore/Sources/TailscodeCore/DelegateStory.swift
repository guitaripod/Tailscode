import CodingAgentKit
import Foundation

/// One line of a run's story, in the words every client prints.
public struct DelegateStoryLine: Sendable, Hashable, Identifiable {
    public var seq: Int
    public var tier: String?
    public var text: String
    public var tone: ActivityTone
    /// A worker's own progress line, indented under the attempt rather than standing as news.
    public var isProgress: Bool

    public var id: Int { seq }

    public init(seq: Int, tier: String?, text: String, tone: ActivityTone, isProgress: Bool = false) {
        self.seq = seq
        self.tier = tier
        self.text = text
        self.tone = tone
        self.isProgress = isProgress
    }
}

/// Where each rung of the ladder stands for one run.
public enum DelegateRungState: Sendable, Hashable {
    /// Cheaper than where the run started; never tried.
    case belowStart
    /// Inside the run's range and not reached yet.
    case pending
    case current
    case passed
    case failed
    case skipped
    case held
    /// Above the ceiling; the run may not climb here.
    case beyondCeiling

    public var tone: ActivityTone {
        switch self {
        case .current, .passed: return .live
        case .failed: return .danger
        case .held: return .attention
        case .belowStart, .pending, .skipped, .beyondCeiling: return .quiet
        }
    }

    public var isLit: Bool { self == .current || self == .passed }
}

public struct DelegateRung: Sendable, Hashable, Identifiable {
    public var tier: String
    public var label: String
    public var model: String?
    public var state: DelegateRungState

    public var id: String { tier }

    public init(tier: String, label: String = "", model: String? = nil, state: DelegateRungState) {
        self.tier = tier
        self.label = label
        self.model = model
        self.state = state
    }
}

/// The ladder of one run: every tier the daemon knows, each with where it stands for this run.
public struct DelegateLadder: Sendable, Hashable {
    public var rungs: [DelegateRung]

    public init(rungs: [DelegateRung]) { self.rungs = rungs }

    public var lit: DelegateRung? { rungs.last { $0.state.isLit } }

    /// The words a screen reader gets: each rung and its state, cheapest first.
    public var spoken: String {
        rungs.map { "\($0.tier) \(DelegateLadder.word($0.state))" }.joined(separator: ", ")
    }

    public static func word(_ state: DelegateRungState) -> String {
        switch state {
        case .belowStart: return Localized.text("below the start")
        case .pending: return Localized.text("waiting")
        case .current: return Localized.text("running")
        case .passed: return Localized.text("passed")
        case .failed: return Localized.text("failed")
        case .skipped: return Localized.text("skipped")
        case .held: return Localized.text("held")
        case .beyondCeiling: return Localized.text("beyond the ceiling")
        }
    }
}

/// One run folded from its events: what is known, in order, as it arrives.
///
/// The story is toolkit-free like everything here. A client feeds it the stored run, then every
/// envelope off the stream, and draws `lines`, `ladder` and the headline; it never composes a word
/// of its own, so the phone, the Mac and the Linux desk tell one run the same way.
public struct DelegateRunStory: Sendable, Hashable {
    public var runID: String
    public var packet: DelegatePacket?
    public var tierOrder: [String]
    public var tierLabels: [String: String]
    public var startTier: String?
    public var ceiling: String?
    public var mode: DelegateMode
    public var status: DelegateRunStatus
    public var passedTier: String?
    public var escalations: Int
    public var durationMS: Int?
    public var summary: String
    public var lines: [DelegateStoryLine]
    public var attempts: [DelegateAttemptOutcome]
    public var appliedFiles: [String]
    public var currentTier: String?
    public var currentModel: [String: String]
    public var failedTiers: Set<String>
    public var skippedTiers: Set<String>
    public var pendingApproval: (tier: String, reason: String)?
    public var lastSeq: Int

    public init(runID: String, tiers: [DelegateTier] = [], run: DelegateRun? = nil) {
        self.runID = runID
        packet = run?.packet
        tierOrder = tiers.map(\.tier)
        tierLabels = Dictionary(uniqueKeysWithValues: tiers.map { ($0.tier, $0.label) })
        startTier = run?.startTier
        ceiling = run?.ceiling
        mode = run?.mode ?? .normal
        status = run?.status ?? .running
        passedTier = run?.passedTier
        escalations = run?.escalations ?? 0
        durationMS = nil
        summary = run?.summary ?? ""
        lines = []
        attempts = []
        appliedFiles = []
        currentTier = nil
        currentModel = [:]
        failedTiers = []
        skippedTiers = []
        pendingApproval = nil
        lastSeq = 0
    }

    public init(detail: DelegateRunDetail, tiers: [DelegateTier]) {
        self.init(runID: detail.run.id, tiers: tiers, run: detail.run)
        attempts = detail.attempts.map { attempt in
            DelegateAttemptOutcome(
                tier: attempt.tier, attempt: attempt.attempt, status: attempt.status,
                verifyExit: attempt.verifyExit, durationMS: attempt.durationMS,
                tokensIn: attempt.tokensIn, tokensOut: attempt.tokensOut,
                changedFiles: attempt.changedFiles, scopeViolations: attempt.scopeViolations,
                verifyTail: attempt.verifyTail, workerSummary: attempt.workerSummary)
        }
        for attempt in detail.attempts {
            currentModel[attempt.tier] = attempt.model
            if attempt.status != .pass && attempt.status != .error { failedTiers.insert(attempt.tier) }
        }
    }

    public static func == (lhs: DelegateRunStory, rhs: DelegateRunStory) -> Bool {
        lhs.runID == rhs.runID && lhs.lastSeq == rhs.lastSeq && lhs.status == rhs.status
            && lhs.lines.count == rhs.lines.count && lhs.attempts.count == rhs.attempts.count
            && lhs.pendingApproval?.tier == rhs.pendingApproval?.tier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(runID)
        hasher.combine(lastSeq)
        hasher.combine(status)
    }

    public var isLive: Bool { status == .running }

    public var needsApproval: Bool { pendingApproval != nil && status == .running }

    /// Folds one envelope; a sequence already seen is ignored so a replayed stream cannot double a line.
    public mutating func fold(_ envelope: DelegateEnvelope) {
        guard envelope.seq > lastSeq else { return }
        lastSeq = envelope.seq
        fold(envelope.event, seq: envelope.seq)
    }

    public mutating func fold(_ event: DelegateEvent, seq: Int) {
        switch event {
        case .runStarted(_, _, let start, let ceiling, let mode, _, _):
            startTier = start
            self.ceiling = ceiling
            self.mode = mode
            status = .running
        case .tierSelected(let tier, _, _, let model, _):
            currentTier = tier
            currentModel[tier] = model
        case .tierSkipped(let tier, _):
            skippedTiers.insert(tier)
        case .attemptStarted(let tier, _, _):
            currentTier = tier
        case .progress:
            break
        case .attemptFinished(let outcome):
            attempts.append(outcome)
            if outcome.status != .pass && outcome.status != .error { failedTiers.insert(outcome.tier) }
        case .approvalRequired(let tier, let reason):
            pendingApproval = (tier, reason)
        case .approvalResolved(let tier, let approved):
            pendingApproval = nil
            if !approved { status = .held; currentTier = tier }
        case .escalated(_, let to, _):
            escalations += 1
            currentTier = to
        case .chainFailover(let tier, _, let to, _):
            currentModel[tier] = to
        case .applied(let files, _):
            appliedFiles = files
        case .runFinished(let status, let passed, let escalations, let duration, let summary):
            self.status = status
            passedTier = passed
            self.escalations = escalations
            durationMS = duration
            self.summary = summary
            pendingApproval = nil
            if status != .running { currentTier = passed ?? currentTier }
        case .unknown:
            break
        }
        if let line = Self.line(for: event, seq: seq) {
            lines.append(line)
        }
    }

    /// The one line each event prints, in the daemon's own wording.
    public static func line(for event: DelegateEvent, seq: Int) -> DelegateStoryLine? {
        switch event {
        case .runStarted(_, let taskClass, let start, let ceiling, let mode, _, _):
            return DelegateStoryLine(
                seq: seq, tier: nil,
                text: Localized.text("%@ · %@ → %@ · %@", taskClass, start, ceiling, DelegateWords.mode(mode).lowercased()),
                tone: .quiet)
        case .tierSelected(let tier, _, _, let model, _):
            return DelegateStoryLine(seq: seq, tier: tier, text: "\(tier) = \(model)", tone: .quiet)
        case .tierSkipped(let tier, let reason):
            return DelegateStoryLine(
                seq: seq, tier: tier, text: Localized.text("%@ skipped: %@", tier, reason), tone: .attention)
        case .attemptStarted(let tier, let attempt, _):
            return DelegateStoryLine(
                seq: seq, tier: tier, text: Localized.text("%@ attempt %d running", tier, attempt), tone: .live)
        case .progress(let tier, _, let text):
            return DelegateStoryLine(seq: seq, tier: tier, text: text, tone: .quiet, isProgress: true)
        case .attemptFinished(let outcome):
            return DelegateStoryLine(
                seq: seq, tier: outcome.tier, text: attemptLine(outcome),
                tone: DelegateWords.tone(outcome.status))
        case .approvalRequired(let tier, let reason):
            return DelegateStoryLine(
                seq: seq, tier: tier, text: Localized.text("%@ needs approval: %@", tier, reason),
                tone: .attention)
        case .approvalResolved(let tier, let approved):
            return DelegateStoryLine(
                seq: seq, tier: tier,
                text: approved ? Localized.text("%@ approved", tier) : Localized.text("%@ held", tier),
                tone: approved ? .live : .attention)
        case .escalated(let from, let to, let reason):
            return DelegateStoryLine(seq: seq, tier: to, text: "\(from) → \(to) (\(reason))", tone: .attention)
        case .chainFailover(let tier, let from, let to, let reason):
            return DelegateStoryLine(
                seq: seq, tier: tier,
                text: Localized.text("%@ ↷ %@ (%@ failed: %@)", tier, to, from, reason), tone: .attention)
        case .applied(let files, let bytes):
            return DelegateStoryLine(
                seq: seq, tier: nil,
                text: Localized.text("applied %@, %d bytes", DelegateWords.files(files.count), bytes), tone: .live)
        case .runFinished(let status, let passed, let escalations, let duration, let summary):
            var text = Localized.text(
                "%@ at %@ · %d escalation(s) · %@", DelegateWords.status(status).lowercased(),
                passed ?? "-", escalations, DelegateWords.seconds(duration))
            if !summary.isEmpty { text += " · " + summary.components(separatedBy: "\n").first! }
            return DelegateStoryLine(seq: seq, tier: passed, text: text, tone: DelegateWords.tone(status))
        case .unknown:
            return nil
        }
    }

    public static func attemptLine(_ outcome: DelegateAttemptOutcome) -> String {
        let mark = outcome.status == .pass ? "✓" : "✗"
        let detail: String
        switch outcome.status {
        case .pass: detail = DelegateWords.files(outcome.changedFiles.count)
        case .fail:
            detail = outcome.verifyExit.map { Localized.text("verify exit %d", $0) } ?? Localized.text("worker failed")
        case .timeout: detail = Localized.text("timed out")
        case .scope: detail = Localized.text("out of scope: %@", outcome.scopeViolations.joined(separator: ", "))
        case .error: detail = Localized.text("never started")
        }
        return "\(outcome.tier) \(mark) \(Localized.text("attempt %d", outcome.attempt)) · \(detail) (\(DelegateWords.seconds(outcome.durationMS)))"
    }

    public var ladder: DelegateLadder {
        let order = tierOrder.isEmpty ? Array(Set([startTier, ceiling, currentTier].compactMap { $0 })).sorted() : tierOrder
        let startIndex = startTier.flatMap { order.firstIndex(of: $0) } ?? 0
        let ceilingIndex = ceiling.flatMap { order.firstIndex(of: $0) } ?? max(order.count - 1, 0)
        let rungs = order.enumerated().map { index, tier -> DelegateRung in
            let state: DelegateRungState
            if index < startIndex {
                state = .belowStart
            } else if index > ceilingIndex {
                state = .beyondCeiling
            } else if passedTier == tier {
                state = .passed
            } else if status == .held, pendingApproval?.tier == tier || (status == .held && currentTier == tier && !failedTiers.contains(tier)) {
                state = .held
            } else if skippedTiers.contains(tier) {
                state = .skipped
            } else if status == .running, currentTier == tier {
                state = pendingApproval?.tier == tier ? .held : .current
            } else if failedTiers.contains(tier) {
                state = .failed
            } else if status == .running, pendingApproval?.tier == tier {
                state = .held
            } else {
                state = .pending
            }
            return DelegateRung(tier: tier, label: tierLabels[tier] ?? "", model: currentModel[tier], state: state)
        }
        return DelegateLadder(rungs: rungs)
    }

    public var headline: String {
        packet?.goal.components(separatedBy: "\n").first.map { String($0.prefix(120)) } ?? runID
    }

    /// The row's second line: where it is now, or how it ended.
    public var subtitle: String {
        switch status {
        case .running:
            if let pending = pendingApproval {
                return Localized.text("Waiting for approval before %@", pending.tier)
            }
            if let tier = currentTier {
                let attempt = attempts.filter { $0.tier == tier }.count + 1
                return Localized.text("%@ attempt %d running", tier, attempt)
            }
            return Localized.text("Starting")
        case .passed:
            let tier = passedTier ?? "-"
            let head = escalations > 0
                ? Localized.text("Passed at %@ after %d escalation(s)", tier, escalations)
                : Localized.text("Passed at %@", tier)
            guard let files = passedFileCount else { return head }
            return head + " · " + DelegateWords.files(files)
        case .failed:
            return summary.isEmpty ? Localized.text("Failed on every rung") : summary
        case .held:
            return Localized.text("Held before %@", currentTier ?? pendingApproval?.tier ?? "-")
        case .cancelled:
            return Localized.text("Cancelled")
        case .error:
            return summary.isEmpty ? Localized.text("The dispatcher hit an error") : summary
        }
    }

    /// How many files the pass landed, from the fold when this device followed it, else from the
    /// daemon's own summary line ("2 file(s): …"); nil when neither says.
    var passedFileCount: Int? {
        if !appliedFiles.isEmpty { return appliedFiles.count }
        if let last = attempts.last, last.status == .pass { return last.changedFiles.count }
        let head = summary.split(separator: ":").first.map(String.init) ?? summary
        guard head.contains("file"), let number = head.split(separator: " ").first, let count = Int(number) else { return nil }
        return count
    }

    public var tone: ActivityTone { DelegateWords.tone(status) }

    /// Work breathes, a wait for you knocks, and anything settled holds still.
    public var activity: ActivityKind? {
        guard status == .running else { return status == .failed || status == .error ? .failed : nil }
        return pendingApproval == nil ? .working : .needsApproval
    }

    public var badge: String? {
        switch status {
        case .running: return nil
        case .passed: return passedTier
        default: return DelegateWords.status(status)
        }
    }

    public var tokensIn: Int { attempts.reduce(0) { $0 + $1.tokensIn } }
    public var tokensOut: Int { attempts.reduce(0) { $0 + $1.tokensOut } }
}
