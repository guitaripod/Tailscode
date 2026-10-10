import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite struct MessageHoverTests {
    private let rows: [(owner: String?, span: ClosedRange<Double>)] = [
        ("u1", 0...40), (nil, 50...60), ("a1", 70...100), ("a1", 110...150), (nil, 160...170),
        ("a1", 180...200), ("u2", 220...260),
    ]

    private func hit(_ y: Double) -> PointerRows.Hit? {
        PointerRows.message(
            atY: y, count: rows.count, span: { rows[$0].span }, owner: { rows[$0].owner })
    }

    @Test("A position finds the row it falls in, and none in the room between rows")
    func rowAtPosition() {
        let find = { (y: Double) in
            PointerRows.row(atY: y, count: rows.count, span: { rows[$0].span })
        }
        #expect(find(0) == 0)
        #expect(find(40) == 0)
        #expect(find(45) == nil)
        #expect(find(120) == 3)
        #expect(find(260) == 6)
        #expect(find(-5) == nil)
        #expect(find(300) == nil)
        #expect(PointerRows.row(atY: 10, count: 0, span: { _ in nil }) == nil)
    }

    @Test("A message is the run of rows that draw its words, and the room inside it is still on it")
    func messageAtPosition() {
        #expect(hit(20) == PointerRows.Hit(owner: "u1", rows: 0...0))
        #expect(hit(55) == nil)
        #expect(hit(85) == PointerRows.Hit(owner: "a1", rows: 2...3))
        #expect(hit(105) == PointerRows.Hit(owner: "a1", rows: 2...3))
        #expect(hit(165) == nil)
        #expect(hit(190) == PointerRows.Hit(owner: "a1", rows: 5...5))
        #expect(hit(210) == nil)
        #expect(hit(230) == PointerRows.Hit(owner: "u2", rows: 6...6))
    }

    @Test("Copy is the words as written with the thoughts and the harness's markup left out")
    func copiedWords() {
        let now = Date()
        let answer = ChatMessage(
            id: "m", role: .assistant, agentType: .claudeCode,
            parts: [
                MessagePart(id: "a", kind: .text("First **paragraph**.")),
                MessagePart(id: "b", kind: .reasoning("not for copying")),
                MessagePart(id: "c", kind: .text("<system-reminder>x</system-reminder>")),
                MessagePart(id: "d", kind: .text("Second.")),
            ], createdAt: now)
        #expect(MessageHover.words(of: answer) == "First **paragraph**.\n\nSecond.")
        #expect(MessageHover.offersCopy(answer))
        let thoughtOnly = ChatMessage(
            id: "t", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "b", kind: .reasoning("hmm"))], createdAt: now)
        #expect(!MessageHover.offersCopy(thoughtOnly))
    }

    @Test("A message written today is stamped with its time, an older one says which day")
    func stamps() {
        let now = Date()
        #expect(
            MessageHover.stamp(now, now: now) == now.formatted(date: .omitted, time: .shortened))
        #expect(
            MessageHover.stamp(now.addingTimeInterval(-3 * 86_400), now: now).count
                > MessageHover.stamp(now, now: now).count)
    }

    @Test("A prompt offers Undo only where the server can wind back to it, an answer never does")
    func verbsOffered() {
        let now = Date()
        let prompt = ChatMessage(
            id: "u", role: .user, agentType: .openCode,
            parts: [MessagePart(id: "t", kind: .text("do it"))], createdAt: now)
        let answer = ChatMessage(
            id: "a", role: .assistant, agentType: .openCode,
            parts: [MessagePart(id: "t", kind: .text("done"))], createdAt: now)
        let silent = ChatMessage(
            id: "s", role: .assistant, agentType: .openCode, parts: [], createdAt: now)
        let reverting = BackendCapabilities(
            supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
            supportsMultipleSessions: true, supportsModelSelection: false,
            supportsAttachments: false, supportsRevert: true)
        let fixed = BackendCapabilities(
            supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
            supportsMultipleSessions: true, supportsModelSelection: false,
            supportsAttachments: false, supportsRevert: false)
        #expect(
            MessageHover.verbs(for: prompt, isPrompt: true, capabilities: reverting, now: now)
                == MessageHover.Verbs(
                    stamp: MessageHover.stamp(now, now: now),
                    fullDate: now.formatted(date: .complete, time: .standard), copy: true,
                    undo: true))
        #expect(
            !MessageHover.verbs(for: prompt, isPrompt: true, capabilities: fixed, now: now).undo)
        #expect(
            !MessageHover.verbs(for: prompt, isPrompt: true, capabilities: nil, now: now).undo)
        #expect(
            !MessageHover.verbs(for: answer, isPrompt: false, capabilities: reverting, now: now)
                .undo)
        #expect(
            !MessageHover.verbs(for: silent, isPrompt: false, capabilities: reverting, now: now)
                .copy)
    }
}

@Suite struct ChatRowVerbsTests {
    @Test("A chat's verbs say which way they would go, and the ones in force are lit")
    func verbsReadTheirState() {
        let off = ChatRowVerbState(pinned: false, saved: false, archived: false)
        let on = ChatRowVerbState(pinned: true, saved: true, archived: true)
        #expect(ChatRowVerb.allCases.map { off.title($0) } == ["Pin", "Save", "Archive", "More"])
        #expect(ChatRowVerb.allCases.map { on.title($0) } == ["Unpin", "Unsave", "Unarchive", "More"])
        #expect(ChatRowVerb.allCases.map { off.isOn($0) } == [false, false, false, false])
        #expect(ChatRowVerb.allCases.map { on.isOn($0) } == [true, true, true, false])
        let pinnedOnly = ChatRowVerbState(pinned: true, saved: false, archived: false)
        #expect(pinnedOnly.title(.pin) == "Unpin" && pinnedOnly.title(.save) == "Save")
    }
}
