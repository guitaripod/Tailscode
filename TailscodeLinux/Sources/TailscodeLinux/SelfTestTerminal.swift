import AgentTestSupport
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// A shell a server holds is drawn here as it is typed into: the keys reach the server in
    /// order, the echo and the answer come back onto the screen, the caption says where the shell
    /// stands, and a split aimed at the terminal goes to the server that holds it. Answers what
    /// went wrong, or nil.
    static func checkTerminal() async -> String? {
        guard TerminalScreen.isAvailable else { return "this build was made without the terminal engine" }
        let backend = MockBackend(terminals: MockTerminalWorld(directory: "/srv/app"))
        let session = TerminalSession(
            backend: backend, target: .init(server: "selftest", directory: "/srv/app", sessionID: nil),
            desk: "selftest", colors: TerminalColors(palette: MatrixTheme.palette), cols: 64, rows: 10)
        defer { session.end() }
        session.start()
        guard await settled({ session.reading.phase == .live }) else {
            return "the shell did not open: \(session.reading.caption)"
        }
        for character in "echo over the wire" {
            session.press(TerminalKeyPress(key: .typing(character), text: String(character), unshifted: character))
        }
        session.press(TerminalKeyPress(key: .enter))
        let drawn = await settled {
            guard let frame = session.frame(force: true) else { return false }
            return (0..<frame.rows).contains { frame.text(row: $0) == "over the wire" }
        }
        guard drawn else { return "what was typed never came back onto the screen" }
        guard session.reading.caption == "zsh · /srv/app on selftest" else {
            return "the caption reads \(session.reading.caption)"
        }
        guard
            TerminalSplit.plan(directory: session.standingDirectory, server: "selftest")
                == .open(profileID: "selftest", directory: "/srv/app")
        else { return "a split at the terminal did not aim at the shell's own server and folder" }
        return nil
    }

    private static func settled(_ done: @escaping () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }
}
