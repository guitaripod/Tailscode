import Foundation

/// How a long transcript is put on a screen without holding the main thread.
///
/// A list that is handed every row at once makes every cell it can see in one layout pass, and in a
/// conversation of a few hundred rows that pass is longer than a hundred frames of the push
/// animation, during which a finger on the left edge goes nowhere. So the page is built from its
/// end, the way it is read: a few rows first, then a few more above them until the window is
/// covered, and only then the thousands that nobody can see, in slices sized by what the last slice
/// cost. Nothing here knows about views; a client measures a stage, says whether the window is
/// covered, and is told how many rows to add next.
public struct TranscriptOpening: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case filling
        case backfilling
        case done
    }

    /// What a client learned from the stage it just ran.
    public struct Stage: Sendable, Equatable {
        public let rows: Int
        public let milliseconds: Double
        public let covered: Bool

        public init(rows: Int, milliseconds: Double, covered: Bool) {
            self.rows = rows
            self.milliseconds = milliseconds
            self.covered = covered
        }
    }

    public static let firstStage = 3
    public static let budgetMilliseconds = 10.0
    public static let largestFillStage = 8
    public static let largestBackfillStage = 4000
    static let fillCostGuess = 3.5
    static let firstBackfillStage = 16

    public private(set) var total: Int
    public private(set) var shown: Int
    public private(set) var phase: Phase
    private var costPerRow = Self.fillCostGuess
    private var backfillRows = Self.firstBackfillStage

    /// A transcript of `total` rows. One no longer than the first stage is shown whole and is
    /// already done.
    public init(total: Int) {
        self.total = max(0, total)
        shown = min(self.total, Self.firstStage)
        phase = shown >= self.total ? .done : .filling
    }

    public var isDone: Bool { phase == .done }

    public var remaining: Int { max(0, total - shown) }

    /// The transcript now has `count` rows. Rows that arrived at its end are shown with it,
    /// because a window anchored on the end that left the newest row out would be showing a page
    /// that is already out of date.
    public mutating func retotal(_ count: Int) {
        let count = max(0, count)
        if count > total { shown += count - total }
        total = count
        shown = min(shown, total)
        if shown >= total { phase = .done }
    }

    /// How many more rows to put above the ones shown, given what the last stage cost; nil when
    /// the whole transcript is in.
    ///
    /// While the page is being filled every row is a cell to make, so a stage is as many rows as the
    /// budget buys at the price the last stages paid for one. Once the page is full the rows added
    /// above it are not drawn at all and cost almost nothing, so a stage doubles while it comes in
    /// under the budget and halves when it runs well over it.
    public mutating func next(after stage: Stage? = nil) -> Int? {
        if let stage {
            if stage.covered, phase == .filling {
                phase = .backfilling
            } else if phase == .filling, stage.rows > 0 {
                let measured = max(stage.milliseconds, 0.05) / Double(stage.rows)
                costPerRow = 0.5 * costPerRow + 0.5 * measured
            } else if phase == .backfilling {
                if stage.milliseconds > Self.budgetMilliseconds * 1.4 {
                    backfillRows = max(1, backfillRows / 2)
                } else if stage.milliseconds < Self.budgetMilliseconds * 0.8 {
                    backfillRows *= 2
                }
            }
        }
        guard shown < total else {
            phase = .done
            return nil
        }
        let rows: Int
        if phase == .filling {
            rows = min(
                max(Int(Self.budgetMilliseconds / max(costPerRow, 0.05)), 1),
                Self.largestFillStage, remaining)
        } else {
            rows = min(max(backfillRows, 1), Self.largestBackfillStage, remaining)
        }
        shown += rows
        if shown >= total { phase = .done }
        return rows
    }
}
