import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Task board")
struct TaskBoardTests {
    private func create(
        _ subject: String, active: String? = nil, output: String? = nil
    ) -> ToolCall {
        var input: [String: JSONValue] = ["subject": .string(subject)]
        if let active { input["activeForm"] = .string(active) }
        return ToolCall(
            id: UUID().uuidString, name: "TaskCreate", status: .completed,
            input: .object(input), output: output)
    }

    private func update(
        _ id: String, status: String? = nil, subject: String? = nil
    ) -> ToolCall {
        var input: [String: JSONValue] = ["taskId": .string(id)]
        if let status { input["status"] = .string(status) }
        if let subject { input["subject"] = .string(subject) }
        return ToolCall(
            id: UUID().uuidString, name: "TaskUpdate", status: .completed, input: .object(input))
    }

    private func todoWrite(_ todos: [(String, String)]) -> ToolCall {
        ToolCall(
            id: UUID().uuidString, name: "TodoWrite", status: .completed,
            input: .object([
                "todos": .array(
                    todos.map {
                        .object(["content": .string($0.0), "status": .string($0.1)])
                    })
            ]))
    }

    @Test("Creates and updates fold into one list")
    func foldsCreatesAndUpdates() {
        let board = TaskBoard.fold([
            create("Install shadPS4", active: "Installing shadPS4", output: "Task #1 created successfully: Install shadPS4"),
            create("Verify GPU", output: "Task #2 created successfully: Verify GPU"),
            update("1", status: "in_progress"),
            update("2", status: "completed"),
        ])
        #expect(board.items.count == 2)
        #expect(board.doneCount == 1)
        #expect(board.current?.id == "1")
        #expect(board.headline == "1 of 2 done · Installing shadPS4")
    }

    @Test("The task's number comes from the result string")
    func idFromOutput() {
        #expect(TaskBoard.createdID("Task #7 created successfully: Docs") == "7")
        #expect(TaskBoard.createdID("no number here") == nil)
    }

    @Test("A create whose result never arrived takes the next free number")
    func idFallback() {
        let board = TaskBoard.fold([
            create("First", output: "Task #3 created successfully: First"),
            create("Second"),
        ])
        #expect(board.items.map(\.id) == ["3", "4"])
    }

    @Test("An update can rename, and deleted removes")
    func updateAmendsAndDeletes() {
        let board = TaskBoard.fold([
            create("Old name", output: "Task #1 created successfully: Old name"),
            create("Doomed", output: "Task #2 created successfully: Doomed"),
            update("1", subject: "New name"),
            update("2", status: "deleted"),
        ])
        #expect(board.items.map(\.subject) == ["New name"])
    }

    @Test("TodoWrite replaces the whole board")
    func todoSnapshotReplaces() {
        let board = TaskBoard.fold([
            create("Stale", output: "Task #1 created successfully: Stale"),
            todoWrite([("Fresh one", "completed"), ("Fresh two", "in_progress")]),
        ])
        #expect(board.items.map(\.subject) == ["Fresh one", "Fresh two"])
        #expect(board.doneCount == 1)
        #expect(board.current?.subject == "Fresh two")
    }

    @Test("Reads never move the board")
    func readsIgnored() {
        #expect(TaskBoard.isBoardCall("TaskCreate"))
        #expect(TaskBoard.isBoardCall("TodoWrite"))
        #expect(!TaskBoard.isBoardCall("TaskList"))
        #expect(!TaskBoard.isBoardCall("TaskGet"))
        #expect(!TaskBoard.isBoardCall("Bash"))
    }

    @Test("Numeric taskId matches a string id")
    func numericID() {
        let board = TaskBoard.fold([
            create("Only", output: "Task #1 created successfully: Only"),
            ToolCall(
                id: "u", name: "TaskUpdate", status: .completed,
                input: .object(["taskId": .integer(1), "status": .string("completed")])),
        ])
        #expect(board.doneCount == 1)
    }

    @Test("A headline with nothing running is just the count")
    func headlineWithoutCurrent() {
        let board = TaskBoard.fold([
            create("Done", output: "Task #1 created successfully: Done"),
            update("1", status: "completed"),
        ])
        #expect(board.headline == "1 of 1 done")
    }
}
