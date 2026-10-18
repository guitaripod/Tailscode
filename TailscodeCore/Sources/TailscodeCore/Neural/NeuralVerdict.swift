import Foundation

/// What a step and a turn are in the reader's terms, derived once and worn by every surface: a
/// chip, a list mark, a node's ring, a card's clause. The vocabulary reports the outcome, not the
/// mechanism: an error that a later step of the same file or command passed is the agent doing
/// its job, so it reads "Fixed on retry" in amber and never "Failed" in red. A step is `failed`
/// only if it stayed failed. The error's own output is evidence and keeps its ink.
public enum NeuralVerdict {
    /// How many tool messages the agent may take after an error, in a turn still running, and
    /// still be trying again; past that it has moved on, and the error stands.
    public static let movedOnAfter = 3

    public enum Step: Sendable, Equatable, CaseIterable {
        case done
        /// An error, and a later step of the same file or command passed.
        case fixed
        /// An error nobody fixed.
        case failed
        /// An error in a turn still running that the agent has not yet moved on from.
        case tryingAgain
        case running
        case waiting
        case stalled
        case stopped

        /// The chip's words in the reader's terms: "Fixed on retry", "Failed", "Hit an error".
        public var word: String {
            switch self {
            case .done: return NeuralReading.verdictDone
            case .fixed: return NeuralReading.verdictFixed
            case .failed: return NeuralReading.verdictFailed
            case .tryingAgain: return NeuralReading.verdictHitError
            case .running: return NeuralReading.verdictRunning
            case .waiting: return NeuralReading.verdictWaiting
            case .stalled: return NeuralReading.verdictStuck
            case .stopped: return NeuralReading.verdictStopped
            }
        }

        /// Fixed and trying again are attention, failed is danger, running is live; a finished
        /// or stopped step is quiet.
        public var tone: NeuralTone {
            switch self {
            case .done, .stopped: return .quiet
            case .fixed, .tryingAgain, .waiting, .stalled: return .attention
            case .failed: return .danger
            case .running: return .live
            }
        }

        /// The chip kind the readout wears for it.
        public var chipKind: NeuralReadout.ChipKind {
            switch self {
            case .done: return .done
            case .fixed: return .fixed
            case .failed: return .failed
            case .tryingAgain: return .hitError
            case .running: return .running
            case .waiting: return .waiting
            case .stalled: return .stalled
            case .stopped: return .stopped
            }
        }

        /// Whether a list marks it: a step that is done says nothing.
        public var isMarked: Bool { self != .done }

        /// The step ended in an error somebody has since fixed or is about to retry.
        public var isError: Bool { self == .fixed || self == .failed || self == .tryingAgain }
    }

    public enum Turn: Sendable, Equatable {
        case done
        /// Done, and `count` errors were fixed on the way.
        case doneAfterRetries(Int)
        case needsYou
        case working
        case stuck
        case stopped
        /// The turn ended without a word.
        case didntAnswer
        case failed

        /// "Done", "Done, fixed 1 error", "Needs you", "Working", "Stuck", "Stopped", "Didn't
        /// answer", "Failed".
        public var word: String {
            switch self {
            case .done: return NeuralReading.verdictDone
            case .doneAfterRetries(let count): return NeuralReading.doneFixed(count)
            case .needsYou: return NeuralReading.verdictNeedsYou
            case .working: return NeuralReading.verdictWorking
            case .stuck: return NeuralReading.verdictStuck
            case .stopped: return NeuralReading.verdictStopped
            case .didntAnswer: return NeuralReading.verdictDidntAnswer
            case .failed: return NeuralReading.verdictFailed
            }
        }

        /// The pill's words: a turn that fixed an error on the way is the same quiet "Done" as a clean
        /// one, and says what it fixed in a clause beside it.
        public var pillWord: String {
            if case .doneAfterRetries = self { return NeuralReading.verdictDone }
            return word
        }

