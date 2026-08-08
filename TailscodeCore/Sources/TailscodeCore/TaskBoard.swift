import CodingAgentKit
import Foundation

/// The agent's own to-do list, read out of the transcript. Claude keeps its plan by tool call —
/// the old CLI rewrites the whole list each time (`TodoWrite`), the current one grows it a task
/// at a time (`TaskCreate`/`TaskUpdate`, with the task's number handed back only inside the
/// result string) — and either way the list is state the calls build, not something any one call
/// contains. The board folds every call in transcript order into the one list the person cares
/// about during a long run: what is done, what the agent is on now, what is still ahead.
public struct TaskBoard: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case pending
        case inProgress
        case completed
    }

    public struct Item: Sendable, Hashable, Identifiable {
        public let id: String
        public var subject: String
        /// The present-tense wording the agent gave for while the task runs ("Installing …").
        public var activeForm: String?
        public var status: Status

        public init(id: String, subject: String, activeForm: String?, status: Status) {
            self.id = id
            self.subject = subject
            self.activeForm = activeForm
            self.status = status
        }
    }

    public var items: [Item]

    public init(items: [Item] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
    public var doneCount: Int { items.filter { $0.status == .completed }.count }

    /// The task the agent is on: the first still marked in progress, in list order.
    public var current: Item? { items.first { $0.status == .inProgress } }

    /// The one line a band or a collapsed card wears: progress, then what is happening now.
    public var headline: String {
        let progress = Localized.text("%@ of %@ done", "\(doneCount)", "\(items.count)")
        guard let current else { return progress }
        return "\(progress) · \(current.activeForm ?? current.subject)"
    }

    /// Whether a call is one the board is built from. `TaskList`/`TaskGet` read the list the
    /// server already holds and change nothing, so they stay ordinary tool rows.
    public static func isBoardCall(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("todowrite") || lowered == "todo"
            || lowered == "taskcreate" || lowered == "taskupdate"
    }

    /// Every board call in the transcript, folded in order into the list's current state.
    public static func fold(_ calls: [ToolCall]) -> TaskBoard {
        var board = TaskBoard()
        for call in calls where isBoardCall(call.name) {
            board.apply(call)
        }
        return board
    }

    private mutating func apply(_ call: ToolCall) {
        let lowered = call.name.lowercased()
        if lowered.contains("todo") {
            applySnapshot(call)
        } else if lowered == "taskcreate" {
            applyCreate(call)
        } else if lowered == "taskupdate" {
            applyUpdate(call)
        }
    }

    /// `TodoWrite` is the whole list every time, so the call replaces the board.
    private mutating func applySnapshot(_ call: ToolCall) {
        guard case .array(let todos)? = call.input?["todos"] else { return }
        items = todos.enumerated().compactMap { index, todo in
            let subject = todo["content"]?.stringValue ?? todo["activeForm"]?.stringValue ?? ""
            guard !subject.isEmpty else { return nil }
            return Item(
                id: "todo-\(index)", subject: subject,
                activeForm: todo["activeForm"]?.stringValue,
                status: Self.status(todo["status"]?.stringValue) ?? .pending)
        }
    }

    /// The task's number exists only in the result string ("Task #5 created …"); a call whose
    /// result never arrived gets the next free number, which is what the server would have said.
    private mutating func applyCreate(_ call: ToolCall) {
        guard let subject = call.input?["subject"]?.stringValue, !subject.isEmpty else { return }
        let id = call.output.flatMap(Self.createdID) ?? nextID
        guard !items.contains(where: { $0.id == id }) else { return }
        items.append(
            Item(
                id: id, subject: subject,
                activeForm: call.input?["activeForm"]?.stringValue, status: .pending))
    }

    private mutating func applyUpdate(_ call: ToolCall) {
        guard let id = Self.taskID(call.input?["taskId"]),
            let index = items.firstIndex(where: { $0.id == id })
        else { return }
        if call.input?["status"]?.stringValue == "deleted" {
            items.remove(at: index)
            return
        }
        if let status = Self.status(call.input?["status"]?.stringValue) {
            items[index].status = status
        }
        if let subject = call.input?["subject"]?.stringValue, !subject.isEmpty {
            items[index].subject = subject
        }
        if let active = call.input?["activeForm"]?.stringValue, !active.isEmpty {
            items[index].activeForm = active
        }
    }

    private static func status(_ raw: String?) -> Status? {
        switch raw {
        case "pending": return .pending
        case "in_progress": return .inProgress
        case "completed": return .completed
        default: return nil
        }
    }

    static func createdID(_ output: String) -> String? {
        guard let range = output.range(of: "#[0-9]+", options: .regularExpression) else {
            return nil
        }
        return String(output[range].dropFirst())
    }

    private static func taskID(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let text): return text
        case .integer(let number): return "\(number)"
        default: return nil
        }
    }

    private var nextID: String {
        let highest = items.compactMap { Int($0.id) }.max() ?? 0
        return "\(highest + 1)"
    }
}
