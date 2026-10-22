import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("What the effort dial says to a screen reader")
struct EffortVoiceTests {
    private let claude = ["low", "medium", "high", "xhigh", "max", "ultracode"]

    private final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func add(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    @Test("A step that moves names the level it landed on")
    func moved() {
        let notch = ModelDial.notch(from: "medium", by: 1, options: claude)
        #expect(notch.moved)
        #expect(notch.level == "high")
        #expect(notch.spoken == ModelDial.stepped(to: "high"))
    }

    @Test("A step against the end of the ladder says so, at either end")
    func pinned() {
        let top = ModelDial.notch(from: "ultracode", by: 1, options: claude)
        #expect(!top.moved)
        #expect(top.spoken.contains("highest"))
        let bottom = ModelDial.notch(from: "low", by: -1, options: claude)
        #expect(!bottom.moved)
        #expect(bottom.spoken.contains("lowest"))
    }

    @Test("A step from the server's own stop is a move, not a pin")
    func fromTheServersStop() {
        let notch = ModelDial.notch(from: nil, by: 1, options: claude)
        #expect(notch.moved)
        #expect(notch.level == "low")
    }

    private final class Hand: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func sleep(_ seconds: TimeInterval) async {
            await withCheckedContinuation { continuation in
                lock.lock()
                waiting.append(continuation)
                lock.unlock()
            }
        }

        var pending: Int {
            lock.lock()
            defer { lock.unlock() }
            return waiting.count
        }

        func turn() {
            lock.lock()
            let all = waiting
            waiting = []
            lock.unlock()
            for continuation in all { continuation.resume() }
        }
    }

    private func until(_ condition: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("the condition never held")
    }

    @Test("A hand that keeps stepping is told once, where it stopped")
    func coalesced() async throws {
        let said = Said()
        let hand = Hand()
        let voice = EffortVoice(sleeper: { await hand.sleep($0) }) { said.add($0) }
        for _ in 0..<12 {
            voice.note(ModelDial.notch(from: "ultracode", by: 1, options: claude))
        }
        voice.note(ModelDial.notch(from: "medium", by: 1, options: claude))
        let last = ModelDial.notch(from: "high", by: 1, options: claude)
        voice.note(last)
        try await until { hand.pending == 14 }
        hand.turn()
        try await until { !said.all.isEmpty }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(said.all == [last.spoken])
    }

    @Test("A pause between steps is two announcements")
    func paused() async throws {
        let said = Said()
        let hand = Hand()
        let voice = EffortVoice(sleeper: { await hand.sleep($0) }) { said.add($0) }
        let first = ModelDial.notch(from: "low", by: 1, options: claude)
        let second = ModelDial.notch(from: "medium", by: 1, options: claude)
        voice.note(first)
        try await until { hand.pending == 1 }
        hand.turn()
        try await until { said.all.count == 1 }
        voice.note(second)
        try await until { hand.pending == 1 }
        hand.turn()
        try await until { said.all.count == 2 }
        #expect(said.all == [first.spoken, second.spoken])
    }
}
