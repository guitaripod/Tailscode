import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

enum StepListFixtures {
    static func list(_ turn: NeuralTurn? = nil, live: Bool = false) -> NeuralStepList {
        NeuralStepList(steps: (turn ?? BrainFixtures.buildFix()).steps, live: live)
    }

    static func ids(_ rows: [NeuralStepList.Row]) -> [Int] { rows.map(\.index) }

    /// A turn of `count` steps over every zone, two calls to a message, every seventh one failed.
    static func synthetic(_ count: Int, running: Bool = false) -> [NeuralStep] {
        let zones = NeuralZone.allCases
        return (0..<count).map { index in
            let zone = zones[index % zones.count]
            let thought = zone == .think
            var step = NeuralStep(
                id: "m\(index / 2):p\(index % 2)", index: index, zone: zone,
                status: index % 7 == 6 ? .failed : .ok, group: index / 2, messageID: "m\(index / 2)",
                title: thought ? "Thinking" : "Tool\(index % 5)",
                detail: thought ? "" : "/src/dir\(index % 9)/sub/file\(index).swift",
                text: thought ? "Thought number \(index)" : "",
                outputLines: ["line \(index)"], tieKey: thought ? nil : "key\(index % 11)")
            if running, index == count - 1 { step.status = .running }
            return step
        }
    }
}

@Suite("Neural step list rows")
struct NeuralStepListRowTests {
    typealias F = StepListFixtures

    @Test("one row per step, in order, numbered from one, with the step's own id")
    func rows() {
        let model = BrainFixtures.model(BrainFixtures.buildFix())
        let list = F.list()
        #expect(list.total == 14)
        #expect(list.rows.map(\.id) == model.steps.map(\.id))
        #expect(list.rows.map(\.number) == Array(1...14))
        #expect(list.rows.map(\.index) == Array(0..<14))
        #expect(list.rows[1].title == "Searched for case .compaction")
        #expect(list.rows[1].rawTitle == "Grep")
        #expect(list.rows[1].argument == "case .compaction TailscodeLinux/Sources")
        #expect(list.rows[4].zone == .act)
        #expect(list.rows[4].group == model.steps[4].group)
    }

