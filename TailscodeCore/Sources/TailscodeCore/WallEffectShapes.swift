import Foundation

/// One drawn piece of an effect, in points of the layout.
public enum WallShape: Sendable, Equatable {
    /// A soft ring: its radius, its width and its brightness.
    case ring(x: Double, y: Double, radius: Double, width: Double, alpha: Double)
    /// A soft glow that falls off from its centre.
    case bloom(x: Double, y: Double, radius: Double, alpha: Double)
    /// A mote of light; `size` is its diameter.
    case dot(x: Double, y: Double, size: Double, alpha: Double)
    /// A band of light that spreads outward from a plate's edge across the ground.
    case ripple(rect: WallRect, corner: Double, grow: Double, width: Double, alpha: Double)
}

/// Where an effect hangs: the rectangle of the tile's own plate, its glyph, the worker's slot when the
/// effect names one, and its heartbeat strip. `width` and `height` are the whole wall's.
public struct WallAnchor: Sendable {
    public var tile: WallRect
    public var glyphX: Double
    public var glyphY: Double
    public var glyphSize: Double
    public var worker: WallRect?
    public var beat: WallRect
    public var width: Double
    public var height: Double

    public init(
        tile: WallRect, glyphX: Double, glyphY: Double, glyphSize: Double, worker: WallRect? = nil,
        beat: WallRect, width: Double, height: Double
    ) {
        self.tile = tile
        self.glyphX = glyphX
        self.glyphY = glyphY
        self.glyphSize = glyphSize
        self.worker = worker
        self.beat = beat
        self.width = width
        self.height = height
    }
}

/// The shapes of every effect at a moment, the same on every client. Radii the design states in
/// glyph units are returned in points, and nothing here allocates beyond the array it returns.
public enum WallEffectShapes {
    public static func shapes(
        for effect: WallEffect, at t: TimeInterval, anchor: WallAnchor, unit: Double
    ) -> [WallShape] {
        guard effect.isStarted(at: t), !effect.isEnded(at: t) else { return [] }
        let frame = Frame(
            effect: effect, p: effect.progress(at: t), a: effect.amplitude, anchor: anchor, unit: unit)
        switch effect.kind {
        case .spark: return frame.spark()
        case .thread: return frame.thread()
        case .dissolve: return frame.dissolve()
        case .exhale: return frame.exhale()
        case .groundRipple: return frame.groundRipple()
        case .knock: return frame.knock()
        case .fracture: return frame.fracture()
        case .pulse: return frame.pulse()
        case .approved: return frame.approved()
        case .drain: return frame.drain()
        case .gather: return frame.gather()
        case .scatter: return frame.scatter()
        case .fade: return frame.fade()
        }
    }

    /// The context share a draining ring shows now: smoothly from where it fell from to where it
    /// fell to. Nil before the effect starts, after it ends, and for any effect that is not a drain.
    public static func drainShare(_ effect: WallEffect, at t: TimeInterval) -> Double? {
        guard effect.kind == .drain, let from = effect.from, let to = effect.to,
            effect.isStarted(at: t), !effect.isEnded(at: t)
        else { return nil }
        let p = effect.progress(at: t)
        if p >= 0.98 { return to }
        return WallMath.lerp(from, to, WallMath.smooth(p))
    }

    /// How sharp the centre of a mote of this effect is, `0...1`.
    public static func core(for kind: WallEffect.Kind) -> Double {
        switch kind {
        case .spark: return 0.25
        case .thread, .dissolve, .gather, .scatter: return 0.35
        case .fracture, .drain: return 0.4
        default: return 0.35
        }
    }

    struct Frame {
        let effect: WallEffect
        let p: Double
        let a: Double
        let anchor: WallAnchor
        let unit: Double

        var size: Double { anchor.glyphSize }
        var x: Double { anchor.glyphX }
        var y: Double { anchor.glyphY }
        var main: WallRect { anchor.tile }
        var corner: Double { max(1.6 * unit, 10) }

        /// A deterministic pseudo-random number in `0..<1` for the `i`-th piece and its `k`-th use, the
        /// same for the same effect on every machine.
        func rnd(_ i: Int, _ k: Int) -> Double {
            let phase = Double(effect.seed % 100_000) / 1000
            let value = sin(Double(i + 1) * 12.9898 + Double(k) * 78.233 + phase * 3.7) * 43758.5453
            return value - value.rounded(.down)
        }

