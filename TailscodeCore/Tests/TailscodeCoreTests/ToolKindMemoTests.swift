import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Tool kind memo: a name is classified once")
struct ToolKindMemoTests {
    private let names = [
        "Bash", "bash", "Read", "Edit", "MultiEdit", "Write", "Grep", "Glob", "Task", "Agent",
        "TodoWrite", "TaskCreate", "TaskUpdate", "AskUserQuestion", "WebFetch", "WebSearch", "Skill",
        "mcp__thing__call", "NotebookEdit", "", "SomethingNobodyHasMet",
    ]

    @Test("it answers what the Kit's classification answers, for a name asked twice")
    func sameAsKit() {
        for name in names + names {
            let call = ToolCall(id: "c", name: name, status: .completed)
            #expect(ToolKindMemo.kind(ofToolNamed: name) == call.summaryKind)
            #expect(call.cachedKind == call.summaryKind)
        }
    }

    @Test("many threads asking at once all get the Kit's answer")
    func threads() async {
        await withTaskGroup(of: Bool.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for round in 0..<200 {
                        let name = (worker + round) % 3 == 0 ? "Bash" : "tool-\(round % 40)"
                        let call = ToolCall(id: "c", name: name, status: .completed)
                        if call.cachedKind != call.summaryKind { return false }
                    }
                    return true
                }
            }
            for await ok in group { #expect(ok) }
        }
    }

    @Test("past its limit the table starts again and still answers")
    func limit() {
        for index in 0..<(ToolKindMemo.limit + 50) {
            let name = "unique-tool-\(index)"
            #expect(
                ToolKindMemo.kind(ofToolNamed: name)
                    == ToolCall(id: "c", name: name, status: .completed).summaryKind)
        }
    }
}
