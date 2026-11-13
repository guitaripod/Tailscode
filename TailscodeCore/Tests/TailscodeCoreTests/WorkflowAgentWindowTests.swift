import Foundation
import Testing

@testable import TailscodeCore

/// A workflow card that drew one row per agent hung a phone for good on a 660-agent run. These pin
/// that a card's rows stay a handful however wide the fan-out, and which handful it keeps.
@Suite("Workflow agent window")
struct WorkflowAgentWindowTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private static func agents(_ count: Int, out: Set<Int> = []) -> [WorkflowAgent] {
        (0..<count).map { index in
            WorkflowAgent(
                id: "agent-\(index)", title: "Translate batch \(index)",
                isActive: out.contains(index), isCompleted: !out.contains(index),
                startedAt: start.addingTimeInterval(Double(index)),
                updatedAt: start.addingTimeInterval(Double(index) + 60))
        }
    }

    private static func run(_ agents: [WorkflowAgent], state: WorkflowRun.State) -> WorkflowRun {
        WorkflowRun(
            id: "wf", name: "nordic-translate", agents: agents, state: state, startedAt: start,
            finishedAt: state == .running ? nil : start.addingTimeInterval(3_600))
    }

    @Test("A small run shows every agent and folds nothing")
    func smallRunShowsAll() {
        let window = WorkflowAgentWindow(Self.run(Self.agents(8), state: .finished))
        #expect(window.shown.map(\.id) == (0..<8).map { "agent-\($0)" })
        #expect(window.folded == 0)
        #expect(window.foldedLabel == nil)
    }

    @Test("One agent over the limit shows whole, because the fold line would cost the same row")
    func oneOverShowsAll() {
        let window = WorkflowAgentWindow(Self.run(Self.agents(9), state: .finished))
        #expect(window.shown.count == 9)
        #expect(window.folded == 0)
    }

    @Test("A wide finished run keeps the latest to report, in the run's order, and folds the rest")
    func wideFinishedRunKeepsTheLatest() {
        let window = WorkflowAgentWindow(Self.run(Self.agents(660), state: .finished))
        #expect(window.shown.count == WorkflowAgentWindow.rowLimit)
        #expect(window.shown.map(\.id) == (652..<660).map { "agent-\($0)" })
        #expect(window.folded == 652)
        #expect(window.shown.count + window.folded == 660)
        #expect(window.foldedLabel != nil)
    }

    @Test("A live run keeps the agents still out ahead of newer finished ones")
    func liveRunKeepsTheOnesOut() {
        let out: Set<Int> = [3, 40, 41, 500]
        let window = WorkflowAgentWindow(Self.run(Self.agents(660, out: out), state: .running))
        let ids = window.shown.map(\.id)
        #expect(ids.count == WorkflowAgentWindow.rowLimit)
        for index in out { #expect(ids.contains("agent-\(index)")) }
        #expect(ids == ids.sorted { Int($0.dropFirst(6))! < Int($1.dropFirst(6))! })
        #expect(ids.suffix(4) == ["agent-656", "agent-657", "agent-658", "agent-659"])
    }

    @Test("An agent still claiming work under a run that ended earns no seat for it")
    func endedRunIgnoresStaleClaims() {
        let window = WorkflowAgentWindow(Self.run(Self.agents(660, out: [3]), state: .finished))
        #expect(!window.shown.map(\.id).contains("agent-3"))
    }

    @Test("More agents out than rows keeps the newest of them")
    func moreOutThanRows() {
        let out = Set(0..<100)
        let window = WorkflowAgentWindow(Self.run(Self.agents(660, out: out), state: .running))
        #expect(window.shown.map(\.id) == (92..<100).map { "agent-\($0)" })
    }

    @Test("An agent the reader has open keeps its row ahead of the ones still out")
    func openAgentKeepsItsRow() {
        let out = Set(600..<660)
        let window = WorkflowAgentWindow(
            Self.run(Self.agents(660, out: out), state: .running), keeping: ["agent-7"])
        let ids = window.shown.map(\.id)
        #expect(ids.first == "agent-7")
        #expect(ids.count == WorkflowAgentWindow.rowLimit)
        #expect(Array(ids.dropFirst()) == (653..<660).map { "agent-\($0)" })
    }

    @Test("The roster names every agent once, on its own line")
    func rosterListsEveryAgent() {
        let run = Self.run(Self.agents(660), state: .finished)
        let lines = WorkflowAgentWindow.roster(of: run, at: Self.start.addingTimeInterval(9_000))
            .split(separator: "\n")
        #expect(lines.count == 660)
        #expect(lines[0].contains("Translate batch 0"))
        #expect(lines[0].contains("1m00s"))
    }

    @Test("Folding a wide run stays cheap")
    func windowIsLinear() {
        let run = Self.run(Self.agents(20_000, out: Set(stride(from: 0, to: 20_000, by: 7))), state: .running)
        let clock = ContinuousClock()
        let spent = clock.measure { _ = WorkflowAgentWindow(run) }
        #expect(spent < .milliseconds(250))
    }
}
