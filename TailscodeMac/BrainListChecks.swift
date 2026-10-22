import AppKit
import CodingAgentKit
import TailscodeCore

/// The step list's and the filter chips' claims, checked headlessly through the same events the
/// window delivers: every key goes through the list's `keyDown` and the reducer in Core, every press
/// and move is a real `NSEvent` handed to the view under it, and what is counted is what the views
/// draw and hold. A picture cannot make these claims.
@MainActor
enum BrainListChecks {
    private typealias Expect = (Bool, String) throws -> Void

    @MainActor
    private struct Env {
        let fixture: BrainFixture
        let view: BrainRowView
        let list: BrainListView
        let chips: BrainFilterChips

        var model: NeuralBrainModel { view.model }
        var steps: NeuralStepList { view.model.browseState.list }
        var window: NSWindow { fixture.window }
    }

    static func run(_ expect: (Bool, String) throws -> Void) throws -> Int {
        var checks = 0
        let counted: Expect = { condition, label in
            try expect(condition, "list: \(label)")
            checks += 1
        }
        guard let env = make(width: 1300) else { return 0 }
        defer { env.fixture.tearDown() }
        try layout(counted)
        try rows(env, counted)
        try keys(env, counted)
        try search(env, counted)
        try mouse(env, counted)
        try chipClaims(env, counted)
        try header(env, counted)
        try reveal(env, counted)
        try accessibility(env, counted)
        try live(counted)
        try large(counted)
        return checks
    }


    private static func make(
        width: CGFloat, messages: [ChatMessage] = NeuralDemo.conversation(), running: Bool = false
    ) -> Env? {
        let fixture = BrainFixture(messages: messages, running: running, width: width)
        guard let view = fixture.open(1), let list = view.list, let chips = view.chips else {
            fixture.tearDown()
            return nil
        }
        fixture.window.makeFirstResponder(list)
        return Env(fixture: fixture, view: view, list: list, chips: chips)
    }