        /// The pill's tone: quiet for any done turn, the clause carries the amber.
        public var pillTone: NeuralTone {
            if case .doneAfterRetries = self { return .quiet }
            return tone
        }

        public var tone: NeuralTone {
            switch self {
            case .done, .stopped, .didntAnswer: return .quiet
            case .doneAfterRetries, .needsYou, .stuck: return .attention
            case .working: return .live
            case .failed: return .danger
            }
        }
    }

    /// A step's verdict with the facts the words are written from.
    public struct StepReading: Sendable, Equatable {
        public let verdict: Step
        /// The later step that passed, for a fixed one.
        public let fixedBy: String?
        /// One-based, the passing step's.
        public let fixedByNumber: Int?
        /// What the error said, short: "switch must be exhaustive".
        public let error: String?

        public var word: String { verdict.word }
        public var tone: NeuralTone { verdict.tone }

        /// The sentence under a chip: "It failed here (switch must be exhaustive) and passed at
        /// step 12." for a fixed step; nil for the others.
        public var detail: String? {
            guard verdict == .fixed, let number = fixedByNumber else { return nil }
            return NeuralReading.fixedDetail(error: error, number: number)
        }

        /// The chip and its sentence: "Fixed on retry. It failed here ... and passed at step 12."
        public var sentence: String {
            detail.map { Localized.text("%1$@. %2$@", word, $0) } ?? word
        }
    }

    /// A turn's verdict with every step's.
    public struct TurnReading: Sendable, Equatable {
        public let verdict: Turn
        public let steps: [StepReading]
        /// Errors fixed on the way.
        public let fixed: Int
        /// Errors nobody fixed.
        public let unfixed: Int
        public let firstUnfixedStepID: String?

        /// The words the card's headline clause wears: "Done, fixed 1 error", "1 step failed";
        /// nil for a turn that is done, working or waiting, which say so elsewhere.
        public var clause: String? {
            switch verdict {
            case .doneAfterRetries(let count): return NeuralReading.doneFixed(count)
            case .failed:
                return unfixed > 0 ? NeuralReading.stepsFailed(unfixed) : NeuralReading.verdictFailed
            case .didntAnswer: return NeuralReading.verdictDidntAnswer
            case .done, .needsYou, .working, .stuck, .stopped: return nil
            }
        }

        public var word: String { verdict.word }
        public var tone: NeuralTone { verdict.tone }

        /// "Fixed 1 error on the way": the turn's count of errors fixed, nil when none.
        public var onTheWay: String? { fixed > 0 ? NeuralReading.fixedOnTheWay(fixed) : nil }
    }

    /// Reads a turn once: O(steps).
    public static func read(_ turn: NeuralTurn) -> TurnReading {
        let steps = turn.steps
        let running = turn.outcome == .running
        let passes = passingIndices(steps)
        let later = toolGroupsAfter(steps)
        var readings: [StepReading] = []
        readings.reserveCapacity(steps.count)
        var fixed = 0
        var unfixed = 0
        var firstUnfixed: String?
        for (index, step) in steps.enumerated() {
            let reading = reading(
                of: step, at: index, steps: steps, running: running, passes: passes,
                groupsAfter: later[index])
            readings.append(reading)
            if reading.verdict == .fixed { fixed += 1 }
            if reading.verdict == .failed {
                unfixed += 1
                if firstUnfixed == nil { firstUnfixed = step.id }
            }
        }
        let verdict = turnVerdict(turn, fixed: fixed, unfixed: unfixed, steps: steps)
        return TurnReading(
            verdict: verdict, steps: readings, fixed: fixed, unfixed: unfixed,
            firstUnfixedStepID: firstUnfixed)
    }

    /// One step's verdict without reading the turn: for a surface that has a step and its turn.
    public static func step(at index: Int, in turn: NeuralTurn) -> StepReading {
        let steps = turn.steps
        guard steps.indices.contains(index) else {
            return StepReading(verdict: .done, fixedBy: nil, fixedByNumber: nil, error: nil)
        }
        return reading(
            of: steps[index], at: index, steps: steps, running: turn.outcome == .running,
            passes: passingIndices(steps), groupsAfter: toolGroupsAfter(steps)[index])
    }

