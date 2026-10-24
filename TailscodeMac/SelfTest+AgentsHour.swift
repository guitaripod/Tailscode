import AppKit
import CodingAgentKit
import TailscodeCore

extension AgentsChecks {
    /// The hour: lanes with their agents beneath, the stretch nobody saw, a name for what a pointer
    /// rests on, and a selection that fills the inspector with that agent's peek.
    static func theHourDrawsLanesAndSelects(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        let controller = AgentsFixtures.controller(feed)
        controller.startWatching()
        controller.setMode(.hour)
        let loaded = await AgentsFixtures.wait { controller.hour.lanes.lanes.count == 8 }
        try expect(loaded, "the demo hour has its eight lanes, the agents of a session indented beneath it")
        await AgentsFixtures.settle(controller)
        let lanes = controller.hour.lanes
        try expect(lanes.hour?.unseen.count == 1, "the stretch this Mac did not see is its own span")
        try expect(lanes.lanes.filter { $0.parentID != nil }.count == 2, "two lanes hang under a session")
        try expect(
            lanes.lanes.flatMap(\.marks).map(\.outcome).contains(.failed),
            "a turn that failed leaves its mark")
        let accessible = lanes.accessibilityChildren()?.count
        try expect(accessible == 8, "every lane is a row for VoiceOver")
        guard let waiting = lanes.lanes.first(where: { $0.title == "CI migration" }) else {
            throw SelfTestFailure("agents: the hour has the lane that waits")
        }
        let index = lanes.lanes.firstIndex(of: waiting) ?? 0
        let middle = lanes.rect(ofLane: index)
        let tip = lanes.tip(for: waiting, at: NSPoint(x: lanes.geometry.chartRight - 4, y: middle.midY))
        try expect(tip.contains("CI migration") && tip.contains(AgentHourView.phaseWord(.needsYou)) && tip.contains("since"), "a pointer on the amber stretch names the chat, the phase and since when: \(tip)")
        let faults = AgentsFixtures.problems(in: controller.hour.view, label: "hour")
        try expect(faults.isEmpty, "the hour is whole: \(faults.prefix(2))")
        let boardKeys = Set(
            (feed.board.needsYou.map(\.id) + feed.board.working.map(\.id) + feed.board.background.map(\.id)))
        let topKeys = lanes.lanes.filter { $0.parentID == nil }.map(AgentHourView.key(of:))
        try expect(boardKeys.isSubset(of: Set(topKeys)), "every lane of a session still on the board carries the board's own key: \(topKeys.sorted())")
        try expect(
            Set(lanes.lanes.filter { $0.parentID != nil }.map(AgentHourView.key(of:))) == [AgentDemo.studio + "/w"],
            "the agents under a session carry its key, never a chat of their own")
        lanes.onSelect?(AgentHourView.key(of: waiting))
        try expect(controller.selectedKey == AgentDemo.homelab + "/ask", "selecting a lane selects the agent with exactly that key")
        try expect(!controller.inspector.isCollapsed, "and opens the inspector")
        try expect(controller.peek.subject?.title == "CI migration", "with that agent's peek")
        try expect(controller.peek.subject?.card != nil, "which is the one that asks")
        guard let child = lanes.lanes.first(where: { $0.title == "Explore" }) else {
            throw SelfTestFailure("agents: the hour has a lane under a session")
        }
        lanes.onSelect?(AgentHourView.key(of: child))
        try expect(controller.peek.subject?.title == "Fix reconnect test", "a lane under a session opens its session's peek, not a chat of its own")
        controller.stopWatching()
    }

    /// The keyboard: headings and endings take no selection so the arrows step over them, Return
    /// opens the chat, Space folds the inspector, and a row's menu offers its three verbs.
    static func theKeyboardAndTheMenuWork(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        let controller = AgentsFixtures.controller(feed)
        var opened: [String] = []
        controller.onOpenChat = { opened.append($0) }
        controller.startWatching()
        await AgentsFixtures.settle(controller)
        let table = controller.board.table
        let items = controller.board.items
        let headings = items.indices.filter { !items[$0].isSelectable }
        try expect(
            headings.allSatisfy { !controller.board.tableView(table, shouldSelectRow: $0) },
            "the arrows step over headings, the head and the finished lines: none of them takes a selection")
        try expect(
            items.indices.filter { items[$0].isSelectable }.allSatisfy {
                controller.board.tableView(table, shouldSelectRow: $0)
            }, "and every card and row does")
        controller.window?.makeFirstResponder(table)
        guard let first = items.firstIndex(where: { $0.isSelectable }) else {
            throw SelfTestFailure("agents: the demo board has something to select")
        }
        table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        try expect(controller.board.selectedKey == feed.board.needsYou.first?.id, "the first selectable line is the card that waits")
        try expect(!controller.inspector.isCollapsed, "a selection opens the inspector")
        controller.select(key: feed.board.working.first?.id, from: .code)
        func press(_ code: UInt16, _ characters: String) {
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: controller.window?.windowNumber ?? 0, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)
            else { return }
            table.keyDown(with: event)
        }
        press(36, "\r")
        try expect(opened == [feed.board.working.first?.id].compactMap { $0 }, "Return opens the selected agent's chat")
        let before = controller.inspector.isCollapsed
        press(49, " ")
        try expect(controller.inspector.isCollapsed != before, "Space folds the inspector")
        if let row = controller.board.items.firstIndex(where: { $0.sessionKey == feed.board.working.first?.id }) {
            let menu = table.menuProvider?(row)
            try expect(
                menu?.items.map(\.title).filter { !$0.isEmpty } == [
                    Localized.text("Open Chat"), Localized.text("Peek"), Localized.text("Stop…"),
                ], "a row's menu is Open Chat, Peek and Stop")
        }
        controller.select(key: nil, from: .code)
        try expect(controller.inspector.isCollapsed, "nothing selected, the inspector folds away")
        controller.stopWatching()
    }

    /// A session nobody watches says so, and offers to watch; an agent waiting shows its ask.
    static func aListedAgentSaysSo(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        let controller = AgentsFixtures.controller(feed)
        controller.startWatching()
        await AgentsFixtures.settle(controller)
        guard let listed = feed.board.working.first(where: { !$0.isWatched }) else {
            throw SelfTestFailure("agents: the demo board has a listed row")
        }
        controller.select(key: listed.id, from: .code)
        await AgentsFixtures.settle(controller)
        try expect(controller.peek.texts.contains(AgentsWords.listedOnly), "a listed agent is read as listed only")
        try expect(controller.peek.texts.contains(Localized.text("Watch this one")), "and offers to watch it")
        let rows = AgentsFixtures.allCells(AgentsRowView.self, in: controller)
        try expect(rows.contains { $0.row?.id == listed.id && $0.childLines == 0 }, "its row folds its agents into a count")
        controller.stopWatching()
    }
}

