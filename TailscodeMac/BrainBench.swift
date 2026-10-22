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


    private static func percentile(_ values: [Double], _ share: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]
    }

    private static func timed(_ body: () -> Void) -> Double {
        let begun = CACurrentMediaTime()
        body()
        RunLoop.current.run(until: Date())
        return (CACurrentMediaTime() - begun) * 1000
    }

    /// What opening and closing one brain costs on the main thread, the move landed at once: the
    /// first open of a conversation (textures, views, the account) and the opens after it.
    private static func openClose(steps: Int, rounds: Int = 12) {
        let fixture = BrainFixture(messages: running(steps: steps), running: false, width: 1300)
        defer { fixture.tearDown() }
        guard let id = fixture.store.order.last else { return }
        var firstOpen = 0.0
        var opens: [Double] = []
        var closes: [Double] = []
        for round in 0..<rounds {
            let open = timed {
                fixture.store.setOpen(true, turnID: id)
                fixture.finishMoves()
            }
            if round == 0 { firstOpen = open } else { opens.append(open) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            closes.append(
                timed {
                    fixture.store.setOpen(false, turnID: id)
                    fixture.finishMoves()
                })
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        print(
            String(
                format:
                    "   %d steps: first open %.1fms · open median %.1fms (p95 %.1f) · close median %.1fms (p95 %.1f)",
                steps, firstOpen, percentile(opens, 0.5), percentile(opens, 0.95), percentile(closes, 0.5),
                percentile(closes, 0.95)))
    }

    private static func wheel(_ delta: Int32, phase: Int64) -> NSEvent? {
        guard
            let cg = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: delta, wheel2: 0, wheel3: 0)
        else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return NSEvent(cgEvent: cg)
    }

    /// What a scroll event costs the main thread over the open brain's step list and account: the
    /// inner scroller moving, and the page's own scroller taking what the list cannot.
    private static func scrolling(steps: Int) {
        let fixture = BrainFixture(messages: running(steps: steps), running: false, width: 1300)
        defer { fixture.tearDown() }
        guard let row = fixture.open(1), let list = row.list, let account = row.account else { return }
        let events = 240
        for (name, scroller) in [("list", list.scroll as NSScrollView), ("account", account.scroll as NSScrollView)] {
            var costs: [Double] = []
            for index in 0..<events {
                let direction: Int32 = (index / 60) % 2 == 0 ? -14 : 14
                guard let event = wheel(direction, phase: index % 60 == 0 ? 1 : 2) else { continue }
                costs.append(timed { scroller.scrollWheel(with: event) })
            }
            print(
                String(
                    format: "   %d steps, %@: scroll event median %.3fms · p95 %.3f · worst %.3f",
                    steps, name, percentile(costs, 0.5), percentile(costs, 0.95), costs.max() ?? 0))
        }
    }

    /// Opening and closing one brain over and over, for a profiler to sample: `--bench brain-open`.
    static func runOpening(rounds: Int) {
        DisplayGate.assumesVisible = true
        print("== opening and closing one brain, \(rounds) times (600 steps)")
        openClose(steps: 600, rounds: rounds)
    }

    static func run() {
        DisplayGate.assumesVisible = true
        print("== the brain while a turn streams (demo large turn, 1300 pt wide)")
        for steps in [29, 174, 600] { parts(steps: steps) }
        print("== opening and closing one brain, and scrolling over it")
        for steps in [29, 174, 600] {
            openClose(steps: steps)
            scrolling(steps: steps)
        }
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