        func spark() -> [WallShape] {
            let beat = anchor.beat
            let from = beat.x + beat.width * (0.58 / 0.62)
            let sx = WallMath.lerp(from, beat.maxX, WallMath.easeOut(p))
            let alpha = sin(.pi * p) * 0.7 * min(a, 1.3)
            return [.dot(x: sx, y: beat.maxY - 2, size: max(10, unit * 1.6), alpha: alpha)]
        }

        func thread() -> [WallShape] {
            guard let slot = anchor.worker else { return [] }
            let toX = slot.x + slot.width * 0.3
            let toY = slot.midY
            let ctlX = (x + toX) / 2 + (toY - y) * 0.25
            let ctlY = (y + toY) / 2 - (toX - x) * 0.25
            let count = Int((16 * min(a, 1.4)).rounded())
            var out: [WallShape] = []
            out.reserveCapacity(count)
            for i in 0..<count {
                let q = WallMath.clamp(p * 1.4 - Double(i) * 0.025, 0, 1)
                if q <= 0 || q >= 1 { continue }
                let px = (1 - q) * (1 - q) * x + 2 * (1 - q) * q * ctlX + q * q * toX
                let py = (1 - q) * (1 - q) * y + 2 * (1 - q) * q * ctlY + q * q * toY
                let size = max(5, unit * 0.9) * (1 - Double(i) / Double(count) * 0.5)
                out.append(.dot(x: px, y: py, size: size, alpha: sin(.pi * q) * 0.5 * min(a, 1.2)))
            }
            return out
        }

        func dissolve() -> [WallShape] {
            guard let slot = anchor.worker else { return [] }
            let count = Int((20 * min(a, 1.4)).rounded())
            var out: [WallShape] = []
            out.reserveCapacity(count)
            for j in 0..<count {
                let fromX = slot.x + rnd(j, 1) * slot.width
                let fromY = slot.y + rnd(j, 2) * slot.height
                let q = WallMath.easeOut(WallMath.clamp(p - rnd(j, 3) * 0.2, 0, 1))
                let px = WallMath.lerp(fromX, x, q * 0.85) + sin(q * 6 + Double(j)) * unit * 0.6
                let py = WallMath.lerp(fromY, y, q * 0.85) + cos(q * 5 + Double(j)) * unit * 0.6
                out.append(.dot(x: px, y: py, size: max(4, unit * 0.75), alpha: (1 - q) * 0.45 * min(a, 1.2)))
            }
            return out
        }

        func exhale() -> [WallShape] {
            let reach = 0.5 * hypot(main.width, main.height) / max(1, size)
            let radius = WallMath.lerp(0.3, reach * 0.9, WallMath.easeOut(p)) * size
            return [
                .ring(
                    x: x, y: y, radius: radius, width: (0.06 + 0.1 * p) * size,
                    alpha: 0.5 * pow(1 - p, 1.6) * min(a, 1.3)),
                .bloom(
                    x: x, y: y, radius: 0.55 * size,
                    alpha: 0.35 * sin(.pi * WallMath.clamp(p * 1.6, 0, 1)) * min(a, 1.3)),
            ]
        }

        func groundRipple() -> [WallShape] {
            let strength = effect.ink == .failed ? 0.1 : 0.12
            return [
                .ripple(
                    rect: main, corner: corner, grow: WallMath.easeOut(p) * unit * 16,
                    width: unit * (1.2 + 3 * p), alpha: strength * pow(1 - p, 2) * min(a, 1.4))
            ]
        }

        func knock() -> [WallShape] {
            [
                .ripple(
                    rect: main, corner: corner, grow: WallMath.easeOut(p) * unit * 9,
                    width: unit * (0.8 + 1.6 * p), alpha: 0.2 * pow(1 - p, 2) * min(a, 1.4))
            ]
        }

