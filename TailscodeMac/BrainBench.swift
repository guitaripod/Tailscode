import AppKit
import CodingAgentKit
import QuartzCore
import TailscodeCore

/// What a streamed token costs while a turn is being written, with the brain a card and with it
/// open, measured off the demo's large turn: the rows rebuilt, the models brought to the turn, and
/// every part of the open brain restated, on the main thread in a window that is never ordered
/// front. `TailscodeMac --bench <transcript.json …>` prints it after the transcripts.
@MainActor
enum BrainBench {
    private static func running(steps: Int) -> [ChatMessage] {
        var messages =
            NeuralDemo.buildFix(prefix: "a-")
            + NeuralDemo.largeTurn(steps: steps, prefix: "b-", origin: 1_792_003_600, answer: false)
        if let index = messages.indices.last(where: { messages[$0].role == .assistant }) {
            messages[index].isStreaming = true
            messages[index].completedAt = nil
            messages[index].parts.append(MessagePart(id: "stream-note", kind: .text("Streaming")))
        }
        return messages
    }

    private static func tokens(
        _ fixture: BrainFixture, count: Int
    ) -> (median: Double, worst: Double, perSecond: Double) {
        var messages = fixture.messages
        guard let index = messages.indices.last(where: { messages[$0].role == .assistant }) else {
            return (0, 0, 0)
        }
        var costs: [Double] = []
        for step in 0..<count {
            if let at = messages[index].parts.firstIndex(where: { $0.id == "stream-note" }),
                case .text(let words) = messages[index].parts[at].kind
            {
                messages[index].parts[at].kind = .text(words + " token\(step) and a few more of them")
            }
            let begun = CACurrentMediaTime()
            fixture.replace(messages: messages)
            RunLoop.current.run(until: Date())
            costs.append((CACurrentMediaTime() - begun) * 1000)
            RunLoop.current.run(until: Date().addingTimeInterval(0.018))
        }
        let sorted = costs.sorted()
        return (sorted[sorted.count / 2], sorted.last ?? 0, costs.reduce(0, +) / (Double(count) * 0.02))
    }

    private static func timeMedian(_ count: Int, _ body: () -> Void) -> Double {
        var costs: [Double] = []
        for _ in 0..<count {
            let begun = CACurrentMediaTime()
            body()
            costs.append((CACurrentMediaTime() - begun) * 1000)
        }
        return costs.sorted()[costs.count / 2]
    }

    /// Where a streamed token's time goes in one turn: reading the messages into steps, bringing
    /// the model to the new turn, and reading the card off it.
    private static func parts(steps: Int) {
        let messages = running(steps: steps)
        let group = messages.filter { $0.role == .assistant && !$0.id.hasPrefix("a-") }
        let read = timeMedian(30) { _ = NeuralTurns.partition(messages: group, running: true) }
        guard let turn = NeuralTurns.partition(messages: group, running: true).first else { return }
        var model = NeuralBrainModel(turn: turn)
        var next = turn
        next.steps = turn.steps
        let update = timeMedian(30) { model.update(turn: next, context: .none) }
        var grown = turn
        if let last = grown.steps.indices.last { grown.steps[last].text += " x" }
        let changed = timeMedian(30) {
            grown.steps[grown.steps.count - 1].text += " x"
            model.update(turn: grown, context: .none)
        }
        let card = timeMedian(30) { _ = model.brainCard(now: Date()) }
        let live = timeMedian(30) { _ = model.liveCard }
        let frame = timeMedian(30) { _ = NeuralNodes.draws(model: model, time: 0, reduceMotion: true) }
        let wires = timeMedian(30) { _ = NeuralNodes.wires(model: model, time: 0, reduceMotion: true) }
        print(
            String(
                format:
                    "   %d steps: read %.2fms · update same %.2fms · update changed %.2fms · card %.2fms · live card %.2fms · node draws %.2fms · wires %.2fms",
                steps, read, update, changed, card, live, frame, wires))
    }

    static func run() {
        DisplayGate.assumesVisible = true
        print("== the brain while a turn streams (demo large turn, 1300 pt wide)")
        for steps in [29, 174, 600] { parts(steps: steps) }
        for steps in [29, 174, 600] {
            let closed = BrainFixture(messages: running(steps: steps), running: true, width: 1300)
            let card = tokens(closed, count: 100)
            closed.tearDown()
            let opened = BrainFixture(messages: running(steps: steps), running: true, width: 1300)
            opened.open(1)
            opened.finishMoves()
            let open = tokens(opened, count: 100)
            let nodes = opened.view(1)?.model.nodeCount ?? 0
            opened.tearDown()
            print(
                String(
                    format:
                        "   %d steps (%d nodes), 50 tokens a second: as a card %.2fms a token (worst %.2f, %.0fms of each second) · open %.2fms (worst %.2f, %.0fms of each second)",
                    steps, nodes, card.median, card.worst, card.perSecond, open.median, open.worst,
                    open.perSecond))
        }
    }
}