    // MARK: Rules

    private static func turnVerdict(
        _ turn: NeuralTurn, fixed: Int, unfixed: Int, steps: [NeuralStep]
    ) -> Turn {
        switch turn.outcome {
        case .running:
            if steps.contains(where: { $0.status == .waitingApproval || $0.status == .waitingAnswer }) {
                return .needsYou
            }
            if steps.contains(where: { $0.status == .stalled }) { return .stuck }
            return .working
        case .failed: return .failed
        case .stopped, .interrupted: return .stopped
        case .answerless: return .didntAnswer
        case .settled:
            if unfixed > 0 { return .failed }
            return fixed > 0 ? .doneAfterRetries(fixed) : .done
        }
    }

    private static func reading(
        of step: NeuralStep, at index: Int, steps: [NeuralStep], running: Bool,
        passes: [String: [Int]], groupsAfter: Int
    ) -> StepReading {
        func plain(_ verdict: Step) -> StepReading {
            StepReading(verdict: verdict, fixedBy: nil, fixedByNumber: nil, error: nil)
        }
        switch step.status {
        case .ok: return plain(.done)
        case .running: return plain(.running)
        case .waitingApproval, .waitingAnswer: return plain(.waiting)
        case .stalled: return plain(.stalled)
        case .stopped: return plain(.stopped)
        case .failed:
            let error = errorSummary(of: step)
            if step.recovered, let passing = passer(of: step, at: index, passes: passes) {
                return StepReading(
                    verdict: .fixed, fixedBy: steps[passing].id, fixedByNumber: passing + 1, error: error)
            }
            if step.recovered {
                return StepReading(verdict: .fixed, fixedBy: nil, fixedByNumber: nil, error: error)
            }
            let trying = running && groupsAfter < movedOnAfter
            return StepReading(
                verdict: trying ? .tryingAgain : .failed, fixedBy: nil, fixedByNumber: nil,
                error: error)
        }
    }

    /// The identity a retry shares with the step it retries: a command, or a tool and its file.
    static func identity(of step: NeuralStep) -> String? {
        guard let key = step.tieKey else { return nil }
        return step.tieIsCommand ? "c\u{1}" + key : "f\u{1}" + step.title + "\u{1}" + key
    }