        func fracture() -> [WallShape] {
            let count = Int((10 * min(a, 1.4)).rounded())
            var out: [WallShape] = []
            out.reserveCapacity(count + 1)
            out.append(.bloom(x: x, y: y, radius: 0.9 * size, alpha: 0.45 * pow(1 - p, 2) * min(a, 1.3)))
            for s in 0..<count {
                let angle = rnd(s, 4) * 2 * .pi
                let distance = WallMath.easeOut(p) * size * (0.6 + rnd(s, 5) * 0.8)
                out.append(
                    .dot(
                        x: x + cos(angle) * distance, y: y + sin(angle) * distance,
                        size: max(4, unit * 0.6), alpha: (1 - p) * 0.5))
            }
            return out
        }

        func pulse() -> [WallShape] {
            [
                .ring(
                    x: x, y: y, radius: WallMath.lerp(0.35, 1.1, WallMath.easeOut(p)) * size,
                    width: 0.05 * size, alpha: 0.4 * pow(1 - p, 2) * min(a, 1.3))
            ]
        }

        func approved() -> [WallShape] {
            [
                .ring(
                    x: x, y: y, radius: WallMath.lerp(1.6, 0.3, WallMath.easeOut(p)) * size,
                    width: 0.08 * size, alpha: 0.45 * pow(1 - p, 1.5)),
                .bloom(x: x, y: y, radius: 0.6 * size, alpha: 0.3 * sin(.pi * p)),
            ]
        }

        func drain() -> [WallShape] {
            guard a > 0 else { return [] }
            let count = Int((12 * min(a, 1.4)).rounded())
            var out: [WallShape] = []
            out.reserveCapacity(count)
            for k in 0..<count {
                let angle = rnd(k, 6) * 2 * .pi + p * 5
                let fall = WallMath.easeOut(WallMath.clamp(p * 1.2 - rnd(k, 7) * 0.3, 0, 1))
                let radius = size * 0.455 * (1 - fall * 0.9)
                out.append(
                    .dot(
                        x: x + cos(angle) * radius, y: y + sin(angle) * radius, size: max(4, unit * 0.55),
                        alpha: 0.5 * sin(.pi * WallMath.clamp(p, 0, 1))))
            }
            return out
        }

        func gather() -> [WallShape] {
            let count = Int((36 * min(a, 1.4)).rounded())
            var out: [WallShape] = []
            out.reserveCapacity(count)
            for m in 0..<count {
                let around = rnd(m, 8)
                let side = Int(around * 4)
                let f = (around * 4).truncatingRemainder(dividingBy: 1)
                let target = perimeter(side: side, f: f)
                let startX = rnd(m, 9) * anchor.width
                let startY = rnd(m, 10) * anchor.height
                let q = WallMath.easeOut(WallMath.clamp(p * 1.25 - rnd(m, 11) * 0.25, 0, 1))
                out.append(
                    .dot(
                        x: WallMath.lerp(startX, target.x, q), y: WallMath.lerp(startY, target.y, q),
                        size: max(5, unit * 0.8), alpha: sin(.pi * q) * 0.55 * min(a, 1.2)))
            }
            return out
        }

        private func perimeter(side: Int, f: Double) -> (x: Double, y: Double) {
            switch side {
            case 0: return (main.x + f * main.width, main.y)
            case 1: return (main.maxX, main.y + f * main.height)
            case 2: return (main.x + (1 - f) * main.width, main.maxY)
            default: return (main.x, main.y + (1 - f) * main.height)
            }
        }

        func scatter() -> [WallShape] {
            let count = Int((28 * min(a, 1.4)).rounded())
            var out: [WallShape] = []
            out.reserveCapacity(count)
            let q = WallMath.easeOut(p)
            for z in 0..<count {
                let fromX = main.x + rnd(z, 12) * main.width
                let fromY = main.y + rnd(z, 13) * main.height
                out.append(
                    .dot(
                        x: fromX + (rnd(z, 14) - 0.5) * unit * 10 * q,
                        y: fromY - unit * 6 * q * rnd(z, 15), size: max(4, unit * 0.7),
                        alpha: (1 - q) * 0.45))
            }
            return out
        }

        func fade() -> [WallShape] {
            [.bloom(x: x, y: y, radius: 0.6 * size, alpha: 0.25 * sin(.pi * p))]
        }
    }
}
