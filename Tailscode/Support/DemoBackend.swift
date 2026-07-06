#if DEBUG
    import AgentTestSupport
    import CodingAgentKit
    import Foundation

    /// A scripted conversation used for `--demo` launches (screenshots, UI iteration) — no server.
    enum DemoBackend {
        static let session = AgentSession(
            id: "demo", agentType: .openCode, title: "Refactor the auth module",
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))

        static func make() -> any CodingAgentBackend {
            let assistant = "msg_a"
            var steps: [MockScriptStep] = []

            steps.append(
                MockScriptStep(
                    .messageUpserted(
                        ChatMessage(
                            id: "msg_u", role: .user, agentType: .openCode,
                            parts: [MessagePart(id: "u", kind: .text(
                                "Refactor the auth module to async/await and add a test."))],
                            createdAt: Date(timeIntervalSince1970: 0)), replaceParts: true),
                    delay: .milliseconds(50)))

            steps.append(
                MockScriptStep(
                    .messageUpserted(
                        ChatMessage(
                            id: assistant, role: .assistant, agentType: .openCode,
                            createdAt: Date(timeIntervalSince1970: 1), isStreaming: true),
                        replaceParts: false), delay: .milliseconds(500)))

            steps.append(
                MockScriptStep(
                    .partUpserted(messageID: assistant, MessagePart(
                        id: "r", kind: .reasoning(
                            "Scanning the auth module for completion-handler APIs to convert."))),
                    delay: .milliseconds(600)))

            steps.append(
                MockScriptStep(
                    .partUpserted(messageID: assistant, MessagePart(id: "t", kind: .text(""))),
                    delay: .milliseconds(300)))
            for chunk in [
                "I'll convert `AuthClient` to async/await, ", "then add a unit test.\n\n",
                "First, finding the callback-based call sites.",
            ] {
                steps.append(
                    MockScriptStep(
                        .partTextDelta(messageID: assistant, partID: "t", delta: chunk),
                        delay: .milliseconds(350)))
            }

            steps.append(
                MockScriptStep(
                    .partUpserted(messageID: assistant, MessagePart(id: "tool", kind: .tool(
                        ToolCall(id: "c1", name: "grep", status: .running,
                            title: "grep -rn completionHandler Sources/Auth")))),
                    delay: .milliseconds(600)))
            steps.append(
                MockScriptStep(
                    .partUpserted(messageID: assistant, MessagePart(id: "tool", kind: .tool(
                        ToolCall(id: "c1", name: "grep", status: .completed,
                            output:
                                "Sources/Auth/AuthClient.swift:42: func login(completion:)\nSources/Auth/AuthClient.swift:58: func refresh(completion:)",
                            title: "grep")))),
                    delay: .milliseconds(800)))

            for chunk in [
                " Found 2 call sites — converting both and adding `AuthClientTests.login()`.",
                " Done.",
            ] {
                steps.append(
                    MockScriptStep(
                        .partTextDelta(messageID: assistant, partID: "t", delta: chunk),
                        delay: .milliseconds(500)))
            }
            steps.append(MockScriptStep(.status(.idle), delay: .milliseconds(300)))

            return MockBackend(agentType: .openCode, script: steps)
        }
    }
#endif
