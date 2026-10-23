import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

enum ColdOpenFixtures {
    static func conversation(turns: Int) -> [ChatMessage] {
        var out: [ChatMessage] = []
        let origin = Date(timeIntervalSince1970: 1_792_000_000)
        for turn in 0..<turns {
            let at = origin.addingTimeInterval(Double(turn) * 60)
            out.append(
                ChatMessage(
                    id: "u\(turn)", role: .user, agentType: .claudeCode,
                    parts: [MessagePart(id: "t", kind: .text("Prompt number \(turn)"))],
                    createdAt: at, completedAt: at))
            var parts: [MessagePart] = [
                MessagePart(id: "r", kind: .reasoning("Thinking about step \(turn)."))
            ]
            for tool in 0..<4 {
                parts.append(
                    MessagePart(
                        id: "c\(tool)",
                        kind: .tool(
                            ToolCall(
                                id: "call-\(turn)-\(tool)", name: tool % 2 == 0 ? "Bash" : "Read",
                                status: .completed,
                                input: .object([
                                    "command": .string("swift build \(turn) \(tool)"),
                                    "file_path": .string("Sources/File\(tool).swift"),
                                ]), output: "ok\nline two"))))
            }
            parts.append(
                MessagePart(
                    id: "a",
                    kind: .text("Done with turn \(turn).\n\n```swift\nlet x = \(turn)\n```\n\nThat is all.")))
            out.append(
                ChatMessage(
                    id: "m\(turn)", role: .assistant, agentType: .claudeCode, parts: parts,
                    createdAt: at.addingTimeInterval(5), completedAt: at.addingTimeInterval(30),
                    modelID: "claude-fable-5"))
        }
        return out
    }

    static func heavy(turns: Int) -> [ChatMessage] {
        (0..<turns).flatMap {
            NeuralDemo.largeTurn(
                steps: 24, prefix: "t\($0)-", origin: 1_792_000_000 + Double($0) * 4000)
        }
    }

    static func milliseconds(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
    }
}

@Suite("Neural cold open bench")
struct NeuralColdOpenBenchTests {
    private func shape(_ name: String, _ make: (Int) -> [ChatMessage]) {
        for turns in [40, 300, 1500] {
            let messages = make(turns)
            var partition = 0.0
            var models = 0.0
            var rows = 0.0
            var brains = 0
            let cache = NeuralTurnCache(capacity: 4096)
            var list = NeuralTurnList()
            partition = ColdOpenFixtures.milliseconds {
                list = cache.partitionList(messages: messages, running: false)
            }
            var held: [NeuralBrainModel] = []
            models = ColdOpenFixtures.milliseconds {
                for turn in list where NeuralOpenPolicy.isBrain(turn: turn) {
                    held.append(NeuralBrainModel(turn: turn, context: .none))
                    brains += 1
                }
            }
            var hashed = 0
            rows = ColdOpenFixtures.milliseconds {
                for (index, turn) in list.enumerated() where NeuralOpenPolicy.isBrain(turn: turn) {
                    let model = held[min(index, held.count - 1)]
                    var hasher = Hasher()
                    hasher.combine(model.revision)
                    hasher.combine(turn.outcome)
                    hasher.combine(model.state.label)
                    hasher.combine(model.face)
                    hasher.combine(model.meters)
                    hashed ^= hasher.finalize()
                    hashed ^= Self.searchText(of: turn).utf8.count
                    hashed ^= (turn.steps.first { turn.memberPartIDs.contains($0.id) }?.id ?? "").utf8.count
                }
            }
            let lazyCache = NeuralTurnCache(capacity: 4096)
            var placed = 0
            var newest = 0.0
            let lazy = ColdOpenFixtures.milliseconds {
                let list = lazyCache.partitionList(messages: messages, running: false)
                for index in 0..<list.count where list.outline(at: index).isBrain {
                    placed += list.outline(at: index).keptPartIDs.count
                }
                newest = ColdOpenFixtures.milliseconds {
                    _ = NeuralBrainModel(turn: list[list.count - 1], context: .none)
                }
            }
            print(
                "NEURAL-COLD-BENCH \(name) turns=\(turns) placed from outlines=\(String(format: "%.2f", lazy))ms of which the newest turn's steps and model=\(String(format: "%.2f", newest))ms sink=\(placed & 1)"
            )
            print(
                "NEURAL-COLD-BENCH \(name) turns=\(turns) brains=\(brains) partition=\(String(format: "%.2f", partition))ms models=\(String(format: "%.2f", models))ms rows=\(String(format: "%.2f", rows))ms total=\(String(format: "%.2f", partition + models + rows))ms sink=\(hashed & 1)"
            )
        }
    }

    private static func searchText(of turn: NeuralTurn) -> String {
        var parts: [String] = []
        parts.reserveCapacity(turn.steps.count * 2)
        for step in turn.steps {
            parts.append(step.title)
            if !step.detail.isEmpty { parts.append(step.detail) }
            if !step.text.isEmpty { parts.append(step.text) }
            if !step.outputLines.isEmpty { parts.append(step.outputLines.joined(separator: " ")) }
        }
        return parts.joined(separator: " ")
    }

    @Test(
        "release microbenchmark: what a cold open of N turns costs read whole, and placed from outlines",
        .enabled(if: ProcessInfo.processInfo.environment["NEURAL_COLD_BENCH"] != nil))
    func baseline() {
        shape("light", ColdOpenFixtures.conversation)
        shape("heavy", ColdOpenFixtures.heavy)
    }
}
