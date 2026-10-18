import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural reader words")
struct NeuralReadingReaderTests {
    typealias Line = NeuralReadout.DiffLine

    @Test("a file written whole is pasted as the file, an edit with its marks")
    func pasteText() {
        let file = [Line(kind: .add, text: "fn main() {"), Line(kind: .add, text: "}")]
        #expect(NeuralReading.isWholeFile(file))
        #expect(NeuralReading.pasteText(of: file) == "fn main() {\n}")

        let edit = [Line(kind: .remove, text: "old"), Line(kind: .add, text: "new")]
        #expect(!NeuralReading.isWholeFile(edit))
        #expect(NeuralReading.pasteText(of: edit) == "- old\n+ new")
        #expect(!NeuralReading.isWholeFile([]))
    }

    @Test("the whole of a Write is its content, every line, numbered from one by the client")
    func writeIsTheWholeFile() {
        let body = (1...140).map { "line \($0)" }.joined(separator: "\n")
        let call = ToolCall(
            id: "c", name: "Write", status: .completed,
            input: .object(["file_path": .string("status.rs"), "content": .string(body)]))
        let step = NeuralStep(
            id: "w", index: 0, zone: .act, group: 0, messageID: "m", title: "Wrote status.rs",
            call: NeuralStepCall(call))
        let lines = NeuralReadout.fullDiff(of: step)
        #expect(lines.count == 140)
        #expect(NeuralReading.isWholeFile(lines))
        #expect(lines.last?.text == "line 140")
    }

    @Test("the demo's writing turn holds a hundred and forty lines Write and records no effort")
    func demoWriting() {
        let messages = NeuralDemo.writing(prefix: "w-")
        #expect(messages.allSatisfy { $0.reasoningEffort == nil && $0.modelID == nil })
        let turn = NeuralTurns.partition(messages: messages, running: false)[0]
        let write = turn.steps.first { $0.call?.call.name == "Write" }
        #expect(write.map { NeuralReadout.fullDiff(of: $0).count } == 140)
        #expect(NeuralDemo.writtenFile.split(separator: "\n", omittingEmptySubsequences: false).count == 140)
        #expect(turn.effort == nil)
    }
}
