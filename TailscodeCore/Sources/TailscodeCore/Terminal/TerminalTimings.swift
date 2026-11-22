import Foundation

/// How long a terminal kept a person waiting: from asking for the shell to its first byte, and
/// from a key leaving this device to the shell's next byte coming back, which is what a person
/// feels as the echo. Kept as the latest few hundred keys, read as a line for the log.
public struct TerminalTimings: Sendable, Equatable {
    public static let kept = 256

    public private(set) var openMilliseconds: Int?
    public private(set) var echoMilliseconds: [Int] = []

    private var askedAt: Date?
    private var keyAt: Date?

    public init() {}

    mutating func asked(at moment: Date) {
        askedAt = moment
        openMilliseconds = nil
    }

    mutating func keyLeft(at moment: Date) {
        if keyAt == nil { keyAt = moment }
    }

    mutating func bytesArrived(at moment: Date) {
        if let askedAt, openMilliseconds == nil {
            openMilliseconds = Self.milliseconds(from: askedAt, to: moment)
        }
        guard let keyAt else { return }
        self.keyAt = nil
        echoMilliseconds.append(Self.milliseconds(from: keyAt, to: moment))
        if echoMilliseconds.count > Self.kept { echoMilliseconds.removeFirst(echoMilliseconds.count - Self.kept) }
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        max(Int((end.timeIntervalSince(start) * 1000).rounded()), 0)
    }

    /// The echo at a fraction of the keys kept, nil before any key came back.
    public func echo(at fraction: Double) -> Int? {
        guard !echoMilliseconds.isEmpty else { return nil }
        let sorted = echoMilliseconds.sorted()
        let index = min(Int((Double(sorted.count - 1) * fraction).rounded()), sorted.count - 1)
        return sorted[index]
    }

    /// `open=… echo n=… p50=… p90=… max=…`, every figure in milliseconds.
    public var line: String {
        let open = openMilliseconds.map(String.init) ?? "-"
        guard let p50 = echo(at: 0.5), let p90 = echo(at: 0.9), let worst = echoMilliseconds.max() else {
            return "open=\(open) echo n=0"
        }
        return "open=\(open) echo n=\(echoMilliseconds.count) p50=\(p50) p90=\(p90) max=\(worst)"
    }
}
