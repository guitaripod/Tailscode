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
}