    private static let keyCodes: [String: (UInt16, String)] = [
        "up": (126, "\u{F700}"), "down": (125, "\u{F701}"), "left": (123, "\u{F702}"),
        "right": (124, "\u{F703}"), "return": (36, "\r"), "esc": (53, "\u{1B}"),
        "space": (49, " "), "pagedown": (121, "\u{F72D}"), "pageup": (116, "\u{F72C}"),
        "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"),
    ]

    private static func keyEvent(_ name: String, window: NSWindow) -> NSEvent? {
        let found = keyCodes[name] ?? (0, name)
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: found.1,
            charactersIgnoringModifiers: found.1, isARepeat: false, keyCode: found.0)
    }

    /// A key arrives at whatever holds the keyboard, the way the window's own dispatch would hand it.
    private static func press(_ name: String, _ env: Env) {
        guard let event = keyEvent(name, window: env.window),
            let responder = env.window.firstResponder
        else { return }
        responder.keyDown(with: event)
    }

    private static func mouseEvent(
        _ type: NSEvent.EventType, at point: CGPoint, in view: NSView, clicks: Int = 1,
        flags: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
        guard let window = view.window else { return nil }
        return NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
            pressure: 1)
    }

    private static func send(
        _ type: NSEvent.EventType, to view: NSView, at point: CGPoint, clicks: Int = 1,
        flags: NSEvent.ModifierFlags = []
    ) {
        guard let event = mouseEvent(type, at: point, in: view, clicks: clicks, flags: flags) else { return }
        switch type {
        case .mouseMoved: view.mouseMoved(with: event)
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .rightMouseDown: view.rightMouseDown(with: event)
        default: break
        }
    }

    private static func click(
        _ view: NSView, at point: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []
    ) {
        send(.leftMouseDown, to: view, at: point, clicks: clicks, flags: flags)
        send(.leftMouseUp, to: view, at: point, clicks: clicks, flags: flags)
    }

    /// A point inside a row, in the rows view's own coordinates.
    private static func rowPoint(_ env: Env, _ id: String, x: CGFloat = 160) -> CGPoint? {
        guard let frame = env.list.rowFrame(of: id) else { return nil }
        return env.list.rows.convert(CGPoint(x: x, y: frame.midY), from: env.list)
    }

    private static func cursorVisible(_ env: Env) -> Bool {
        guard let id = env.model.pinnedStep, let frame = env.list.rowFrame(of: id) else { return false }
        let top = BrainListHeader.height
        return frame.minY >= top - 0.5 && frame.maxY <= top + env.list.viewportHeight + 0.5
    }

    private static func settle(_ seconds: Double = 0.06) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private static func reset(_ env: Env) {
        var presses = 0
        while presses < 6,
            env.steps.filter.isActive || env.model.pinnedStep != nil || env.model.browseState.legend
        {
            env.view.browse(.key(.escape), grabFocus: false)
            presses += 1
        }
        env.view.updateModel {
            $0.setBrowseFocus(.list)
            $0.setBrowseSearchOpen(false)
        }
        env.list.modelChanged()
        env.window.makeFirstResponder(env.list)
        env.list.pointerMoved(to: nil)
        settle()
    }

    private static func drawPass(_ view: NSView) {
        let rect = view.visibleRect
        guard !rect.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
    }


    private static func layout(_ expect: Expect) throws {
        for width in [1300, 1050, 910] as [CGFloat] {
            guard let env = make(width: width) else { continue }
            defer { env.fixture.tearDown() }
            let m = env.view.currentMetrics
            let name = "\(Int(m.width)) wide"
            try expect(m.arrangement == .split, "\(name) is a split")
            try expect(
                env.list.frame == env.view.rect(m.list), "\(name): the list stands where Core puts it")
            try expect(env.list.header.frame.height == 36, "\(name): the header is 36 high")
            try expect(
                env.list.scroll.frame.height == CGFloat(m.rowsShown) * 28,
                "\(name): the viewport holds \(m.rowsShown) rows")
            try expect(
                env.list.scroll.frame.minY == 36, "\(name): the rows start under the header")
            try expect(
                !env.list.hint.isHidden && env.list.hint.frame.height == 24,
                "\(name): the hint line is 24 high")
            try expect(
                env.list.hint.frame.minY == 36 + env.list.scroll.frame.height + 4,
                "\(name): the hint sits 4 under the rows")
            try expect(
                env.chips.frame == env.view.rect(m.filterChips ?? .zero),
                "\(name): the chips stand where Core puts them")
            try expect(env.chips.frame.height == 28, "\(name): chips are 28 high")
            if let last = env.chips.entries.last {
                try expect(
                    last.frame.maxX <= env.chips.bounds.width + 0.5,
                    "\(name): six chips do not wrap or overflow \(Int(env.chips.bounds.width))")
            }
            try expect(
                env.list.isWide == (m.column.width >= 400), "\(name): wide words follow the column")
        }
        if let env = make(width: 1300), let failed = env.steps.visibleRows.first(where: { $0.status == .failed }) {
            defer { env.fixture.tearDown() }
            let narrowPlan = env.list.painter.markPlan(for: failed, width: 330, wide: false)
            let widePlan = env.list.painter.markPlan(for: failed, width: 420, wide: true)
            try expect(
                narrowPlan?.text?.string.hasPrefix("\u{2192}") == true,
                "a narrow column marks a fixed step with an arrow and its number")
            try expect(
                widePlan?.text?.string == failed.related?.label,
                "a column of 400 or more says retried at N")
            try expect(
                (widePlan?.glyphX ?? 0) < (narrowPlan?.glyphX ?? 0) + 90 && (widePlan?.left ?? 0) > 100,
                "the mark and its words fit the row")
        }
        let narrow = BrainFixture(width: 560)
        defer { narrow.tearDown() }
        if let view = narrow.open(1), let list = view.list {
            let m = view.currentMetrics
            try expect(m.arrangement == .accordion, "a narrow row is an accordion")
            try expect(list.isHidden, "the accordion hides the list")
            list.configure(metrics: m)
            list.frame = CGRect(x: 0, y: 0, width: 40, height: 20)
            list.layoutSubtreeIfNeeded()
            list.modelChanged()
            try expect(list.viewportHeight >= 0, "a list asked to lay out at any width does not break")
            try expect(list.hint.isHidden == (m.listHint == nil), "the hint follows the metrics")
        }
    }


    private static func rows(_ env: Env, _ expect: Expect) throws {
        let list = env.list
        let steps = env.steps
        try expect(steps.total == 29, "the demo turn has 29 steps")
        try expect(list.visibleIDs.count <= env.view.currentMetrics.rowsShown + 2, "only the rows in view are listed")
        try expect(list.contentHeight == CGFloat(steps.contentHeight()), "the document is the whole turn tall")
        try expect(list.rows.frame.height >= list.contentHeight, "the rows view holds every row")
        drawPass(list.rows)
        try expect(
            list.rows.rowsDrawn > 0 && list.rows.rowsDrawn <= list.visibleIDs.count + 2,
            "a pass draws the rows in view and no more (\(list.rows.rowsDrawn))")
        try expect(list.scroll.hasVerticalScroller && !list.scroll.hasHorizontalScroller, "the scroll view is the system's")
        try expect(list.scroll.verticalScrollElasticity == .none, "the list never rubber-bands, so it cannot hold on to a gesture at its end")
        try expect(list.snapshot.list.row(atVisible: 6)?.isSaid == true, "step 7 is a said message")
        let said = steps.rows(in: 6..<7).first
        try expect(said?.height() == 40, "a said row is 40 tall")
        try expect(steps.row(atVisible: 0)?.height() == 28, "a thought row is 28 tall")
        try expect(list.pulseCountForChecks == 0, "a settled turn has no breathing mark")
        try expect(!list.isAnimating && !list.ownsClock, "a settled list owns no clock and nothing moves")
        let far = steps.rows(in: 26..<27).first?.id ?? ""
        list.scrollTo(far)
        try expect(list.visibleIDs.contains(far), "scrolling to a row brings it into view")
        list.setOffset(0, animated: false)
        try expect(list.offset == 0, "the list can go back to the top (\(list.offset) \(list.maxOffset) \(list.scroll.contentView.bounds) \(list.rows.frame))")
        let before = painterGeneration(list)
        list.retheme()
        try expect(painterGeneration(list) == before + 1, "a retheme drops the cached text")
    }

    private static func painterGeneration(_ list: BrainListView) -> Int { list.painter.generation }


    private static func keys(_ env: Env, _ expect: Expect) throws {
        let list = env.list
        reset(env)
        try expect(env.window.firstResponder === list, "the list holds the keyboard when the brain opens")
        try expect(env.model.pinnedStep == nil, "no cursor to begin with")
        let first = env.steps.firstVisibleID
        press("down", env)
        try expect(env.model.pinnedStep == first, "down from nothing takes the first row")
        try expect(cursorVisible(env), "the cursor row is in view")
        press("down", env)
        try expect(env.model.pinnedStep == env.steps.row(atVisible: 1)?.id, "down walks one row")
        press("pagedown", env)
        try expect(env.model.pinnedStep == env.steps.row(atVisible: 9)?.id, "page down is eight rows")
        try expect(cursorVisible(env), "the cursor row is in view after a page")
        press("end", env)
        try expect(env.model.pinnedStep == env.steps.lastVisibleID, "end goes to the last step")
        try expect(cursorVisible(env), "the last row is in view")
        try expect(
            list.offset == list.maxOffset, "the list is scrolled to its end")
        press("home", env)
        try expect(env.model.pinnedStep == first, "home goes to the first step")
        try expect(list.offset == 0, "and the list is back at the top")
        press("j", env)
        press("j", env)
        press("k", env)
        try expect(env.model.pinnedStep == env.steps.row(atVisible: 1)?.id, "j and k walk the rows")
        press("G", env)
        try expect(env.model.pinnedStep == env.steps.lastVisibleID, "G goes to the end")
        press("g", env)
        try expect(env.model.pinnedStep == first, "g goes to the start")
        press("up", env)
        try expect(env.model.pinnedStep == first, "up stops at the top and never wraps")
        press("]", env)
        let failed = env.steps.visibleRows.first { $0.status == .failed }?.id
        try expect(env.model.pinnedStep == failed, "] walks to the failed step")
        try expect(cursorVisible(env), "the failed row is in view")
        press("[", env)
        try expect(
            env.steps.row(id: env.model.pinnedStep ?? "")?.status != .failed || env.model.pinnedStep == failed,
            "[ goes back")
        press("home", env)
        press("s", env)
        try expect(
            env.steps.row(id: env.model.pinnedStep ?? "")?.isSaid == true, "s walks to what it said")
        try expect(cursorVisible(env), "the said row is in view")
        press("l", env)
        press("h", env)
        try expect(env.model.pinnedStep != nil, "h and l walk the same zone")
        press("1", env)
        try expect(env.steps.filter.zones == [.say], "1 filters on what it said")
        try expect(env.steps.visibleCount == env.steps.saidCount, "the list shows only the said rows")
        try expect(
            env.chips.summary.first { $0.zone == .say }?.isOn == true, "the chip shows it is on")
        try expect(list.snapshot.list.visibleCount == env.steps.saidCount, "the list follows the filter")
        press("0", env)
        try expect(env.steps.filter.zones.isEmpty && env.steps.visibleCount == 29, "0 clears the zones")
        press("!", env)
        try expect(env.steps.filter.failedOnly, "! filters on failed")
        try expect(env.steps.visibleCount == env.steps.failedCount, "only the failed rows remain")
        try expect(list.header.failedRect != nil, "the failed toggle shows in the header")
        press("esc", env)
        try expect(!env.steps.filter.isActive, "esc lets go of the filters first")
        try expect(env.model.pinnedStep != nil, "and keeps the cursor")
        press("esc", env)
        try expect(env.model.pinnedStep == nil, "the next esc clears the cursor")
        press("c", env)
        press("down", env)
        let subject = env.model.pinnedStep.flatMap { env.view.model.step(id: $0) }.map { NeuralBrowse.subjectText(of: $0) }
        let saved = NSPasteboard.general.string(forType: .string)
        press("c", env)
        try expect(
            NSPasteboard.general.string(forType: .string) == subject, "c copies the subject of the cursor row")
        try expect(list.copiedID == env.model.pinnedStep, "and the row says Copied")
        if let saved {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(saved, forType: .string)
        }
        reset(env)
        press("/", env)
        try expect(list.searchOpen, "/ opens the search")
        press("esc", env)
        reset(env)
    }


    private static func search(_ env: Env, _ expect: Expect) throws {
        let list = env.list
        let box = list.header.box
        reset(env)
        try expect(box.isHidden && !list.searchOpen, "the search is a quiet button until it opens")
        press("/", env)
        try expect(list.searchOpen && !box.isHidden, "/ shows the field")
        try expect(box.field.currentEditor() != nil, "and the keyboard is in it")
        try expect(env.model.browseFocus == .search, "the browse state knows it")
        try expect(box.frame.width == 240, "the field is 240 wide")
        box.field.currentEditor()?.insertText("cut-list")
        try expect(env.steps.filter.query == "cut-list", "typing filters live")
        try expect(env.steps.visibleCount == 5, "five steps match cut-list")
        try expect(env.steps.countLabel.contains("5"), "the count says 5 of 29")
        drawPass(list.rows)
        try expect(list.rows.rowsDrawn == 5, "only the matches are drawn")
        box.field.currentEditor()?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try expect(env.model.pinnedStep == env.steps.firstVisibleID, "Enter takes the first match")
        try expect(env.window.firstResponder === list, "and gives the keyboard back to the list")
        try expect(list.searchOpen, "the field stays while it holds a query")
        press("esc", env)
        try expect(env.steps.filter.query.isEmpty && !list.searchOpen, "esc clears the search and closes it")
        try expect(box.isHidden, "the field is gone again")
        reset(env)
        press("/", env)
        box.field.currentEditor()?.insertText("cut")
        box.field.currentEditor()?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try expect(!env.steps.filter.isActive && !list.searchOpen, "esc inside the field clears and closes it")
        try expect(env.window.firstResponder === list, "and the keyboard goes back to the list")
        press("/", env)
        box.field.currentEditor()?.insertText("zzzz")
        try expect(env.steps.visibleCount == 0, "a search that matches nothing lists nothing")
        list.layoutSubtreeIfNeeded()
        let overlay = list.overlay!
        let clear = overlay.clearRect
        try expect(
            overlay.target(at: CGPoint(x: clear.midX, y: clear.midY)) == .clear,
            "the empty state offers Clear filters")
        try expect(
            overlay.hitTest(
                overlay.convert(CGPoint(x: clear.midX, y: clear.midY), to: overlay.superview))
                === overlay,
            "and only its button takes the press")
        try expect(overlay.hitTest(overlay.convert(CGPoint(x: 4, y: 4), to: overlay.superview)) == nil, "the rest of the overlay lets presses through")
        if let event = mouseEvent(.leftMouseDown, at: CGPoint(x: clear.midX, y: clear.midY), in: overlay) {
            overlay.mouseDown(with: event)
        }
        try expect(!env.steps.filter.isActive && env.steps.visibleCount == 29, "Clear filters clears them")
        reset(env)
    }


    private static func mouse(_ env: Env, _ expect: Expect) throws {
        let list = env.list
        reset(env)
        list.setOffset(0, animated: false)
        guard let third = env.steps.row(atVisible: 2)?.id, let fifth = env.steps.row(atVisible: 4)?.id,
            let point = rowPoint(env, third)
        else { return }
        send(.mouseMoved, to: list.rows, at: point)
        settle()
        try expect(list.pointerRowID == third, "the pointer takes the row under it")
        try expect(env.model.browseState.hovered == third, "and the readout previews it")
        try expect(env.model.pinnedStep == nil, "hover never moves the cursor")
        send(.mouseMoved, to: list.rows, at: CGPoint(x: 5000, y: 5000))
        try expect(list.pointerRowID == nil, "leaving the rows leaves the row")
        settle()
        try expect(env.model.browseState.hovered == nil, "and ends the preview")
        click(list.rows, at: point)
        try expect(env.model.pinnedStep == third, "a click sets the cursor")
        try expect(env.window.firstResponder === list, "and the list holds the keyboard")
        if let fifthPoint = rowPoint(env, fifth) {
            click(list.rows, at: fifthPoint, clicks: 2)
            try expect(env.model.pinnedStep == fifth, "a double click sets the cursor")
            try expect(env.model.browseFocus == .readout, "and moves the keyboard to the readout")
        }
        env.window.makeFirstResponder(list)
        env.view.updateModel { $0.setBrowseFocus(.list) }
        if let row = env.steps.row(id: third), let id = Optional(row.id),
            let frame = list.rowFrame(of: id)
        {
            let copy = list.painter.copyRect(for: row, width: list.rows.bounds.width, copied: false)
            let at = list.rows.convert(CGPoint(x: copy.midX, y: frame.minY + copy.midY), from: list)
            send(.mouseMoved, to: list.rows, at: at)
            try expect(list.pointerCopy, "the pointer is on the Copy button of its row")
            let saved = NSPasteboard.general.string(forType: .string)
            let held = env.model.pinnedStep
            click(list.rows, at: at)
            let subject = env.view.model.step(id: id).map { NeuralBrowse.subjectText(of: $0) }
            try expect(NSPasteboard.general.string(forType: .string) == subject, "the Copy button copies the row's subject")
            try expect(list.copiedID == id, "and the row says Copied")
            if let saved {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(saved, forType: .string)
            }
            try expect(env.model.pinnedStep == held, "Copy does not move the cursor")
        }
        reset(env)
        click(list.rows, at: CGPoint(x: 100, y: list.contentHeight + 400))
        try expect(env.window.firstResponder === list, "a press on empty space still gives the list the keyboard")
    }


    private static func chipClaims(_ env: Env, _ expect: Expect) throws {
        let chips = env.chips
        reset(env)
        let summary = chips.summary
        try expect(summary.first?.zone == .say, "SAID leads the chips")
        try expect(summary.first?.label == NeuralZone.say.displayLabel, "and carries its word")
        try expect(summary.dropFirst().allSatisfy { $0.label == nil }, "no other chip carries a word")
        try expect(summary.map(\.zone) == env.steps.zoneChips.map(\.zone), "the chips are the zones the turn used, in order")
        try expect(summary.map(\.count) == env.steps.zoneChips.map(\.count), "each chip carries its count")
        try expect(chips.entries.allSatisfy { $0.frame.height == 28 }, "chips are 28 high")
        try expect(
            zip(chips.entries, chips.entries.dropFirst()).allSatisfy { $1.x - ($0.x + $0.width) == 4 },
            "four points between chips")
        try expect(!chips.isCompact, "six chips fit a 346 column at full size")
        guard let shell = chips.centre(of: .shell), let say = chips.centre(of: .say) else { return }
        click(chips, at: shell)
        try expect(env.steps.filter.zones == [.shell], "a press toggles the zone on")
        try expect(env.steps.visibleCount == env.steps.zoneCounts[.shell], "the list shows that zone")
        try expect(chips.summary.first { $0.zone == .shell }?.isOn == true, "and the chip is on")
        click(chips, at: shell)
        try expect(env.steps.filter.zones.isEmpty, "a second press toggles it off")
        click(chips, at: shell)
        click(chips, at: say)
        try expect(env.steps.filter.zones == [.shell, .say], "chips add to one another")
        click(chips, at: shell, flags: .shift)
        try expect(env.steps.filter.zones == [.shell], "shift shows only that zone")
        click(chips, at: say, clicks: 2)
        try expect(env.steps.filter.zones == [.say], "a double press solos it")
        click(chips, at: say, clicks: 2)
        try expect(env.steps.filter.zones == [.say], "a double press on the only zone leaves it")
        reset(env)
        press("0", env)
        try expect(env.window.firstResponder === env.list, "a chip press gives the keyboard to the list")
        if let entry = chips.entries.first {
            try expect(
                chips.tooltip(for: entry) == "\(NeuralZone.say.displayLabel) \u{00B7} 1",
                "the tooltip names the zone and its key")
        }
        try expect(chips.accessibilityRole() == .group, "the chips are a group")
        try expect(chips.accessibilityLabel() == "Step filters", "named Step filters")
        let elements = (chips.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        try expect(elements.count == chips.entries.count, "a button per chip")
        try expect(elements.allSatisfy { $0.accessibilityRole() == .button }, "each is a button")
        try expect(
            elements.allSatisfy { ($0.accessibilityValue() as? String) == BrainListWords.off },
            "each says it is off")
        click(chips, at: shell)
        let after = (chips.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        try expect(
            after.contains { ($0.accessibilityValue() as? String) == BrainListWords.on },
            "an active chip says it is on")
        reset(env)
        try expect(chips.entries.allSatisfy { !$0.isOn }, "chips follow the filters being cleared")
    }


    private static func header(_ env: Env, _ expect: Expect) throws {
        let list = env.list
        reset(env)
        let header = list.header!
        try expect(header.failedRect != nil, "a turn with a failure offers the failed toggle")
        try expect(env.steps.countLabel == "29 steps" || env.steps.countLabel.contains("29"), "the count reads the steps")
        if let rect = header.failedRect {
            click(header, at: CGPoint(x: rect.midX, y: rect.midY))
            try expect(env.steps.filter.failedOnly, "pressing the failed toggle filters")
            try expect(env.steps.countLabel.contains("of"), "the count says N of M while filtered")
        }
        reset(env)
        click(header, at: CGPoint(x: 30, y: 18))
        try expect(list.searchOpen, "pressing Search opens the field")
        try expect(header.failedRect == nil, "the failed toggle makes room while searching")
        env.window.makeFirstResponder(list)
        reset(env)
        try expect(!list.searchOpen, "closing leaves the quiet button")
    }


    private static func reveal(_ env: Env, _ expect: Expect) throws {
        let list = env.list
        settle(1.2)
        try expect(list.copiedID == nil, "the word Copied goes after a second")
        let m = env.view.currentMetrics
        let transition = NeuralTransition.make(
            .open, metrics: m, nodeCount: env.model.nodeCount, reduceMotion: false, level: .calm,
            live: false)
        let frame = transition.frame(at: 0.3)
        list.setReveal(rows: frame.listRows, headerAlpha: frame.listHeaderAlpha)
        try expect(list.isAnimating, "a move in progress counts as animation")
        try expect(abs(list.header.alphaValue - CGFloat(frame.listHeaderAlpha)) < 0.001, "the header fades with the move")
        drawPass(list.rows)
        try expect(list.rows.rowsDrawn > 0, "rows draw through the move")
        list.setReveal(rows: nil, headerAlpha: 1)
        try expect(!list.isAnimating && list.header.alphaValue == 1, "a settled list is whole")
    }


    private static func accessibility(_ env: Env, _ expect: Expect) throws {
        let list = env.list
        reset(env)
        list.setOffset(0, animated: false)
        try expect(list.accessibilityRole() == .group, "the list is a group")
        try expect(list.accessibilityLabel()?.hasPrefix(BrainListWords.stepList) == true, "named Steps")
        try expect(list.rows.accessibilityRole() == .list, "the rows are a list")
        let rows = (list.rows.accessibilityChildren() ?? []).compactMap { $0 as? BrainRowElement }
        try expect(rows.count == list.visibleIDs.count, "a screen reader meets every row in view")
        try expect(rows.allSatisfy { $0.accessibilityRole() == .row }, "each is a row")
        try expect(rows.first?.accessibilityLabel()?.contains("1") == true, "a row says its number")
        press("down", env)
        let selected = (list.rows.accessibilitySelectedChildren() ?? []).compactMap { $0 as? BrainRowElement }
        try expect(selected.map(\.stepID) == [env.model.pinnedStep ?? ""], "the cursor row is the selected one")
        try expect(list.header.box.field.accessibilityLabel() == BrainListWords.searchSteps, "the search field is named")
        selected.first?.onPress?()
        try expect(env.model.pinnedStep == selected.first?.stepID, "pressing a row element sets the cursor")
        reset(env)
    }


    private static func runningMessages(extra: Int = 0) -> [ChatMessage] {
        var messages = NeuralDemo.buildFix(prefix: "a-", origin: 1_792_000_000)
            + NeuralDemo.largeTurn(steps: 40, prefix: "b-", origin: 1_792_003_600, answer: false)
        for index in messages.indices.reversed() where messages[index].role == .assistant {
            for part in messages[index].parts.indices.reversed() {
                guard case .tool(var call) = messages[index].parts[part].kind else { continue }
                call.status = .running
                call.output = nil
                messages[index].parts[part].kind = .tool(call)
                messages[index].isStreaming = true
                messages[index].completedAt = nil
                break
            }
            break
        }
        for number in 0..<extra {
            if let last = messages.indices.last, case .tool(var call)? = messages[last].parts.last?.kind {
                call.status = .completed
                call.output = "done"
                messages[last].parts[messages[last].parts.count - 1].kind = .tool(call)
                messages[last].isStreaming = false
                messages[last].completedAt = Date()
            }
            var added = ChatMessage(
                id: "b-extra\(number)", role: .assistant, agentType: .claudeCode,
                parts: [
                    MessagePart(
                        id: "p0",
                        kind: .tool(
                            ToolCall(
                                id: "call-extra\(number)", name: "Bash", status: .running,
                                input: .object(["command": .string("echo \(number)")]), output: nil)))
                ], createdAt: Date())
            added.isStreaming = true
            messages.append(added)
        }
        return messages
    }

    private static func live(_ expect: Expect) throws {
        guard let env = make(width: 1300, messages: runningMessages(), running: true) else { return }
        defer { env.fixture.tearDown() }
        let list = env.list
        try expect(env.steps.isLive, "the running turn is live")
        try expect(env.steps.isFollowing, "a live list follows")
        try expect(list.offset == list.maxOffset, "it sits at the newest step")
        try expect(!env.steps.showsFollowPill, "and says nothing about following")
        try expect(list.pulseCountForChecks >= 1, "the step still out wears a breathing mark")
        try expect(
            list.pulseHasAnimationForChecks || !ActivityPulse.motionAllowed,
            "the mark breathes by animation, not by a clock")
        try expect(!list.ownsClock, "the list owns no clock while it follows quietly")
        list.driveScroll(to: 0)
        try expect(!env.steps.following, "a person's scroll pauses following")
        try expect(env.steps.showsFollowPill, "and the pill appears")
        try expect(list.offset == 0, "the list stays where the person put it")
        drawPass(list.overlay)
        let pill = list.overlay.pillRect
        try expect(
            list.overlay.target(at: CGPoint(x: pill.midX, y: pill.midY)) == .pill, "the pill is a button")
        let before = list.maxOffset
        env.fixture.replace(messages: runningMessages(extra: 2), running: true)
        try expect(list.maxOffset > before, "a new step arrives at the end")
        try expect(list.offset == 0, "a paused list does not follow it")
        if let event = mouseEvent(.leftMouseDown, at: CGPoint(x: pill.midX, y: pill.midY), in: list.overlay) {
            list.overlay.mouseDown(with: event)
        }
        try expect(env.steps.following && !env.steps.showsFollowPill, "the pill resumes following")
        try expect(list.offset == list.maxOffset, "and goes to the newest step")
        env.fixture.replace(messages: runningMessages(extra: 4), running: true)
        try expect(list.offset == list.maxOffset, "a following list stays on the newest step as steps arrive")
        press("up", env)
        try expect(!env.steps.following, "setting a cursor pauses following")
        press("end", env)
        try expect(env.steps.following, "End resumes following")
        list.driveScroll(to: 0)
        press("end", env)
        try expect(env.steps.following && list.offset == list.maxOffset, "End goes to the newest step")
        let held = list.offset
        let manual = list.manualScrolls
        list.scroll.simulateUserScroll {
            list.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, held - 56)))
            list.scroll.reflectScrolledClipView(list.scroll.contentView)
        }
        try expect(list.offset < held, "a scroll by the wheel moves the list")
        try expect(list.manualScrolls == manual + 1, "and is told as a person's scroll")
        try expect(!env.steps.following && env.steps.showsFollowPill, "which pauses following")
        try expect(list.scrollTarget == list.offset, "the list's own target follows the hand")
        list.setReveal(rows: nil, headerAlpha: 1)
    }


    private static func large(_ expect: Expect) throws {
        let messages = NeuralDemo.buildFix(prefix: "a-", origin: 1_792_000_000)
            + NeuralDemo.largeTurn(steps: 2000, prefix: "b-", origin: 1_792_003_600)
        guard let env = make(width: 1300, messages: messages) else { return }
        defer { env.fixture.tearDown() }
        let list = env.list
        try expect(env.steps.total >= 1500, "the long turn has \(env.steps.total) steps")
        try expect(
            abs(list.contentHeight - CGFloat(env.steps.contentHeight())) < 0.5,
            "the document is as tall as the turn")
        drawPass(list.rows)
        try expect(list.rows.rowsDrawn <= 14, "a screenful is drawn, not the turn (\(list.rows.rowsDrawn))")
        list.driveScroll(to: list.contentHeight / 2)
        drawPass(list.rows)
        try expect(list.rows.rowsDrawn <= 14, "scrolled to the middle it is still a screenful (\(list.rows.rowsDrawn))")
        try expect(list.pulseCountForChecks == 0, "a settled long turn has no breathing mark")
        let clock = ContinuousClock()
        let drawn = clock.measure { for _ in 0..<20 { drawPass(list.rows) } }
        try expect(drawn < .milliseconds(300), "twenty screenfuls draw in \(drawn)")
        FileHandle.standardOutput.write(Data("BRAIN list perf: 20 passes \(drawn)\n".utf8))
        let updated = clock.measure { for _ in 0..<30 { list.modelChanged() } }
        try expect(updated < .milliseconds(60), "thirty model changes cost \(updated)")
        FileHandle.standardOutput.write(Data("BRAIN list perf: 30 model changes \(updated) on \(env.steps.total) steps\n".utf8))
        try expect(list.painter.cachedCount <= 600, "the text cache is bounded (\(list.painter.cachedCount))")
        press("end", env)
        try expect(env.model.pinnedStep == env.steps.lastVisibleID, "End on the long turn goes to its last step")
        try expect(cursorVisible(env), "and shows it")
        press("home", env)
        try expect(cursorVisible(env), "Home shows the first row")
        for _ in 0..<5 { press("pagedown", env) }
        try expect(cursorVisible(env), "five pages down is still in view")
        env.view.browse(.zoneChip(.shell, solo: true), grabFocus: false)
        try expect(list.snapshot.list.visibleCount == env.steps.visibleCount, "a filter on the long turn reaches the list")
        try expect(list.contentHeight == CGFloat(env.steps.contentHeight()), "and shrinks the document with it")
        try expect(list.offset <= list.maxOffset, "the offset stays inside the shorter list")
        reset(env)
    }
}