    /// The indices of the steps that passed, by identity, in order.
    private static func passingIndices(_ steps: [NeuralStep]) -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        for (index, step) in steps.enumerated() where step.status == .ok {
            if let key = identity(of: step) { out[key, default: []].append(index) }
        }
        return out
    }

    private static func passer(of step: NeuralStep, at index: Int, passes: [String: [Int]]) -> Int? {
        guard let key = identity(of: step), let list = passes[key] else { return nil }
        var low = 0
        var high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid] <= index { low = mid + 1 } else { high = mid }
        }
        return low < list.count ? list[low] : nil
    }

    /// For every step, how many other messages of tool calls came after it.
    private static func toolGroupsAfter(_ steps: [NeuralStep]) -> [Int] {
        var out = [Int](repeating: 0, count: steps.count)
        var seen = Set<Int>()
        for index in steps.indices.reversed() {
            let group = steps[index].group
            out[index] = seen.count - (seen.contains(group) ? 1 : 0)
            if NeuralReading.isTool(steps[index]) { seen.insert(group) }
        }
        return out
    }

    /// What an error said, short: the first line of its output that names the error, with
    /// anything before "error:" dropped.
    public static func errorSummary(of step: NeuralStep) -> String? {
        let line = NeuralReadoutBuilder.errorLine(of: step)
        guard !line.isEmpty else { return nil }
        var text = line
        if let range = line.range(of: "error:", options: .caseInsensitive) {
            text = String(line[range.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return NeuralReadoutText.capped(text, limit: 80).text
    }
}

extension NeuralReading {
    public static var verdictDone: String { Localized.text("Done") }
    public static var verdictFixed: String { Localized.text("Fixed on retry") }
    public static var verdictFailed: String { Localized.text("Failed") }
    public static var verdictHitError: String { Localized.text("Hit an error") }
    public static var verdictRunning: String { Localized.text("Running") }
    public static var verdictWaiting: String { Localized.text("Waiting for you") }
    public static var verdictStuck: String { Localized.text("Stuck") }
    public static var verdictStopped: String { Localized.text("Stopped") }
    public static var verdictNeedsYou: String { Localized.text("Needs you") }
    public static var verdictWorking: String { Localized.text("Working") }
    public static var verdictDidntAnswer: String { Localized.text("Didn't answer") }

    /// "Done, fixed 1 error", "Done, fixed 3 errors".
    public static func doneFixed(_ count: Int) -> String {
        count == 1 ? Localized.text("Done, fixed 1 error") : Localized.text("Done, fixed %lld errors", count)
    }

    /// The heading over a list of errors that were all fixed.
    public static var fixedOnTheWayLabel: String { Localized.text("Fixed on the way") }

    /// "1 step failed", "2 steps failed".
    public static func stepsFailed(_ count: Int) -> String {
        count == 1 ? Localized.text("1 step failed") : Localized.text("%lld steps failed", count)
    }

    /// "fixed 1 error on the way": the header's clause beside the pill, lower case.
    public static func fixedOnTheWayClause(_ count: Int) -> String {
        count == 1
            ? Localized.text("fixed 1 error on the way")
            : Localized.text("fixed %lld errors on the way", count)
    }

    /// "Fixed 1 error on the way", "Fixed 3 errors on the way".
    public static func fixedOnTheWay(_ count: Int) -> String {
        count == 1
            ? Localized.text("Fixed 1 error on the way")
            : Localized.text("Fixed %lld errors on the way", count)
    }

    /// "It failed here (switch must be exhaustive) and passed at step 12."
    public static func fixedDetail(error: String?, number: Int) -> String {
        guard let error, !error.isEmpty else {
            return Localized.text("It failed here and passed at step %lld.", number)
        }
        return Localized.text("It failed here (%1$@) and passed at step %2$lld.", error, number)
    }

    /// "fixed an error at step 8": a work line's amber words.
    public static func fixedAtStep(_ number: Int) -> String {
        Localized.text("fixed an error at step %lld", number)
    }

    /// The status word of a step in the reader's terms: "fixed on retry" for a failure a later
    /// step passed, the raw status word otherwise.
    public static func statusWord(of step: NeuralStep) -> String {
        step.status == .failed && step.recovered
            ? Localized.text("fixed on retry") : statusWord(step.status)
    }
}

/// Holds the reading the model last made, so every surface asks it for free.
final class NeuralVerdictCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stamp: Int?
    private var held: NeuralVerdict.TurnReading?

    func reading(stamp wanted: Int, make: () -> NeuralVerdict.TurnReading) -> NeuralVerdict.TurnReading {
        lock.lock()
        defer { lock.unlock() }
        if let held, stamp == wanted { return held }
        let built = make()
        held = built
        stamp = wanted
        return built
    }
}

extension NeuralBrainModel {
    /// Every step's verdict and the turn's, read once per change.
    public var verdicts: NeuralVerdict.TurnReading {
        let turn = self.turn
        return verdictCache.reading(stamp: accountStamp) { NeuralVerdict.read(turn) }
    }

    /// The turn's verdict.
    public var turnVerdict: NeuralVerdict.Turn { verdicts.verdict }

    /// A step's verdict, from the one reading.
    public func verdict(ofStep id: String) -> NeuralVerdict.StepReading? {
        guard let index = indexByID[id], verdicts.steps.indices.contains(index) else { return nil }
        return verdicts.steps[index]
    }
}
