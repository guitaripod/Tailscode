import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    static func press(_ view: BrainView, _ name: String) {
        view.driveBrowse(verb: "key", value: name)
    }

    private static func settle(_ view: BrainView, _ seconds: Double = 0.3) {
        _ = brainPump(seconds) { view.list?.isAnimating == false && view.readout?.isFading == false }
        _ = brainPump(0.05)
    }

    /// The step list, the filters, the keys, the accordion and what a shed window promises, each on
    /// a real widget: the claims about how a person browses a turn.
    static func checkBrainBrowse(_ expect: (Bool, String) throws -> Void) throws {
        try timedBrain("browse list") { try checkBrainList(expect) }
        try timedBrain("browse keys") { try checkBrainKeys(expect) }
        try timedBrain("browse accordion") { try checkBrainAccordion(expect) }
        try timedBrain("browse huge") { try checkBrainHuge(expect) }
        try timedBrain("browse shed") { try checkBrainShed(expect) }
        try timedBrain("browse stress") { try checkBrainStress(expect) }
    }

    // MARK: the list, the cursor, the hover and the filters

    private static func checkBrainList(_ expect: (Bool, String) throws -> Void) throws {
        let (brains, builder) = try brainRows()
        var open = brains[1]
        open.open = true
        let bed = try BrainBed(row: open, width: 1440, key: "st-list", policy: { builder.brainPolicy })
        defer { bed.close() }
        _ = brainPump(10) { bed.view.stage?.hasPicture == true }
        _ = brainPump(0.4)
        let view = bed.view
        guard let list = view.list, let readout = view.readout, let filters = view.filters else {
            throw SelfTestFailure("brain: no list")
        }
        let metrics = view.currentMetrics
        let steps = view.model.steps
        try expect(
            widgetCount(list.canvas) == 1 && metrics.filterStyle == .chips && !filters.isPanel
                && widgetCount(filters.canvas) == 1,
            "the list is one canvas, never a widget per row, and the zone filters are one row of chips")
        try expect(
            list.visibleIDs.count <= metrics.rowsShown + 2 && list.visibleIDs.count >= metrics.rowsShown - 3,
            "it draws the rows the metrics give it (\(list.visibleIDs.count) of \(metrics.rowsShown))")
        let rect = bed.rect(of: list.canvas)
        try expect(
            abs(rect.x - metrics.list.x) <= 1.5 && abs(rect.y - metrics.list.y) <= 1.5
                && abs(rect.h - list.canvasHeight) <= 1.5,
            "and stands where the metrics put it")

        let failedStep = steps.first { $0.status == .failed && $0.recovered }!
        let shell = steps.first { $0.zone == .shell && $0.status == .ok }!
        view.browse(.click(failedStep.id, double: false))
        settle(view, 1.0)
        try expect(
            view.model.pinnedStep == failedStep.id && list.visibleIDs.contains(failedStep.id),
            "a click on a row puts the cursor there and scrolls it into view")
        try expect(
            readout.shown?.step?.stepID == failedStep.id && readout.visibleText.contains(BrainWords.pinned),
            "the readout shows the cursor's step and says it is pinned")
        try expect(
            view.ringed(failedStep.id)?.number == (steps.firstIndex { $0.id == failedStep.id } ?? -1) + 1
                && view.model.browseState.list.nodeID(of: failedStep.id) == view.ringed(failedStep.id)?.node,
            "the head rings that step's node with its number, a ganglion's member through the ganglion")
        let before = list.scroll
        view.hoverStep(shell.id)
        _ = brainPump(0.3) { readout.shown?.step?.stepID == shell.id && !readout.isFading }
        try expect(
            readout.shown?.step?.stepID == shell.id && view.model.pinnedStep == failedStep.id,
            "a hovered row previews in the readout and never moves the cursor")
        try expect(list.scroll == before, "and hovering does not scroll")
        view.hoverLeftStep()
        view.model.pointer(over: nil, at: BrainClock.now - 10)
        view.afterSelection()
        _ = brainPump(1.0) { readout.shown?.step?.stepID == failedStep.id && !readout.isFading }
        try expect(readout.shown?.step?.stepID == failedStep.id, "leaving the row returns the readout to the cursor")

        view.browse(.zoneChip(.shell, solo: false), grabFocus: false)
        settle(view)
        let shellCount = steps.filter { $0.zone == .shell }.count
        try expect(
            view.model.stepList.visibleCount == shellCount && view.model.stepList.countLabel.contains("\(shellCount)"),
            "a zone filter narrows the list and the header says \"N of M\" (\(view.model.stepList.countLabel))")
        let lit = Set(view.model.browseState.list.zoneChips.map(\.zone))
        try expect(
            !view.dimmedNodes.isEmpty && lit.contains(.shell)
                && view.dimmedNodes.isDisjoint(with: Set(steps.filter { $0.zone == .shell && view.model.layout.representative(of: $0.id) == $0.id }.map(\.id))),
            "and the head dims the nodes the list hides, not the ones it shows (\(view.dimmedNodes.count) dimmed)")
        try expect(filters.reading.contains("on=[SHELL]"), "the panel row shows it on")
        view.browse(.failedToggle, grabFocus: false)
        try expect(view.model.stepList.visibleCount == 1, "failed-only narrows it further (\(view.model.stepList.visibleCount))")
        try expect(view.model.pinnedStep == failedStep.id, "the cursor survives a filter it still matches")
        view.browse(.zoneChip(.act, solo: true), grabFocus: false)
        try expect(
            view.model.stepList.filter.zones == [.act] && view.model.stepList.filter.failedOnly,
            "a solo press leaves only that zone on")
        _ = view.escapePressed()
        try expect(!view.model.stepList.isFiltered, "Esc clears the filters")
        try expect(view.model.pinnedStep == failedStep.id, "before it touches the cursor")

        view.driveBrowse(verb: "search", value: "cut-list")
        _ = brainPump(0.2)
        let matches = steps.filter { NeuralStepList.matchesForTest($0, "cut-list") }.count
        try expect(
            view.model.stepList.visibleCount == matches && matches >= 3
                && String(cString: gtk_editable_get_text(op(list.entry))) == "cut-list",
            "search filters by title, argument and output and the field holds the words (\(matches) matches)")
        try expect(view.model.browseState.searchOpen && list.searchOpen, "and the field is open")
        _ = view.escapePressed()
        _ = brainPump(0.2)
        try expect(
            !view.model.stepList.isFiltered && !view.model.browseState.searchOpen
                && String(cString: gtk_editable_get_text(op(list.entry))).isEmpty,
            "Esc clears the search and closes the field")
        view.model.pointer(over: nil, at: BrainClock.now - 10)

        view.toggleLegend()
        _ = brainPump(0.3) { view.legendPopover?.widget != nil }
        let legend = view.legendPopover?.widget
        try expect(
            view.model.browseState.legend && legend.map { gtk_widget_get_mapped($0) != 0 } == true
                && NeuralBrowse.legend.count >= 14,
            "? opens the legend popover with every entry of the key table (\(NeuralBrowse.legend.count)) (legend=\(view.model.browseState.legend) focus=\(view.model.browseFocus) popover=\(legend != nil) mapped=\(legend.map { gtk_widget_get_mapped($0) } ?? -1))")
        _ = view.escapePressed()
        _ = brainPump(0.3) { view.legendPopover == nil }
        try expect(!view.model.browseState.legend && view.legendPopover == nil, "and Esc closes it before anything else")
        _ = view.escapePressed()
        _ = brainPump(0.2)
        try expect(view.model.pinnedStep == nil, "the next Esc lets go of the cursor")
        let effects = view.model.browse(.key(.escape))
        try expect(effects.contains(.collapseBrain), "and only the one after that collapses the brain")

        let withRelated = view.model.browseState.list.row(id: failedStep.id)!
        let plain = view.model.browseState.list.rows.first { $0.related == nil }!
        try expect(
            NeuralBrowse.menuItems(for: withRelated).count == 6 && NeuralBrowse.menuItems(for: plain).count == 5
                && !NeuralBrowse.menuItems(for: plain).contains(.goToRelated),
            "the row menu offers its six entries, Go to related only where there is one")
        view.presentMenu(for: failedStep.id, items: NeuralBrowse.menuItems(for: withRelated), at: (120, 60), holding: true)
        _ = brainPump(0.3)
        let menu = view.menuPopover?.widget
        var buttons = 0
        if let menu, let child = gtk_popover_get_child(ptr(menu)) {
            var node = gtk_widget_get_first_child(child)
            while node != nil {
                buttons += 1
                node = gtk_widget_get_next_sibling(node)
            }
        }
        try expect(menu.map { gtk_widget_get_mapped($0) != 0 } == true && buttons == 6, "the menu stands with six entries (\(buttons))")
        view.browse(.menu(.copyOutput, failedStep.id))
        try expect(list.copiedID == failedStep.id, "Copy output copies and the row says Copied")
        if let menu { gtk_popover_popdown(ptr(menu)) }
        _ = brainPump(0.2)
    }

    // MARK: every key

    private static func checkBrainKeys(_ expect: (Bool, String) throws -> Void) throws {
        let (brains, builder) = try brainRows()
        var open = brains[1]
        open.open = true
        let bed = try BrainBed(row: open, width: 1440, key: "st-keys", policy: { builder.brainPolicy })
        defer { bed.close() }
        _ = brainPump(10) { bed.view.stage?.hasPicture == true }
        _ = brainPump(0.3)
        let view = bed.view
        let list = view.model.browseState.list
        let ids = list.rows.map(\.id)
        view.focusList()
        _ = brainPump(0.1)

        press(view, "down")
        try expect(view.model.pinnedStep == ids[0], "Down with no cursor takes the first row")
        press(view, "down")
        press(view, "j")
        try expect(view.model.pinnedStep == ids[2], "Down and j walk on")
        press(view, "k")
        press(view, "up")
        try expect(view.model.pinnedStep == ids[0], "Up and k walk back")
        press(view, "pgdn")
        try expect(view.model.pinnedStep == ids[NeuralStepList.pageSize], "PageDown is eight steps")
        press(view, "pgup")
        try expect(view.model.pinnedStep == ids[0], "and PageUp eight back")
        press(view, "end")
        try expect(view.model.pinnedStep == ids.last, "End is the last step")
        press(view, "home")
        try expect(view.model.pinnedStep == ids.first, "Home the first")
        press(view, "G")
        try expect(view.model.pinnedStep == ids.last, "G is End")
        press(view, "g")
        try expect(view.model.pinnedStep == ids.first, "and g is Home")
        press(view, "up")
        try expect(view.model.pinnedStep == ids.first, "a walk stops at the end and never wraps")

        let first = list.rows[0]
        press(view, "right")
        let sameZone = list.rows.dropFirst().first { $0.zone == first.zone }
        try expect(view.model.pinnedStep == sameZone?.id, "Right is the next step in the same zone")
        press(view, "h")
        try expect(view.model.pinnedStep == first.id, "and h the previous")

        press(view, "]")
        let failedID = list.rows.first { $0.status == .failed }!.id
        try expect(view.model.pinnedStep == failedID, "] is the next failed step")
        press(view, "r")
        try expect(view.model.pinnedStep == list.row(id: failedID)?.related?.stepID, "r goes to the related step")
        press(view, "[")
        try expect(view.model.pinnedStep == failedID, "[ is the previous failed step")
        press(view, "n")
        press(view, "p")
        try expect(view.model.pinnedStep == failedID, "n and p are ] and [")

        press(view, "\(NeuralZone.shell.filterKey)")
        try expect(view.model.stepList.filter.zones == [.shell], "the zone's own key toggles SHELL (\(NeuralZone.shell.filterKey))")
        press(view, "\(NeuralZone.sense.filterKey)")
        try expect(view.model.stepList.filter.zones == [.shell, .sense], "and another adds SENSE (\(NeuralZone.sense.filterKey))")
        press(view, "\(NeuralZone.say.filterKey)")
        try expect(view.model.stepList.filter.zones.contains(.say), "key 1 is SAID")
        press(view, "0")
        try expect(view.model.stepList.filter.zones.isEmpty, "0 clears the zones")
        press(view, "x")
        try expect(view.model.stepList.filter.failedOnly, "x is failed only")
        press(view, "!")
        try expect(!view.model.stepList.filter.failedOnly, "and ! turns it off")

        _ = brainPump(1.0) { view.readout?.shown?.step?.stepID == view.model.pinnedStep && view.readout?.isFading == false }
        press(view, "enter")
        _ = brainPump(0.3)
        try expect(
            view.model.browseFocus == .readout && gtk_widget_has_focus(view.list!.canvas) == 0
                && view.account?.hasFocus == true,
            "Enter moves the keyboard into the account (\(view.model.browseFocus))")
        press(view, "enter")
        _ = brainPump(0.3)
        try expect(
            view.model.browseFocus == .list && gtk_widget_has_focus(view.list!.canvas) != 0,
            "and Enter again returns it to the list (\(view.model.browseFocus))")
        press(view, "c")
        try expect(view.list?.copiedID == view.model.pinnedStep, "c copies the step's subject")
        press(view, "C")
        press(view, "o")
        press(view, "space")
        press(view, "/")
        _ = brainPump(0.3)
        try expect(
            view.model.browseFocus == .search && view.model.browseState.searchOpen,
            "/ opens the search and the keyboard goes to it")
        view.browse(.key(.escape))
        _ = brainPump(0.2)
        try expect(view.model.browseFocus == .list, "Esc comes back to the list")
        press(view, "?")
        _ = brainPump(0.2)
        try expect(view.model.browseState.legend, "? shows the keys")
        press(view, "?")
        _ = brainPump(0.2)
        try expect(!view.model.browseState.legend, "and hides them")
        view.clearSelection()
        _ = view.escapePressed()

        let holder = bed.holder
        let other = gtk_entry_new()!
        gtk_box_append(ptr(holder), other)
        gtk_widget_grab_focus(other)
        _ = brainPump(0.2)
        let consumed = ["j", "k", "G", "g", "[", "]", "n", "p", "x", "/", "o", "?", " "].filter { key in
            guard let scalar = key.unicodeScalars.first else { return false }
            return bed.host.handleKey(keyval: gdk_unicode_to_keyval(scalar.value), state: 0)
        }
        try expect(consumed.isEmpty, "with the keyboard in another field the brain takes no key (\(consumed))")
        view.focusList()
        _ = brainPump(0.2)
        let taken = ["j", "k", "G", "g", "[", "]", "n", "p", "x", "o", "?", "?"].filter { key in
            guard let scalar = key.unicodeScalars.first else { return false }
            return bed.host.handleKey(keyval: gdk_unicode_to_keyval(scalar.value), state: 0)
        }
        try expect(
            taken.count == 12,
            "and with it on the list it takes every one the window's normal mode also binds (\(taken.joined()))")
        view.clearSelection()
        gtk_widget_unparent(other)
    }

    // MARK: the accordion

    private static func checkBrainAccordion(_ expect: (Bool, String) throws -> Void) throws {
        let (brains, builder) = try brainRows()
        var open = brains[1]
        open.open = true
        let bed = try BrainBed(row: open, width: 520, key: "st-accordion", policy: { builder.brainPolicy })
        defer { bed.close() }
        _ = brainPump(10) { bed.view.stage?.hasPicture == true }
        _ = brainPump(0.6)
        let view = bed.view
        guard let account = view.account else { throw SelfTestFailure("brain: no narrow account") }
        let metrics = view.currentMetrics
        let height = Double(gtk_widget_get_height(bed.widget))
        let want = metrics.rowHeight + view.narrowExtra(metrics)
        try expect(
            metrics.arrangement == .accordion && metrics.filterStyle == .chips && abs(height - want) <= 1.5,
            "under 860 the brain is the head, the chips and the account, \(Int(height)) tall (\(Int(want)))")
        let place = bed.rect(of: account.root)
        try expect(
            abs(place.x) <= 1.5 && abs(place.w - metrics.width) <= 1.5 && place.y >= metrics.stage.height
                && abs(place.h - view.narrowAccountHeight(metrics)) <= 1.5,
            "the account stands where the step list would, at the row's full width (\(Int(place.y)), \(Int(place.w)) by \(Int(place.h)))")
        try expect(
            gtk_widget_get_child_visible(view.list!.canvas) == 0 && !view.currentMetrics.hasLeader,
            "the step list is not drawn there and there is no leader line")
        let steps = view.model.steps
        let work = steps.first { $0.zone == .shell && $0.status == .failed }!
        view.browse(.click(work.id, double: false))
        _ = brainPump(1.0) { account.cells.values.contains { $0.cursorPage != nil } }
        try expect(
            account.cells.values.contains { $0.cursorPage != nil } && Double(gtk_widget_get_height(bed.widget)) == height,
            "a cursor opens the step's card inside its work line and the row's height does not move")
        try expect(account.entries.count > 3 && account.cells.count > 0, "and the story lists the turn's notes, thoughts and work")
        _ = view.escapePressed()
        _ = brainPump(0.4)
        try expect(view.model.pinnedStep == nil && Double(gtk_widget_get_height(bed.widget)) == height, "Esc lets go of it")
    }

    // MARK: two thousand steps

    private static func checkBrainHuge(_ expect: (Bool, String) throws -> Void) throws {
        let builder = brainBuilder(style: .brain)
        let rows = builder.rows(state: brainState(NeuralDemo.largeTurn(steps: 2000)))
        var open: BrainRow?
        for row in rows {
            if case .brain(let brain) = row.kind { open = brain }
        }
        guard var huge = open else { throw SelfTestFailure("brain: the large turn made no brain") }
        huge.open = true
        let bed = try BrainBed(row: huge, width: 1100, key: "st-huge", policy: { builder.brainPolicy })
        defer { bed.close() }
        _ = brainPump(15) { bed.view.stage?.hasPicture == true }
        _ = brainPump(0.5)
        let view = bed.view
        guard let list = view.list else { throw SelfTestFailure("brain: no list") }
        let total = view.model.browseState.list.total
        try expect(total >= 1900, "the large turn has its steps (\(total))")
        let count = widgetCount(bed.widget)
        report("brain widgets at \(total) steps: row=\(count) list=\(widgetCount(list.canvas)) readout=\(view.readout.map { widgetCount($0.widget) } ?? 0) footer=\(view.footer.map { widgetCount($0.widget) } ?? 0) card=\(widgetCount(view.card.surface) + widgetCount(view.card.text)) filters=\(view.filters.map { widgetCount($0.canvas) } ?? 0)")
        try expect(count < 400, "and the open row holds a fixed number of widgets, not one per step (\(count))")
        let metrics = view.currentMetrics
        list.resetPaintStats()
        for _ in 0..<60 {
            list.driveScroll(84)
            _ = brainPump(0.02)
        }
        _ = brainPump(0.3)
        try expect(list.rowsDrawn <= metrics.rowsShown + 2, "a frame draws only the rows in view (\(list.rowsDrawn))")
        try expect(list.scroll > 1000, "the wheel scrolls it a long way (\(Int(list.scroll)))")
        let mean = Double(list.paintNanoseconds) / Double(max(list.paints, 1)) / 1_000_000
        report(String(format: "brain list: %d paints, mean %.2f ms, worst %.2f ms at %d steps", list.paints, mean, Double(list.worstPaintNanoseconds) / 1_000_000, total))
        try expect(mean < 6, "and a paint is a few milliseconds, not the size of the turn (\(String(format: "%.2f", mean)) ms)")
        let id = view.model.browseState.list.rows[1500].id
        view.browse(.click(id, double: false))
        _ = brainPump(2.0) { abs(list.scroll - list.target) < 1 }
        try expect(list.visibleIDs.contains(id), "a step far down is scrolled to and shown")
        press(view, "pgdn")
        try expect(view.model.pinnedStep == view.model.browseState.list.rows[1508].id, "PageDown is still eight steps")
        view.browse(.zoneChip(.shell, solo: true), grabFocus: false)
        try expect(view.model.stepList.visibleCount > 100 && view.model.stepList.visibleCount < total, "filters narrow two thousand steps (\(view.model.stepList.visibleCount) of \(total))")
        view.clearAllFilters()
    }

    // MARK: a shed window

    private static func checkBrainShed(_ expect: (Bool, String) throws -> Void) throws {
        let (brains, builder) = try brainRows()
        var closed = brains[1]
        closed.open = false
        var opened = closed
        opened.open = true
        let bed = try BrainBed(row: closed, width: 1440, key: "st-shed", policy: { builder.brainPolicy })
        defer { bed.close() }
        _ = brainPump(8) { bed.view.card.hasPicture }
        BrainBudget.force(allowed: false)
        defer { BrainBudget.reset() }
        bed.host.choices = [:]
        bed.view.restate(opened)
        _ = brainPump(0.5)
        try expect(
            bed.view.phase == .closed && !bed.view.hasStage,
            "a shed window does not open a turn by itself")
        bed.host.choices = [bed.view.turnID: true]
        bed.view.restate(closed)
        _ = brainPump(0.1)
        bed.view.restate(opened)
        _ = brainPump(10) { bed.view.phase == .open && bed.view.stage?.hasPicture == true }
        try expect(
            bed.view.phase == .open && bed.view.stage != nil && bed.view.moveState == nil,
            "but a press opens it, at once and with no move")
        try expect(!bed.view.clock.isRunning, "and the settled picture owns no clock")
        try expect(
            bed.view.stage?.hasPicture == true && bed.view.list != nil && bed.view.readout != nil,
            "it is drawn once, and the list and the readout work as ever")
        let id = bed.view.model.browseState.list.rows[3].id
        bed.view.browse(.click(id, double: false))
        _ = brainPump(0.6) { bed.view.readout?.shown?.step?.stepID == id }
        try expect(bed.view.readout?.shown?.step?.stepID == id, "a click on a row reads it out")
        BrainBudget.reset()
    }

    // MARK: pointers and rebuilds, hard

    private static func checkBrainStress(_ expect: (Bool, String) throws -> Void) throws {
        let (brains, builder) = try brainRows()
        var closed = brains[1]
        closed.open = false
        var opened = closed
        opened.open = true
        let bed = try BrainBed(row: opened, width: 1440, key: "st-stress", policy: { builder.brainPolicy })
        defer { bed.close() }
        _ = brainPump(10) { bed.view.stage?.hasPicture == true }
        _ = brainPump(0.3)
        let view = bed.view
        let ids = view.model.browseState.list.rows.map(\.id)
        BrainLogWatch.install()
        let complaints = BrainLogWatch.count
        let sweepSeconds = ProcessInfo.processInfo.environment["TAILSCODE_STRESS_SECONDS"].flatMap(Double.init) ?? 0.6
        let passes = Int(ProcessInfo.processInfo.environment["TAILSCODE_STRESS_PASSES"] ?? "") ?? 3
        var swaps = 0
        for pass in 0..<passes {
            let end = Date().addingTimeInterval(sweepSeconds)
            var index = pass
            let hardStop = Date().addingTimeInterval(8)
            while Date() < end || (swaps < 100 && Date() < hardStop) {
                let step = ids[index % ids.count]
                view.stripHover(step)
                view.hoverStep(ids[(index * 7) % ids.count])
                view.stagePointer(over: ids[(index * 3) % ids.count])
                if index % 5 == 0 { view.driveBrowse(verb: "filter", value: index % 10 == 0 ? "shell" : "clear") }
                if index % 11 == 0 { press(view, "j") }
                index += 1
                swaps += 1
                while g_main_context_iteration(nil, 0) != 0 {}
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        view.driveBrowse(verb: "filter", value: "clear")
        report("brain stress: \(swaps) swaps, account \(view.account?.reading ?? "-")")
        try expect(swaps > 60 && view.phase == .open, "a pointer swept across the strip, the rows and the head while subjects swap, \(swaps) times, without a crash (\(view.phase))")

        view.focusList()
        var cycles = 0
        let heavy = ProcessInfo.processInfo.environment["TAILSCODE_STRESS_FULL"] == nil ? 20 : 200
        for index in 0..<200 {
            view.browse(.click(ids[index % ids.count], double: false))
            switch index % 4 {
            case 0: view.driveBrowse(verb: "filter", value: "shell")
            case 1: view.driveBrowse(verb: "filter", value: "clear")
            case 2: press(view, index % 8 == 2 ? "]" : "j")
            default: view.driveBrowse(verb: "search", value: index % 8 == 3 ? "cut" : "")
            }
            if index < heavy {
                view.restate(index % 2 == 0 ? closed : opened)
                _ = brainPump(0.005)
                view.restate(opened)
            }
            if index % 25 == 0 { _ = brainPump(0.02) }
            cycles += 1
        }
        view.driveBrowse(verb: "search", value: "")
        view.driveBrowse(verb: "filter", value: "clear")
        _ = brainPump(0.5)
        try expect(
            BrainLogWatch.count == complaints,
            "and the toolkit complained of nothing in all of it (\(BrainLogWatch.count - complaints): \(BrainLogWatch.last))")
        try expect(cycles == 200, "click, filter, search, walk and \(heavy) open-and-close cycles with the keyboard on the list hold, 200 rounds")

        let narrow = try BrainBed(row: opened, width: 520, key: "st-stress-narrow", policy: { builder.brainPolicy })
        defer { narrow.close() }
        _ = brainPump(0.5) { narrow.view.stage != nil }
        narrow.view.focusList()
        for index in 0..<200 {
            narrow.view.browse(.click(ids[(index * 3) % ids.count], double: false))
            if index % 3 == 0 { _ = narrow.view.escapePressed() }
            if index % 40 == 0 { _ = brainPump(0.03) }
        }
        _ = brainPump(0.6)
        try expect(narrow.view.phase == .open, "the accordion opens and folds two hundred times with the keyboard on the list")
    }
}

/// Counts the toolkit's own complaints (a critical or a warning that is not the accessibility
/// registry being absent from a headless bus), so a stress run can fail on the first assertion
/// the brain provokes rather than only on a crash.
enum BrainLogWatch {
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var last = ""
    nonisolated(unsafe) private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        g_log_set_default_handler(
            { domain, level, message, _ in
                let text = message.map { String(cString: $0) } ?? ""
                let serious = level.rawValue & 24 != 0
                if serious, !text.contains("atspi"), !text.contains("Registry") {
                    BrainLogWatch.count += 1
                    BrainLogWatch.last = text
                }
                g_log_default_handler(domain, level, message, nil)
            }, nil)
    }
}

extension NeuralStepList {
    static func matchesForTest(_ step: NeuralStep, _ query: String) -> Bool {
        var list = NeuralStepList(steps: [step])
        list.setSearch(query)
        return list.visibleCount == 1
    }
}
