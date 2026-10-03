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
    /// What a failed attempt left behind — the verifier's last lines, the files out of scope —
    /// carried under its line instead of in a second list that tells the same attempt twice.
    public var detail: String?

    public var id: Int { seq }

    public init(seq: Int, tier: String?, text: String, tone: ActivityTone, isProgress: Bool = false, detail: String? = nil) {
        self.seq = seq
        self.tier = tier
        self.text = text
        self.tone = tone
        self.isProgress = isProgress
        self.detail = detail
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
    /// What the numbers say about this rung for the class being written — a pass rate and an
    /// average, or that it is untried — so a start is chosen on evidence rather than a hunch.
    public var note: String?

    public var id: String { tier }

    public init(tier: String, label: String = "", model: String? = nil, state: DelegateRungState, note: String? = nil) {
        self.tier = tier
        self.label = label
        self.model = model
        self.state = state
        self.note = note
    }
}

/// What a settled run invites next. Two roads and no more: the same packet on another rung —
/// one down after a pass, to qualify the cheaper tier; one up or the same after a stop — and a
/// fresh packet that starts from this one's words.
public struct DelegateNextStep: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case replay(tier: String)
        case duplicate
    }

    public var kind: Kind
    public var title: String
    public var detail: String

    public var id: String {
        switch kind {
        case .replay(let tier): return "replay:\(tier)"
        case .duplicate: return "duplicate"
        }
    }

    public init(kind: Kind, title: String, detail: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }

    public static var duplicate: DelegateNextStep {
        DelegateNextStep(
            kind: .duplicate, title: Localized.text("New packet like this"),
            detail: Localized.text("The same goal, paths and verifier, open to edit before it goes."))
    }
}

/// What the app says when a run it follows needs a person or is over: the words are the story's,
/// and a client only decides how its platform taps a shoulder.
public struct DelegateNotice: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case asks
        case passed
        case failed
    }

    public var kind: Kind
    public var title: String
    public var body: String

    public init(kind: Kind, title: String, body: String) {
        self.kind = kind
        self.title = title
        self.body = body
    }
}

/// The ladder of one run: every tier the daemon knows, each with where it stands for this run.
public struct DelegateLadder: Sendable, Hashable {
    public var rungs: [DelegateRung]
    /// How the run ended, or nil while it is out: a rung it never reached is "waiting" only while
    /// there is still something to wait for.
    public var settledAs: DelegateRunStatus?

    public init(rungs: [DelegateRung], settledAs: DelegateRunStatus? = nil) {
        self.rungs = rungs
        self.settledAs = settledAs
    }

    public var lit: DelegateRung? { rungs.last { $0.state.isLit } }

    /// The words a screen reader gets: each rung and its state, cheapest first.
    public var spoken: String {
        rungs.map { "\($0.tier) \(word(for: $0))" }.joined(separator: ", ")
    }

