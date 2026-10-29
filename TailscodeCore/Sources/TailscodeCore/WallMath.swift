import Foundation

enum WallMath {
    static func clamp(_ x: Double, _ low: Double, _ high: Double) -> Double { min(max(x, low), high) }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    static func smooth(_ t: Double) -> Double {
        let x = clamp(t, 0, 1)
        return x * x * (3 - 2 * x)
    }

    static func easeOut(_ t: Double) -> Double { 1 - pow(1 - clamp(t, 0, 1), 3) }

    static func bump(_ x: Double) -> Double { exp(-(x * x) / 0.0072) }

    /// A slow swell between 0 and 1 with the given period; a steady 0.6 when nothing may move.
    static func breath(_ t: Double, period: Double, animated: Bool) -> Double {
        animated ? 0.5 + 0.5 * sin(2 * .pi * t / period) : 0.6
    }

    /// Two quick beats once a period, the second a little softer; a steady 0.35 when nothing may move.
    static func knock(_ t: Double, period: Double, second: Double, animated: Bool) -> Double {
        guard animated else { return 0.35 }
        let p = t.truncatingRemainder(dividingBy: period)
        return max(bump(p), 0.8 * bump(p - second))
    }
}
