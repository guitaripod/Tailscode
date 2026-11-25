import CodingAgentKit
import Foundation

/// ``WorkflowRunAssembly/runs(messages:agents:)`` for a client that asks on every state a
/// conversation emits, which while a turn streams is every token. Finding the launches means asking
/// every tool call in the conversation what it is and reading every text part for a task
/// notification, so a long transcript paid for the whole of itself on each word of the answer. The
/// fold reads each message once and again only when that message changed, keeps the launches and
/// notifications gathered until one of them moves, and answers exactly what the assembly would.
public final class WorkflowRunFold {
    private struct Reading {
        let launches: [WorkflowRunAssembly.Launch]
        let completions: [String: String]

        var isEmpty: Bool { launches.isEmpty && completions.isEmpty }
    }

    private var memo = MessageMemo<Reading>()
    private var launches: [WorkflowRunAssembly.Launch] = []
    private var completions: [String: String] = [:]
    private var gathered = false
    private var agentsAnswered: [SubagentSummary]?
    private var answer: [WorkflowRun] = []

    public init() {}

    public func runs(messages: [ChatMessage], agents: [SubagentSummary]) -> [WorkflowRun] {
        var moved = false
        let change = memo.refresh(
            messages,
            read: { message in
                Reading(
                    launches: WorkflowRunAssembly.launches(in: [message]),
                    completions: WorkflowRunAssembly.completions(in: [message]))
            },
            changed: { old, new in
                if old?.isEmpty == false || new?.isEmpty == false { moved = true }
            })
        if change == .reordered { moved = true }
        if moved || !gathered { gather() }
        guard !launches.isEmpty else { return [] }
        if !moved, let held = agentsAnswered, held == agents { return answer }
        let fresh = WorkflowRunAssembly.runs(
            launches: launches, agents: agents, completions: completions)
        agentsAnswered = agents
        answer = fresh
        return fresh
    }

    private func gather() {
        var launches: [WorkflowRunAssembly.Launch] = []
        var completions: [String: String] = [:]
        memo.forEachReading { reading in
            launches += reading.launches
            completions.merge(reading.completions) { _, later in later }
        }
        self.launches = launches
        self.completions = completions
        gathered = true
        agentsAnswered = nil
    }
}
