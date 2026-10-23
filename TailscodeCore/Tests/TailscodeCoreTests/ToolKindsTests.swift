import CodingAgentKit
import Testing

@testable import TailscodeCore

@Suite struct ToolKindsTests {
    @Test func theMemoAnswersExactlyWhatTheKitDoes() {
        let names = [
            "Bash", "bash", "Read", "Edit", "Write", "Grep", "Glob", "WebFetch", "WebSearch", "Task",
            "TodoWrite", "AskUserQuestion", "workflow_run", "mcp__server__tool", "", "Skill", "LS",
        ]
        for name in names {
            let call = ToolCall(id: "1", name: name, status: .completed)
            #expect(ToolKinds.kind(of: call) == call.summaryKind, "\(name)")
            #expect(ToolKinds.kind(of: call) == call.summaryKind, "\(name) again")
        }
    }

    @Test func aNameIsReadOnceNoMatterWhichCallAsks() {
        let first = ToolCall(id: "a", name: "Bash", status: .running)
        let second = ToolCall(id: "b", name: "Bash", status: .completed)
        #expect(ToolKinds.kind(of: first) == ToolKinds.kind(of: second))
    }
}