    /// One rung's word for this run: a rung inside the range the run never reached reads "not
    /// needed" after a pass and "not reached" after any other end.
    public func word(for rung: DelegateRung) -> String {
        guard rung.state == .pending, let settledAs else { return Self.word(rung.state) }
        return settledAs == .passed ? Localized.text("not needed") : Localized.text("not reached")
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
    /// The files the passing patch touches, wherever it went.
    public var patchFiles: [String]
    /// Where the passing patch went: into the tree, held for a person, or set aside.
    public var delivery: DelegateDelivery?
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
        patchFiles = []
        delivery = run?.effectiveDelivery
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
            if attempt.status == .pass { patchFiles = attempt.changedFiles }
        }
    }

    public static func == (lhs: DelegateRunStory, rhs: DelegateRunStory) -> Bool {
        lhs.runID == rhs.runID && lhs.lastSeq == rhs.lastSeq && lhs.status == rhs.status
            && lhs.lines.count == rhs.lines.count && lhs.attempts.count == rhs.attempts.count
            && lhs.pendingApproval?.tier == rhs.pendingApproval?.tier && lhs.delivery == rhs.delivery
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(runID)
        hasher.combine(lastSeq)
        hasher.combine(status)
        hasher.combine(delivery)
    }

    public var isLive: Bool { status == .running }

    public var needsApproval: Bool { pendingApproval != nil && status == .running }

    /// A pass whose patch is held until somebody reads it.
    public var needsReview: Bool { status == .passed && delivery == .pending }

    /// Waiting on a person in either way a run can: a rung to approve or a patch to read.
    public var needsYou: Bool { needsApproval || needsReview }

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
            if outcome.status == .pass { patchFiles = outcome.changedFiles }
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
            patchFiles = files
            delivery = .applied
        case .awaitingReview(let files, _):
            patchFiles = files
            delivery = .pending
        case .discarded(let files):
            if !files.isEmpty { patchFiles = files }
            delivery = .discarded
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
                tone: DelegateWords.tone(outcome.status), detail: failureDetail(outcome))
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
        case .applied(let files, _):
            return DelegateStoryLine(
                seq: seq, tier: nil,
                text: Localized.text("Applied %@ to the tree, unstaged", DelegateWords.files(files.count)), tone: .live)
        case .awaitingReview(let files, _):
            return DelegateStoryLine(
                seq: seq, tier: nil,
                text: Localized.text("Holding %@ for your review", DelegateWords.files(files.count)), tone: .attention)
        case .discarded(let files):
            return DelegateStoryLine(
                seq: seq, tier: nil,
                text: Localized.text("Discarded %@; the tree never saw them", DelegateWords.files(files.count)), tone: .quiet)
        case .runFinished(let status, let passed, let escalations, let duration, let summary):
            var parts: [String] = []
            if let passed {
                parts.append(Localized.text("%@ at %@", DelegateWords.status(status), passed))
            } else {
                parts.append(DelegateWords.status(status))
            }
            if escalations > 0 { parts.append(DelegateWords.escalations(escalations)) }
            parts.append(DelegateWords.seconds(duration))
            if let said = DelegateWords.summaryClaim(summary, status: status) { parts.append(said) }
            return DelegateStoryLine(seq: seq, tier: passed, text: parts.joined(separator: " · "), tone: DelegateWords.tone(status))
        case .unknown:
            return nil
        }
    }

    /// What a failed attempt leaves under its line: the files it touched outside its paths, or the
    /// last lines the verifier or worker printed, trimmed to what fits under one row.
    public static func failureDetail(_ outcome: DelegateAttemptOutcome) -> String? {
        switch outcome.status {
        case .pass, .error:
            return nil
        case .scope:
            return outcome.scopeViolations.isEmpty ? nil : outcome.scopeViolations.joined(separator: "\n")
        case .fail, .timeout:
            return DelegateWords.tail(outcome.verifyTail)
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
        case .scope:
            detail = outcome.scopeViolations.count == 1
                ? Localized.text("changed a file outside its paths")
                : Localized.text("changed %d files outside its paths", outcome.scopeViolations.count)
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
        return DelegateLadder(rungs: rungs, settledAs: status == .running ? nil : status)
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
            var parts = [passedTier.map { Localized.text("Passed at %@", $0) } ?? DelegateWords.status(.passed)]
            if escalations > 0 { parts[0] += " " + DelegateWords.afterEscalations(escalations) }
            if let files = passedFileCount { parts.append(DelegateWords.files(files)) }
            switch delivery {
            case .pending: parts.append(Localized.text("waiting for your review"))
            case .discarded: parts.append(Localized.text("discarded"))
            case .applied, nil: break
            }
            return parts.joined(separator: " · ")
        case .failed:
            if let last = lastFailure {
                return Localized.text("Stopped at %@ · %@", last.tier, DelegateRunStory.attemptReason(last))
            }
            if let tier = Self.stoppedTier(summary) {
                return Localized.text("Stopped at %@ after every rung it could climb", tier)
            }
            return Localized.text("Failed on every rung")
        case .held:
            return Localized.text("Held before %@", currentTier ?? pendingApproval?.tier ?? "-")
        case .cancelled:
            return Localized.text("Cancelled")
        case .error:
            return summary.isEmpty ? Localized.text("The dispatcher hit an error") : summary
        }
    }

    /// The rung a stored failure names ("exhausted ladder; last failure at t2 attempt 1"), for a row
    /// drawn from the record before its attempts have been read.
    static func stoppedTier(_ summary: String) -> String? {
        guard let range = summary.range(of: "last failure at ") else { return nil }
        let tier = summary[range.upperBound...].split(separator: " ").first.map(String.init)
        return tier?.isEmpty == false ? tier : nil
    }

    /// How many files the pass landed, from the fold when this device followed it, else from the
    /// daemon's own summary line ("2 file(s): …"); nil when neither says.
    var passedFileCount: Int? {
        if !patchFiles.isEmpty { return patchFiles.count }
        if let last = attempts.last, last.status == .pass { return last.changedFiles.count }
        let head = summary.split(separator: ":").first.map(String.init) ?? summary
        guard head.contains("file"), let number = head.split(separator: " ").first, let count = Int(number) else { return nil }
        return count
    }

    public var tone: ActivityTone { needsReview ? .attention : DelegateWords.tone(status) }

    /// Work breathes, a wait for you knocks — a rung to approve or a patch to read — and anything
    /// settled holds still.
    public var activity: ActivityKind? {
        if needsReview { return .needsApproval }
        guard status == .running else { return status == .failed || status == .error ? .failed : nil }
        return pendingApproval == nil ? .working : .needsApproval
    }

    /// The word a row's pill says. A pass says where its patch went rather than the rung it passed
    /// at, which the line under the headline already gives.
    public var badge: String? {
        switch status {
        case .running: return needsApproval ? Localized.text("Approve") : nil
        case .passed:
            switch delivery {
            case .pending: return Localized.text("Review")
            case .discarded: return Localized.text("Discarded")
            case .applied, nil: return Localized.text("Applied")
            }
        default: return DelegateWords.status(status)
        }
    }

    /// The last attempt that failed, the one a stopped run is explained by.
    public var lastFailure: DelegateAttemptOutcome? {
        attempts.last { $0.status != .pass && $0.status != .error } ?? attempts.last { $0.status == .error }
    }

    /// Why one attempt failed, in the fewest words that still say it.
    public static func attemptReason(_ outcome: DelegateAttemptOutcome) -> String {
        switch outcome.status {
        case .pass: return DelegateWords.attemptStatus(.pass)
        case .fail:
            return outcome.verifyExit.map { Localized.text("the verifier exited %d", $0) } ?? Localized.text("the worker failed")
        case .timeout: return Localized.text("timed out")
        case .scope:
            return outcome.scopeViolations.count == 1
                ? Localized.text("changed a file outside its paths")
                : Localized.text("changed %d files outside its paths", outcome.scopeViolations.count)
        case .error: return Localized.text("the worker never started")
        }
    }

    public var tokensIn: Int { attempts.reduce(0) { $0 + $1.tokensIn } }
    public var tokensOut: Int { attempts.reduce(0) { $0 + $1.tokensOut } }

    /// The highest rung this run tried, from its attempts and where it was standing.
    public var highestTriedTier: String? {
        let order = tierOrder
        let tried = Set(attempts.map(\.tier) + [currentTier].compactMap { $0 })
        return order.last { tried.contains($0) } ?? tried.first
    }

    /// What this run invites next, empty while it is still out.
    public func nextSteps(tierOrder order: [String]) -> [DelegateNextStep] {
        guard !isLive else { return [] }
        let ladder = order.isEmpty ? tierOrder : order
        var steps: [DelegateNextStep] = []
        switch status {
        case .passed:
            if let passed = passedTier, let index = ladder.firstIndex(of: passed), index > 0 {
                let cheaper = ladder[index - 1]
                if !failedTiers.contains(cheaper) {
                    steps.append(
                        DelegateNextStep(
                            kind: .replay(tier: cheaper), title: Localized.text("Try it at %@", cheaper),
                            detail: Localized.text("The same packet one rung down — a pass there is a streak the table can promote on.")))
                }
            }
        case .failed, .held, .cancelled, .error:
            if let tried = highestTriedTier, let index = ladder.firstIndex(of: tried) {
                if index + 1 < ladder.count {
                    steps.append(
                        DelegateNextStep(
                            kind: .replay(tier: ladder[index + 1]), title: Localized.text("Climb to %@", ladder[index + 1]),
                            detail: Localized.text("The same packet one rung above where it stopped.")))
                }
                steps.append(
                    DelegateNextStep(
                        kind: .replay(tier: tried), title: Localized.text("Run it again at %@", tried),
                        detail: status == .held
                            ? Localized.text("Start over where it was held.")
                            : Localized.text("Another attempt on the same rung.")))
            }
        case .running:
            break
        }
        steps.append(.duplicate)
        return steps
    }

    /// The notice one event earns once it has been folded: a rung waiting for a person, or an end
    /// nobody chose. A hold or a cancel is the person's own doing and says nothing.
    public func notice(after event: DelegateEvent) -> DelegateNotice? {
        switch event {
        case .approvalRequired(let tier, _):
            return DelegateNotice(
                kind: .asks, title: Localized.text("Delegate needs you"),
                body: Localized.text("%@ waits before %@", headline, tier))
        case .runFinished(let status, let passed, _, _, _):
            switch status {
            case .passed:
                if delivery == .pending {
                    return DelegateNotice(
                        kind: .passed, title: Localized.text("Ready for your review"),
                        body: headline + " · " + DelegateWords.files(passedFileCount ?? patchFiles.count))
                }
                return DelegateNotice(
                    kind: .passed,
                    title: passed.map { Localized.text("Delegate passed at %@", $0) } ?? Localized.text("Delegate passed"),
                    body: headline)
            case .failed, .error:
                return DelegateNotice(kind: .failed, title: Localized.text("Delegate failed"), body: headline + " · " + subtitle)
            case .running, .held, .cancelled:
                return nil
            }
        default:
            return nil
        }
    }
}
