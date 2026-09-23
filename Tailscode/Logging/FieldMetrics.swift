import Foundation
import MetricKit

/// What the phone itself measured about this app in the field, written into the log file.
///
/// A lab benchmark says how fast a path can be; only the device says how it went for the person
/// holding it. MetricKit hands over a day's launches, hangs, scroll hitches, bandwidth and memory
/// once a day, and a hang's or a crash's stack as soon as the system has it, so a stall that only
/// happens on a train is still a stack in `Library/Logs` the next time anyone looks.
final class FieldMetrics: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = FieldMetrics()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { AppLogger.performance.info(Self.summary(payload)) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let hangs = payload.hangDiagnostics?.count ?? 0
            let crashes = payload.crashDiagnostics?.count ?? 0
            let writes = payload.diskWriteExceptionDiagnostics?.count ?? 0
            let file = Self.keep(payload.jsonRepresentation(), endingAt: payload.timeStampEnd)
            AppLogger.performance.info(
                "diagnostics hangs=\(hangs) crashes=\(crashes) diskWrites=\(writes) file=\(file ?? "unwritten")")
        }
    }

    private static func summary(_ payload: MXMetricPayload) -> String {
        var parts = ["metrics version=\(payload.latestApplicationVersion)"]
        if let launch = payload.applicationLaunchMetrics {
            parts.append("firstDraw=\(percentiles(launch.histogrammedTimeToFirstDraw))")
            parts.append("resume=\(percentiles(launch.histogrammedApplicationResumeTime))")
        }
        if let hangs = payload.applicationResponsivenessMetrics {
            parts.append("hangs=\(percentiles(hangs.histogrammedApplicationHangTime))")
        }
        if let animation = payload.animationMetrics {
            parts.append("scrollHitch=\(animation.scrollHitchTimeRatio.value)")
        }
        if let network = payload.networkTransferMetrics {
            let cellular = network.cumulativeCellularDownload.converted(to: .megabytes).value
            let wifi = network.cumulativeWifiDownload.converted(to: .megabytes).value
            parts.append(String(format: "downMB cellular=%.1f wifi=%.1f", cellular, wifi))
        }
        if let memory = payload.memoryMetrics {
            parts.append(
                String(format: "peakMB=%.0f", memory.peakMemoryUsage.converted(to: .megabytes).value))
        }
        return parts.joined(separator: " ")
    }

    /// The middle and the slow tail of a day's histogram, in milliseconds, read off the buckets.
    private static func percentiles(_ histogram: MXHistogram<UnitDuration>) -> String {
        var buckets: [(end: Double, count: Int)] = []
        let enumerator = histogram.bucketEnumerator
        while let bucket = enumerator.nextObject() as? MXHistogramBucket<UnitDuration> {
            buckets.append((bucket.bucketEnd.converted(to: .milliseconds).value, bucket.bucketCount))
        }
        let total = buckets.reduce(0) { $0 + $1.count }
        guard total > 0 else { return "none" }
        func at(_ share: Double) -> Int {
            var seen = 0
            for bucket in buckets {
                seen += bucket.count
                if Double(seen) >= share * Double(total) { return Int(bucket.end) }
            }
            return Int(buckets.last?.end ?? 0)
        }
        return "p50<\(at(0.5))ms p90<\(at(0.9))ms n=\(total)"
    }

    private static func keep(_ json: Data, endingAt end: Date) -> String? {
        guard
            let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Logs/diagnostics", isDirectory: true)
        else { return nil }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let name = "diagnostic-\(Int(end.timeIntervalSince1970)).json"
        guard (try? json.write(to: logs.appendingPathComponent(name), options: .atomic)) != nil
        else { return nil }
        return name
    }
}
