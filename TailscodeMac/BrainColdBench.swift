import AppKit
import CodingAgentKit
import QuartzCore
import TailscodeCore

/// What opening a chat costs the main thread's own CPU time for its brains: a fresh store is handed
/// a conversation of `turns` earlier turns (fourteen messages each) and reads it, and then the
/// model of the newest turn and of one in the middle are asked for. The read is what every open
/// pays; the models are what a card pays when it is shown. `TailscodeMac --bench brain-cold[=40,300,1500]`.
@MainActor
enum BrainColdBench {
    private static func cpu() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
    }

    private static func spend(_ body: () -> Void) -> Double {
        let began = cpu()
        body()
        return cpu() - began
    }

    private static func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    static func run(sizes: [Int]) {
        MacBrain.forcedStyle = .brain
        defer { MacBrain.forcedStyle = nil }
        for turns in sizes {
            let messages = BrainStreamBench.history(turns: turns)
            var reads: [Double] = []
            var newest: [Double] = []
            var older: [Double] = []
            var brains = 0
            for _ in 0..<7 {
                let store = BrainStore()
                reads.append(spend { store.read(messages: messages, running: false, awaiting: .none) })
                brains = store.order.count
                newest.append(spend { _ = store.entry(store.order.last ?? "") })
                older.append(spend { _ = store.entry(store.order[store.order.count / 2]) })
            }
            print(
                String(
                    format: "brain-cold turns=%d messages=%d brains=%d read=%.2fms newest=%.2fms older=%.2fms",
                    turns, messages.count, brains, median(reads), median(newest), median(older)))
        }
    }
}
