import CodingAgentKit
import Foundation
import TailscodeCore

#if DEBUG
    /// `TAILSCODE_BENCH_REBUILD=<turns>` times what a streamed token costs a transcript of that many
    /// turns, in the `performance` log: the rows built cold, the rows built again with the
    /// per-message memo while the last answer grows, the turns read through the brain's cache and
    /// the brains prepared. The point is the ratio of the cold and the warm figures and how the warm
    /// one grows with the conversation, not the absolute milliseconds of a Debug build.
    @MainActor
    enum ChatRebuildBench {
        static func runIfRequested() {
            guard let value = ProcessInfo.processInfo.environment["TAILSCODE_BENCH_REBUILD"],
                let turns = Int(value), turns > 0
            else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { run(turns: turns) }
        }

        static func conversation(turns: Int, growing: String) -> [ChatMessage] {
            var out: [ChatMessage] = []
            let origin = Date(timeIntervalSince1970: 1_792_000_000)
            for turn in 0..<turns {
                let at = origin.addingTimeInterval(Double(turn) * 60)
                out.append(
                    ChatMessage(
                        id: "u\(turn)", role: .user, agentType: .claudeCode,
                        parts: [MessagePart(id: "t", kind: .text("Prompt number \(turn)"))],
                        createdAt: at, completedAt: at))
                let last = turn == turns - 1
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
                        kind: .text(
                            last
                                ? growing
                                : "Done with turn \(turn).\n\n```swift\nlet x = \(turn)\n```\n\nThat is all.")))
                out.append(
                    ChatMessage(
                        id: "m\(turn)", role: .assistant, agentType: .claudeCode, parts: parts,
                        createdAt: at.addingTimeInterval(5),
                        completedAt: last ? nil : at.addingTimeInterval(30), isStreaming: last,
                        modelID: "claude-fable-5"))
            }
            return out
        }

        private static func milliseconds(_ body: () -> Void) -> Double {
            let start = ContinuousClock.now
            body()
            let elapsed = ContinuousClock.now - start
            return Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15
        }

        private static func run(turns: Int) {
            let iterations = 20
            let agents = ChatViewController.SubagentPlacement()
            let memo = SegmentRowMemo()
            let cache = NeuralTurnCache(capacity: 4096)
            let store = BrainStore()
            var cold = 0.0
            var warm = 0.0
            var brainCold = 0.0
            var partition = 0.0
            var prepare = 0.0
            var rowCount = 0
            var compare = 0.0
            var workflow = 0.0
            var index = 0.0
            var previous = conversation(turns: turns, growing: "")
            var retained: [[ChatMessage]] = []
            _ = cache.partitionList(messages: previous, running: true)
            _ = store.prepare(messages: previous, running: true, awaiting: .none) { _, _ in .none }
            _ = ChatRowBuilder.makeRows(from: previous, agents: agents, turnOpen: true, memo: memo)
            for pass in 0..<iterations {
                let messages = conversation(turns: turns, growing: String(repeating: "word ", count: pass + 1))
                compare += milliseconds {
                    var same = 0
                    for (a, b) in zip(previous, messages) where a == b { same += 1 }
                    if same < 0 { print(same) }
                }
                previous = messages
                retained.append(messages)
                cold += milliseconds {
                    rowCount = ChatRowBuilder.makeRows(from: messages, agents: agents, turnOpen: true).count
                }
                warm += milliseconds {
                    _ = ChatRowBuilder.makeRows(
                        from: messages, agents: agents, turnOpen: true, memo: memo)
                }
                workflow += milliseconds {
                    _ = WorkflowRunAssembly.runs(messages: messages, agents: [])
                }
                index += milliseconds {
                    let rows = ChatRowBuilder.makeRows(
                        from: messages, agents: agents, turnOpen: true, memo: memo)
                    var seen = Set<String>()
                    let unique = rows.filter { seen.insert($0.id).inserted }
                    let byID = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0) })
                    let ids = unique.map(\.id)
                    if byID.count + ids.count < 0 { print(ids.count) }
                }
                partition += milliseconds {
                    _ = cache.partitionList(
                        messages: messages, running: true, stablePrefix: messages.count - 12)
                }
                prepare += milliseconds {
                    _ = store.prepare(
                        messages: messages, running: true, awaiting: .none
                    ) { _, _ in .none }
                }
                brainCold += milliseconds {
                    _ = NeuralTurns.partition(messages: messages, running: true)
                }
            }
            _ = retained.count
            let n = Double(iterations)
            let timings = ChatRowBuilder.BuilderTimings.self
            AppLogger.performance.info(
                "bench phases (cold+memo, summed over \(iterations) passes) fuse=\(String(format: "%.1f", timings.fuse))ms rails=\(String(format: "%.1f", timings.rails))ms pictures=\(String(format: "%.1f", timings.pictures))ms"
            )
            AppLogger.performance.info(
                "bench rebuild turns=\(turns) messages=\(turns * 2) rows=\(rowCount) coldRows=\(String(format: "%.2f", cold / n))ms memoRows=\(String(format: "%.2f", warm / n))ms memoHits=\(memo.messageHits) memoBuilds=\(memo.messageBuilds) partitionCold=\(String(format: "%.2f", brainCold / n))ms partitionCached=\(String(format: "%.2f", partition / n))ms brainPrepare=\(String(format: "%.2f", prepare / n))ms messageCompare=\(String(format: "%.2f", compare / n))ms workflowRuns=\(String(format: "%.2f", workflow / n))ms rowsAndIndex=\(String(format: "%.2f", index / n))ms"
            )
        }
    }
#endif
