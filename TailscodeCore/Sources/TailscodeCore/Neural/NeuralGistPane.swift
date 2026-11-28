import Foundation

/// A turn in short as a client draws it: the model's title, sentence and stages, and beside each
/// stage what the turn itself counts there (its steps, the errors fixed and left, the lines
/// written). The words are the model's and wear its mark; the numbers are read from the steps
/// and are right whatever the model wrote. A client lays this out and decides nothing.
public struct NeuralGistPane: Sendable, Equatable {
    /// A stage is over or it is the one the turn is in. An error left in a stage is a count and a
    /// tick beside it and never the stage's mark: one failed command among ninety steps does not
    /// make the stage a failure, and a column of red marks would say the turn was one.
    public enum Mark: Sendable, Equatable {
        case done
        /// The stage the turn is in.
        case now
    }

    /// An error on a stage's stretch of the rail, by how far along the stage it happened.
    public struct Tick: Sendable, Equatable {
        public let at: Double
        public let failed: Bool
    }

    public struct Row: Identifiable, Sendable, Equatable {
        public let id: String
        /// Zero-based place among the stages.
        public let index: Int
        public let says: String
        public let mark: Mark
        /// One-based, inclusive.
        public let from: Int
        public let to: Int
        public let stepCount: Int
        public let fixed: Int
        public let unfixed: Int
        public let added: Int
        public let removed: Int
        /// What the stage's messages cost in dollars as the server priced them; nil where it
        /// priced none.
        public let costUSD: Double?
        /// The stage's share of the turn's steps, for its stretch of the rail.
        public let weight: Double
        public let ticks: [Tick]
        public let firstStepID: String

        public var numbers: ClosedRange<Int> { from...to }
        /// "69 steps".
        public var stepsWords: String { NeuralGistWords.steps(stepCount) }
        /// "2 fixed", nil when none were.
        public var fixedWords: String? { fixed > 0 ? Localized.text("%lld fixed", fixed) : nil }
        /// "1 failed", nil when none stayed failed.
        public var failedWords: String? { unfixed > 0 ? Localized.text("%lld failed", unfixed) : nil }
        /// "+612 \u{2212}48", nil when the stage wrote nothing.
        public var tally: String? { NeuralReading.tally(added, removed) }
        /// "steps 92\u{2013}160".
        public var rangeWords: String { NeuralGistWords.range(from, to) }
        /// What the stage cost, in the person's currency with the mark of an estimate: "~\u{20AC}3.10".
        public var costWords: String? { costUSD.map(Money.approximate) }

        /// The row with no price: a server that prices a turn as one figure prices no stage, and
        /// that figure on the first stage alone would say the first stage cost it all.
        var unpriced: Row {
            Row(
                id: id, index: index, says: says, mark: mark, from: from, to: to, stepCount: stepCount, fixed: fixed,
                unfixed: unfixed, added: added, removed: removed, costUSD: nil, weight: weight, ticks: ticks,
                firstStepID: firstStepID)
        }

        /// Everything counted about the stage on one line, for a sheet's subtitle and a screen
        /// reader: "stage 3 of 6 \u{00B7} steps 92\u{2013}160 \u{00B7} 2 fixed \u{00B7} +612 \u{2212}48".
        public func facts(of count: Int) -> String {
            [NeuralGistWords.place(index + 1, of: count), rangeWords, fixedWords, failedWords, tally, costWords]
                .compactMap { $0 }.joined(separator: " \u{00B7} ")
        }
    }

    public let phase: NeuralGistDesk.Phase
    /// The model's title, or who is reading while the first telling is written.
    public let title: String
    /// "Pennyroyal on arch".
    public let byline: String
    /// The model's sentence; empty while the first telling is written.
    public let now: String
    public let rows: [Row]
    public let isRunning: Bool
    /// A newer telling is being written.
    public let isRefreshing: Bool
    /// How many steps the turn has.
    public let stepCount: Int

    public var isWriting: Bool { phase == .writing }

