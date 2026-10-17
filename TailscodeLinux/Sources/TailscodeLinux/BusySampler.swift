import CGtkShim
import Foundation
import Glibc
import TailscodeCore

/// What the app writes down when its own main thread is pinned, so the next freeze explains itself.
///
/// The ring and the log used to say "busy 1.00, stall 120 ms, level 4" and nothing about what the
/// thread was doing or which threads burned the CPU. When the loop has been busy for five seconds
/// running, or has not answered the watchdog for a second, the watchdog thread asks the main
/// thread for its own backtrace (a real-time signal whose handler lives in the shim and writes
/// return addresses into a preallocated buffer), reads every thread's CPU from `/proc`, and writes
/// them to the app log as module-relative offsets that `addr2line` resolves offline.
/// `tailscode --stacks` prints them back, resolved.
///
/// Everything here runs on the watchdog thread, which touches no widget; the only main-thread
/// work is the handler. Thread CPU is read once a second only while a busy run is under way, so a
/// calm app pays nothing.
final class BusySampler: @unchecked Sendable {
    private struct Snapshot {
        let at: TimeInterval
        let ticks: [Int32: UInt64]
    }

    private static let keep = 7
    private static let samples = 3
    private static let answerTimeoutMs: Int32 = 250
    private static let frameLimit = 40

    private var snapshots: [Snapshot] = []
    private let ticksPerSecond = Double(sysconf(Int32(_SC_CLK_TCK)))
    private(set) var installed = false

    /// Main thread, before the watchdog starts.
    func install() {
        installed = tailscode_stack_sampler_install() != 0
        if !installed { AppLog.write(.lifecycle, "watchdog: stack sampling unavailable") }
    }

    /// Watchdog thread, once a second while a busy run is under way.
    func remember(now: TimeInterval) {
        snapshots.append(Snapshot(at: now, ticks: Self.threadTicks().reduce(into: [:]) { $0[$1.id] = $1.ticks }))
        if snapshots.count > Self.keep { snapshots.removeFirst(snapshots.count - Self.keep) }
    }

    /// Watchdog thread, when the run ended.
    func forget() {
        if !snapshots.isEmpty { snapshots.removeAll() }
    }

    /// Watchdog thread. The lines to write for one capture: a summary, then each sample of the
    /// main thread's stack. Sampling stops at the first sample the thread did not answer, which
    /// is itself the finding (it is waiting in the kernel, and the summary says where).
    func capture(reason: String, now: TimeInterval, main: MainThreadState?) -> [String] {
        let counts = ProcessCounts.read()
        let current = Self.threadTicks()
        let earlier = snapshots.first(where: { now - $0.at >= 3 }) ?? snapshots.first
        let hot = earlier.map {
            ThreadCPU.hottest(
                since: $0.ticks, now: current, seconds: now - $0.at, ticksPerSecond: ticksPerSecond)
        } ?? []
        var lines = [
            StackReport.summary(
                reason: reason, mainThread: main?.line ?? "?", rssKiB: counts.rssKiB,
                threads: counts.threads, hot: hot, build: TailscodeVersion.current)
        ]
        guard installed else { return lines }
        for index in 1...Self.samples {
            let frames = sampleMain()
            lines.append(StackReport.stackLine(index: index, of: Self.samples, frames: frames))
            if frames.isEmpty { break }
            if index < Self.samples { usleep(30_000) }
        }
        return lines
    }

    private func sampleMain() -> [String] {
        var addresses = [UInt](repeating: 0, count: Int(TAILSCODE_STACK_DEPTH))
        let count = addresses.withUnsafeMutableBufferPointer {
            tailscode_stack_sample_main(Self.answerTimeoutMs, $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return [] }
        var frames: [String] = []
        for index in 0..<min(Int(count), Self.frameLimit) {
            let address = index == 0 ? addresses[index] : addresses[index] - 1
            var module = [CChar](repeating: 0, count: 96)
            var offset: UInt64 = 0
            _ = tailscode_stack_resolve(address, &module, module.count, &offset)
            frames.append(StackReport.frame(module: String(cString: module), offset: offset))
        }
        return frames
    }

    private static func threadTicks() -> [ThreadSample] {
        guard let directory = opendir("/proc/self/task") else { return [] }
        defer { closedir(directory) }
        var samples: [ThreadSample] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            guard let id = Int32(name), let stat = ProcFile.read("/proc/self/task/\(id)/stat"),
                let sample = ThreadCPU.parse(stat: stat)
            else { continue }
            samples.append(sample)
        }
        return samples
    }
}
