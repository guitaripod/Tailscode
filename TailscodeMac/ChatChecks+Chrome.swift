import AppKit
import CodingAgentKit
import TailscodeCore

extension ChatChecks {
    /// The claims of the chat-screen redesign that a screenshot cannot make: the failed turn has a
    /// card and a way to send it again, the idle band says nothing, Stop is in one place, every chip
    /// is one height, the jump control reads Core, a fan-out collapses, an answer chip wraps rather
    /// than clips, and an agent count is the turn's witness rather than the server's record.
    static func chrome(_ expect: (Bool, String) throws -> Void) throws {
        let asked = message("u", .user, [MessagePart(id: "p", kind: .text("Run the suite"))])
        var failed = message("a", .assistant, [MessagePart(id: "t", kind: .text("Starting"))])
        failed.error = "The model provider returned 529: overloaded."
        let rows = TranscriptRow.rows(for: [asked, failed])
        let card = rows.first {
            if case .failedTurn = $0.kind { return true }
            return false
        }
        try expect(card != nil, "an errored message draws a failed-turn row")
        try expect(
            rows.last.map { if case .failedTurn = $0.kind { true } else { false } } == true,
            "the failed card stands after the turn's own rows")
        let context = TranscriptContext()
        var resent = ""
        context.askAgain = { resent = $0 }
        if let card {
            let view = card.makeView(context: context)
            stage(view)
            try expect(
                view.accessibilityLabel()?.contains("overloaded") == true,
                "the card is spoken with the server's own words")
            try expect(
                view.accessibilityRole() == .group, "the card is one group for a screen reader")
            let links = allViews(in: view).compactMap { $0 as? NSButton }
            try expect(
                links.contains { $0.title == FailedTurnReading.read(failed, prompt: asked)?.action },
                "the card offers Try again")
            links.first { $0.title == Localized.text("Try again") }?.performClick(nil)
            try expect(resent == "Run the suite", "Try again sends the words that started the turn")
        }
        failed.error = nil
        try expect(
            !TranscriptRow.rows(for: [asked, failed]).contains {
                if case .failedTurn = $0.kind { return true }
                return false
            }, "a turn with no error draws no failed card")

        let idle = StatusFacts.from(
            state: ConversationState(
                messages: [asked], status: .idle, connection: .live, hasLoadedTranscript: true),
            agents: [], usage: nil, attachments: 0)
        let band = StatusBandView()
        band.render(facts: idle, notice: nil)
        try expect(!band.hasContent, "an idle band with nothing to say is not drawn")
        try expect(
            !idle.segments.contains { $0.id == "phase" }, "idle has no phase segment, ready or not")
        let running = StatusFacts.from(
            state: ConversationState(
                messages: [asked], status: .running, connection: .live, hasLoadedTranscript: true),
            agents: [], usage: nil, attachments: 0, queued: 2)
        try expect(
            running.segments.allSatisfy { $0.action != .stop }, "the band carries no Stop")
        try expect(
            running.segments.contains { $0.id == "queued" }, "a queue of two is on the band")

        let pills = PillsRow()
        pills.setStopShown(true)
        stage(pills)
        pills.frame = NSRect(x: 0, y: 0, width: 900, height: 24)
        pills.layoutSubtreeIfNeeded()
        let stops = allViews(in: pills).filter {
            guard let chip = $0 as? SymbolChip else { return false }
            return chip.symbol == "stop.fill" && !chip.isHidden
        }
        try expect(stops.count == 1, "\(stops.count) Stop controls in the pills row")
        let heights = allViews(in: pills).compactMap { $0 as? ChipButton }.filter { !$0.isHidden }
            .map(\.frame.height)
        try expect(
            !heights.isEmpty && heights.allSatisfy { abs($0 - heights[0]) < 0.5 },
            "every chip in the row is one height: \(heights)")
        try expect(
            heights.allSatisfy { $0 >= CGFloat(ChatChrome.chip(on: .pointer).height) },
            "no chip is under the table's \(ChatChrome.chip(on: .pointer).height)")

        let reading = JumpReading.read(rowsNow: 12, rowsAtDeparture: 5, needsYou: false)
        try expect(reading.label == Localized.text("New below"), "rows that arrived while away say so without a count")
        try expect(
            JumpReading.read(rowsNow: 12, rowsAtDeparture: 5, needsYou: true).tone == .attention,
            "what needs the reader outranks news")
        let controller = TranscriptViewController()
        _ = controller.view
        controller.followsBottom = false
        controller.refreshJumpReading()
        try expect(
            controller.jumpControl.accessibilityLabel() == JumpReading.read(rowsNow: 0, rowsAtDeparture: nil, needsYou: false).spoken,
            "the jump control is spoken from Core's reading")
        try expect(
            controller.jumpControl.frame.height == 0
                || controller.jumpControl.frame.height >= CGFloat(ChatChrome.chip(on: .pointer).height),
            "the jump control is a chip")

        let flow = StarterFlow()
        flow.centered = false
        let answers = (1...3).map { index -> SymbolChip in
            let chip = SymbolChip()
            chip.text = "Answer number \(index)"
            chip.accented = index == 1
            return chip
        }
        flow.set(answers)
        stage(flow)
        func lines(at width: CGFloat) -> Int {
            flow.frame = NSRect(x: 0, y: 0, width: width, height: 0)
            flow.layout()
            return Set(answers.map { $0.frame.minY }).count
        }
        try expect(lines(at: 900) == 1, "three answers share a line when the card has room")
        try expect(lines(at: 200) > 1, "and break onto more lines instead of clipping a word")
        try expect(
            answers.allSatisfy { $0.frame.height >= CGFloat(ChatChrome.chip(on: .pointer).height) },
            "an answer chip is at least the table's height")

        let held = TranscriptViewController()
        let heldWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
            backing: .buffered, defer: true)
        heldWindow.contentView = held.view
        windows.append(heldWindow)
        let answered = message("b", .assistant, [MessagePart(id: "t", kind: .text("Done"))])
        let quiet = ConversationState(
            messages: [asked, answered], status: .idle, connection: .live, hasLoadedTranscript: true)
        held.show(state: quiet)
        held.view.layoutSubtreeIfNeeded()
        held.followsBottom = false
        held.show(state: quiet)
        let grown = message("b", .assistant, [MessagePart(id: "t", kind: .text("Done. Next"))])
        held.show(
            state: ConversationState(
                messages: [asked, grown], status: .running,
                pendingPermissions: [PermissionRequest(id: "p1", sessionID: "s", toolName: "Edit")],
                connection: .live, hasLoadedTranscript: true))
        try expect(
            held.jumpControl.text == Localized.text("Needs you"),
            "a permission that arrives while the reader is up the page says so on the jump chip (\(held.jumpControl.text))")
        held.show(
            state: ConversationState(
                messages: [asked, answered], status: .running, connection: .live,
                hasLoadedTranscript: true))
        try expect(
            held.jumpControl.text != Localized.text("Needs you"),
            "and stops saying it once nothing waits")
        heldWindow.contentView = nil
        windows.removeAll { $0 === heldWindow }