    @Test("thoughts and notes are rows of their own kind, with the first line of their words")
    func thoughtsAndNotes() {
        let messages = [
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [
                .reasoning("First line.\nSecond line."), NeuralTurnFixtures.bash("ls", out: ["a"]),
                .text("A note on the way."), NeuralTurnFixtures.read("a.txt", out: ["x"]),
            ]),
        ]
        let list = F.list(NeuralTurns.partition(messages: messages, running: false)[0])
        #expect(list.rows.map(\.kind) == [.thought, .tool, .note, .tool])
        #expect(list.rows[0].argument == "First line.")
        #expect(list.rows[0].argumentKind == .words)
        #expect(list.rows[2].argument == "A note on the way.")
        #expect(list.rows[1].argumentKind == .command)
        #expect(list.rows[3].argumentKind == .path)
    }

    @Test("a path keeps its file name and gives up the middle, a command gives up its end")
    func ellipsis() {
        let list = F.list()
        let path = list.rows[2]
        #expect(path.argument == "TailscodeLinux/Sources/Chat/TranscriptRows.swift")
        #expect(path.argument(fittingChars: 200) == path.argument)
        for limit in [47, 40, 36, 30, 24, 22, 21, 12] {
            let cut = path.argument(fittingChars: limit)
            #expect(cut.count <= limit, "\(limit): \(cut)")
            #expect(cut.hasSuffix("TranscriptRows.swift") || limit < 22, "\(limit): \(cut)")
        }
        #expect(path.argument(fittingChars: 40) == "TailscodeLinu\u{2026}/Chat/TranscriptRows.swift")
        #expect(path.argument(fittingChars: 22) == "\u{2026}/TranscriptRows.swift")
        #expect(path.argument(fittingChars: 12) == "\u{2026}" + "TranscriptRows.swift".suffix(11))
        let command = list.rows[5]
        let cut = command.argument(fittingChars: 12)
        #expect(cut == "swift build\u{2026}")
        #expect(cut.count == 12)
        #expect(command.argument(fittingChars: 1) == "\u{2026}")
        #expect(command.argument(fittingChars: 0) == "")
        #expect(command.argument(fittingChars: 500) == command.argument)
    }

    @Test("a failure that was retried carries the retry, a failure nobody retried is failed")
    func marks() {
        let list = F.list()
        guard case .retried(let id, let number) = list.rows[5].mark else {
            Issue.record("expected a retried mark")
            return
        }
        #expect(id == list.rows[10].id && number == 11)
        #expect(list.rows[10].mark == .none)
        let alone = NeuralTurns.partition(messages: [
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("false", out: ["boom"], status: .error)]),
        ], running: false)[0]
        #expect(F.list(alone).rows[0].mark == .failed)
        #expect(F.list(alone).rows[0].isFailure)
    }

    @Test("waiting, running and stopped steps wear their marks")
    func otherMarks() {
        let (waiting, id) = ReadoutFixtures.waitingTurn()
        let list = F.list(waiting)
        #expect(list.row(id: id)?.mark == .waiting)
        let running = NeuralTurns.partition(messages: [
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("sleep 9", status: .running)], streaming: true),
        ], running: true)[0]
        #expect(F.list(running, live: true).rows[0].mark == .running)
        let stopped = NeuralTurns.partition(messages: [
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("sleep 9", status: .stopped)], finish: "abort"),
        ], running: false)[0]
        #expect(F.list(stopped).rows[0].mark == .stopped)
    }

    @Test("a retry points back at its failure, a failure at its retry, a file at its other use")
    func related() {
        let list = F.list()
        #expect(list.rows[5].related?.kind == .retry)
        #expect(list.rows[5].related?.stepID == list.rows[10].id)
        #expect(list.rows[5].related?.label == "retried at 11")
        #expect(list.rows[10].related?.kind == .retriedFrom)
        #expect(list.rows[10].related?.stepID == list.rows[5].id)
        #expect(list.rows[2].related?.kind == .sameFile)
        #expect(list.rows[2].related?.stepID == list.rows[4].id)
        #expect(list.rows[9].related?.stepID == list.rows[4].id)
        #expect(list.rows[11].related == nil)
        #expect(list.rows[0].related == nil)
    }

    @Test("calls made together share a bracket: first, middle, last; a lone call or a thought has none")
    func brackets() {
        let list = F.list()
        #expect(list.rows[1].bracket == .first)
        #expect(list.rows[2].bracket == .middle)
        #expect(list.rows[3].bracket == .last)
        #expect(list.rows[0].bracket == .none)
        #expect(list.rows[4].bracket == .none)
        let both = NeuralTurns.partition(messages: [
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [.reasoning("why"), NeuralTurnFixtures.bash("ls", out: ["a"])]),
        ], running: false)[0]
        #expect(F.list(both).rows.map(\.bracket) == [.none, .none])
    }

    @Test("rows keep their ids and their place as the turn grows")
    func growth() {
        var steps = F.synthetic(40, running: true)
        var list = NeuralStepList(steps: steps, live: true)
        let before = list.rows.map(\.id)
        steps += F.synthetic(45)[40...]
        list.update(steps: steps, live: true)
        #expect(Array(list.rows.map(\.id).prefix(40)) == before)
        #expect(list.total == 45)
        let again = list.rows
        list.update(steps: steps, live: true)
        #expect(list.rows == again)
    }
}

@Suite("Neural step list: words that grow")
struct NeuralStepListStreamingTests {
    typealias F = StepListFixtures

    @Test("a streamed token changes one row and the list equals one built from scratch")
    func tokenGrowth() {
        var steps = F.synthetic(30, running: true)
        steps[29] = NeuralStep(
            id: "live:p0", index: 29, zone: .think, status: .running, group: 15, messageID: "live",
            title: "Thinking", text: "w")
        var list = NeuralStepList(steps: steps, live: true)
        let others = list.rows.dropLast()
        var words = "w"
        for token in 0..<25 {
            words += token % 6 == 5 ? "\nline \(token)" : " token\(token)"
            steps[29].text = words
            list.update(steps: steps, live: true)
            #expect(list.rows == NeuralStepList(steps: steps, live: true).rows)
            #expect(Array(list.rows.dropLast()) == Array(others))
        }
        #expect(list.rows[29].argument.hasPrefix("w token0"))
        #expect(list.rows[29].lines.count == 1)
    }

