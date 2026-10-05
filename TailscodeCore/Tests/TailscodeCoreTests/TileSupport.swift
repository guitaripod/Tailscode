import Foundation

@testable import TailscodeCore

/// A seeded generator, so every property case that fails names a seed that fails again.
struct TileRandom {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(truncatingIfNeeded: seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407)
        _ = next()
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 11
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func unit() -> Double {
        Double(next() % 1_000_000) / 1_000_000
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[int(0...(items.count - 1))]
    }

    mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }
}

enum TileFixtures {
    static let minimums: [PaneMinimum] = [
        PaneSizing.chatGlance, PaneSizing.chatGlance, PaneSizing.chatGlance, PaneSizing.web,
        PaneSizing.video, PaneSizing.draw, PaneSizing.empty,
    ]

    /// A tree grown by random splits, ratios and focus moves, so focus history is non-trivial.
    static func layout(_ random: inout TileRandom, maxPanes: Int = 9) -> SplitLayout {
        var layout = SplitLayout()
        let splits = random.int(0...(maxPanes - 1))
        for _ in 0..<splits {
            let target = random.pick(layout.paneIDs)
            layout.split(
                target, axis: random.chance(0.5) ? .horizontal : .vertical,
                placingNewFirst: random.chance(0.3))
        }
        for id in splitIDs(layout.root) where random.chance(0.6) {
            layout.setRatio(0.05 + random.unit() * 0.9, of: id)
        }
        for _ in 0..<random.int(0...6) {
            layout.focus(random.pick(layout.paneIDs))
        }
        return layout
    }

    static func minimums(for layout: SplitLayout, _ random: inout TileRandom) -> [PaneID: PaneMinimum] {
        var result: [PaneID: PaneMinimum] = [:]
        for id in layout.paneIDs { result[id] = random.pick(minimums) }
        return result
    }

    static func splitIDs(_ node: SplitNode) -> [SplitID] {
        guard case .split(let id, _, _, let first, let second) = node else { return [] }
        return [id] + splitIDs(first) + splitIDs(second)
    }

    static func ratios(_ node: SplitNode) -> [Double] {
        guard case .split(_, _, let ratio, let first, let second) = node else { return [] }
        return [ratio] + ratios(first) + ratios(second)
    }

    static func overlap(_ a: SplitRect, _ b: SplitRect) -> Double {
        let width = min(a.maxX, b.maxX) - max(a.x, b.x)
        let height = min(a.maxY, b.maxY) - max(a.y, b.y)
        return width > 0 && height > 0 ? width * height : 0
    }
}
