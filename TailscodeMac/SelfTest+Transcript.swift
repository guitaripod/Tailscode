import AgentTestSupport
import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// What the reader opened stays open while the turn that drew it keeps arriving. A step's place
    /// inside a run is not its identity — a lone call becomes the second step of a run the moment
    /// another joins it — so the key it was drawn under has to survive the fold that reshapes it.
    static func checkTranscriptRows() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("transcript row case failed: \(label)") }
            checks += 1
        }
        func call(_ id: String) -> ToolCall {
            ToolCall(id: id, name: "Read", status: .completed)
        }

        let lone = TranscriptRow.fuse([TranscriptRow(key: "m1:p1", kind: .tool(call("t1")))])
        try expect(
            lone.map(\.key) == ["run:m1:p1"], "a lone call already wears the key its run will")
        let fanned = TranscriptRow.fuse([
            TranscriptRow(key: "m1:p1", kind: .tool(call("t1"))),
            TranscriptRow(key: "m1:p2", kind: .tool(call("t2"))),
        ])
        try expect(
            fanned.map(\.key) == ["run:m1:p1"],
            "a second step joins that row instead of renaming it")
        guard case .run(let steps) = fanned.first?.kind else {
            throw SelfTestFailure("transcript row case failed: two calls fold into one run")
        }
        try expect(
            steps.map(\.key) == ["m1:p1", "m1:p2"], "and every step keeps the key its row had")
        try expect(
            TranscriptRow.fuse([
                TranscriptRow(key: "m1:p1", kind: .reasoning("first")),
                TranscriptRow(key: "m1:p2", kind: .reasoning("second")),
            ]).map(\.key) == ["m1:p1", "m1:p2"],
            "a run that never reached a tool stays its own thoughts, each still itself")

        let context = TranscriptContext()
        context.expanded.set("run:m1:p1", open: true)
        try expect(
            context.isExpanded("run:m1:p1"),
            "so the row opened while it was a lone call is still open once it is a run")
        context.expanded.set("run:m1:p1", open: false)
        try expect(!context.isExpanded("run:m1:p1"), "and closing it closes it")
        return checks
    }

    /// Where a row stands on the transcript's page is read in the page's own coordinates, and every
    /// reader of that number — the prompt that rises, the rows a reflow keeps still, the pictures
    /// near the reader, a find hit — compares it with a clip whose origin is the top. A stack view
    /// measures up from its bottom, and a page built from one read a prompt sent at the foot of a
    /// long conversation as standing near its head: every send scrolled the transcript to the top.
    /// So the page the transcript builds is laid out here, a row at a time, and read back.
    static func checkTranscriptPage() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("transcript page case failed: \(label)") }
            checks += 1
        }
        let page = TranscriptViewController.page()
        let rows = (0..<3).map { _ -> NSView in
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 120).isActive = true
            page.addArrangedSubview(row)
            return row
        }
        page.spacing = 10
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 800))
        host.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: host.topAnchor),
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        let tops = rows.map { $0.convert($0.bounds, to: page).minY }
        try expect(
            tops == [0, 130, 260],
            "each row reads as far from the top of the page as it is drawn, \(tops)")
        let last = rows[2].convert(rows[2].bounds, to: page)
        try expect(
            last.maxY == page.bounds.height,
            "so the prompt at the foot of the conversation reads as its foot, not its head")
        return checks
    }

    /// The transcript lays its rows out by hand so that no constraint joins one row to another, and
    /// the hand has to agree with the stack it replaced: rows top-down at the stack's spacing and as
    /// tall as the same rows in a stack, a row that grows pushing the rest down, an opened body
    /// making room for itself, a row taken out leaving with its host and closing its gap, and a
    /// hidden row taking no room until it shows again.
    static func checkTranscriptColumn() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else {
                throw SelfTestFailure("transcript column case failed: \(label)")
            }
            checks += 1
        }
        let sentence = String(repeating: "A sentence long enough to wrap across the page. ", count: 9)
        func rows() -> [NSView] {
            let fixed = NSView()
            fixed.translatesAutoresizingMaskIntoConstraints = false
            fixed.heightAnchor.constraint(equalToConstant: 40).isActive = true
            let disclosure = DisclosureRow(
                header: RowKit.label(
                    "thought", font: MacTheme.Ramp.font(.toolName), color: MacTheme.Color.label),
                expanded: false, onToggle: { _, _ in }
            ) {
                RowKit.wrapping(
                    sentence, font: MacTheme.Ramp.font(.cardBody), color: MacTheme.Color.label)
            }
            return [RowKit.attributedLabel(MacMarkdown.render(sentence)), fixed, disclosure]
        }
        func staged(_ column: NSView) -> NSView {
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 800))
            let window = NSWindow(
                contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: true)
            window.contentView = root
            column.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(column)
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: root.topAnchor),
                column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
            return root
        }
        let stack = FillingStack(topDown: true)
        stack.spacing = 12
        let stackRoot = staged(stack)
        let stacked = rows()
        for row in stacked { stack.addArrangedSubview(row) }
        stackRoot.layoutSubtreeIfNeeded()

        let column = TranscriptColumn()
        column.spacing = 12
        let root = staged(column)
        let placed = rows()
        for row in placed { column.addArrangedSubview(row) }
        root.layoutSubtreeIfNeeded()
        func top(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: column).minY }

        try expect(
            top(placed[0]) == 0 && top(placed[1]) == placed[0].frame.height + 12
                && top(placed[2]) == top(placed[1]) + 52,
            "rows stand top-down at the spacing")
        try expect(
            zip(stacked, placed).allSatisfy { abs($0.frame.height - $1.frame.height) < 0.5 },
            "each row is as tall as it is in a stack")
        try expect(
            abs(column.intrinsicContentSize.height - stack.fittingSize.height) < 1,
            "the column is as tall as the stack")

        let below = top(placed[2])
        (placed[0] as? NSTextField)?.attributedStringValue = MacMarkdown.render(sentence + sentence)
        root.layoutSubtreeIfNeeded()
        try expect(top(placed[2]) > below, "a row that grows moves every row under it")

        let closed = column.intrinsicContentSize.height
        _ = (placed[2] as? DisclosureRow)?.accessibilityPerformPress()
        root.layoutSubtreeIfNeeded()
        try expect(column.intrinsicContentSize.height > closed, "an opened body makes room for itself")

        placed[1].removeFromSuperview()
        root.layoutSubtreeIfNeeded()
        try expect(
            column.arrangedSubviews.count == 2 && column.subviews.count == 2,
            "a row taken out leaves with its host")
        try expect(top(placed[2]) == placed[0].frame.height + 12, "and its gap closes")

        placed[0].isHidden = true
        root.layoutSubtreeIfNeeded()
        try expect(top(placed[2]) == 0, "a hidden row takes no room")
        placed[0].isHidden = false
        root.layoutSubtreeIfNeeded()
        try expect(top(placed[2]) == placed[0].frame.height + 12, "and takes it back when shown")
        return checks
    }

    /// What can be pressed answers the pointer before the press: a thought's header comes up under
    /// the pointer, deepens on the press, opens on a release over it and not on one dragged away,
    /// and takes the first click on a window that is not in front; a borderless button takes a
    /// plate and gives it back; and a chat row trades its age for its verbs while it is hovered.
    static func checkPointerFeedback() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("pointer case failed: \(label)") }
            checks += 1
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        let window = NSWindow(
            contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = root
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
            switch type {
            case .mouseEntered, .mouseExited:
                return NSEvent.enterExitEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    trackingNumber: 0, userData: nil)
            default:
                return NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1)
            }
        }

        var opened = 0
        let row = DisclosureRow(
            header: RowKit.label(
                "thought", font: MacTheme.Ramp.font(.toolName), color: MacTheme.Color.label),
            expanded: false, onToggle: { open, _ in if open { opened += 1 } }
        ) {
            RowKit.label("body", font: MacTheme.Ramp.font(.cardBody), color: MacTheme.Color.label)
        }
        row.frame = NSRect(x: 20, y: 200, width: 400, height: 40)
        root.addSubview(row)
        root.layoutSubtreeIfNeeded()
        let surface = row.headerSurface
        let inside = surface.convert(NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
        let outside = NSPoint(x: 5, y: 5)

        try expect(surface.acceptsFirstMouse(for: nil), "a header takes the first click on a window behind")
        try expect(
            surface.hitTest(surface.convert(inside, from: nil).applying(.identity)) != nil
                && root.hitTest(root.convert(inside, from: nil)) === surface,
            "a press anywhere on the header is a press on the header")
        try expect(surface.plateLevel == .rest, "a header nobody points at wears nothing")
        if let entered = event(.mouseEntered, at: inside) { surface.mouseEntered(with: entered) }
        try expect(surface.plateLevel == .hover, "the pointer arriving brings the plate up")
        if let down = event(.leftMouseDown, at: inside) { surface.mouseDown(with: down) }
        try expect(surface.plateLevel == .press, "the button going down deepens it at once")
        if let up = event(.leftMouseUp, at: outside) { surface.mouseUp(with: up) }
        try expect(opened == 0 && row.bodyView == nil, "a press dragged away and let go opens nothing")
        if let down = event(.leftMouseDown, at: inside) { surface.mouseDown(with: down) }
        if let up = event(.leftMouseUp, at: inside) { surface.mouseUp(with: up) }
        try expect(opened == 1 && row.bodyView != nil, "a release over the header opens the body")
        try expect(surface.plateLevel == .hover, "and the plate settles back to the pointer")
        if let exited = event(.mouseExited, at: outside) { surface.mouseExited(with: exited) }
        try expect(surface.plateLevel == .rest, "the pointer leaving takes it away")

        let button = RowKit.linkButton("copy") {}
        button.frame = NSRect(x: 20, y: 20, width: 60, height: 20)
        root.addSubview(button)
        HoverPlate.attach(to: button)
        HoverPlate.simulate(true, on: button)
        try expect(HoverPlate.isShowing(on: button), "a borderless button takes a plate under the pointer")
        HoverPlate.simulate(false, on: button)
        try expect(!HoverPlate.isShowing(on: button), "and gives it back")
        button.isEnabled = false
        HoverPlate.simulate(true, on: button)
        try expect(!HoverPlate.isShowing(on: button), "a button that cannot be pressed never offers to be")

        let session = AgentSession(
            id: "pointer-probe", agentType: .claudeCode, title: "pointer probe",
            directory: "/tmp/pointer", createdAt: Date(), updatedAt: Date())
        let entry = SessionEntry(
            profileID: "probe", profileName: "probe", host: "probe", backendType: .claudeCode,
            session: session)
        let cell = SidebarSessionCell()
        cell.configure(
            with: SessionRowModel(entry: entry, unreachable: false, unread: false, saved: false),
            marked: false)
        try expect(!cell.showsQuickActions, "a chat row nobody points at shows its age")
        cell.setHovered(SidebarQuickState(pinned: false, saved: true, archived: false))
        try expect(cell.showsQuickActions, "a hovered chat row offers its verbs")
        cell.setHovered(nil)
        try expect(!cell.showsQuickActions, "and puts its age back when the pointer leaves")

        let now = Date()
        let answer = ChatMessage(
            id: "hover-probe", role: .assistant, agentType: .claudeCode,
            parts: [
                MessagePart(id: "a", kind: .text("First **paragraph**.")),
                MessagePart(id: "b", kind: .reasoning("not for copying")),
                MessagePart(id: "c", kind: .text("Second.")),
            ], createdAt: now)
        try expect(
            MessageHoverBar.words(of: answer) == "First **paragraph**.\n\nSecond.",
            "a message's Copy is its words as written, thoughts left out")
        try expect(
            MessageHoverBar.stamp(now, now: now) == now.formatted(date: .omitted, time: .shortened),
            "a message written today is stamped with its time alone")
        try expect(
            MessageHoverBar.stamp(now.addingTimeInterval(-3 * 86_400), now: now).count
                > MessageHoverBar.stamp(now, now: now).count,
            "and an older one says which day")
        return checks
    }

    /// The subagent row's live line, which is the whole of what a reader saw go wrong: a sidecar
    /// still calling itself busy under a call that had already reported back, beside a clock that
    /// grew every time the transcript was opened. Proved by drawing the row at stated moments,
    /// because what a row claims about time is a reading rather than an animation to watch.
    static func checkSubagentRow() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("subagent row case failed: \(label)") }
            checks += 1
        }
        let began = Date(timeIntervalSince1970: 1_700_000_000)
        let over = began.addingTimeInterval(252)
        let week = over.addingTimeInterval(604_800)
        let context = TranscriptContext()
        let errand = SubagentSummary(
            id: "a", title: "hunt", updatedAt: over.addingTimeInterval(1_800), isActive: true,
            startedAt: began)
        let settled = SubagentSummary(
            id: "a", title: "hunt", updatedAt: over, isActive: true, isCompleted: true,
            startedAt: began)
        func reading(_ status: ToolStatus, _ agent: SubagentSummary, read now: Date) -> String {
            context.agentFacts = ["t": agent]
            context.agentReadAt = now
            return SubagentRowView.reading(
                of: SubagentRowView.make(
                    ToolCall(id: "t", name: "Task", status: status), key: "agent", context: context)
            )
        }

        try expect(
            reading(.running, errand, read: over) == StatusFacts.clock(252),
            "an agent still out under a running call is timed to the moment its facts arrived")
        try expect(
            reading(.running, errand, read: week) != reading(.running, errand, read: over),
            "which is what makes it a clock while the work holding it is still going")
        try expect(
            reading(.running, settled, read: week) == StatusFacts.clock(252),
            "an agent that reported finishing keeps its own length, however long the call runs on")
        try expect(
            reading(.completed, errand, read: week) == Localized.text("done"),
            "a call that reported back says so, whatever its sidecar's record still claims")
        try expect(
            reading(.completed, errand, read: week) == reading(.completed, errand, read: over),
            "so a transcript reopened a week later reads exactly what it read on the day")
        for ending in [ToolStatus.error, .pending] {
            try expect(
                reading(ending, errand, read: week).isEmpty,
                "and no call that is not running has a working agent under it to report")
        }
        return checks
    }
}
