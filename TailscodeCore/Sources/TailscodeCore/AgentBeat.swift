import Foundation

/// The last minute of an agent's pulse: how many times this device saw it move, in equal slices of
/// time. A strip of these is the quickest way to tell a turn that is working from one that stopped
/// — a flat line is a stall you can see — and it is only ever made from what this device watched.
public enum AgentBeat {
    public static let buckets = 24
    public static let span: TimeInterval = 60
    /// The tallest a slice stands, so a client scales a bar by `height / ceiling`.
    public static let ceiling = 4

    /// One height per slice, oldest first, each `0...ceiling`.
    public static func read(
        stamps: [Date], now: Date, buckets: Int = AgentBeat.buckets, span: TimeInterval = AgentBeat.span
    ) -> [Int] {
        var counts = [Int](repeating: 0, count: buckets)
        let width = span / Double(buckets)
        for stamp in stamps {
            let age = now.timeIntervalSince(stamp)
            guard age >= 0, age < span else { continue }
            let index = buckets - 1 - Int(age / width)
            if counts.indices.contains(index) { counts[index] += 1 }
        }
        return counts.map { min($0, ceiling) }
    }

    /// The stamps that still count, so a watcher that keeps them does not keep every one it ever
    /// took.
    public static func pruned(_ stamps: [Date], now: Date, span: TimeInterval = AgentBeat.span) -> [Date] {
        stamps.filter { now.timeIntervalSince($0) < span }
    }
}