    @Test("a search follows the words as they grow")
    func searchFollows() {
        var steps = F.synthetic(10, running: true)
        steps[9] = NeuralStep(
            id: "live:p0", index: 9, zone: .think, status: .running, group: 5, messageID: "live",
            title: "Thinking", text: "start")
        var list = NeuralStepList(steps: steps, live: true)
        list.setSearch("zebra")
        #expect(list.visibleCount == 0)
        steps[9].text = "start with a zebra"
        list.update(steps: steps, live: true)
        #expect(list.visibleCount == 1)
    }
}

@Suite("Neural step list filters")
struct NeuralStepListFilterTests {
    typealias F = StepListFixtures

    @Test("zone chips count the zones the turn has, in zone order, whatever the filters")
    func chips() {
        var list = F.list()
        #expect(list.zoneChips.map(\.zone) == [.think, .sense, .act, .shell, .delegate])
        #expect(list.zoneChips.map(\.count) == [2, 4, 3, 4, 1])
        #expect(list.zoneChips.allSatisfy { !$0.isOn })
        list.toggleZone(.shell)
        #expect(list.zoneChips.first { $0.zone == .shell }?.isOn == true)
        #expect(list.zoneChips.map(\.count) == [2, 4, 3, 4, 1])
        #expect(list.failedCount == 1)
        #expect(list.offersFailedFilter)
    }

    @Test("a zone filter shows the steps of its zones, a second zone adds to it, a zone with none is ignored")
    func zones() {
        var list = F.list()
        list.toggleZone(.shell)
        #expect(F.ids(list.visibleRows) == [5, 10, 11, 13])
        list.toggleZone(.act)
        #expect(F.ids(list.visibleRows) == [4, 5, 8, 9, 10, 11, 13])
        let said = list.toggleZone(.say)
        #expect(said == false)
        #expect(list.filter.zones == [.shell, .act])
        list.toggleZone(.shell)
        #expect(F.ids(list.visibleRows) == [4, 8, 9])
        list.soloZone(.sense)
        #expect(F.ids(list.visibleRows) == [1, 2, 3, 7])
        list.soloZone(.sense)
        #expect(list.visibleCount == 14)
    }

    @Test("failed only shows the failures, and a turn with none refuses the toggle")
    func failed() {
        var list = F.list()
        let toggled = list.toggleFailedOnly()
        #expect(toggled)
        #expect(F.ids(list.visibleRows) == [5])
        #expect(list.countLabel == "1 of 14")
        list.toggleFailedOnly()
        #expect(list.visibleCount == 14)
        var clean = NeuralStepList(steps: F.synthetic(6))
        #expect(clean.offersFailedFilter == false)
        let refused = clean.toggleFailedOnly()
        #expect(refused == false)
    }

    @Test("search matches the title, the argument, a thought's words, the output and the digest's words")
    func search() {
        var list = F.list()
        list.setSearch("grep")
        #expect(F.ids(list.visibleRows) == [1])
        list.setSearch("transcriptrows")
        #expect(F.ids(list.visibleRows) == [0, 1, 2, 4, 5, 9])
        list.setSearch("did not cover")
        #expect(F.ids(list.visibleRows) == [6])
        list.setSearch("switch must be exhaustive")
        #expect(F.ids(list.visibleRows) == [5])
        list.setSearch("Installed Tailscode 1.79")
        #expect(F.ids(list.visibleRows) == [13])
        list.setSearch("SHELL")
        #expect(F.ids(list.visibleRows) == [5, 10, 11, 13])
        list.setSearch("retried")
        #expect(F.ids(list.visibleRows) == [5])
        list.setSearch("no such words")
        #expect(list.visibleCount == 0)
        list.setSearch("   ")
        #expect(list.visibleCount == 14)
        #expect(!list.isFiltered)
    }

