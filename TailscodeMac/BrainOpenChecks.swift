import AppKit
import Foundation
import TailscodeCore

/// The guard on what opening and closing a Megatron costs the main thread: no turn of the run loop
/// longer than a ceiling, measured in the thread's own CPU time through the real pane
/// (`BrainPaneBench`) in a child process of this binary, where AppKit runs on the real main
/// thread and the display ticks the move. The ceiling is generous, a little under what the open
/// cost before it was spread over frames, so it fails on a regression and not on a noisy host.
/// The check says why it did not run, and does not fail, when the host is too loaded for CPU time
/// to mean anything or when the display did not tick the move.
@MainActor
enum BrainOpenChecks {
    nonisolated static let spec = "megatron-check"

    /// The longest a single run loop turn of an open or a close may take, in milliseconds: the
    /// median of the longest turns of several opens, which a noisy second does not move, and the
    /// worst of them, which only a real stall reaches.
    static let ceiling = 22.0
    static let worstCeiling = 45.0
    /// Load average per core above which the host is too busy for the figures to be read.
    static let busyLoadPerCore = 4.0

    private static func hostIsBusy() -> String? {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        guard load[0] > busyLoadPerCore * cores else { return nil }
        return String(format: "the host is too busy (load average %.0f on %.0f cores)", load[0], cores)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// The child's side: it prints the verdict and exits.
    static func runAsChild() -> Never {
        if CommandLine.arguments.contains("--force") == false, let busy = hostIsBusy() {
            print("BRAINOPEN_SKIPPED \(busy)")
            exit(0)
        }
        var notes: [String] = []
        var failures: [String] = []
        for steps in [29, 174] {
            let result = BrainPaneBench.measure(turns: 30, steps: steps, rounds: 6)
            guard result.landed else {
                print("BRAINOPEN_SKIPPED the display did not tick the move at \(steps) steps")
                exit(0)
            }
            let open = median(result.longestOpen)
            let close = median(result.longestClose)
            let worst = max(result.longestOpen.max() ?? 0, result.longestClose.max() ?? 0)
            notes.append(String(format: "%d steps: open %.1f ms, close %.1f ms, worst %.1f", steps, open, close, worst))
            if open > ceiling { failures.append("an open took one turn of \(Int(open)) ms at \(steps) steps") }
            if close > ceiling { failures.append("a close took one turn of \(Int(close)) ms at \(steps) steps") }
            if worst > worstCeiling { failures.append("a turn took \(Int(worst)) ms at \(steps) steps") }
        }
        print("BRAINOPEN_NOTES \(notes.joined(separator: " · "))")
        print(failures.isEmpty ? "BRAINOPEN_OK" : "BRAINOPEN_FAILED \(failures.joined(separator: " · "))")
        exit(failures.isEmpty ? 0 : 1)
    }

    /// The selftest's side, begun at once so the child runs beside the rest of the selftest.
    final class Child {
        private let process = Process()
        private let pipe = Pipe()
        private var startFailure: String?

        init() {
            guard let executable = Bundle.main.executablePath else {
                startFailure = "no executable path"
                return
            }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--bench", BrainOpenChecks.spec]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                startFailure = "could not start the check: \(error)"
            }
        }

        /// What the check found: failures, the sentence to report when it ran or why it did not.
        func verdict(timeout: TimeInterval = 120) -> (failures: [String], note: String) {
            if let startFailure { return ([startFailure], "") }
            let deadline = Date().addingTimeInterval(timeout)
            let pid = process.processIdentifier
            var exited = false
            while !exited, Date() < deadline {
                var status: Int32 = 0
                let reaped = waitpid(pid, &status, WNOHANG)
                exited = reaped == pid || reaped == -1
                if !exited { usleep(50_000) }
            }
            if !exited {
                kill(pid, SIGKILL)
                return (["the check did not finish in \(Int(timeout)) s"], "")
            }
            let lines = String(
                decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            ).split(separator: "\n")
            if let skipped = lines.last(where: { $0.hasPrefix("BRAINOPEN_SKIPPED ") }) {
                return ([], "skipped, " + skipped.dropFirst("BRAINOPEN_SKIPPED ".count))
            }
            let notes = lines.last { $0.hasPrefix("BRAINOPEN_NOTES ") }
                .map { String($0.dropFirst("BRAINOPEN_NOTES ".count)) } ?? ""
            guard
                let verdict = lines.last(where: { $0 == "BRAINOPEN_OK" || $0.hasPrefix("BRAINOPEN_FAILED") })
            else { return (["the check printed no verdict"], notes) }
            return (
                verdict == "BRAINOPEN_OK" ? [] : [String(verdict.dropFirst("BRAINOPEN_FAILED ".count))],
                notes
            )
        }
    }
}
