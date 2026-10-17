import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural real assets")
struct NeuralRealAssetsTests {
    private static let directory = ProcessInfo.processInfo.environment["NEURAL_ASSETS_DIR"]
    private static let output = ProcessInfo.processInfo.environment["NEURAL_OUT_DIR"]

    private func store(_ directory: String) -> NeuralAssetStore {
        NeuralAssetStore(loader: { name in
            try? Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("\(name).ntrg"))
        })
    }

    @Test(
        "every state renders from the packed set and the pictures are written out for a look",
        .enabled(if: NeuralRealAssetsTests.directory != nil))
    func everyState() throws {
        let directory = try #require(Self.directory)
        let assets = store(directory)
        assets.retain()
        defer { assets.release() }
        for name in NeuralAssetName.allCases {
            #expect(assets.image(named: name) != nil, "\(name.rawValue) is missing")
        }
        let palette = AppTheme.phosphor.dark
        let face = NeuralFace(family: .opus)
        let compositor = NeuralCompositor(
            assets: assets, size: (width: 768, height: 504), palette: palette, face: face)
        var states: [(String, NeuralState, Double)] = ActivityKind.everyState.enumerated().map {
            ("\($0.offset)-\(NeuralState.make(activity: $0.element).label)", NeuralState.make(activity: $0.element), 0.128)
        }
        states.append(("settled", .settled, 0))
        states.append(("idle", .idle, 0))
        for (name, state, time) in states {
            let frame = NeuralFrame.at(
                time: time, state: state, face: face,
                meters: NeuralMeters(contextFill: 0.62),
                reduceMotion: false)
            let pair = compositor.renderFull(frame, time: Float(time))
            if let output = Self.output {
                let base = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                try Data(pair.interior.bytes).write(to: base.appendingPathComponent("\(name)-interior.bgra"))
                try Data(pair.front.bytes).write(to: base.appendingPathComponent("\(name)-front.bgra"))
            }
        }
    }

    @Test(
        "full renders and deltas at the design size are timed on the real layers",
        .enabled(if: NeuralRealAssetsTests.directory != nil))
    func timings() throws {
        let directory = try #require(Self.directory)
        let assets = store(directory)
        assets.retain()
        defer { assets.release() }
        let palette = AppTheme.phosphor.dark
        let face = NeuralFace(family: .opus)
        let compositor = NeuralCompositor(
            assets: assets, size: (width: 1536, height: 1008), palette: palette, face: face)
        let working = NeuralState.make(activity: .usingTool(name: "Bash", kind: .shell))
        var pair = compositor.makeSurfacePair()
        var previous = NeuralFrame.at(time: 0, state: working, face: face, reduceMotion: false)
        let clock = ContinuousClock()
        let full = clock.measure { pair = compositor.renderFull(previous, time: 0) }
        var delta = Duration.zero
        let steps = 30
        for step in 1...steps {
            let time = Double(step) / 30
            let next = NeuralFrame.at(time: time, state: working, face: face, reduceMotion: false)
            let region = compositor.dirtyRegion(for: next, previous: previous)
            delta += clock.measure {
                compositor.renderDelta(
                    next, previous: previous, into: &pair, region: region, sparse: compositor.fibrePixels,
                    time: Float(time))
            }
            previous = next
        }
        print("NEURAL-REAL full \(full) delta \(delta / steps) footprint \(compositor.memoryFootprint / 1_048_576) MB")
    }

    private static func cpuMilliseconds() -> Double {
        var spec = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &spec)
        return Double(spec.tv_sec) * 1000 + Double(spec.tv_nsec) / 1_000_000
    }

    private static func difference(_ a: [UInt8], _ b: [UInt8]) -> (max: Int, mean: Double) {
        guard a.count == b.count, !a.isEmpty else { return (255, 255) }
        var worst = 0
        var total = 0
        for index in 0..<a.count {
            let delta = abs(Int(a[index]) - Int(b[index]))
            worst = max(worst, delta)
            total += delta
        }
        return (worst, Double(total) / Double(a.count))
    }

    private static func format(_ value: Double) -> String { String(format: "%.3f", value) }

    @Test(
        "CPU time per frame for a full render and for the deltas of each kind of state, at two sizes",
        .enabled(if: NeuralRealAssetsTests.directory != nil))
    func cpuTimePerFrame() throws {
        let directory = try #require(Self.directory)
        let assets = store(directory)
        assets.retain()
        defer { assets.release() }
        let palette = AppTheme.phosphor.dark
        let face = NeuralFace(family: .opus)
        let scenarios: [(String, NeuralState)] = [
            ("working", NeuralState.make(activity: .usingTool(name: "Bash", kind: .shell))),
            ("thinking", NeuralState.make(activity: .thinking)),
            ("sweep", NeuralState.make(activity: .retrying(attempt: 1))),
            ("approval", NeuralState.make(activity: .needsApproval)),
            ("compacting", NeuralState.make(activity: .compacting)),
        ]
        for size in [(760, 499), (1536, 1008)] {
            let compositor = NeuralCompositor(
                assets: assets, size: (width: size.0, height: size.1), palette: palette, face: face)
            let tag = "\(size.0)x\(size.1)"
            var pair = compositor.makeSurfacePair()
            NeuralParallelism.maximumWorkers = 4
            NeuralParallelism.minimumRows = 4
            let settled = NeuralFrame.at(time: 0, state: .settled, face: face, reduceMotion: false)
            var started = Self.cpuMilliseconds()
            let fullRuns = 10
            for _ in 0..<fullRuns { compositor.renderFull(settled, time: 0, into: &pair) }
            let settledFull = (Self.cpuMilliseconds() - started) / Double(fullRuns)
            let idle = compositor.memoryFootprint / 1_048_576
            let diving = NeuralDive(center: NeuralPoint(0.55, 0.5), chassisScale: 1.4, glassScale: 1.7, fade: 0.7)
            started = Self.cpuMilliseconds()
            for _ in 0..<fullRuns { compositor.renderFull(settled, dive: diving, time: 0, into: &pair) }
            let diveFull = (Self.cpuMilliseconds() - started) / Double(fullRuns)
            var line = "NEURAL-BENCH \(tag) idle \(idle) MB settledFull \(Self.format(settledFull)) ms diveFull \(Self.format(diveFull)) ms"
            NeuralParallelism.maximumWorkers = 1
            NeuralParallelism.minimumRows = 16
            for (name, state) in scenarios {
                let steps = 60
                var previous = NeuralFrame.at(time: 0, state: state, face: face, reduceMotion: false)
                NeuralParallelism.maximumWorkers = 4
                NeuralParallelism.minimumRows = 4
                started = Self.cpuMilliseconds()
                for _ in 0..<fullRuns { compositor.renderFull(previous, time: 0, into: &pair) }
                let full = (Self.cpuMilliseconds() - started) / Double(fullRuns)
                NeuralParallelism.maximumWorkers = 1
                NeuralParallelism.minimumRows = 16
                var frames: [NeuralFrame] = []
                for step in 1...steps {
                    frames.append(
                        NeuralFrame.at(time: Double(step) / 30, state: state, face: face, reduceMotion: false))
                }
                started = Self.cpuMilliseconds()
                for (offset, next) in frames.enumerated() {
                    let region = compositor.dirtyRegion(for: next, previous: previous)
                    compositor.renderDelta(
                        next, previous: previous, into: &pair, region: region, time: Float(Double(offset + 1) / 30))
                    previous = next
                }
                let delta = (Self.cpuMilliseconds() - started) / Double(steps)
                NeuralParallelism.maximumWorkers = 4
                NeuralParallelism.minimumRows = 4
                let expected = compositor.renderFull(previous, time: Float(Double(steps) / 30))
                let inner = Self.difference(pair.interior.bytes, expected.interior.bytes)
                let outer = Self.difference(pair.front.bytes, expected.front.bytes)
                line += " | \(name) full \(Self.format(full)) delta \(Self.format(delta)) vsFull int \(inner.max)/\(Self.format(inner.mean)) front \(outer.max)/\(Self.format(outer.mean))"
                NeuralParallelism.maximumWorkers = 1
                NeuralParallelism.minimumRows = 16
            }
            print(line + " footprint \(compositor.memoryFootprint / 1_048_576) MB")
        }
        NeuralParallelism.maximumWorkers = Int.max
        NeuralParallelism.minimumRows = 4
    }

    @Test(
        "the goldens written for this run differ from a baseline set by at most a level",
        .enabled(if: NeuralRealAssetsTests.output != nil && ProcessInfo.processInfo.environment["NEURAL_BASELINE_DIR"] != nil))
    func againstBaseline() throws {
        let output = try #require(Self.output)
        let baseline = try #require(ProcessInfo.processInfo.environment["NEURAL_BASELINE_DIR"])
        let names = try FileManager.default.contentsOfDirectory(atPath: baseline).filter { $0.hasSuffix(".bgra") }.sorted()
        #expect(!names.isEmpty)
        var worst = 0
        for name in names {
            let old = [UInt8](try Data(contentsOf: URL(fileURLWithPath: baseline).appendingPathComponent(name)))
            let new = [UInt8](try Data(contentsOf: URL(fileURLWithPath: output).appendingPathComponent(name)))
            let result = Self.difference(old, new)
            worst = max(worst, result.max)
            print("NEURAL-DIFF \(name) max \(result.max) mean \(Self.format(result.mean))")
        }
        #expect(worst <= 1)
    }

    @Test(
        "on the real layers the lit-pixel paths draw what the every-pixel paths draw, full and delta",
        .enabled(if: NeuralRealAssetsTests.directory != nil))
    func sparseAgreesWithDense() throws {
        let directory = try #require(Self.directory)
        let assets = store(directory)
        assets.retain()
        defer { assets.release() }
        let palette = AppTheme.phosphor.dark
        let face = NeuralFace(family: .opus)
        let states: [(String, NeuralState)] = [
            ("working", NeuralState.make(activity: .usingTool(name: "Bash", kind: .shell))),
            ("thinking", NeuralState.make(activity: .thinking)),
            ("writing", NeuralState.make(activity: .writing)),
            ("sweep", NeuralState.make(activity: .retrying(attempt: 1))),
            ("approval", NeuralState.make(activity: .needsApproval)),
            ("compacting", NeuralState.make(activity: .compacting)),
            ("background", NeuralState.make(activity: .inBackground(tasks: 2))),
            ("failed", NeuralState.make(activity: .failed)),
        ]
        for size in [(760, 499), (1536, 1008)] {
            let fast = NeuralCompositor(
                assets: assets, size: (width: size.0, height: size.1), palette: palette, face: face)
            let dense = NeuralCompositor(
                assets: assets, size: (width: size.0, height: size.1), palette: palette, face: face)
            dense.denseOnly = true
            for (name, state) in states {
                var fastPair = fast.makeSurfacePair()
                var densePair = dense.makeSurfacePair()
                var previous = NeuralFrame.at(time: 0, state: state, face: face, meters: NeuralMeters(contextFill: 0.4), reduceMotion: false)
                fast.renderFull(previous, time: 0, into: &fastPair)
                dense.renderFull(previous, time: 0, into: &densePair)
                var worst = Self.difference(fastPair.interior.bytes, densePair.interior.bytes)
                var front = Self.difference(fastPair.front.bytes, densePair.front.bytes)
                for step in 1...45 {
                    let time = Double(step) / 30
                    let next = NeuralFrame.at(time: time, state: state, face: face, meters: NeuralMeters(contextFill: 0.4 + Float(step) / 200), reduceMotion: false)
                    fast.renderDelta(next, previous: previous, into: &fastPair, time: Float(time))
                    dense.renderDelta(next, previous: previous, into: &densePair, time: Float(time))
                    let inner = Self.difference(fastPair.interior.bytes, densePair.interior.bytes)
                    let outer = Self.difference(fastPair.front.bytes, densePair.front.bytes)
                    worst = (max(worst.max, inner.max), max(worst.mean, inner.mean))
                    front = (max(front.max, outer.max), max(front.mean, outer.mean))
                    previous = next
                }
                print("NEURAL-DENSE \(size.0)x\(size.1) \(name) interior max \(worst.max) mean \(Self.format(worst.mean)) front max \(front.max) mean \(Self.format(front.mean))")
                #expect(worst.max <= 1 && front.max <= 1, "\(name) at \(size.0)")
                #expect(worst.mean < 0.0005 && front.mean < 0.0005, "\(name) at \(size.0)")
            }
        }
    }
}