    @Test("search looks in the whole output, not just its first lines")
    func deepOutput() {
        let output = (0..<500).map { $0 == 420 ? "needle in line 420" : "hay \($0)" }.joined(separator: "\n")
        let turn = NeuralTurns.partition(messages: [
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.tool("Bash", ["command": .string("big")], out: [output])]),
            NeuralTurnFixtures.message(2, [NeuralTurnFixtures.bash("ls", out: ["a"])]),
        ], running: false)[0]
        var list = F.list(turn)
        list.setSearch("needle")
        #expect(F.ids(list.visibleRows) == [0])
    }

    @Test("filters combine, count as 5 of 29, and give hidden ids for the head to dim")
    func combined() {
        var list = F.list()
        #expect(list.countLabel == "14 steps")
        list.toggleZone(.shell)
        list.setSearch("scripts")
        #expect(F.ids(list.visibleRows) == [11, 13])
        #expect(list.countLabel == "2 of 14")
        #expect(list.hiddenIDs.count == 12)
        #expect(!list.hiddenIDs.contains(list.rows[11].id))
        #expect(list.hiddenIDs.contains(list.rows[0].id))
        list.clearFilters()
        #expect(list.hiddenIDs.isEmpty)
        #expect(NeuralStepList(steps: []).countLabel == "No steps")
        #expect(NeuralStepList(steps: Array(F.synthetic(1))).countLabel == "1 step")
    }

    @Test("a live turn's list follows until it is paused, and the pill shows only while paused")
    func following() {
        var list = NeuralStepList(steps: F.synthetic(10, running: true), live: true)
        #expect(list.isFollowing && !list.showsFollowPill)
        list.following = false
        #expect(!list.isFollowing && list.showsFollowPill)
        let settled = NeuralStepList(steps: F.synthetic(10))
        #expect(!settled.isFollowing && !settled.showsFollowPill)
    }
}

@Suite("Neural step list windows and walks")
struct NeuralStepListWindowTests {
    typealias F = StepListFixtures

    @Test("a window of rows is clamped to the visible list and keeps the rows' ids")
    func windows() {
        var list = F.list()
        #expect(F.ids(list.rows(in: 2..<5)) == [2, 3, 4])
        #expect(F.ids(list.rows(in: 12..<40)) == [12, 13])
        #expect(list.rows(in: 20..<30).isEmpty)
        #expect(F.ids(list.rows(in: -4..<2)) == [0, 1])
        list.toggleZone(.act)
        #expect(F.ids(list.rows(in: 0..<10)) == [4, 8, 9])
        #expect(list.row(atVisible: 1)?.index == 8)
        #expect(list.row(atVisible: 3) == nil)
        #expect(list.visibleIndex(of: list.rows[8].id) == 1)
        #expect(list.visibleIndex(of: list.rows[0].id) == nil)
        #expect(list.rows(in: 0..<3).map(\.id) == [4, 8, 9].map { list.rows[$0].id })
    }

    @Test("walking steps by one or a page stops at the ends and starts from the right end with no cursor")
    func walking() {
        let list = F.list()
        #expect(list.step(from: nil, by: 1) == list.rows[0].id)
        #expect(list.step(from: nil, by: -1) == list.rows[13].id)
        #expect(list.step(from: list.rows[3].id, by: 1) == list.rows[4].id)
        #expect(list.step(from: list.rows[3].id, by: -8) == list.rows[0].id)
        #expect(list.step(from: list.rows[3].id, by: 8) == list.rows[11].id)
        #expect(list.step(from: list.rows[13].id, by: 1) == list.rows[13].id)
        #expect(list.step(from: list.rows[0].id, by: -1) == list.rows[0].id)
    }

    @Test("a walk from a step the filters hide continues at the nearest visible one")
    func hiddenCursor() {
        var list = F.list()
        list.toggleZone(.shell)
        #expect(list.step(from: list.rows[7].id, by: 1) == list.rows[10].id)
        #expect(list.step(from: list.rows[7].id, by: -1) == list.rows[5].id)
        #expect(list.step(from: list.rows[0].id, by: 1) == list.rows[5].id)
        #expect(list.step(from: list.rows[13].id, by: 1) == list.rows[13].id)
    }

    @Test("the zone walk goes to the previous and next step of the cursor's zone and stops at its ends")
    func zoneWalk() {
        let list = F.list()
        #expect(list.zoneStep(from: list.rows[1].id, forward: true) == list.rows[2].id)
        #expect(list.zoneStep(from: list.rows[7].id, forward: false) == list.rows[3].id)
        #expect(list.zoneStep(from: list.rows[5].id, forward: true) == list.rows[10].id)
        #expect(list.zoneStep(from: list.rows[13].id, forward: true) == nil)
        #expect(list.zoneStep(from: list.rows[1].id, forward: false) == nil)
        #expect(list.zoneStep(from: nil, forward: true) == list.rows[0].id)
    }

