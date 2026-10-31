import MidgarCore
#if DEBUG
    import CodingAgentKit
    import TailscodeCore
    import UIKit

    extension BrainChecks {
        struct Sample {
            let mean: Double
            let p95: Double
            let max: Double
        }

        static func time(_ count: Int, _ body: () -> Void) -> Sample {
            var all: [Double] = []
            for _ in 0..<count {
                let start = CACurrentMediaTime()
                body()
                all.append((CACurrentMediaTime() - start) * 1000)
            }
            all.sort()
            return Sample(
                mean: all.reduce(0, +) / Double(max(all.count, 1)),
                p95: all[min(all.count - 1, Int(Double(all.count) * 0.95))], max: all.last ?? 0)
        }

        static func report(_ name: String, _ sample: Sample, _ extra: String = "") {
            MidgarLog.info("brain-perf \(name) mean=\(String(format: "%.3f", sample.mean))ms p95=\(String(format: "%.3f", sample.p95))ms max=\(String(format: "%.3f", sample.max))ms \(extra)", category: .ui)
        }

        /// The longest the main thread went between two frames while it ran, and how many gaps
        /// were longer than 25 ms: what a person feels as a hitch.
        @MainActor
        private final class GapMeter: NSObject {
            private var link: CADisplayLink?
            private var last: CFTimeInterval = 0
            private(set) var longest = 0.0
            private(set) var hitches = 0
            private(set) var frames = 0

            func start() {
                last = 0
                longest = 0
                hitches = 0
                frames = 0
                link?.invalidate()
                let made = CADisplayLink(target: self, selector: #selector(step(_:)))
                made.add(to: .main, forMode: .common)
                link = made
            }

            @objc private func step(_ display: CADisplayLink) {
                let now = display.timestamp
                if last > 0 {
                    let gap = (now - last) * 1000
                    longest = max(longest, gap)
                    if gap > 25 { hitches += 1 }
                    frames += 1
                }
                last = now
            }

            func stop() {
                link?.invalidate()
                link = nil
            }
        }

        static var isPerf: Bool {
            ProcessInfo.processInfo.environment["TAILSCODE_NEURAL_PERF"] != nil
        }

        /// What the main thread pays for a running turn's Megatron: a conversation state arriving
        /// (a token), the one-second clock, and what stays alive once the chat has left the window.
        /// Needs `TAILSCODE_NEURAL_STATE=shell` and a long turn (`TAILSCODE_NEURAL_LARGE=174`).
        static func runPerf(
            collection: UICollectionView, store: BrainStore, toggle: @escaping (String) -> Void
        ) async {
            guard let id = store.latestTurnID else { return }
            func cell() -> NeuralBrainCell? {
                collection.visibleCells.compactMap { $0 as? NeuralBrainCell }
                    .first { $0.brainRow.turnID == id }
            }
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            let streamed = (0..<40).flatMap {
                NeuralDemo.largeTurn(steps: 24, prefix: "p\($0)-", origin: 1_792_000_000 + Double($0) * 4000)
            }
            let probe = BrainStore()
            let neutral: (Bool) -> NeuralBrainContext = { _ in NeuralBrainContext() }
            report("prepare cold 40 turns", time(1) {
                _ = probe.prepare(messages: streamed, running: true, awaiting: .none, context: neutral)
            })
            for turns in [40, 300, 1500] {
                let conversation = ChatRebuildBench.conversation(turns: turns, growing: "done")
                let cold = BrainStore()
                report("open cold \(turns) turns", time(1) {
                    _ = cold.prepare(messages: conversation, running: false, awaiting: .none, context: neutral)
                })
                report("open cold \(turns) turns, newest model", time(1) {
                    _ = cold.model(for: cold.latestTurnID ?? "")
                })
                report("open cold \(turns) turns, one older model", time(1) {
                    _ = cold.model(for: cold.turnID(atBrain: max(1, turns / 2)) ?? "")
                })
                var streamed = conversation
                var words = 0
                report("open cold \(turns) turns, then a token", time(200) {
                    words += 1
                    let last = streamed.count - 1
                    streamed[last].parts[streamed[last].parts.count - 1].kind = .text(String(repeating: "word ", count: words))
                    _ = cold.prepare(messages: streamed, running: true, awaiting: .none, context: neutral)
                })
            }
            for turns in [40, 300] {
                let conversation = (0..<turns).flatMap {
                    NeuralDemo.largeTurn(steps: 24, prefix: "h\($0)-", origin: 1_792_000_000 + Double($0) * 4000)
                }
                let cold = BrainStore()
                report("open cold \(turns) heavy turns", time(1) {
                    _ = cold.prepare(messages: conversation, running: false, awaiting: .none, context: neutral)
                })
            }
            var growing = streamed
            var counter = 0
            report("prepare per token 40 turns", time(300) {
                counter += 1
                if let message = growing.indices.last(where: { index in
                    growing[index].parts.contains { if case .text = $0.kind { return true } else { return false } }
                }), let part = growing[message].parts.indices.last(where: { if case .text = growing[message].parts[$0].kind { return true } else { return false } }),
                    case .text(let words) = growing[message].parts[part].kind
                {
                    growing[message].parts[part].kind = .text(words + "x")
                }
                _ = probe.prepare(messages: growing, running: true, awaiting: .none, context: neutral)
            })
            var partitioned: [NeuralTurn] = []
            report("partition 40 turns", time(1) {
                partitioned = NeuralTurns.partition(messages: streamed, running: true)
            })
            report("models of 40 turns", time(1) {
                for turn in partitioned { _ = NeuralBrainModel(turn: turn, context: NeuralBrainContext()) }
            })
            report("search text of 40 turns", time(1) {
                for turn in partitioned { _ = BrainStore.searchText(of: turn) }
            })
            let heavy: [ChatMessage] = streamed.map { message in
                var copy = message
                for index in copy.parts.indices {
                    if case .tool(var call) = copy.parts[index].kind {
                        call.output = String(repeating: "a line of tool output that a build prints\n", count: 500)
                        copy.parts[index].kind = .tool(call)
                    }
                }
                return copy
            }
            let heavyProbe = BrainStore()
            report("prepare cold 40 turns 20 KB outputs", time(1) {
                _ = heavyProbe.prepare(messages: heavy, running: true, awaiting: .none, context: neutral)
            })
            var heavyGrowing = heavy
            report("prepare per token 40 turns 20 KB outputs", time(200) {
                if let message = heavyGrowing.indices.last(where: { index in
                    heavyGrowing[index].parts.contains { if case .text = $0.kind { return true } else { return false } }
                }), let part = heavyGrowing[message].parts.indices.last(where: { if case .text = heavyGrowing[message].parts[$0].kind { return true } else { return false } }),
                    case .text(let words) = heavyGrowing[message].parts[part].kind
                {
                    heavyGrowing[message].parts[part].kind = .text(words + "x")
                }
                _ = heavyProbe.prepare(messages: heavyGrowing, running: true, awaiting: .none, context: neutral)
            })
            await wait(1.5)
            guard let closed = cell() else {
                MidgarLog.info("brain-perf the latest brain is not on screen", category: .ui)
                return
            }
            report("closed-live token", time(300) { closed.refreshLive(); closed.layoutIfNeeded() })
            let settled = collection.visibleCells.compactMap { $0 as? NeuralBrainCell }.first { $0.brainRow.turnID != id }
            if let settled {
                report("settled-card token", time(300) { settled.refreshLive(); settled.layoutIfNeeded() })
            } else {
                MidgarLog.info("brain-perf no settled card on screen", category: .ui)
            }
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
            attributes.size = CGSize(width: collection.bounds.width, height: 100)
            report("closed-live self-size", time(300) { _ = closed.preferredLayoutAttributesFitting(attributes) })
            if let settled {
                report("settled-card self-size", time(300) { _ = settled.preferredLayoutAttributesFitting(attributes) })
            }
            let meter = GapMeter()
            meter.start()
            let tap = time(1) { toggle(id); collection.layoutIfNeeded() }
            await wait(2)
            meter.stop()
            report("open tap", tap, "frames=\(meter.frames) longestGap=\(String(format: "%.1f", meter.longest))ms hitches=\(meter.hitches)")
            guard let open = cell(), open.brainRow.openView != nil else {
                MidgarLog.info("brain-perf the brain did not open", category: .ui)
                return
            }
            report("open-live token", time(300) { open.refreshLive(); open.layoutIfNeeded() })
            report("open-live second", time(100) { open.brainRow.openView?.tick(); open.layoutIfNeeded() })
            let before = BrainLiveClock.shared.ticks
            let held = BrainLiveClock.shared.registered
            let headRunning = open.brainRow.openView?.stage.head.isClockRunning ?? false
            let context = NeuralMetalContext.shared?.retainCount ?? -1
            let parent = collection.superview
            collection.removeFromSuperview()
            await wait(3.5)
            MidgarLog.info("brain-perf away registered=\(BrainLiveClock.shared.registered)/\(held) ticks=\(BrainLiveClock.shared.ticks - before) running=\(BrainLiveClock.shared.isRunning) headClock=\(headRunning)->\(open.brainRow.openView?.stage.head.isClockRunning ?? false) displayLink=\(open.brainRow.ownsDisplayLink) metalHolds=\(context)->\(NeuralMetalContext.shared?.retainCount ?? -1)", category: .ui)
            if let parent { parent.addSubview(collection) }
            await wait(1)
            MidgarLog.info("brain-perf back registered=\(BrainLiveClock.shared.registered) running=\(BrainLiveClock.shared.isRunning)", category: .ui)
            toggle(id)
            await wait(1.2)
            let second = time(1) { toggle(id); collection.layoutIfNeeded() }
            await wait(1.5)
            report("reopen tap", second)
            MidgarLog.info("brain-perf done", category: .ui)
        }
    }
#endif
