import AppKit
import CodingAgentKit
import QuartzCore
import TailscodeCore

/// What a streamed token costs through the real pane: a `TranscriptViewController` in a window
/// that is never ordered front is handed the states a stream would emit, fifty tokens a second, on
/// top of a conversation of `turns` earlier turns, and the main thread's own CPU time over the run
/// is divided by the tokens. The brain is a card (closed), the live card the same turn wears
/// while it runs, open, or off (the Lines style), so what the brain adds is the difference.
/// `TailscodeMac --bench brain-stream[=100,600,2400]` prints it.
@MainActor
enum BrainStreamBench {
    enum Mode: String, CaseIterable {
        case lines, card, open
    }

    private static let paragraph =
        "The reconnect path retries with a capped backoff and the jitter stays inside its range, "
        + "so a burst of failures spreads out instead of landing together. "

    static func history(turns: Int) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        messages.reserveCapacity(turns * 14)
        for index in 0..<turns {
            messages += NeuralDemo.buildFix(
                prefix: "h\(index)-", origin: 1_700_000_000 + Double(index) * 600)
        }
        return messages
    }

    private static func streaming(_ tick: Int, history: [ChatMessage]) -> ConversationState {
        var all = history
        all.append(
            ChatMessage(
                id: "stream-u", role: .user, agentType: .claudeCode,
                parts: [MessagePart(id: "u", kind: .text("Why is the reconnect test flaky?"))],
                createdAt: Date().addingTimeInterval(-2)))
        var parts = [
            MessagePart(
                id: "think", kind: .reasoning("Looking at how the reconnect test decides it has failed."))
        ]
        let blocks = tick / 150
        for block in 0...blocks {
            parts.append(
                MessagePart(
                    id: "tool\(block)a",
                    kind: .tool(
                        ToolCall(
                            id: "call-\(block)a", name: "Read", status: .completed,
                            input: .object(["file_path": .string("/src/Reconnect\(block).swift")]),
                            output: "ok"))))
            parts.append(
                MessagePart(
                    id: "tool\(block)b",
                    kind: .tool(
                        ToolCall(
                            id: "call-\(block)b", name: "Bash", status: .completed,
                            input: .object(["command": .string("swift test --filter Reconnect\(block)")]),
                            output: "Test Suite passed"))))
            let source = paragraph + paragraph
            let characters = block < blocks ? source.count : min(source.count, (tick % 150) * 2 + 1)
            parts.append(
                MessagePart(id: "text\(block)", kind: .text(String(source.prefix(characters)))))
        }
        all.append(
            ChatMessage(
                id: "stream-a", role: .assistant, agentType: .claudeCode, parts: parts,
                createdAt: Date(), isStreaming: true))
        return ConversationState(
            messages: all, status: .running, connection: .live, hasLoadedTranscript: true)
    }

    private static func cpu() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
    }

    struct Result {
        var perToken: Double
        var worst: Double
        var perSecond: Double
        var tailReads: Int
        var partitions: Int
        var brainPerToken: Double
        var brainMedian: Double
        var brainP95: Double
        var brainWorst: Double
        var reading: Double
        var restating: Double
        var shaping: Double
        var wholeReads: Int
        var contextChanges: Int
        var restateCalls: Int
        var restateWork: Int
        var wholeCost: Double
    }

    static func measure(mode: Mode, turns: Int, tokens: Int = 200) -> Result {
        MacBrain.forcedStyle = mode == .lines ? .lines : .brain
        defer { MacBrain.forcedStyle = nil }
        DisplayGate.assumesVisible = true
        let controller = TranscriptViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
        let base = history(turns: turns)
        controller.show(state: streaming(0, history: base))
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if mode == .open, let latest = controller.brains.latestTurnID {
            controller.brains.setOpen(true, turnID: latest)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        var costs: [Double] = []
        costs.reserveCapacity(tokens)
        var brainCosts: [Double] = []
        brainCosts.reserveCapacity(tokens)
        let warm = 15
        var spentBaseline = controller.brains.spent
        var readBase = 0.0
        var restateBase = 0.0
        var shapeBase = 0.0
        for tick in 1...(tokens + warm) {
            let state = streaming(tick, history: base)
            let begun = cpu()
            let spentThen = controller.brains.spent
            controller.show(state: state)
            RunLoop.current.run(until: Date().addingTimeInterval(0.019))
            guard tick > warm else {
                spentBaseline = controller.brains.spent
                readBase = controller.brains.spentReading
                restateBase = controller.brains.spentRestating
                shapeBase = controller.brains.spentShaping
                continue
            }
            costs.append(cpu() - begun)
            brainCosts.append((controller.brains.spent - spentThen) * 1000)
        }
        let brainSorted = brainCosts.sorted()
        let result = Result(
            perToken: costs.reduce(0, +) / Double(costs.count), worst: costs.max() ?? 0,
            perSecond: costs.reduce(0, +) / Double(costs.count) * 50,
            tailReads: controller.brains.tailReads, partitions: controller.brains.partitions,
            brainPerToken: (controller.brains.spent - spentBaseline) * 1000 / Double(tokens),
            brainMedian: brainSorted[brainSorted.count / 2],
            brainP95: brainSorted[min(brainSorted.count - 1, brainSorted.count * 95 / 100)],
            brainWorst: brainSorted.last ?? 0, reading: (controller.brains.spentReading - readBase) * 1000 / Double(tokens),
            restating: (controller.brains.spentRestating - restateBase) * 1000 / Double(tokens),
            shaping: (controller.brains.spentShaping - shapeBase) * 1000 / Double(tokens),
            wholeReads: controller.brains.wholeReads, contextChanges: controller.brains.contextChanges,
            restateCalls: controller.brains.restateCalls, restateWork: controller.brains.restateWork,
            wholeCost: controller.brains.wholeCost * 1000)
        window.contentView = nil
        controller.brains.clear()
        return result
    }

    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// What a conversation costs while nothing arrives: the main thread's CPU over `seconds` of
    /// stillness with the last turn settled (a card, or open), and what the process holds for it.
    static func idle(mode: Mode, turns: Int, seconds: Double = 5) -> (cpuPerSecond: Double, megabytes: Double) {
        MacBrain.forcedStyle = mode == .lines ? .lines : .brain
        defer { MacBrain.forcedStyle = nil }
        DisplayGate.assumesVisible = true
        let before = footprint()
        let controller = TranscriptViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
        var messages = history(turns: turns)
        messages += NeuralDemo.buildFix(prefix: "tail-", origin: 1_792_000_000)
        controller.show(
            state: ConversationState(
                messages: messages, status: .idle, connection: .live, hasLoadedTranscript: true))
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        if mode == .open, let latest = controller.brains.latestTurnID {
            controller.brains.setOpen(true, turnID: latest)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        }
        let held = footprint() - before
        let begun = cpu()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        let used = (cpu() - begun) / seconds
        window.contentView = nil
        controller.brains.clear()
        return (used, held)
    }

    static func run(sizes: [Int], only: Mode? = nil, tokens: Int? = nil) {
        print("== a streamed token through the real pane (50 tokens a second, main-thread CPU)")
        for turns in sizes {
            var line = "   \(turns) earlier turns:"
            for mode in Mode.allCases where only == nil || only == mode {
                let result = measure(
                    mode: mode, turns: turns, tokens: tokens ?? (turns > 1000 ? 100 : 200))
                line += String(
                    format: " %@ %.2fms a token (worst %.1f, %.0fms of each second; the brain's own: mean %.3f, median %.3f, p95 %.2f, worst %.1f ms, %d tail reads, %d whole reads %.0f ms; reading %.3f, restating %.3f (%d calls, %d restated, %d context changes)) ·",
                    mode.rawValue, result.perToken, result.worst, result.perSecond, result.brainPerToken,
                    result.brainMedian, result.brainP95, result.brainWorst, result.tailReads,
                    result.wholeReads, result.wholeCost, result.reading, result.restating, result.restateCalls, result.restateWork, result.contextChanges)
            }
            print(line)
        }
        print("== the same conversations with nothing arriving (main-thread CPU over 5 s, what the process holds)")
        for turns in sizes {
            var line = "   \(turns) earlier turns:"
            for mode in Mode.allCases where only == nil || only == mode {
                let result = idle(mode: mode, turns: turns)
                line += String(
                    format: " %@ %.1fms of each second, %.0f MB ·", mode.rawValue, result.cpuPerSecond,
                    result.megabytes)
            }
            print(line)
        }
    }
}
