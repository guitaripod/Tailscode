import Foundation

/// When the loop has been pinned long enough that the next freeze should explain itself: busy at
/// least ``threshold`` for ``window`` seconds running, and again no more often than ``rearm``
/// while it stays that way. Fed once a second with the meter's one-second reading; the answer is
/// how long the run has lasted when a capture is due.
public struct SustainedBusy: Sendable, Equatable {
    public static let threshold = 0.9
    public static let window: TimeInterval = 5
    public static let rearm: TimeInterval = 60

    private var run: TimeInterval = 0
    private var previous: TimeInterval?
    private var lastFired: TimeInterval?

    public init() {}

    /// Whether a run is under way, so the thread-time baseline is worth keeping.
    public var isRising: Bool { run > 0 }

    /// A reading that covers the time since the last one, so a tick that arrives late counts
    /// for the whole of the wait rather than for one second of it. A gap longer than the window
    /// is clipped, because one stall is the stall record's to describe.
    public mutating func record(busy: Double, now: TimeInterval) -> TimeInterval? {
        let covered = previous.map { min(Self.window, max(0, now - $0)) } ?? 1
        previous = now
        guard busy >= Self.threshold else {
            run = 0
            return nil
        }
        run += covered
        guard run >= Self.window - 0.05 else { return nil }
        if let lastFired, now - lastFired < Self.rearm { return nil }
        lastFired = now
        return run
    }
}

/// One thread's cumulative CPU as `/proc/self/task/<tid>/stat` reports it.
public struct ThreadSample: Sendable, Equatable {
    public var id: Int32
    public var name: String
    public var ticks: UInt64

    public init(id: Int32, name: String, ticks: UInt64) {
        self.id = id
        self.name = name
        self.ticks = ticks
    }
}

/// A thread and the share of one core it used over a span.
public struct HotThread: Sendable, Equatable {
    public var id: Int32
    public var name: String
    public var percent: Int

    public init(id: Int32, name: String, percent: Int) {
        self.id = id
        self.name = name
        self.percent = percent
    }

    /// `gmain(4021) 71%`.
    public var phrase: String { "\(name)(\(id)) \(percent)%" }
}

public enum ThreadCPU {
    /// `tid (comm) S ...` with `utime` and `stime` as fields 14 and 15, counted after the name's
    /// closing parenthesis because the name may hold spaces and parentheses.
    public static func parse(stat: String) -> ThreadSample? {
        guard let open = stat.firstIndex(of: "("), let close = stat.lastIndex(of: ")"), open < close,
            let id = Int32(stat[stat.startIndex..<open].trimmingCharacters(in: .whitespaces))
        else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 12, let user = UInt64(fields[11]), let system = UInt64(fields[12]) else {
            return nil
        }
        let name = String(stat[stat.index(after: open)..<close])
        return ThreadSample(id: id, name: name.replacingOccurrences(of: " ", with: "_"), ticks: user + system)
    }

    /// The `count` threads that used the most CPU between `earlier` (thread id to ticks) and
    /// `now`, over `seconds`, busiest first. A thread that did not exist at the baseline is
    /// counted from zero, which can only overstate a thread born inside the span, and a thread
    /// under 1 % is not worth a name.
    public static func hottest(
        since earlier: [Int32: UInt64], now: [ThreadSample], seconds: TimeInterval,
        ticksPerSecond: Double, count: Int = 5
    ) -> [HotThread] {
        guard seconds > 0, ticksPerSecond > 0 else { return [] }
        let ranked = now.compactMap { sample -> HotThread? in
            let before = earlier[sample.id] ?? 0
            guard sample.ticks > before else { return nil }
            let share = Double(sample.ticks - before) / ticksPerSecond / seconds * 100
            let percent = Int(share.rounded())
            return percent >= 1 ? HotThread(id: sample.id, name: sample.name, percent: percent) : nil
        }
        return Array(ranked.sorted { $0.percent > $1.percent }.prefix(count))
    }
}

/// The lines the watchdog writes when the loop is pinned or silent, and the way `--stacks` reads
/// them back. Frames are module-relative so `addr2line -e <module> <offset>` resolves them
/// offline, whatever the load address was.
public enum StackReport {
    public static let marker = "watchdog: "

    /// One frame as `module+0xoffset`.
    public static func frame(module: String, offset: UInt64) -> String {
        "\(module)+0x\(String(offset, radix: 16))"
    }

    public static func parseFrame(_ token: Substring) -> (module: String, offset: UInt64)? {
        guard let plus = token.lastIndex(of: "+"), token[token.index(after: plus)...].hasPrefix("0x"),
            let offset = UInt64(token[token.index(plus, offsetBy: 3)...], radix: 16), plus != token.startIndex
        else { return nil }
        return (String(token[..<plus]), offset)
    }

    /// The first line of a capture: why, what the main thread was waiting in, how big the process
    /// is and which threads used the CPU.
    public static func summary(
        reason: String, mainThread: String, rssKiB: UInt64?, threads: Int?, hot: [HotThread],
        build: String
    ) -> String {
        var parts = ["\(marker)\(reason)", "main \(mainThread)"]
        if let rssKiB { parts.append("rss \(rssKiB / 1024) MB") }
        if let threads { parts.append("\(threads) threads") }
        parts.append(hot.isEmpty ? "hot: none over 1%" : "hot: " + hot.map(\.phrase).joined(separator: ", "))
        parts.append("build \(build)")
        return parts.joined(separator: " · ")
    }

    /// One sampled stack of the main thread, innermost frame first.
    public static func stackLine(index: Int, of total: Int, frames: [String]) -> String {
        "\(marker)stack \(index)/\(total) · main: " + (frames.isEmpty ? "no reply" : frames.joined(separator: " "))
    }

    /// The last `count` captures from a log's text: every summary line with the stack lines that
    /// follow it, oldest first.
    public static func captures(in log: String, last count: Int) -> [[String]] {
        var groups: [[String]] = []
        for line in log.split(separator: "\n") {
            guard let range = line.range(of: marker) else { continue }
            let body = line[range.upperBound...]
            if body.hasPrefix("stack ") {
                guard !groups.isEmpty else { continue }
                groups[groups.count - 1].append(String(line))
            } else if body.hasPrefix("sustained busy") || body.hasPrefix("loop silent") || body.hasPrefix("crash") {
                groups.append([String(line)])
            }
        }
        return Array(groups.suffix(count))
    }
}

/// How much a background poller stretches its period as the governor sheds. Work nobody is
/// waiting on is the first thing to give back when the loop is the bottleneck.
public enum BackgroundCadence {
    public static func factor(for level: ShedLevel) -> Int {
        switch level {
        case .calm, .busy, .loaded: return 1
        case .strained: return 3
        case .critical: return 6
        }
    }

    public static func period(_ base: TimeInterval, level: ShedLevel) -> TimeInterval {
        base * Double(factor(for: level))
    }
}
