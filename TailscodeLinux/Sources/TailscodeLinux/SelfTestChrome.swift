import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The band over the prompt box: a status that shows every field always is a status nobody
    /// reads, so what is asserted here is mostly what is *absent*. Compact by default — the
    /// agents band counts while its popover names, and the goal is a glyph until it is asked
    /// about, its words living in the popover. Twenty agents spawned with one preamble must not
    /// read as twenty copies of the preamble.
    /// The chat's chrome as the design contract states it: a band that says nothing at idle, one
    /// Stop and it is not in the band, a failed turn that draws a card holding the server's words,
    /// a stylesheet GTK parses without a single complaint in every theme at both densities, and a
    /// dim ink that clears AA on every canvas the row can sit on.
    static func checkChatChrome() throws -> Int {
        var claims = 0
        func expect(_ condition: Bool, _ words: String) throws {
            guard condition else { throw SelfTestFailure(words) }
            claims += 1
        }

        let broken = ".x { color: red;; }".withCString { tailscode_css_problems($0) }
        try expect(broken != nil, "the stylesheet check hears an empty declaration")
        if let broken { g_free(broken) }

        var facts = StatusFacts()
        try expect(facts.segments.isEmpty, "an idle band says nothing")
        facts.queued = 2
        try expect(
            facts.segments.contains { $0.id == "queued" && $0.text.contains("2") },
            "a queued prompt shows on the band")
        facts.phase = .working
        facts.activity = .working
        facts.elapsed = 5
        try expect(
            !facts.segments.contains { $0.action == .stop },
            "the band holds no second Stop beside the composer's")

        let now = Date()
        let asked = ChatMessage(
            id: "u1", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text("Run the migration."))], createdAt: now)
        let broke = ChatMessage(
            id: "a1", role: .assistant, agentType: .claudeCode, createdAt: now,
            error: "429  rate limited,\n try later", modelID: "fable")
        let rows = TranscriptRow.rows(for: broke, prompt: asked)
        let card = rows.compactMap { row -> FailedTurn? in
            if case .failed(let turn) = row.kind { return turn }
            return nil
        }.first
        try expect(card != nil, "an errored turn draws a failed card")
        try expect(card?.reason == "429 rate limited, try later", "the server's words are quoted, tidied")
        try expect(card?.prompt == "Run the migration.", "the card carries the words to ask again")
        let clean = ChatMessage(id: "a2", role: .assistant, agentType: .claudeCode, createdAt: now)
        try expect(
            !TranscriptRow.rows(for: clean, prompt: asked).contains {
                if case .failed = $0.kind { return true }
                return false
            }, "a turn that did not fail draws no failed card")

        let crowd = (0..<4).map { index in
            TranscriptRow(
                key: "sub\(index)",
                kind: .subagent(
                    ToolCall(
                        id: "task\(index)", name: "Task", status: .completed,
                        input: .object(["description": .string("errand \(index)")]))))
        }
        let grouped = TranscriptRow.groupAgents(in: crowd, messageID: "a1")
        try expect(
            grouped.count == 1 && grouped[0].key == "agents:a1",
            "four sibling agents collapse behind one row")
        try expect(
            TranscriptRow.groupAgents(in: Array(crowd.prefix(3)), messageID: "a1").count == 3,
            "three agents stay as cards")

        let split = PangoMarkdown.chunks("Here is the plan:\n- one\n- two\n\nThen we ship.")
        try expect(
            split.map(\.isList) == [false, true, false], "prose splits at the edges of a list")
        try expect(
            PangoMarkdown.hangingMarker(for: split[1].text) == "• ", "a list hangs by its bullet")
        try expect(
            PangoMarkdown.hangingMarker(for: "9. a\n10. b") == "10. ",
            "a numbered list hangs by its widest number")
        try expect(
            PangoMarkdown.hangingMarker(for: split[0].text) == nil, "a paragraph does not hang")

        let keys = ShortcutSet.build(overrides: [:])
        for (spec, action) in [
            ("[", KeyAction.previousPrompt), ("]", .nextPrompt), ("Y", .copyLastAnswer),
        ] {
            guard let (_, chords) = KeySpec.parse(spec), let chord = chords.first else {
                throw SelfTestFailure("\(spec) does not parse")
            }
            try expect(
                keys.resolve(chord, context: .normal, pending: [], awaitingApproval: false)
                    == .run(action),
                "\(spec) reaches \(action)")
        }
        if gtk_init_check() != 0 { claims += try checkChatChromeWidgets() }

        for theme in AppTheme.all {
            for dark in [true, false] {
                let palette = MatrixTheme.palette(for: theme.id, dark: dark)
                let ink = MatrixTheme.quietInk(for: palette)
                let fill =
                    Contrast.blend(
                        palette.canvas, palette.text, ChatChrome.fill(.fact).inkShare)
                    ?? palette.canvas
                for background in [palette.canvas, palette.canvasRaised, fill] {
                    let ratio = Contrast.ratio(ink, on: background) ?? 0
                    try expect(
                        ratio >= Contrast.readable - 0.05,
                        "\(theme.id) \(dark ? "dark" : "light") dim ink is \(ratio) on \(background)")
                }
                for density in [ChatDensity.compact, .comfortable] {
                    let sheet = MatrixTheme.css(for: palette, density: density)
                    let problems = sheet.withCString { tailscode_css_problems($0) }
                    if let problems {
                        let text = String(cString: problems)
                        g_free(problems)
                        throw SelfTestFailure("\(theme.id) stylesheet: \(text)")
                    }
                    claims += 1
                }
            }
        }
        return claims
    }

    /// What a screen reader would be told by the chat's own controls: a name that is words and
    /// never a glyph, the state of a disclosure and of a choice, an Answer that waits for an answer,
    /// and the keys on the approval buttons read from the set the person has.
    static func checkChatChromeWidgets() throws -> Int {
        var claims = 0
        func expect(_ condition: Bool, _ words: String) throws {
            guard condition else { throw SelfTestFailure(words) }
            claims += 1
        }
        func descendants(
            of widget: UnsafeMutablePointer<GtkWidget>, with css: String
        ) -> [UnsafeMutablePointer<GtkWidget>] {
            var found: [UnsafeMutablePointer<GtkWidget>] = []
            if gtk_widget_has_css_class(widget, css) != 0 { found.append(widget) }
            var child = gtk_widget_get_first_child(widget)
            while let current = child {
                found += descendants(of: current, with: css)
                child = gtk_widget_get_next_sibling(current)
            }
            return found
        }

        let chip = ChatChips.control(
            glyph: "↓", word: "3 new", label: "Jump to the newest, 3 new", onClick: {})
        try expect(
            tailscode_accessible_has_label(chip.button, "Jump to the newest, 3 new") != 0,
            "a chip is named by words, not by its glyph")

        let header = Gtk.label("Thought · 3 words", selectable: false)
        let row = Gtk.disclosure(header: header, expanded: true, onToggle: { _, _ in }) {
            Gtk.label("body")
        }
        let toggle = gtk_widget_get_first_child(row)!
        try expect(
            tailscode_accessible_has_label(toggle, "Thought · 3 words") != 0,
            "a disclosure is named by its header, not by its chevron")
        try expect(tailscode_accessible_state_is(toggle, 0, 1) != 0, "an open disclosure says so")
        tailscode_emit_clicked(toggle)
        try expect(tailscode_accessible_state_is(toggle, 0, 0) != 0, "a shut disclosure says so")

        let request = QuestionRequest(
            id: "q", sessionID: "s",
            questions: [
                QuestionRequest.Item(
                    question: "Which surfaces?", header: "Target",
                    options: [
                        QuestionRequest.Option(label: "Web", description: ""),
                        QuestionRequest.Option(label: "Email", description: ""),
                    ], multiple: true)
            ])
        let card = PendingCards.question(request, in: nil) { _ in }
        let options = descendants(of: card, with: "answer-option")
        let answer = descendants(of: card, with: "btn-primary").first
        try expect(options.count == 2 && answer != nil, "a question card has its options and Answer")
        if let answer, let first = options.first {
            try expect(gtk_widget_get_sensitive(answer) == 0, "Answer waits for an answer")
            try expect(tailscode_accessible_state_is(first, 1, 0) != 0, "an option starts unpressed")
            tailscode_emit_clicked(first)
            try expect(
                tailscode_accessible_state_is(first, 1, 1) != 0
                    && gtk_widget_has_css_class(first, "answer-selected") != 0,
                "a chosen option is pressed and wears the selected look")
            try expect(gtk_widget_get_sensitive(answer) != 0, "Answer opens once something is chosen")
            tailscode_emit_clicked(first)
            try expect(gtk_widget_get_sensitive(answer) == 0, "Answer closes when it is unchosen")
        }
        try expect(
            tailscode_accessible_has_label(card, ActivityKind.needsAnswer.spoken + ". Which surfaces?")
                != 0,
            "a question card is a named group")

        let permission = PermissionRequest(id: "p", sessionID: "s", title: "Edit a.swift", toolName: "Edit")
        let plain = PendingCards.permission(
            permission, hints: PendingCards.Hints(ShortcutSet.build(overrides: [:]))
        ) { _ in }
        let plainWords = Gtk.spokenText(of: plain)
        try expect(
            plainWords.contains("Allow once · y") && plainWords.contains("Always · a")
                && plainWords.contains("Deny · n"),
            "the approval buttons carry the default keys: \(plainWords)")
        let rebound = PendingCards.permission(
            permission,
            hints: PendingCards.Hints(ShortcutSet.build(overrides: ["approve.always": ["b"]]))
        ) { _ in }
        let reboundWords = Gtk.spokenText(of: rebound)
        try expect(
            reboundWords.contains("Always · b") && !reboundWords.contains("Always · a"),
            "a rebound key is the one printed on the button: \(reboundWords)")
        try expect(
            tailscode_accessible_has_label(
                plain, ActivityKind.needsApproval.spoken + ". " + Localized.text("Allow %@?", "Edit a.swift"))
                != 0,
            "an approval card is a named group")

        let agentCall = { (index: Int) in
            ToolCall(
                id: "task\(index)", name: "Task", status: .running,
                input: .object(["description": .string("errand \(index)")]))
        }
        let members = (0..<4).map {
            TranscriptRow.AgentMember(key: "sub\($0)", call: agentCall($0))
        }
        let context = TranscriptContext()
        for member in members.prefix(2) {
            context.agentFacts[member.call.id] = SubagentSummary(
                id: "s\(member.key)", title: "x", toolUseID: member.call.id,
                updatedAt: Date(), isActive: true)
        }
        let group = SubagentRowView.makeGroup(members, key: "agents:a", context: context)
        let groupWords = Gtk.spokenText(of: group)
        try expect(
            groupWords.contains(Localized.text("%lld agents", 4))
                && groupWords.contains(Localized.text("%lld working", 2)),
            "a group of agents says how many and how many are out: \(groupWords)")
        return claims
    }

    static func checkStatusBand() throws -> Int {
        func text(_ facts: StatusFacts) -> String {
            facts.segments.map(\.text).joined(separator: " | ")
        }

        let read = Date()
        let todoAgent = SubagentSummary(
            id: "a", title: "port the renderer", updatedAt: read, isActive: true,
            startedAt: read.addingTimeInterval(-95), toolCount: 4,
            currentTool: "Bash swift build", todosDone: 2, todosTotal: 5,
            currentTodo: "port the disclosure rows")
        let todoLine = StatusFacts.liveDetail(todoAgent, at: read, under: .going)
        guard todoLine.hasPrefix("2/5 · port the disclosure rows"), todoLine.hasSuffix("1m 35s")
        else {
            throw SelfTestFailure("todo agent line: \(todoLine)")
        }
        let toolAgent = SubagentSummary(
            id: "b", title: "sweep the band", updatedAt: read, isActive: true,
            toolCount: 7, currentTool: "Edit StatusBand.swift")
        let toolLine = StatusFacts.liveDetail(toolAgent, at: read, under: .going)
        guard toolLine.contains("7"), toolLine.contains("Edit StatusBand.swift") else {
            throw SelfTestFailure("tool agent line: \(toolLine)")
        }
        let quietAgent = SubagentSummary(id: "c", title: "quiet", updatedAt: read, isActive: true)
        guard StatusFacts.liveDetail(quietAgent, at: read, under: .going)
            == Localized.text("working")
        else {
            throw SelfTestFailure("quiet agent line")
        }
        let aWeekOn = read.addingTimeInterval(604_800)
        guard StatusFacts.liveDetail(todoAgent, at: aWeekOn, under: .going).hasSuffix("10081m 35s")
        else { throw SelfTestFailure("a line under work still open stopped counting") }
        let held = StatusFacts.liveDetail(todoAgent, at: aWeekOn, under: .over(at: nil))
        guard held.hasSuffix("1m 35s") else {
            throw SelfTestFailure("a line under work that is over counts on: \(held)")
        }

        var idle = StatusFacts()
        guard idle.segments.isEmpty else { throw SelfTestFailure("idle band: \(text(idle))") }

        idle.phase = .working
        idle.activity = .usingTool(name: "Bash", kind: .other)
        idle.elapsed = 72
        idle.runningTool = "Bash"
        guard text(idle).contains("1m 12s"), text(idle).contains("Bash") else {
            throw SelfTestFailure("working band: \(text(idle))")
        }

        let now = Date()
        idle.lastPromptAt = now.addingTimeInterval(-120)
        idle.agents = [
            SubagentSummary(
                id: "a", title: "map the theme", agentType: "explore", toolUseID: "t1",
                updatedAt: now, isActive: true),
            SubagentSummary(
                id: "b", title: "check the diff", agentType: "review", toolUseID: "t2",
                updatedAt: now.addingTimeInterval(-30), isActive: true),
            SubagentSummary(
                id: "c", title: "verify", agentType: "verify", toolUseID: "t3",
                updatedAt: now.addingTimeInterval(-90), isCompleted: true),
        ]
        guard text(idle).contains("▸ 2 · 1✓"), !text(idle).contains("explore") else {
            throw SelfTestFailure("agents band is not compact: \(text(idle))")
        }
        guard let agentSegment = idle.segments.first(where: { $0.text.hasPrefix("▸") }),
            agentSegment.rows.count == 3,
            agentSegment.rows.first?.title.contains("explore") == true,
            agentSegment.rows.first?.detail?.contains("working") == true,
            agentSegment.rows.last?.detail?.contains("done") == true,
            agentSegment.rows.first?.action == .agent("t1")
        else { throw SelfTestFailure("agents popover does not list the agents") }

        idle.context = ContextFill(
            used: 148_900, window: 200_000, model: "claude-fable-5", basis: .reported)
        guard text(idle).contains("74% · 148.9k"),
            idle.segments.contains(where: { $0.id == "context" && $0.css == "seg-warn" }),
            idle.segments.first(where: { $0.id == "context" })?.action == .range,
            idle.segments.first(where: { $0.id == "context" })?.meter != nil
        else { throw SelfTestFailure("context band: \(text(idle))") }
        idle.context = ContextFill(used: 40_000, window: nil, model: "mystery", basis: .estimated)
        guard text(idle).contains("~40.0k"),
            idle.segments.first(where: { $0.id == "context" })?.meter == nil
        else { throw SelfTestFailure("context band without a window: \(text(idle))") }

        idle.lastCostUSD = 0.38
        guard text(idle).contains("$0.38") else { throw SelfTestFailure("cost: \(text(idle))") }

        idle.goal = "ship it"
        guard text(idle).contains("⦿"), !text(idle).contains("ship it") else {
            throw SelfTestFailure("goal is not compact: \(text(idle))")
        }
        guard let goalSegment = idle.segments.first(where: { $0.css == "seg-goal" }),
            goalSegment.rows.first?.title == "ship it",
            goalSegment.rows.last?.action == .goal
        else { throw SelfTestFailure("goal popover does not carry the goal") }
        idle.goalMet = true
        guard text(idle).contains("✓") else { throw SelfTestFailure("goal met: \(text(idle))") }

        var failed = StatusFacts()
        failed.phase = .failed("the bridge said no")
        guard text(failed).contains("the bridge said no"), failed.segments.count == 1 else {
            throw SelfTestFailure("failure band: \(text(failed))")
        }

        var approval = StatusFacts()
        approval.phase = .awaitingApproval
        guard approval.segments.first?.action == .scrollToPending else {
            throw SelfTestFailure("approval segment is not actionable")
        }

        var fanOut = StatusFacts()
        fanOut.lastPromptAt = now.addingTimeInterval(-60)
        fanOut.agents = (0..<4).map { index in
            SubagentSummary(
                id: "f\(index)", title: "In /home/marcus/Dev/iOS/Tailscode, verify claim number \(index) about the diff",
                agentType: "workflow-subagent", toolUseID: "ft\(index)",
                updatedAt: now.addingTimeInterval(Double(-index)), isCompleted: true)
        }
        guard let fanRows = fanOut.segments.first(where: { $0.id == "agents" })?.rows,
            fanRows.allSatisfy({ $0.title.contains("…") }),
            fanRows[0].title.contains("0"), fanRows[1].title.contains("1"),
            !fanRows[0].title.contains("/home/marcus")
        else { throw SelfTestFailure("fan-out titles keep their shared preamble") }
        return 11
    }

    /// A subagent card's live line is a clock, and it has to read the errand rather than the days
    /// since. The agent handed here is deliberately left claiming to be active, because that is the
    /// one shape the fault lives in: a sidecar goes on reporting itself out for as long as its
    /// window lasts, so a call that is over holding an agent that still says it is working is what
    /// a real fan-out delivers, and a check that settled the record by hand would never once build
    /// it. Read off the widget rather than off the vocabulary, and read twice — at the moment the
    /// card was built and a week later — because a clock that grows is only ever caught by asking
    /// a second time.
    static func checkSubagentCard() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        let now = Date()
        let aWeekOn = now.addingTimeInterval(604_800)
        var call = ToolCall(
            id: "task-1", name: "Task", status: .running,
            input: .object(["description": .string("port the renderer")]))
        let agent = SubagentSummary(
            id: "s1", title: "port the renderer", agentType: "explore", toolUseID: call.id,
            updatedAt: now.addingTimeInterval(-12), isActive: true,
            startedAt: now.addingTimeInterval(-252), toolCount: 4, currentTool: "Bash swift build")
        let context = TranscriptContext()
        context.agentFacts[call.id] = agent

        guard drawn(call, at: now, in: context) == "live=4 tools · Bash swift build · 4m 12s" else {
            throw SelfTestFailure("a live card's line: \(drawn(call, at: now, in: context))")
        }
        let counting = drawn(call, at: aWeekOn, in: context)
        guard counting.hasSuffix("10084m 12s") else {
            throw SelfTestFailure("a card under a running call stopped counting: \(counting)")
        }

        call.status = .completed
        let settled = drawn(call, at: now, in: context)
        guard settled.hasSuffix("4m 0s") else {
            throw SelfTestFailure("a card under an ended call: \(settled)")
        }
        guard drawn(call, at: aWeekOn, in: context) == settled else {
            throw SelfTestFailure(
                "a card under an ended call kept counting a week later: "
                    + drawn(call, at: aWeekOn, in: context))
        }

        call.background = BackgroundOutcome(
            taskID: "task-1", status: .completed, summary: "the errand ended",
            reportedAt: now.addingTimeInterval(-100))
        let credited = drawn(call, at: aWeekOn, in: context)
        guard credited.hasSuffix("2m 32s") else {
            throw SelfTestFailure(
                "a stale sidecar is credited with work past the report: \(credited)")
        }

        context.agentFacts[call.id] = nil
        guard drawn(call, at: now, in: context) == "live=none" else {
            throw SelfTestFailure("a card with no live agent wears a clock anyway")
        }
        return 5
    }
}
