import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// What keeps a streamed token cheap in the pane's apply path: the row builder's brain settings
    /// and policy are reachable while a build is running, and the watch for an answer on the page
    /// twice reads only what changed and forgets what left.
    static func checkApplyPath() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("apply path: \(label)") }
            checks += 1
        }

        try checkBuilderLock(expect)
        try checkDoubledWatch(expect)
        return checks
    }

    private static func checkBuilderLock(_ expect: (Bool, String) throws -> Void) throws {
        let builder = TranscriptRowBuilder()
        let settings = BrainBuildSettings(
            style: .brain, choices: [:], rowsShown: [], look: MatrixTheme.palette.name)
        builder.setBrains(settings)
        let selection = ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5")
        let note = TranscriptNote(.model(selection, effort: nil, previous: nil))
        let message = ChatMessage(
            id: "note", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "note", kind: .note(note))],
            createdAt: Date(timeIntervalSince1970: 1_780_000_000))
        var askedMidBuild = false
        var policyMidBuild: NeuralOpenPolicy?
        let rows = builder.rows(for: [message]) { _ in
            builder.setBrains(settings)
            policyMidBuild = builder.brainPolicy
            askedMidBuild = true
            return nil
        }
        try expect(askedMidBuild, "the build asked for a model's name while it ran")
        try expect(
            policyMidBuild != nil,
            "the policy a build made is readable the moment it is made, in the middle of that build")
        try expect(!rows.isEmpty, "the build that was asked questions still built its rows")
        try expect(
            builder.brainPolicy == policyMidBuild, "the policy stays readable once the build is over")
    }

    private static func checkDoubledWatch(_ expect: (Bool, String) throws -> Void) throws {
        let passage = String(repeating: "the same answer, said once and then again. ", count: 6)
        func prose(_ key: String, _ text: String) -> TranscriptRow {
            TranscriptRow(key: key, kind: .agentProse(text: text, markup: text))
        }
        var watch = DoubledRowWatch()
        try expect(watch.read([prose("a", passage)]).isEmpty, "one long passage is not a double")
        try expect(
            watch.read([prose("a", passage), prose("b", "short")]).isEmpty,
            "a short line beside it is not a double")
        let doubled = watch.read([prose("a", passage), prose("b", passage)])
        try expect(
            doubled.count == 1 && doubled.first?.first == "a" && doubled.first?.second == "b",
            "the same passage under two keys is named once, first and second")
        try expect(
            watch.read([prose("a", passage), prose("b", passage)]).isEmpty,
            "a pass that changed nothing reads nothing new")

        var gone = DoubledRowWatch()
        _ = gone.read([prose("a", passage)])
        try expect(
            gone.read([prose("b", "something else entirely")]).isEmpty,
            "a row that left the transcript is not a double of the next")
        _ = gone.read([prose("b", passage)])
        try expect(
            gone.read([prose("b", passage), prose("c", "tail")]).isEmpty,
            "the row that left was forgotten, so its words under a new key are the first sight")

        var changed = DoubledRowWatch()
        _ = changed.read([prose("a", passage)])
        _ = changed.read([TranscriptRow(key: "a", kind: .turnBreak), prose("b", passage)])
        try expect(
            changed.read([TranscriptRow(key: "a", kind: .turnBreak), prose("b", passage)]).isEmpty,
            "a row that stopped being prose gave up its reading")

        var growing = DoubledRowWatch()
        var text = passage
        var found = 0
        for _ in 0..<5 {
            text += " and a little more."
            found += growing.read([prose("a", passage), prose("b", text)]).count
        }
        try expect(found == 0, "a growing answer never mistakes an earlier prefix for a copy")
    }
}