    @Test("the failed walk goes to the previous and next failed step, never wrapping")
    func failedWalk() {
        let messages = [
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("a", out: ["x"], status: .error)]),
            NeuralTurnFixtures.message(2, [NeuralTurnFixtures.bash("b", out: ["x"])]),
            NeuralTurnFixtures.message(3, [NeuralTurnFixtures.bash("c", out: ["x"], status: .error)]),
            NeuralTurnFixtures.message(4, [NeuralTurnFixtures.bash("d", out: ["x"])]),
            NeuralTurnFixtures.message(5, [NeuralTurnFixtures.bash("e", out: ["x"], status: .error)]),
        ]
        let list = F.list(NeuralTurns.partition(messages: messages, running: false)[0])
        let ids = list.rows.map(\.id)
        #expect(list.failedStep(from: nil, forward: true) == ids[0])
        #expect(list.failedStep(from: nil, forward: false) == ids[4])
        #expect(list.failedStep(from: ids[0], forward: true) == ids[2])
        #expect(list.failedStep(from: ids[1], forward: true) == ids[2])
        #expect(list.failedStep(from: ids[2], forward: false) == ids[0])
        #expect(list.failedStep(from: ids[4], forward: true) == nil)
        #expect(list.failedStep(from: ids[0], forward: false) == nil)
        #expect(NeuralStepList(steps: F.synthetic(5)).failedStep(from: nil, forward: true) == nil)
    }
}

@Suite("Neural step list at scale")
struct NeuralStepListScaleTests {
    typealias F = StepListFixtures

    @Test("a 174-step turn answers window queries with exactly the window")
    func hundredSeventyFour() {
        let list = NeuralStepList(steps: F.synthetic(174))
        #expect(list.total == 174)
        for start in stride(from: 0, to: 174, by: 13) {
            let rows = list.rows(in: start..<(start + 30))
            #expect(rows.count == min(30, 174 - start))
            #expect(rows.map(\.index) == Array(start..<(start + rows.count)))
            #expect(rows.map(\.id) == (start..<(start + rows.count)).map { list.rows[$0].id })
        }
        var filtered = list
        filtered.toggleZone(.shell)
        #expect(filtered.visibleCount == 29)
        #expect(filtered.rows(in: 0..<30).count == 29)
        #expect(filtered.rows(in: 0..<30).allSatisfy { $0.zone == .shell })
    }

    @Test("a 30-row window of a 2,000-step turn is cheap, and no dearer than a window of a small turn")
    func microbenchmark() {
        let big = NeuralStepList(steps: F.synthetic(2_000))
        let small = NeuralStepList(steps: F.synthetic(100))
        let clock = ContinuousClock()
        func average(_ list: NeuralStepList, _ position: Int) -> Double {
            var sink = 0
            let rounds = 2_000
            let elapsed = clock.measure {
                for round in 0..<rounds { sink &+= list.rows(in: (position + round % 20)..<(position + round % 20 + 30)).count }
            }
            #expect(sink > 0)
            let parts = elapsed.components
            return (Double(parts.seconds) + Double(parts.attoseconds) / 1e18) / Double(rounds)
        }
        let bigCost = average(big, 900)
        let smallCost = average(small, 20)
        #expect(bigCost < 0.002, "debug build: \(bigCost * 1000) ms per window")
        #expect(bigCost < max(smallCost * 4, 0.0003), "window cost grew with the turn: \(bigCost) vs \(smallCost)")
        print("NEURAL-LIST rows(in:) 30-row window of 2000 steps: \(bigCost * 1000) ms")
    }

    @Test("filtering a 2,000-step turn and finding a row in it is cheap")
    func filtering() {
        var list = NeuralStepList(steps: F.synthetic(2_000))
        list.toggleZone(.sense)
        #expect(list.visibleCount == 334)
        let id = list.rows(in: 100..<101)[0].id
        #expect(list.visibleIndex(of: id) == 100)
        list.setSearch("file19")
        let expected = (0..<2_000).filter { $0 % 6 == 1 && "\($0)".hasPrefix("19") }.count
        #expect(list.visibleCount == expected)
        #expect(list.rows(in: 0..<30).allSatisfy { $0.argument.contains("file19") })
    }
}
