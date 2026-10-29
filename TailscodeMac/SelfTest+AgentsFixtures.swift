import AgentTestSupport
import AppKit
import CodingAgentKit
import TailscodeCore

/// What the Agents checks stand on: sessions and conversations built the way the real tower reads
/// them, a board of any size, and the audit that says a laid-out view is whole.
@MainActor
enum AgentsFixtures {
    static func entry(
        _ id: String, _ title: String, profile: String, machine: String, active: Bool = true
    ) -> SessionEntry {
        let session = AgentSession(
            id: id, agentType: .claudeCode, title: title,
            createdAt: Date().addingTimeInterval(-7200), updatedAt: Date(), isActive: active)
        return SessionEntry(
            profileID: profile, profileName: machine, host: machine, backendType: .claudeCode,
            session: session)
    }

    static func message(_ text: String) -> ChatMessage {
        ChatMessage(
            id: "u-" + text.prefix(8), role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "p", kind: .text(text))], createdAt: Date().addingTimeInterval(-200))
    }

    static func asking(_ command: String, permission: String = "perm") -> AgentFacts {
        let bash = ToolCall(
            id: "b", name: "Bash", status: .pending, input: .object(["command": .string(command)]))
        let turn = ChatMessage(
            id: "a-b", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p-b", kind: .tool(bash))],
            createdAt: Date().addingTimeInterval(-100), isStreaming: true)
        let request = PermissionRequest(id: permission, sessionID: "s", title: "Bash", toolName: "Bash")
        return AgentFacts.read(
            state: ConversationState(
                messages: [message("go"), turn], status: .running, pendingPermissions: [request],
                hasLoadedTranscript: true),
            agents: [], seen: [permission: Date().addingTimeInterval(-90)], now: Date())
    }

    /// One working row, one card and the ask's words as long as a person could make them.
    static func longBoard(title: String, command: String) -> AgentBoard {
        let asked = entry("ask", title, profile: "p-long", machine: String(repeating: "machine-", count: 6))
        let working = entry("w", title + " working", profile: "p-long", machine: "studio")
        return AgentBoard.read(
            sources: [
                AgentSource(entry: asked, facts: asking(command), reachable: true, unread: false),
                AgentSource(entry: working, facts: nil, reachable: true, unread: true),
            ], now: Date())
    }

    /// Three machines asking: one answering, one nobody has heard from yet, one that stopped.
    static func awayBoard() -> AgentBoard {
        func source(_ id: String, _ reachable: Bool?) -> AgentSource {
            AgentSource(
                entry: entry(id, "Chat \(id)", profile: "p-\(id)", machine: "machine \(id)"),
                facts: asking("echo \(id)", permission: "perm-\(id)"), reachable: reachable,
                unread: false)
        }
        let working = AgentSource(
            entry: entry("w-away", "Away at work", profile: "p-away", machine: "machine away"),
            facts: nil, reachable: false, unread: false)
        return AgentBoard.read(
            sources: [source("up", true), source("unknown", nil), source("away", false), working],
            now: Date())
    }

    /// The windows this run made, kept for the length of the process: the app holds its one Agents
    /// window for as long as it runs and never lets one go, so a check does not either.
    private static var kept: [AgentsWindowController] = []

    static func keep(_ controller: AgentsWindowController) -> AgentsWindowController {
        kept.append(controller)
        return controller
    }

    static func controller(
        _ feed: any AgentsFeed, width: CGFloat = 1180, mode: AgentsWindowController.Mode = .now
    ) -> AgentsWindowController {
        let controller = keep(AgentsWindowController(feed: feed, mode: mode))
        controller.visibilityOverride = true
        controller.window?.setContentSize(NSSize(width: width, height: 760))
        return controller
    }

    static func settle(_ controller: AgentsWindowController) async {
        for _ in 0..<3 {
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            controller.board.table.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    static func cell<T: NSView>(_ type: T.Type, in controller: AgentsWindowController, nth: Int = 0) -> T? {
        let table = controller.board.table
        var seen = 0
        for row in 0..<table.numberOfRows {
            guard let found = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? T else { continue }
            if seen == nth { return found }
            seen += 1
        }
        return nil
    }

    static func allCells<T: NSView>(_ type: T.Type, in controller: AgentsWindowController) -> [T] {
        let table = controller.board.table
        return (0..<table.numberOfRows).compactMap {
            table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? T
        }
    }

    static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Whether a view laid out at its width is whole: nothing Auto Layout calls ambiguous, no
    /// wrapping label shorter than its words, no label running past the edge of what holds it.
    static func problems(in root: NSView, within bounds: NSRect? = nil, label: String) -> [String] {
        var found: [String] = []
        let frame = bounds ?? root.bounds
        for view in [root] + descendants(of: root) where !view.isHiddenOrHasHiddenAncestor {
            if view.hasAmbiguousLayout { found.append("\(label): ambiguous \(type(of: view))") }
            guard let field = view as? NSTextField, field.frame.width > 1 else { continue }
            if field.maximumNumberOfLines != 1 {
                let needed = field.cell?.cellSize(
                    forBounds: NSRect(x: 0, y: 0, width: field.frame.width, height: .greatestFiniteMagnitude)
                ).height ?? 0
                let capped = field.maximumNumberOfLines > 0
                if !capped, field.frame.height + 1 < needed {
                    found.append("\(label): \"\(field.stringValue.prefix(24))\" is \(field.frame.height) tall, wants \(needed)")
                }
            }
            let rect = root.convert(field.bounds, from: field)
            if rect.maxX > frame.maxX + 1 || rect.minX < frame.minX - 1 {
                found.append("\(label): \"\(field.stringValue.prefix(24))\" leaves the view at \(rect.minX)...\(rect.maxX) of \(frame.width)")
            }
        }
        return found
    }

    static func script() -> [MockScriptStep] {
        let edit = ToolCall(
            id: "e1", name: "Edit", status: .running,
            input: .object(["file_path": .string("/r/Backoff.swift")]))
        let turn = ChatMessage(
            id: "a1", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p1", kind: .tool(edit))], createdAt: Date(), isStreaming: true)
        return [
            MockScriptStep(.messageUpserted(message("go"), replaceParts: true)),
            MockScriptStep(.status(.running)),
            MockScriptStep(.messageUpserted(turn, replaceParts: true)),
        ]
    }

    static func askingScript() -> [MockScriptStep] {
        let bash = ToolCall(
            id: "b", name: "Bash", status: .pending,
            input: .object(["command": .string("rm -rf build")]))
        let turn = ChatMessage(
            id: "a-b", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p-b", kind: .tool(bash))], createdAt: Date(), isStreaming: true)
        let request = PermissionRequest(id: "perm", sessionID: "s1", title: "Bash", toolName: "Bash")
        return [
            MockScriptStep(.messageUpserted(message("go"), replaceParts: true)),
            MockScriptStep(.status(.running)),
            MockScriptStep(.messageUpserted(turn, replaceParts: true)),
            MockScriptStep(.permission(request)),
        ]
    }

    static func tower(script: [MockScriptStep]) -> (AgentTower, SessionEntry) {
        let backend = MockBackend(agentType: .claudeCode, script: script, interactive: true)
        let tower = AgentTower(setup: AgentTowerSetup(backend: { _ in backend }, catalog: { _ in [] }))
        return (tower, entry("s1", "Fix the thing", profile: "p1", machine: "studio"))
    }

    static func wait(timeout: TimeInterval = 8, until condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