extension AgentsChecks {
    /// What a call is about, under the words: the whole command, or the path with what changed, and
    /// no tool's name.
    static func theObjectSitsUnderWhatItIsDoing(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        let controller = AgentsFixtures.controller(feed)
        controller.startWatching()
        guard let row = feed.board.working.first else { throw SelfTestFailure("agents: a working row") }
        controller.select(key: row.id, from: .code)
        let facts = AgentDemo.facts(now: Date())
        controller.peek.apply(facts: facts)
        controller.peek.renderNow()
        await AgentsFixtures.settle(controller)
        try expect(
            facts.object.map { controller.peek.texts.contains($0.text) } ?? true,
            "what the call is about is shown under the line")
        try expect(
            facts.tool.map { !controller.peek.texts.contains($0) } ?? true,
            "and a tool's name is not")
        let command = "cd build\nrm -rf cache\nswift build -c release\necho done"
        let running = ToolCall(
            id: "bash", name: "Bash", status: .running, input: .object(["command": .string(command)]))
        let turn = ChatMessage(
            id: "a-bash", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p-bash", kind: .tool(running))],
            createdAt: Date().addingTimeInterval(-30), isStreaming: true)
        let ran = AgentFacts.read(
            state: ConversationState(
                messages: [AgentsFixtures.message("go"), turn], status: .running,
                hasLoadedTranscript: true),
            agents: [], now: Date())
        try expect(ran.object?.kind == .command && ran.object?.text == command, "Core reads the whole command, every line")
        controller.peek.apply(facts: ran)
        controller.peek.renderNow()
        await AgentsFixtures.settle(controller)
        try expect(controller.peek.texts.contains(command), "and the peek shows every line of it")
        let faults = AgentsFixtures.problems(in: controller.peek.view, label: "peek object")
        try expect(faults.isEmpty, "the peek with a command is whole: \(faults.prefix(2))")
        controller.stopWatching()
    }

    /// A five-line command is five lines on the card, and one a hundred lines long scrolls inside it.
    static func aMultiLineCommandShowsEveryLine(_ expect: (Bool, String) throws -> Void) async throws {
        let five = "ls\ncd build\nrm -rf cache\nswift build -c release\necho done"
        let hundred = (1...100).map { "echo step \($0)" }.joined(separator: "\n")
        for (command, lines) in [(five, 5), (hundred, 100)] {
            let feed = DemoFeed()
            let controller = AgentsFixtures.controller(feed)
            controller.startWatching()
            feed.replace(AgentsFixtures.longBoard(title: "Ask", command: command))
            await AgentsFixtures.settle(controller)
            guard let card = AgentsFixtures.cell(AgentsAskCardView.self, in: controller) else {
                throw SelfTestFailure("agents: a card for the command")
            }
            let said = feed.board.needsYou.first?.ask.object
            try expect(said == command, "Core's ask carries the whole command, not its first line")
            try expect(card.block.commandText == command, "the card shows all \(lines) lines word for word")
            let line = NSLayoutManager().defaultLineHeight(for: MacTheme.Ramp.font(.code))
            try expect(card.block.commandHeight >= line * CGFloat(lines) - 1, "the text is as tall as its \(lines) lines")
            if lines == 5 {
                try expect(card.block.commandBoxHeight >= card.block.commandHeight, "five lines are shown in full, not cut")
            } else {
                try expect(card.block.commandBoxHeight <= AgentsAskBlockView.commandCeiling + 1, "a long command stops at the ceiling")
                try expect(card.block.commandHeight > AgentsAskBlockView.commandCeiling, "and scrolls inside the card rather than being cut")
            }
            controller.stopWatching()
        }
    }
}
