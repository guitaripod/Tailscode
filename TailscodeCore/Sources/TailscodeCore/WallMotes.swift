import Foundation

/// The drifting points behind the wall, allocated once. Their speed follows the wall's mood: almost
/// still when calm, a gentle current when busy, drawn toward whatever needs a person when something
/// does, slow and warm in an alarm. A step moves numbers in place; positions are fractions of the
/// screen, `0...1` across and down, and each mote keeps four past positions for Currents' trails.
public struct WallMotes: Sendable {
    public static let trailLength = 4
    public static let fewest = 18
    public static let most = 96

    public let count: Int
    public private(set) var x: [Double]
    public private(set) var y: [Double]
    public private(set) var size: [Double]
    public private(set) var phase: [Double]
    /// `trailX[i * trailLength + k]` is where mote `i` was `k + 1` steps ago.
    public private(set) var trailX: [Double]
    public private(set) var trailY: [Double]
    private var heading: [Double]
    private var seed: UInt64

    /// How many motes a screen of this area carries.
    public static func count(width: Double, height: Double) -> Int {
        let wanted = (max(0, width) * max(0, height) / 11_000).rounded()
        return Int(min(Double(most), max(Double(fewest), wanted)))
    }

    public init(width: Double, height: Double, seed: UInt64) {
        let count = Self.count(width: width, height: height)
        self.count = count
        self.seed = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed &* 0x9E37_79B9_7F4A_7C15 | 1
        x = [Double](repeating: 0, count: count)
        y = [Double](repeating: 0, count: count)
        size = [Double](repeating: 0, count: count)
        phase = [Double](repeating: 0, count: count)
        heading = [Double](repeating: 0, count: count)
        trailX = [Double](repeating: 0, count: count * Self.trailLength)
        trailY = [Double](repeating: 0, count: count * Self.trailLength)
        for index in 0..<count { respawn(index, anywhere: true) }
    }

    private mutating func next() -> Double {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return Double(seed % 10_000) / 10_000
    }

    private mutating func respawn(_ index: Int, anywhere: Bool) {
        x[index] = anywhere ? next() : (next() < 0.5 ? -0.01 : 1.01)
        y[index] = next()
        heading[index] = next() * 2 * .pi
        size[index] = 0.18 + next() * 0.32
        phase[index] = next() * 2 * .pi
        resetTrail(index)
    }

    private mutating func resetTrail(_ index: Int) {
        let base = index * Self.trailLength
        for k in 0..<Self.trailLength {
            trailX[base + k] = x[index]
            trailY[base + k] = y[index]
        }
    }

    public static func speed(_ mood: WallMood) -> Double {
        switch mood {
        case .calm: return 0.003
        case .busy: return 0.022
        case .attention: return 0.03
        case .alarm: return 0.009
        }
    }

    /// Moves every mote by `dt` seconds. `target` is where an ask or an alarm is, in the same
    /// fractions; `slow` scales the pace (0 holds the field still); `aspect` is width over height, so
    /// a mote travels the same distance across as down.
    public mutating func step(
        dt: Double, mood: WallMood, target: (x: Double, y: Double)?, slow: Double, aspect: Double
    ) {
        let shape = max(0.05, aspect)
        let pace = Self.speed(mood) * slow * dt
        let drawn = target != nil && (mood == .attention || mood == .alarm)
        for index in 0..<count {
            var dx = cos(heading[index])
            var dy = sin(heading[index])
            if mood == .busy {
                dx += 1.4
                dy -= 0.5
            }
            if drawn, let target {
                let toX = (target.x - x[index]) * shape
                let toY = target.y - y[index]
                let distance = max(0.001, (toX * toX + toY * toY).squareRoot())
                if distance < 0.035 {
                    respawn(index, anywhere: false)
                    continue
                }
                dx = dx * 0.35 + toX / distance
                dy = dy * 0.35 + toY / distance
            }
            pushTrail(index)
            x[index] += dx * pace / shape
            y[index] += dy * pace
            heading[index] += (next() - 0.5) * 0.4 * dt
            wrap(index)
        }
    }

    private mutating func pushTrail(_ index: Int) {
        let base = index * Self.trailLength
        for k in stride(from: Self.trailLength - 1, to: 0, by: -1) {
            trailX[base + k] = trailX[base + k - 1]
            trailY[base + k] = trailY[base + k - 1]
        }
        trailX[base] = x[index]
        trailY[base] = y[index]
    }

    private mutating func wrap(_ index: Int) {
        var wrapped = false
        if x[index] < -0.02 {
            x[index] = 1.02
            wrapped = true
        } else if x[index] > 1.02 {
            x[index] = -0.02
            wrapped = true
        }
        if y[index] < -0.02 {
            y[index] = 1.02
            wrapped = true
        } else if y[index] > 1.02 {
            y[index] = -0.02
            wrapped = true
        }
        if wrapped { resetTrail(index) }
    }

    /// The sum of every position, for a test or a check that the field moved.
    public var positionSum: Double {
        var total = 0.0
        for index in 0..<count { total += x[index] + y[index] }
        return total
    }
}
