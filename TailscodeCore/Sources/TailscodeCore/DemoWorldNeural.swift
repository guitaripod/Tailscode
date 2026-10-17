import AgentTestSupport
import CodingAgentKit
import Foundation

extension DemoWorld {
    /// The conversation whose turns the neural trace is drawn from: the build-fix turn and the long
    /// one, scripted as the transcript a server would hold, so a demo launch lands on a head
    /// without a machine.
    static var claudeNeuralScript: [MockScriptStep] {
        NeuralDemo.conversation().map {
            MockScriptStep(.messageUpserted($0, replaceParts: true), delay: .milliseconds(10))
        } + [MockScriptStep(.status(.idle), delay: .milliseconds(10))]
    }

    static func claudeNeuralSession(created: Date, updated: Date) -> AgentSession {
        AgentSession(
            id: "demo-c6", agentType: .claudeCode, title: "Make a product demonstration video",
            directory: "/Users/demo/dev/tailscode", createdAt: created, updatedAt: updated,
            model: "claude-fable-5", reasoningEffort: "xhigh")
    }
}
