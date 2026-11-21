import AgentTestSupport
import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite struct TerminalSessionTests {
    private static let colors = TerminalColors(
        foreground: 0xdddddd, background: 0x111111, cursor: 0xffffff, ansi: Array(repeating: 0x808080, count: 16),
        selectionForeground: 0xdddddd, selectionBackground: 0x333366, isDark: true)

    private func session(_ backend: MockBackend, directory: String? = "/srv/app", desk: String = "desk (test)")
        -> TerminalSession
    {
        TerminalSession(
            backend: backend, target: .init(server: "arch", directory: directory, sessionID: "chat"),
            desk: desk, colors: Self.colors, cols: 60, rows: 8)
    }

    private func screenText(_ session: TerminalSession) -> String {
        guard let frame = session.frame(force: true) else { return "" }
        return (0..<frame.rows).map { frame.text(row: $0) }.joined(separator: "\n")
    }

    private func wait(_ seconds: Double = 5, until done: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    private func type(_ session: TerminalSession, _ text: String) {
        for character in text {
            if character == "\r" {
                session.press(TerminalKeyPress(key: .enter))
            } else {
                session.press(TerminalKeyPress(key: .typing(character), text: String(character), unshifted: character))
            }
        }
    }

    @Test func whatIsTypedIsDrawnAsTheShellEchoesIt() async throws {
        let backend = MockBackend(terminals: MockTerminalWorld())
        let session = session(backend)
        let dirtied = Counter()
        session.onDirty { dirtied.add() }
        session.start()
        #expect(await wait { session.reading.phase == .live })
        type(session, "echo over the wire\r")
        #expect(await wait { self.screenText(session).contains("\nover the wire") })
        #expect(dirtied.value > 0)
        #expect(session.reading.shell == "bash")
        #expect(session.reading.directory == "/srv/app")
        #expect(session.reading.caption == "bash · /srv/app on arch")
        session.end()
    }

    @Test func aDeskFindsTheShellItLeft() async throws {
        let backend = MockBackend(terminals: MockTerminalWorld())
        let first = session(backend)
        first.start()
        #expect(await wait { first.reading.phase == .live })
        type(first, "echo kept\r")
        #expect(await wait { self.screenText(first).contains("\nkept") })
        let id = first.terminalID
        first.leave()
        let second = session(backend)
        second.start()
        #expect(await wait { second.reading.phase == .live })
        #expect(second.terminalID == id)
        #expect(await wait { self.screenText(second).contains("\nkept") })
        #expect(try await backend.terminals().count == 1)
        let other = session(backend, desk: "another desk (test)")
        other.start()
        #expect(await wait { other.reading.phase == .live })
        #expect(other.terminalID != id)
        second.end()
        other.end()
    }

    @Test func aShellThatEndedWaitsForReturn() async throws {
        let backend = MockBackend(terminals: MockTerminalWorld())
        let session = session(backend)
        session.start()
        #expect(await wait { session.reading.phase == .live })
        type(session, "cd /srv/other\r")
        type(session, "exit 2\r")
        #expect(await wait { session.reading.phase == .ended(code: 2) })
        #expect(screenText(session).contains("The shell ended. Press Return for a new one."))
        #expect(session.reading.caption == "The shell ended (exit 2) · Return starts a new one")
        type(session, "x")
        #expect(session.reading.phase == .ended(code: 2))
        session.press(TerminalKeyPress(key: .enter))
        #expect(await wait { session.reading.phase == .live })
        session.end()
    }

    @Test func aShellTheServerLostIsReplacedAndSaysSo() async throws {
        let backend = MockBackend(terminals: MockTerminalWorld())
        let session = session(backend)
        session.start()
        #expect(await wait { session.reading.phase == .live })
        let id = try #require(session.terminalID)
        backend.forgetTerminal(id)
        #expect(await wait { session.terminalID != nil && session.terminalID != id && session.reading.phase == .live })
        #expect(screenText(session).contains("arch restarted. This is a new shell in the same folder."))
        session.end()
    }

    @Test func theShellIsWalkedToTheConversationOnlyAtItsPrompt() {
        #expect(TerminalFollow.line(to: "/srv/app", standing: "/srv/app/", job: nil) == nil)
        #expect(TerminalFollow.line(to: "/srv/app", standing: "/tmp", job: "vim") == nil)
        #expect(TerminalFollow.line(to: nil, standing: "/tmp", job: nil) == nil)
        #expect(TerminalFollow.line(to: "/srv/it's", standing: "/tmp", job: nil) == " cd -- '/srv/it'\\''s'\r")
        #expect(TerminalFollow.shortened("/home/marcus/Dev/x") == "~/Dev/x")
        #expect(TerminalFollow.shortened("/Users/m") == "~")
        #expect(TerminalFollow.shortened("/srv/app") == "/srv/app")
    }

    @Test func followingTypesTheWalk() async throws {
        let backend = MockBackend(terminals: MockTerminalWorld())
        let session = session(backend)
        session.start()
        #expect(await wait { session.reading.phase == .live })
        session.follow(directory: "/srv/elsewhere")
        #expect(await wait { self.screenText(session).contains("cd -- '/srv/elsewhere'") })
        session.end()
    }

    @Test func aServerThatHoldsNoShellsSaysWhy() async {
        let none = session(MockBackend())
        none.start()
        #expect(await wait { none.reading.phase == .unavailable(.serverHoldsNone(server: "arch")) })
        #expect(none.reading.caption.contains("arch does not hold a terminal"))
        #expect(!none.reading.acceptsInput)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
