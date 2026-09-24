import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Tool diff tally")
struct ToolDiffTests {
    private func call(_ name: String, _ input: [String: JSONValue], output: String? = nil)
        -> ToolCall
    {
        ToolCall(
            id: UUID().uuidString, name: name, status: .completed, input: .object(input),
            output: output)
    }

    @Test("A run counts the lines its edits and writes changed and nothing else")
    func tallyCountsEditsAndWrites() {
        let calls = [
            call(
                "Edit",
                [
                    "file_path": .string("/repo/a.swift"), "old_string": .string("one\ntwo"),
                    "new_string": .string("one\ntwo\nthree"),
                ]),
            call("Write", ["file_path": .string("/repo/b.swift"), "content": .string("x\ny\nz\nw")]),
            call(
                "Bash", ["command": .string("swift build")],
                output: String(repeating: "Compiling module\n", count: 5_000)),
            call("Read", ["file_path": .string("/repo/c.swift")], output: "a\nb\nc"),
        ]
        let tally = ToolDiff.tally(calls)
        #expect(tally.added == 7)
        #expect(tally.removed == 2)
    }

    @Test("The tally agrees with every call's own summary")
    func tallyMatchesSummaries() {
        let calls = [
            call(
                "MultiEdit",
                ["file_path": .string("/r/x"), "old_string": .string("a"), "new_string": .string("b\nc")]),
            call("apply_patch", ["path": .string("/r/y"), "content": .string("k")]),
            call("Grep", ["pattern": .string("TODO")], output: "x:1: TODO"),
        ]
        let tally = ToolDiff.tally(calls)
        #expect(tally.added == calls.compactMap { $0.summary.diffStats?.added }.reduce(0, +))
        #expect(tally.removed == calls.compactMap { $0.summary.diffStats?.removed }.reduce(0, +))
    }

    @Test("A run with no edits changed nothing")
    func tallyOfReadsIsZero() {
        let tally = ToolDiff.tally([call("Read", ["file_path": .string("/r/z")], output: "q")])
        #expect(tally.added == 0 && tally.removed == 0)
    }
}
