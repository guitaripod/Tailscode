import AppKit
import CodingAgentKit
import TailscodeCore

/// The compact chat's logic and its views, checked headlessly from `--selftest`: how every row kind
/// is spaced, when a rail arrives and what it says at every stage of its fetches, where its plate
/// goes, how pictures wrap into a strip and when the plate opens and closes. The looks are checked
/// with `--open` and `--shot`; these are the claims a screenshot cannot make.
@MainActor
enum ChatChecks {
    nonisolated static let spec = "chat-check"

    /// The child's side: both halves of the checks under a running application, where AppKit lays
    /// views out on the real main thread and a suspension resumes on it.
    static func runAsChild() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            var failures: [String] = []
            var notes: [String] = []
            do {
                notes.append("\(try runLayout()) layout")
            } catch {
                failures.append("\(error)")
            }
            do {
                notes.append("\(try await runFetches()) fetch")
            } catch {
                failures.append("\(error)")
            }
            do {
                notes.append("\(try BrainChecks.run()) neural trace")
            } catch {
                failures.append("\(error)")
            }
            do {
                notes.append("\(try await BrainChecks.runPoster()) poster")
            } catch {
                failures.append("\(error)")
            }
            do {
                notes.append("\(try BandChecks.run()) status band")
            } catch {
                failures.append("\(error)")
            }
            notes.append(BandChecks.costs())
            print("CHAT_NOTES \(notes.joined(separator: " + "))")
            print(failures.isEmpty ? "CHAT_OK" : "CHAT_FAILED \(failures.joined(separator: " · "))")
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    /// The selftest's side: begun at once so the child runs beside the rest of the selftest, and
    /// read with a blocking wait for the reason `TileChecks.Child` gives — under `--selftest` a
    /// suspension can resume the main queue on another thread, and AppKit refuses a layout engine
    /// touched from two threads.
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
            process.arguments = ["--bench", ChatChecks.spec]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                startFailure = "could not start the check: \(error)"
            }
        }

        func verdict(timeout: TimeInterval = 60) -> (failures: [String], notes: String) {
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
            let notes = lines.last { $0.hasPrefix("CHAT_NOTES ") }
                .map { String($0.dropFirst("CHAT_NOTES ".count)) } ?? ""
            guard
                let verdict = lines.last(where: { $0 == "CHAT_OK" || $0.hasPrefix("CHAT_FAILED") })
            else { return (["the check printed no verdict"], notes) }
            return (
                verdict == "CHAT_OK" ? [] : [String(verdict.dropFirst("CHAT_FAILED ".count))],
                notes
            )
        }
    }

    /// The claims that need a window and a layout pass.
    static func runLayout() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("compact chat: \(label)") }
            checks += 1
        }
        try spacing(expect)
        try settling(expect)
        try placement(expect)
        try strips(expect)
        try galleries(expect)
        try timing(expect)
        try column(expect)
        try quietLines(expect)
        try promptFocus(expect)
        try replacedRows(expect)
        try chrome(expect)
        try railViews(expect)
        try carrying(expect)
        return checks
    }

    /// The claims about what a rail learns and when: stubbed pages, no network, no layout.
    static func runFetches() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("compact chat: \(label)") }
            checks += 1
        }
        try await fetches(expect)
        return checks
    }

    static var windows: [NSWindow] = []
}
