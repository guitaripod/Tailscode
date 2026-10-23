import AppKit
import CodingAgentKit
import QuartzCore
import TailscodeCore

/// Opening and closing one Megatron through the real pane, the way a person does it: a
/// `TranscriptViewController` in a window that is on screen with the app active, a conversation of
/// earlier turns above a settled turn of `steps` steps, the press handed to the store and the
/// display link left to run the move. Every main run loop turn from the press to the end of the
/// move is timed in the main thread's own CPU (`BrainTurnMeter`), so the figure that matters is
/// the longest turn: a frame is lost for every 8 ms (120 Hz) or 16 ms (60 Hz) past the first.
///
/// The display link ticks only while the Mac's display is awake, so the run is made under
/// `caffeinate -d -u`. `TailscodeMac --bench brain-pane[=turns[:steps,steps]] [--rounds n]`.
@MainActor
enum BrainPaneBench {
    struct Summary {
        var longestOpen: [Double] = []
        var longestClose: [Double] = []
        var totalOpen: [Double] = []
        var totalClose: [Double] = []
        var turnsOverOpen: [Double] = []
        var turnsOverClose: [Double] = []
        var firstOpen = 0.0
        var firstClose = 0.0
        var landed = true
        var sequences: (open: [Double], close: [Double]) = ([], [])
    }

    /// Rounds that are not counted: the first opens of a process read code and fonts nothing has
    /// read yet, which is the first open's cost and not the next ones'.
    static let warmRounds = 2

    static func conversation(turns: Int, steps: Int) -> ConversationState {
        var messages = BrainStreamBench.history(turns: turns)
        messages += NeuralDemo.buildFix(prefix: "tail-", origin: 1_792_000_000)
        messages += NeuralDemo.largeTurn(steps: steps, prefix: "big-", origin: 1_792_003_600, answer: true)
        return ConversationState(
            messages: messages, status: .idle, connection: .live, hasLoadedTranscript: true)
    }

    private static func settle(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The pane, scrolled to the end of a conversation with its newest turn a card, in a window on
    /// screen.
    @MainActor
    final class Stand {
        let controller = TranscriptViewController()
        let window: NSWindow

        init(turns: Int, steps: Int) {
            MacBrain.forcedStyle = .brain
            DisplayGate.assumesVisible = true
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.finishLaunching()
            app.activate(ignoringOtherApps: true)
            NeuralMetalContext.warm()
            BrainPaneBench.settle(1.5)
            window = NSWindow(
                contentRect: NSRect(x: 80, y: 80, width: 1300, height: 900), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            controller.rowTailMessages = 100_000
            window.contentView = controller.view
            window.orderFrontRegardless()
            controller.view.layoutSubtreeIfNeeded()
            controller.show(state: BrainPaneBench.conversation(turns: turns, steps: steps))
            controller.view.layoutSubtreeIfNeeded()
            BrainPaneBench.settle(0.6)
            controller.scrollToBottom()
            BrainPaneBench.settle(0.4)
        }

        func tearDown() {
            window.contentView = nil
            window.close()
            controller.brains.clear()
            MacBrain.forcedStyle = nil
        }
    }

    /// One press and the move after it, every turn timed. Returns whether the brain landed in the
    /// state asked for.
    static func press(
        _ open: Bool, on stand: Stand, meter: BrainTurnMeter, seconds: Double
    ) -> Bool {
        guard let latest = stand.controller.brains.latestTurnID else { return false }
        meter.start()
        RunLoop.current.perform { stand.controller.brains.setOpen(open, turnID: latest) }
        settle(seconds)
        meter.stop()
        let phase = stand.controller.brains.view(forTurn: latest)?.phase
        return phase == (open ? .open : .closed)
    }

    static func measure(turns: Int, steps: Int, rounds: Int, limit: Double = 4) -> Summary {
        let stand = Stand(turns: turns, steps: steps)
        defer { stand.tearDown() }
        let meter = BrainTurnMeter()
        var summary = Summary()
        for round in 0..<rounds {
            if !press(true, on: stand, meter: meter, seconds: 0.8) { summary.landed = false }
            let open = meter.sequenceCPU
            let openLongest = meter.longestCPU
            let openTotal = meter.totalCPU
            let openOver = Double(meter.turnsOver(cpuMilliseconds: limit))
            settle(0.3)
            if !press(false, on: stand, meter: meter, seconds: 0.6) { summary.landed = false }
            if round == 0 {
                summary.firstOpen = openLongest
                summary.firstClose = meter.longestCPU
            } else if round >= warmRounds {
                summary.longestOpen.append(openLongest)
                summary.totalOpen.append(openTotal)
                summary.turnsOverOpen.append(openOver)
                summary.longestClose.append(meter.longestCPU)
                summary.totalClose.append(meter.totalCPU)
                summary.turnsOverClose.append(Double(meter.turnsOver(cpuMilliseconds: limit)))
            }
            if round == rounds - 1 { summary.sequences = (open, meter.sequenceCPU) }
            settle(0.3)
        }
        return summary
    }

    private static func sequence(_ turns: [Double]) -> String {
        turns.filter { $0 > 0.4 }.map { String(format: "%.1f", $0) }.joined(separator: " ")
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    static func line(turns: Int, steps: Int, summary r: Summary) -> String {
        String(
            format:
                "   %d earlier turns, %d steps: OPEN longest turn first %.1fms · median %.1f (worst %.1f) · whole move %.0fms of CPU · %.0f turns over 4ms · CLOSE longest turn first %.1fms · median %.1f (worst %.1f) · whole move %.0fms · %.0f turns over 4ms%@",
            turns, steps, r.firstOpen, median(r.longestOpen), r.longestOpen.max() ?? 0,
            median(r.totalOpen), median(r.turnsOverOpen), r.firstClose, median(r.longestClose),
            r.longestClose.max() ?? 0, median(r.totalClose), median(r.turnsOverClose),
            r.landed ? "" : " · THE BRAIN DID NOT LAND (is the display awake?)")
    }

    static func run(spec: String) -> Never {
        let fields = spec.split(separator: "=").dropFirst().first.map { $0.split(separator: ":") } ?? []
        let turns = fields.first.flatMap { Int($0) } ?? 100
        let steps =
            fields.dropFirst().first.map { $0.split(separator: ",").compactMap { Int($0) } }
            ?? [29, 174, 600]
        let arguments = CommandLine.arguments
        let rounds = arguments.firstIndex(of: "--rounds").flatMap { Int(arguments[$0 + 1]) } ?? 10
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        print(
            String(
                format: "== opening and closing one Megatron through the real pane, main thread CPU per run loop turn (load average %.1f %.1f %.1f)",
                load[0], load[1], load[2]))
        for count in steps {
            let summary = measure(turns: turns, steps: count, rounds: rounds)
            print(line(turns: turns, steps: count, summary: summary))
            print("      open turns: \(sequence(summary.sequences.open))")
            print("      close turns: \(sequence(summary.sequences.close))")
        }
        exit(0)
    }
}
