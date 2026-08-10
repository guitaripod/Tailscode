import Testing

@testable import TailscodeCore

@Suite("Row diff")
struct RowDiffTests {
    private func apply(_ plan: RowDiff.Plan, to old: [String], expecting new: [String]) -> [String] {
        var rows = old
        for index in plan.removals.reversed() { rows.remove(at: index) }
        for index in plan.insertions { rows.insert(new[index], at: index) }
        return rows
    }

    private func keys(_ seed: Int, count: Int) -> [String] {
        var value = UInt64(truncatingIfNeeded: seed &* 6_364_136_223_846_793_005 &+ 1)
        func next() -> UInt64 {
            value ^= value << 13
            value ^= value >> 7
            value ^= value << 17
            return value
        }
        return (0..<count).map { _ in "row\(next() % 40)" }
    }

    @Test("applying the plan turns the old list into the new one")
    func roundTrip() {
        for seed in 0..<200 {
            let old = keys(seed, count: Int(seed % 17) + 1)
            let new = keys(seed &* 7 &+ 3, count: Int(seed % 23) + 1)
            let plan = RowDiff.plan(from: old, to: new)
            #expect(apply(plan, to: old, expecting: new) == new)
        }
    }

    @Test("a value change is never an insertion — same keys, no structural ops")
    func valueChangesAreNotStructural() {
        let rows = (0..<200).map { "msg:part\($0)" }
        let plan = RowDiff.plan(from: rows, to: rows)
        #expect(plan.removals.isEmpty)
        #expect(plan.insertions.isEmpty)
        #expect(plan.isOrderPreserving)
        #expect(plan.survivors.count == rows.count)
        #expect(plan.survivors.allSatisfy { $0.old == $0.new })
    }

    @Test("a row appended to a long transcript costs exactly one insertion")
    func appendIsOneOp() {
        let old = (0..<300).map { "msg:part\($0)" }
        let plan = RowDiff.plan(from: old, to: old + ["msg:part300"])
        #expect(plan.insertions == [300])
        #expect(plan.removals.isEmpty)
        #expect(plan.survivors.count == 300)
    }

    @Test("a row removed from the middle costs exactly one removal")
    func removalIsOneOp() {
        let old = (0..<40).map { "msg:part\($0)" }
        var new = old
        new.remove(at: 12)
        let plan = RowDiff.plan(from: old, to: new)
        #expect(plan.removals == [12])
        #expect(plan.insertions.isEmpty)
    }

    @Test("an early row surviving a rename below it keeps its widget")
    func prefixSurvivesTailChurn() {
        let old = (0..<20).map { "msg:part\($0)" }
        let new = old.prefix(15) + ["agent:a1", "agent:a2"]
        let plan = RowDiff.plan(from: old, to: Array(new))
        #expect(plan.survivors.count == 15)
        #expect(plan.survivors.allSatisfy { $0.old == $0.new && $0.old < 15 })
        #expect(plan.removals == Array(15..<20))
        #expect(plan.insertions == [15, 16])
    }

    @Test("a duplicate key pairs first with first and leaves the extra an insertion")
    func duplicateKeysSurvive() {
        let old = ["a", "b", "c"]
        let new = ["a", "b", "b", "c"]
        let plan = RowDiff.plan(from: old, to: new)
        #expect(apply(plan, to: old, expecting: new) == new)
        #expect(plan.removals.isEmpty)
        #expect(plan.insertions.count == 1)
    }

    @Test("a reordering moves the fewest rows it can")
    func reorderKeepsTheLongestRun() {
        let old = ["a", "b", "c", "d", "e"]
        let new = ["a", "c", "d", "e", "b"]
        let plan = RowDiff.plan(from: old, to: new)
        #expect(apply(plan, to: old, expecting: new) == new)
        #expect(plan.removals == [1])
        #expect(plan.insertions == [4])
    }

    @Test("an empty side is all insertions or all removals")
    func emptySides() {
        #expect(RowDiff.plan(from: [], to: ["a", "b"]).insertions == [0, 1])
        #expect(RowDiff.plan(from: ["a", "b"], to: []).removals == [0, 1])
        #expect(RowDiff.plan(from: [], to: []).isOrderPreserving)
    }
}
