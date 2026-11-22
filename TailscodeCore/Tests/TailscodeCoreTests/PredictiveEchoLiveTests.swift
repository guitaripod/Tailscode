import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// Against a real claude-bridge behind a slow link: `TERMINAL_LIVE_URL=http://127.0.0.1:4199`
/// `TERMINAL_LIVE_PASSWORD=…`, with a proxy in front of the bridge that holds every piece for a
/// while each way.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMINAL_LIVE_URL"] != nil))
struct PredictiveEchoLiveTests {
    private static let colors = TerminalColors(
        foreground: 0xdddddd, background: 0x111111, cursor: 0xffffff, ansi: Array(repeating: 0x808080, count: 16),
        selectionForeground: 0xdddddd, selectionBackground: 0x333366, isDark: true)

    private func screenText(_ session: TerminalSession) -> String {
        guard let frame = session.frame(force: true) else { return "" }
        return (0..<frame.rows).map { frame.text(row: $0) }.joined(separator: "\n")
    }

    private func wait(_ seconds: Double = 10, until done: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return done()
    }

    @Test func typedLettersShowBeforeTheirEchoAndASecretNeverDoes() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = try #require(URL(string: environment["TERMINAL_LIVE_URL"] ?? ""))
        let credentials = environment["TERMINAL_LIVE_PASSWORD"].map { BasicCredentials(username: "claude", password: $0) }
        let backend = ClaudeCodeBackend(config: ServerConfig(baseURL: url, credentials: credentials))
        let session = TerminalSession(
            backend: backend, target: .init(server: "arch", directory: "/tmp"), desk: "predict-live (test)",
            colors: Self.colors, cols: 80, rows: 12)
        session.start()
        defer { session.end() }
        #expect(await wait { session.reading.phase == .live })
        #expect(await wait { self.screenText(session).contains("$") })

        session.type("e")
        let firstShownEarly = screenText(session).contains("$ e")
        #expect(await wait { self.screenText(session).contains("$ e") })
        let start = Date()
        for letter in "cho predicted" { session.type(String(letter)) }
        let early = screenText(session)
        let elapsed = Date().timeIntervalSince(start)
        print("PREDICT first=\(firstShownEarly) early-in-\(Int(elapsed * 1000))ms=\(early.contains("echo predicted"))")
        #expect(!firstShownEarly)
        #expect(early.contains("$ echo predicted"))
        session.press(TerminalKeyPress(key: .enter))
        #expect(await wait { self.screenText(session).contains("\npredicted") })

        for letter in "read -s x" { session.type(String(letter)) }
        session.press(TerminalKeyPress(key: .enter))
        try await Task.sleep(for: .seconds(1))
        var leaked = false
        for letter in "hunter" {
            session.type(String(letter))
            if screenText(session).contains("hunt") { leaked = true }
            try await Task.sleep(for: .milliseconds(40))
        }
        for _ in 0..<60 {
            if screenText(session).contains("hunt") { leaked = true }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!leaked)
        session.press(TerminalKeyPress(key: .enter))
        for letter in "echo after" { session.type(String(letter)) }
        session.press(TerminalKeyPress(key: .enter))
        #expect(await wait { self.screenText(session).contains("\nafter") })
        print("PREDICT timings \(session.timings.line)")
    }
}
