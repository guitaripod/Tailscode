import Testing

@testable import TailscodeCore

@Suite struct TranscriptOpeningTests {
    private func drain(_ opening: inout TranscriptOpening, coveredAfter: Int, cost: (Int) -> Double)
        -> [Int]
    {
        var stages: [Int] = []
        var last: TranscriptOpening.Stage?
        var added = 0
        while let rows = opening.next(after: last) {
            stages.append(rows)
            added += rows
            last = .init(rows: rows, milliseconds: cost(rows), covered: added >= coveredAfter)
            #expect(stages.count < 10_000)
        }
        return stages
    }

    @Test func aShortTranscriptIsShownWholeAndIsDone() {
        let opening = TranscriptOpening(total: 3)
        #expect(opening.shown == 3)
        #expect(opening.isDone)
        var again = opening
        #expect(again.next() == nil)
    }

    @Test func aLongOneStartsWithTheFirstStage() {
        let opening = TranscriptOpening(total: 600)
        #expect(opening.shown == TranscriptOpening.firstStage)
        #expect(opening.phase == .filling)
        #expect(opening.remaining == 597)
    }

    @Test func everyRowArrivesExactlyOnce() {
        var opening = TranscriptOpening(total: 600)
        let stages = drain(&opening, coveredAfter: 12) { Double($0) * 3 }
        #expect(opening.shown == 600)
        #expect(opening.isDone)
        #expect(stages.reduce(0, +) == 597)
        #expect(stages.allSatisfy { $0 >= 1 })
    }

    @Test func fillingStagesAreSmallAndBackfillingStagesGrow() {
        var opening = TranscriptOpening(total: 3000)
        let stages = drain(&opening, coveredAfter: 12) { rows in
            rows <= TranscriptOpening.largestFillStage ? Double(rows) * 3.0 : 1 + Double(rows) * 0.01
        }
        let filling = stages.prefix { $0 <= TranscriptOpening.largestFillStage }
        #expect(!filling.isEmpty)
        #expect(stages.max()! > 50)
        #expect(stages.count < 60)
    }

    @Test func aFillStageIsAsManyRowsAsTheBudgetBuys() {
        var opening = TranscriptOpening(total: 600)
        _ = opening.next()
        let cheap = opening.next(after: .init(rows: 3, milliseconds: 1.5, covered: false))!
        var costly = TranscriptOpening(total: 600)
        _ = costly.next()
        let expensive = costly.next(after: .init(rows: 3, milliseconds: 60, covered: false))!
        #expect(expensive < cheap)
        #expect(expensive >= 1)
        #expect(cheap <= TranscriptOpening.largestFillStage)
    }

    @Test func aBackfillThatIsAllFixedPriceStillGrows() {
        var opening = TranscriptOpening(total: 5000)
        var last = TranscriptOpening.Stage(rows: 3, milliseconds: 9, covered: true)
        var sizes: [Int] = []
        while let rows = opening.next(after: last) {
            sizes.append(rows)
            last = .init(rows: rows, milliseconds: 6 + Double(rows) * 0.01, covered: true)
        }
        #expect(sizes.max()! >= 200)
        #expect(sizes.count < 24)
    }

    @Test func stagesNeverExceedTheLargestFillBeforeTheWindowIsCovered() {
        var opening = TranscriptOpening(total: 600)
        var last: TranscriptOpening.Stage?
        for _ in 0..<20 {
            guard let rows = opening.next(after: last) else { break }
            #expect(rows <= TranscriptOpening.largestFillStage)
            last = .init(rows: rows, milliseconds: 0.01, covered: false)
        }
    }

    @Test func aCoveredWindowBackfillsInLargeSlices() {
        var opening = TranscriptOpening(total: 5000)
        let first = opening.next(after: .init(rows: 3, milliseconds: 9, covered: true))!
        #expect(opening.phase == .backfilling)
        #expect(first > TranscriptOpening.largestFillStage)
    }

    @Test func rowsArrivingAtTheEndJoinTheWindow() {
        var opening = TranscriptOpening(total: 100)
        #expect(opening.shown == 3)
        opening.retotal(102)
        #expect(opening.shown == 5)
        #expect(opening.total == 102)
    }

    @Test func aTranscriptThatShrinksNeverShowsMoreThanItHas() {
        var opening = TranscriptOpening(total: 100)
        _ = opening.next(after: .init(rows: 3, milliseconds: 1, covered: true))
        opening.retotal(2)
        #expect(opening.shown == 2)
        #expect(opening.isDone)
    }

    @Test func aTranscriptThatEmptiesIsDone() {
        var opening = TranscriptOpening(total: 50)
        opening.retotal(0)
        #expect(opening.shown == 0)
        #expect(opening.isDone)
        #expect(opening.next() == nil)
    }
}