    /// The pane for a turn, or nil when there is nothing told and nothing being written, which
    /// is when a client shows the account as it always did.
    public static func make(reading: NeuralGistDesk.Reading, model: NeuralBrainModel) -> NeuralGistPane? {
        let steps = model.steps
        let running = model.turn.outcome == .running
        let byline = NeuralGistWords.byline(writer: reading.writer, place: reading.place)
        switch reading.phase {
        case .none:
            return nil
        case .writing:
            return NeuralGistPane(
                phase: .writing, title: NeuralGistWords.reading(writer: reading.writer, steps: steps.count),
                byline: byline, now: "", rows: [], isRunning: running, isRefreshing: true,
                stepCount: steps.count)
        case .told:
            guard let gist = reading.gist, !steps.isEmpty, gist.stepCount <= steps.count else { return nil }
            let verdicts = model.verdicts.steps
            var rows: [Row] = []
            for (index, stage) in gist.stages.enumerated() {
                let isLast = index == gist.stages.count - 1
                let from = min(stage.from, steps.count)
                let to = isLast ? steps.count : min(stage.to, steps.count)
                guard from >= 1, to >= from else { continue }
                var fixed = 0
                var unfixed = 0
                var added = 0
                var removed = 0
                var cost: Double?
                var ticks: [Tick] = []
                let count = to - from + 1
                for number in from...to {
                    let step = steps[number - 1]
                    added += step.added ?? 0
                    removed += step.removed ?? 0
                    if let price = step.costUSD { cost = (cost ?? 0) + price }
                    guard number - 1 < verdicts.count else { continue }
                    let at = (Double(number - from) + 0.5) / Double(count)
                    switch verdicts[number - 1].verdict {
                    case .fixed:
                        fixed += 1
                        ticks.append(Tick(at: at, failed: false))
                    case .failed:
                        unfixed += 1
                        ticks.append(Tick(at: at, failed: true))
                    case .tryingAgain:
                        ticks.append(Tick(at: at, failed: false))
                    default:
                        break
                    }
                }
                let mark: Mark = isLast && running ? .now : .done
                rows.append(
                    Row(
                        id: "stage:\(from)", index: rows.count, says: stage.says, mark: mark, from: from, to: to,
                        stepCount: count, fixed: fixed, unfixed: unfixed, added: added, removed: removed,
                        costUSD: cost, weight: Double(count) / Double(steps.count), ticks: ticks,
                        firstStepID: steps[from - 1].id))
            }
            guard !rows.isEmpty else { return nil }
            if rows.contains(where: { $0.costUSD == nil }) { rows = rows.map { $0.unpriced } }
            return NeuralGistPane(
                phase: .told, title: gist.title, byline: byline, now: gist.now, rows: rows,
                isRunning: running, isRefreshing: reading.refreshing, stepCount: steps.count)
        }
    }

    public func row(containing number: Int) -> Row? {
        rows.first { $0.numbers.contains(number) }
    }

    /// The row a move of `delta` from `index` lands on, held at the ends; from nothing, the stage
    /// the turn is in, which is the last.
    public func index(moving delta: Int, from index: Int?) -> Int? {
        guard !rows.isEmpty else { return nil }
        guard let index else { return delta < 0 ? rows.count - 1 : 0 }
        return min(max(index + delta, 0), rows.count - 1)
    }
}

/// Every word a telling's surfaces say, so the three clients say the same thing. A model's own
/// words wear `mark` wherever they stand beside words the app wrote.
public enum NeuralGistWords {
    public static let mark = "\u{2726}"

    public static var title: String { Localized.text("In short") }

    /// "Told 46", "Told 9 of 46".
    public static func told(_ count: Int, of total: Int? = nil) -> String {
        guard let total, total != count else { return Localized.text("Told %lld", count) }
        return Localized.text("Told %1$lld of %2$lld", count, total)
    }

    public static func steps(_ count: Int) -> String {
        count == 1 ? Localized.text("1 step") : Localized.text("%lld steps", count)
    }

    public static func range(_ from: Int, _ to: Int) -> String {
        from == to ? Localized.text("step %lld", from) : Localized.text("steps %1$lld\u{2013}%2$lld", from, to)
    }

    public static func place(_ number: Int, of count: Int) -> String {
        Localized.text("stage %1$lld of %2$lld", number, count)
    }

    public static func byline(writer: String, place: String) -> String {
        guard !place.isEmpty else { return writer }
        return Localized.text("%@ on %@", writer, place)
    }

    public static func reading(writer: String, steps: Int) -> String {
        Localized.text("%1$@ is reading %2$lld steps\u{2026}", writer, steps)
    }

    /// What the mark means, for a tooltip and a screen reader.
    public static func provenance(writer: String, place: String) -> String {
        Localized.text(
            "Written by %@ from this turn's notes and steps. The numbers are counted, not written.",
            byline(writer: writer, place: place))
    }

    public static var backToShort: String { Localized.text("In short") }
    public static var stagesHint: String { Localized.text("stages") }
    public static var openStageHint: String { Localized.text("what it told you there") }
    public static var toggleHint: String { Localized.text("in short / told") }
    public static var neighbourHint: String { Localized.text("stage before / after") }
    public static var nowLabel: String { Localized.text("NOW") }

    public static var settingTitle: String { Localized.text("Tell each turn in short") }

    public static var settingSubtitle: String {
        Localized.text(
            "Megatron opens on what a turn is for, what is happening and the stages so far, written from the agent's own notes. The counts beside them are counted, never written."
        )
    }

    /// What a settled turn came to in counts, under its stages: "5 files changed +1108 \u{2212}0
    /// \u{00B7} Fixed 1 error on the way". Empty while the turn runs.
    public static func result(of account: NeuralAccount) -> String {
        guard let result = account.result else { return "" }
        var parts: [String] = []
        if !result.changes.isEmpty {
            let files = result.changes.count == 1
                ? Localized.text("1 file changed") : Localized.text("%lld files changed", result.changes.count)
            parts.append([files, result.tally].compactMap { $0 }.joined(separator: " "))
        } else if let words = result.changedWords {
            parts.append(words)
        }
        if let fixed = account.header.fixedWords { parts.append(fixed) }
        if let cost = account.header.costUSD { parts.append(Money.approximate(cost)) }
        return parts.joined(separator: "  \u{00B7}  ")
    }
}