        func fan(_ count: Int) -> [TranscriptRow] {
            let parts = (1...count).map {
                MessagePart(
                    id: "s\($0)",
                    kind: .tool(ToolCall(id: "c\($0)", name: "Task", status: .completed)))
            }
            return TranscriptRow.rows(for: message("f\(count)", .assistant, parts))
        }
        let three = fan(3)
        try expect(
            three.count == 3 && three.allSatisfy { if case .subagent = $0.kind { true } else { false } },
            "three agents stay three cards")
        let five = fan(5)
        try expect(five.count == 1, "five agents collapse behind one row (\(five.count))")
        if let group = five.first {
            let view = group.makeView(context: context)
            stage(view)
            try expect(
                view.accessibilityLabel()?.contains(Localized.text("%lld agents", 5)) == true,
                "the group is named by its count")
            try expect(
                group.spacing == .row(.furniture), "the group sits as furniture, not as prose")
            try expect(
                group.kind.spawnedCalls.count == 5, "a fact about any agent still finds its row")
        }

        let now = Date()
        let agents = [
            SubagentSummary(id: "a", title: "a", updatedAt: now, isActive: true),
            SubagentSummary(id: "b", title: "b", updatedAt: now, isActive: true),
        ]
        let settled = StatusFacts.from(
            state: ConversationState(
                messages: [asked], status: .idle, connection: .live, hasLoadedTranscript: true),
            agents: agents, usage: nil, attachments: 0)
        try expect(
            settled.activeAgents == 0,
            "agents a server still calls active are not out under a turn that is over (\(settled.activeAgents))")
        let out = StatusFacts.from(
            state: ConversationState(
                messages: [asked], status: .running, connection: .live, hasLoadedTranscript: true),
            agents: agents, usage: nil, attachments: 0)
        try expect(out.activeAgents == 2, "both agents are out inside an open turn")
    }

    private static func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
    }

    static func column(_ expect: (Bool, String) throws -> Void) throws {
        func block(_ width: CGFloat, _ height: CGFloat) -> NSView {
            let view = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.flowWidth = width
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: width),
                view.heightAnchor.constraint(equalToConstant: height),
            ])
            return view
        }
        func stretched(_ height: CGFloat) -> NSView {
            let view = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.heightAnchor.constraint(equalToConstant: height).isActive = true
            return view
        }
        let column = TranscriptColumn()
        column.metrics = compact
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        stage(root)
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        let first = stretched(40)
        let line = stretched(24)
        let pictures = [block(260, 180), block(260, 180), block(260, 180), block(400, 120)]
        let last = stretched(40)
        column.addArrangedSubview(first, spacing: .row(.prose))
        column.addArrangedSubview(line, spacing: .row(.furniture))
        for picture in pictures { column.addArrangedSubview(picture, spacing: .row(.picture)) }
        column.addArrangedSubview(last, spacing: .row(.prose))
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        try expect(line.superview!.frame.minY == 44, "a line sits 4 under the prose above it")
        let stripTop = line.superview!.frame.maxY + 6
        let frames = pictures.map { $0.superview!.frame }
        try expect(
            frames[0].minY == stripTop && frames[1].minY == stripTop && frames[2].minY == stripTop,
            "the strip starts 6 under a line and three pictures share its top")
        try expect(
            frames[1].minX == 268 && frames[2].minX == 536 && frames[3].minX == 0,
            "pictures are 8 apart and the fourth wraps: \(frames.map(\.minX))")
        try expect(frames[3].minY == stripTop + 180 + 8, "the second line of the strip is 8 under the first")
        try expect(
            last.superview!.frame.minY == frames[3].maxY + 6,
            "prose after the strip is 6 under its last line")
        column.metrics = comfortable
        root.layoutSubtreeIfNeeded()
        try expect(
            line.superview!.frame.minY == 52,
            "choosing comfortable re-lays the column and gives the pointer's 12 back: \(line.superview!.frame.minY)")
    }

    static func quietLines(_ expect: (Bool, String) throws -> Void) throws {
        let column = TranscriptColumn()
        column.metrics = compact
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        stage(root)
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        let words = [
            "Background command finished: go test ./internal/auth/...",
            "Switched from Sonnet 5 to GPT-5.1 Codex at high effort",
        ]
        let rows = words.map {
            SeamLineView(
                symbol: "checkmark.circle", text: $0, tint: .secondaryLabelColor, spoken: $0,
                onPress: nil)
        }
        for row in rows { column.addArrangedSubview(row, spacing: .row(.furniture)) }
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        let hosts = rows.map { $0.superview! }
        try expect(
            hosts[0].frame.maxY <= hosts[1].frame.minY,
            "two note rows at 320 wide do not overlap: \(hosts.map(\.frame))")
        for row in rows {
            let outside = row.subviews.filter { !row.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) }
            try expect(
                outside.isEmpty && row.frame.height > CGFloat(compact.seamRowHeight),
                "a note's words stay inside its row, which grows to hold a second line: \(row.frame.height) tall")
        }
    }

    static func replacedRows(_ expect: (Bool, String) throws -> Void) throws {
        func line() -> NSView {
            let view = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return view
        }
        let column = TranscriptColumn()
        column.metrics = compact
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        stage(root)
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        var rows = (0..<8).map { _ in line() }
        for row in rows { column.addArrangedSubview(row, spacing: .row(.furniture)) }
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        let before = column.frame.height
        var heights: [CGFloat] = []
        column.postsFrameChangedNotifications = true
        let watch = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: column, queue: nil
        ) { _ in MainThread.call { heights.append(column.frame.height) } }
        defer { NotificationCenter.default.removeObserver(watch) }
        for round in 0..<4 {
            let at = rows.count - 1 - round
            let standing = rows[at].superview?.frame.height
            rows[at].removeFromSuperview()
            let fresh = line()
            column.insertArrangedSubview(fresh, at: at, spacing: .row(.furniture), standingIn: standing)
            rows[at] = fresh
            root.layoutSubtreeIfNeeded()
            root.layoutSubtreeIfNeeded()
        }
        try expect(
            heights.allSatisfy { $0 >= before - 0.5 } && abs(column.frame.height - before) < 0.5,
            "a row replaced by its next version never shortens the page, so a reader at the bottom is not moved: \(before) then \(heights)")
        let hosts = rows.compactMap { $0.superview?.frame }
        let overlapping = zip(hosts, hosts.dropFirst()).filter { $0.maxY > $1.minY + 0.5 }
        try expect(overlapping.isEmpty, "no two rows stand on each other after the replacements: \(hosts)")
    }

    static func promptFocus(_ expect: (Bool, String) throws -> Void) throws {
        let composer = ComposerView()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 240))
        stage(root)
        root.addSubview(composer)
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            composer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            composer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        let editor = composer.promptEditor
        let field = editor.fieldView
        let frame = field.convert(field.bounds, to: root)
        var misses: [String] = []
        var y = frame.minY + 1
        while y < frame.maxY - 1 {
            var x = frame.minX + 1
            while x < frame.maxX - 1 {
                let hit = root.hitTest(root.convert(NSPoint(x: x, y: y), to: root.superview))
                if !(hit === editor.focusTarget || hit?.isDescendant(of: editor.focusTarget) == true) {
                    misses.append("(\(Int(x - frame.minX)),\(Int(y - frame.minY))) \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
                }
                x += 5
            }
            y += 3
        }
        editor.vim.reset(to: "", cursor: 0, mode: .normal)
        try expect(editor.vim.mode == .normal, "the vim box can be left in normal mode, where it draws no caret")
        editor.pointerFocused(vimEnabled: true)
        try expect(
            editor.vim.mode == .insert,
            "a press that takes the keyboard for the vim box leaves it typing, with a caret")
        try expect(
            misses.isEmpty,
            "every point of the visible prompt box lands on the text view: \(misses.count) of them do not, first \(misses.prefix(4)) in a box \(frame.size)")
    }
}
