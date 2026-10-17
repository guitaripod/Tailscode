import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// One brain's row in a window of its own at an exact width, with the pane's host around it.
    final class BrainBed {
        let window: UnsafeMutablePointer<GtkWidget>
        let holder: UnsafeMutablePointer<GtkWidget>
        let host = BrainHost()
        let context = TranscriptContext()
        let widget: UnsafeMutablePointer<GtkWidget>
        let view: BrainView

        init(
            row: BrainRow, width: Int, key: String, policy: (() -> NeuralOpenPolicy?)? = nil,
            onScreen: ((BrainView) -> Bool)? = nil
        ) throws {
            host.sessionKey = key
            host.onScreen = onScreen
            host.policy = policy
            context.brains = host
            window = gtk_window_new()!
            gtk_window_set_default_size(ptr(window), Int32(width + 40), 1000)
            holder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
            widget = BrainView.make(row, context: context)
            gtk_widget_set_size_request(holder, Int32(width), -1)
            gtk_widget_set_halign(holder, GTK_ALIGN_START)
            gtk_widget_set_valign(holder, GTK_ALIGN_START)
            gtk_box_append(ptr(holder), widget)
            gtk_window_set_child(ptr(window), holder)
            gtk_window_present(ptr(window))
            guard let found = BrainView.current(of: widget) else {
                throw SelfTestFailure("brain: no view for the bed")
            }
            view = found
            _ = SelfTest.brainPump(5) { gtk_widget_get_mapped(widget) != 0 && gtk_widget_get_width(widget) > 8 }
        }

        func close() {
            gtk_window_set_child(ptr(window), nil)
            gtk_window_destroy(ptr(window))
            _ = SelfTest.brainPump(0.3)
        }

        func rect(of child: UnsafeMutablePointer<GtkWidget>) -> (x: Double, y: Double, w: Double, h: Double) {
            guard let box = Gtk.bounds(of: child, in: holder) else { return (0, 0, 0, 0) }
            return (box.x, box.y, box.width, box.height)
        }
    }

    static func brainRows(turns: Int = 2) throws -> (rows: [BrainRow], builder: TranscriptRowBuilder) {
        let builder = brainBuilder(style: .brain)
        let rows = builder.rows(state: brainState(NeuralDemo.conversation()))
        let brains = rows.compactMap { row -> BrainRow? in
            if case .brain(let brain) = row.kind { return brain }
            return nil
        }
        guard brains.count >= turns else { throw SelfTestFailure("brain: the demo built \(brains.count) brains") }
        return (brains, builder)
    }

    /// The claims about the card, the open row's geometry, the readout and the leader, the move
    /// between them, and what the performance work promised, each on a real widget in a window.
    static func checkBrainSurfaces(_ expect: (Bool, String) throws -> Void) throws {
        guard gtk_init_check() != 0, NeuralAssetFiles.isAvailable else { return }
        Gtk.installStyle()
        tailscode_set_animations_enabled(1)
        tailscode_notify_animations()
        BrainView.openFallbackMilliseconds = 20_000
        try timedBrain("cards") { try checkBrainCards(expect) }
        try timedBrain("geometry") { try checkBrainGeometry(expect) }
        try timedBrain("readout") { try checkBrainReadout(expect) }
        try timedBrain("moves") { try checkBrainMoves(expect) }
        try timedBrain("efficiency") { try checkBrainEfficiency(expect) }
        try timedBrain("budget") { try checkBrainBudget(expect) }
        try timedBrain("browse") { try checkBrainBrowse(expect) }
    }

    /// Runs one group of brain claims and says how long it took, because the whole group has a
    /// time it must stay inside.
    static func timedBrain(_ name: String, _ body: () throws -> Void) throws {
        let begun = Date()
        try body()
        report(String(format: "brain group %@: %.1f s", name, Date().timeIntervalSince(begun)))
    }

    static func widgetCount(_ widget: UnsafeMutablePointer<GtkWidget>) -> Int {
        var count = 1
        var child = gtk_widget_get_first_child(widget)
        while let held = child {
            count += widgetCount(held)
            child = gtk_widget_get_next_sibling(held)
        }
        return count
    }

    // MARK: cards

    private static func checkBrainCards(_ expect: (Bool, String) throws -> Void) throws {
        let (brains, builder) = try brainRows()
        var closed = brains[1]
        closed.open = false
        let policy: () -> NeuralOpenPolicy? = { builder.brainPolicy }

        let wide = try BrainBed(row: closed, width: 760, key: "st-card-wide", policy: policy)
        _ = brainPump(8) { wide.view.card.hasPicture && wide.view.card.hasContent }
        _ = brainPump(0.4)
        let card = wide.view.card!
        try expect(wide.view.phase == .closed && !wide.view.hasStage, "a collapsed turn is a card and builds no stage")
        try expect(card.layoutClass == .wide, "a card 760 points wide is the wide card")
        try expect(
            card.parts.isSuperset(of: [.picture, .headline, .replay, .rows, .zoneStrip]),
            "and keeps its picture, headline, Replay, Rows and zone strip (\(card.parts.count) parts)")
        let used = Set(wide.view.model.steps.map(\.zone))
        try expect(
            Set(card.card.lights.map(\.zone)) == used && Set(card.card.chips.map(\.zone)) == used,
            "the head's lights and the zone chips are the zones the turn worked in")
        let first = card.card.lights.first { $0.count > 0 }
        try expect(
            first.map { $0.radius == NeuralGlyph.radius(forCount: $0.count) } ?? false,
            "and each light's radius follows how many steps its zone holds")
        try expect(
            card.hasPicture && card.visibleChipCount > 0 && card.digestVisible || wide.view.density == .compact,
            "the card has its picture, its chips and its digest")
        let rowHeight = Int(gtk_widget_get_height(wide.widget))
        let metrics = NeuralStageMetrics.make(width: 760, density: wide.view.density)
        try expect(
            abs(Double(rowHeight) - metrics.card.height) <= 1,
            "the card is \(Int(metrics.card.height)) points tall at this density (\(rowHeight))")
        let digest = card.digestText
        try expect(
            digest.isEmpty || card.card.digest(fitting: Int.max).hasPrefix(String(digest.prefix(12)))
                || digest.hasSuffix("."),
            "the digest is cut by whole clauses and ends on a full stop (\(digest))")
        try expect(
            gtk_widget_get_focusable(wide.widget) != 0 && gtk_widget_get_cursor(wide.widget) != nil,
            "the whole card takes the keyboard and shows a hand")

        let before = BrainPictures.renders
        var beds: [BrainBed] = []
        for index in 0..<8 {
            beds.append(try BrainBed(row: closed, width: 700, key: "st-many-\(index)", policy: policy))
        }
        _ = brainPump(8) { beds.allSatisfy { $0.view.card.hasPicture } }
        _ = brainPump(0.3)
        try expect(
            BrainPictures.renders - before <= 1,
            "eight cards of one look share one rendered head (\(BrainPictures.renders - before) renders)")
        let shell = beds.map { widgetCount($0.widget) }.max() ?? 0
        try expect(
            beds.allSatisfy { $0.view.card.hasContent } == false || shell > 0,
            "cards are built lazily (\(beds.filter { $0.view.card.hasContent }.count) of 8 have their words)")
        let offscreen = try BrainBed(row: closed, width: 700, key: "st-lazy", policy: policy, onScreen: { _ in false })
        _ = brainPump(0.5)
        let shellOnly = widgetCount(offscreen.widget)
        try expect(
            shellOnly <= 12,
            "a card nobody can see is a shell of \(shellOnly) widgets, not its whole tree")
        offscreen.view.card.ensureContent()
        try expect(
            widgetCount(offscreen.widget) > shellOnly,
            "and its words are made the moment they are asked for")
        offscreen.close()
        beds.forEach { $0.close() }

        let narrow = try BrainBed(row: closed, width: 420, key: "st-card-narrow", policy: policy)
        _ = brainPump(5) { narrow.view.card.hasContent }
        _ = brainPump(0.3)
        try expect(narrow.view.card.layoutClass == .narrow, "a card 420 points wide is the narrow card")
        try expect(
            !narrow.view.card.parts.contains(.zoneStrip) && !narrow.view.card.parts.contains(.digest)
                && narrow.view.card.parts.isSuperset(of: [.picture, .headline, .replay, .rows]),
            "which drops its zone strip and digest and keeps its picture, headline, Replay and Rows")
        try expect(
            narrow.view.card.visibleChipCount == 0 && !narrow.view.card.digestVisible,
            "and shows neither")
        let exact = NeuralStageMetrics.cardLayout(width: 459) == .narrow
            && NeuralStageMetrics.cardLayout(width: 460) == .wide
        try expect(exact, "the narrow card begins below 460 points")
        narrow.close()

        let chips = wide.view.card.chipButtons
        if let chip = chips.first, wide.view.density == .comfortable || true {
            let zone = wide.view.card.card.chips[0].zone
            var opened = closed
            opened.open = true
            wide.host.changed = { [view = wide.view] in view.restate(opened) }
            _ = gtk_widget_activate(chip)
            _ = brainPump(10) { wide.view.stage?.diveZone == zone }
            if wide.view.stage?.diveZone != zone {
                report("brain chip debug: phase=\(wide.view.phase) stage=\(wide.view.stage != nil) pending=\(wide.view.pendingOpen != nil) open=\(wide.view.row.open) moving=\(wide.view.moveState != nil) dive=\(String(describing: wide.view.stage?.diveZone)) host=\(wide.host.pendingDive)")
            }
            try expect(
                wide.view.stage?.diveZone == zone,
                "a zone chip on the card asks for the brain opened diving into that zone")
        }
        wide.close()
        BrainCompositors.dropIdle(olderThan: 0)
    }

    // MARK: geometry

    private static func checkBrainGeometry(_ expect: (Bool, String) throws -> Void) throws {
        let (brains, builder) = try brainRows()
        var open = brains[1]
        open.open = true
        let policy: () -> NeuralOpenPolicy? = { builder.brainPolicy }
        var reports: [String] = []
        for width in [380, 460, 700, 859, 860, 1300] {
            let bed = try BrainBed(row: open, width: width, key: "st-geo-\(width)", policy: policy)
            _ = brainPump(0.4) { bed.view.stage != nil && bed.view.readout?.shown != nil }
            _ = brainPump(0.15)
            let metrics = NeuralStageMetrics.make(width: Double(width), density: bed.view.density)
            guard let stage = bed.view.stage, let readout = bed.view.readout else {
                throw SelfTestFailure("brain: no stage at \(width)")
            }
            let hit = bed.rect(of: stage.visibleLayers[0])
            let rowHeight = Double(gtk_widget_get_height(bed.widget))
            let want = metrics.rowHeight
            try expect(
                abs(hit.x - metrics.stage.x) <= 1.5 && abs(hit.w - metrics.stage.width) <= 1.5
                    && abs(hit.h - metrics.stage.height) <= 1.5,
                "at \(width) the head is \(Int(metrics.stage.width)) by \(Int(metrics.stage.height)) at x \(Int(metrics.stage.x)) (\(Int(hit.x)), \(Int(hit.w)) by \(Int(hit.h)))")
            try expect(abs(rowHeight - want) <= 1.5, "and the row is \(Int(want)) tall (\(Int(rowHeight)))")
            switch metrics.arrangement {
            case .split:
                let place = bed.rect(of: readout.widget)
                try expect(
                    abs(place.x - metrics.readout.x) <= 1.5 && abs(place.w - metrics.readout.width) <= 1.5
                        && place.h >= NeuralStageMetrics.readoutMinHeight - 1.5,
                    "at \(width) the readout stands \(Int(metrics.readout.x)) points in, \(Int(metrics.readout.width)) wide and at least 460 tall (\(Int(place.x)), \(Int(place.w)), \(Int(place.h)); \(readout.overflowReading(limit: Int(metrics.readout.width) - 1).prefix(1800)))")
                if let listPart = bed.view.list {
                    let listRect = bed.rect(of: listPart.canvas)
                    try expect(
                        abs(listRect.x - metrics.list.x) <= 1.5 && abs(listRect.y - metrics.list.y) <= 1.5
                            && abs(listRect.h - listPart.canvasHeight) <= 1.5,
                        "and the step list stands under the head at \(Int(metrics.list.y)) (\(Int(listRect.x)), \(Int(listRect.y)), \(Int(listRect.h)))")
                }
                try expect(
                    bed.view.currentMetrics.hasLeader && stage.size.width == Int(metrics.stage.width.rounded()),
                    "and the head's own size is the metrics' (\(stage.size.width))")
            case .accordion:
                let listRect = bed.rect(of: bed.view.list?.canvas ?? readout.widget)
                try expect(
                    listRect.y >= metrics.stage.height && !bed.view.currentMetrics.hasLeader
                        && abs(listRect.w - metrics.list.width) <= 1.5,
                    "at \(width) the list is under the head at full width and there is no leader (\(Int(listRect.y)), \(Int(listRect.w)))")
            }
            if let filters = bed.view.filters, let place = metrics.filterPanel ?? metrics.filterChips {
                let box = bed.rect(of: filters.canvas)
                try expect(
                    filters.isPanel == (metrics.filterStyle == .panel) && abs(box.x - place.x) <= 1.5
                        && abs(box.w - place.width) <= 1.5 && abs(box.h - place.height) <= 1.5,
                    "at \(width) the zone filters are a \(metrics.filterStyle == .panel ? "panel beside the head" : "row of chips above the list")")
            }
            let parts = NeuralStageMetrics.footerParts(width: Double(width))
            try expect(
                (bed.view.footer?.closeVisible ?? false) == parts.contains { $0.kind == .close }
                    && (bed.view.footer?.replayIconOnly ?? false) == (parts.first { $0.kind == .replay }?.isIcon ?? false),
                "at \(width) the footer drops Close under 960 and makes Replay its icon under 640")
            reports.append("\(width):\(metrics.arrangement == .split ? "split" : "accordion")")
            bed.close()
            BrainCompositors.dropIdle(olderThan: 0)
        }
        try expect(
            reports.joined(separator: " ")
                == "380:accordion 460:accordion 700:accordion 859:accordion 860:split 1300:split",
            "the layout is an accordion under 860 and a split from it (\(reports.joined(separator: " ")))")
    }

    // MARK: the readout

    private static func checkBrainReadout(_ expect: (Bool, String) throws -> Void) throws {
        let (brains, builder) = try brainRows()
        var open = brains[1]
        open.open = true
        let policy: () -> NeuralOpenPolicy? = { builder.brainPolicy }
        let bed = try BrainBed(row: open, width: 1100, key: "st-readout", policy: policy)
        _ = brainPump(10) { bed.view.stage?.hasPicture == true }
        _ = brainPump(0.5)
        let view = bed.view
        guard let readout = view.readout else { throw SelfTestFailure("brain: no readout") }
        try expect(readout.shown != nil && readout.reading.hasPrefix("digest"), "a settled turn's readout opens on its digest")
        let digestSize = (gtk_widget_get_width(readout.widget), gtk_widget_get_height(readout.widget))
        let made = view.readoutValue(at: BrainClock.now)
        if case .digest(let digest) = made.body {
            let said = readout.visibleText
            try expect(
                digest.zoneBars.allSatisfy { said.contains($0.label) } && said.contains(String(digest.ticks.count)),
                "the digest names every zone and counts the steps")
            try expect(
                digest.failures.isEmpty || said.contains(digest.failures[0].label),
                "and says how a failure ended (\(digest.failures.first?.label ?? "none"))")
        }

        let visible = view.model.steps.filter { view.model.layout.representative(of: $0.id) == $0.id }
        let shell = visible.first { $0.zone == .shell && $0.status == .failed } ?? visible.first { $0.zone == .shell }!
        let before = readout.pageSwaps
        view.stagePointer(over: shell.id)
        try expect(readout.reading.hasPrefix("digest"), "a node the pointer has only just reached does not take the readout yet")
        _ = brainPump(0.12)
        try expect(readout.reading.hasPrefix("step"), "after 40 ms of rest the readout reads that step out")
        let stepText = readout.visibleText
        try expect(
            stepText.contains(NeuralReadout.fullSubject(of: shell).components(separatedBy: "\n")[0].prefix(24))
                && stepText.contains(shell.zone.label),
            "in full: the command and the zone it ran in (\(stepText.replacingOccurrences(of: "\n", with: "|").prefix(300)) / \(NeuralReadout.fullSubject(of: shell).prefix(40)))")
        let stepSize = (gtk_widget_get_width(readout.widget), gtk_widget_get_height(readout.widget))
        try expect(stepSize == digestSize, "the panel is the same size for a step as for the digest (\(stepSize) and \(digestSize))")
        try expect(readout.pageSwaps == before + 1, "and was built once for it")
        view.stagePointer(over: shell.id)
        view.stagePointer(over: shell.id)
        _ = brainPump(0.1)
        try expect(readout.pageSwaps == before + 1, "the same step arriving again builds nothing")
        try expect(
            view.leaderState.current?.stepID == shell.id && view.leaderState.searches == 1,
            "the leader line goes to that node by a route searched once (\(view.leaderState.searches))")
        if let leg = view.leaderState.current, let anchor = view.currentMetrics.leaderAnchor(forNodeAt: leg.node) {
            try expect(
                leg.route.last == anchor && NeuralLeader.isOnRoads(leg.route)
                    && abs(leg.anchor.x * 1 - anchor.x) < 0.001,
                "which ends on the readout's edge on the node's own row, on the wires' 45 degree roads")
            let tab = view.currentMetrics.leaderTab(forNodeAt: leg.node)
            try expect(
                tab.map { abs($0.x + 1 - view.currentMetrics.readout.x) <= 2 && $0.width == 3 && $0.height == 24 } ?? false,
                "and lands on a 3 by 24 tab on the hairline")
        }
        view.stagePointer(over: nil)
        _ = brainPump(0.2)
        try expect(readout.reading.hasPrefix("step"), "leaving a node keeps its readout for the grace, so a drift across a wire is no flash")
        _ = brainPump(0.45)
        try expect(readout.reading.hasPrefix("digest"), "and the digest comes back once the 400 ms are up")

        view.stagePointer(over: shell.id)
        _ = brainPump(0.12)
        view.stagePointer(over: nil)
        view.readoutPointer(inside: true)
        _ = brainPump(0.7)
        try expect(readout.reading.hasPrefix("step"), "the pointer in the readout keeps what it shows, however long")
        view.readoutPointer(inside: false)
        _ = brainPump(0.55)
        try expect(readout.reading.hasPrefix("digest"), "and leaving it starts the grace")

        view.pin(shell.id)
        _ = brainPump(0.1)
        let pinned = readout.shown?.step?.header.isPinned == true
        try expect(pinned && readout.visibleText.contains(BrainWords.pinned), "a click puts the cursor on the step and the panel says so")
        view.stagePointer(over: view.model.steps[0].id)
        _ = brainPump(0.3)
        try expect(
            readout.shown?.step?.stepID == view.model.steps[0].id && view.model.pinnedStep == shell.id,
            "the pointer elsewhere previews that step and leaves the cursor where it is")
        view.stagePointer(over: nil)
        _ = brainPump(0.5)
        try expect(readout.shown?.step?.stepID == shell.id, "and leaving it returns the readout to the cursor")
        if let relation = readout.shown?.step?.relations.first, let target = relation.stepIDs.first {
            view.pin(target)
            _ = brainPump(0.1)
            try expect(readout.shown?.step?.stepID == target, "a relation chip pins the step it names (\(relation.label))")
        }
        _ = view.escapePressed()
        _ = brainPump(0.3)
        try expect(view.model.pinned == nil && readout.reading.hasPrefix("digest"), "Esc lets go of the pin (pinned=\(view.model.pinned ?? "-") cursor=\(view.model.pinnedStep ?? "-") reading=\(readout.reading) focus=\(view.model.browseFocus) filter=\(view.model.stepList.filter.isActive) hovered=\(view.model.browseState.hovered ?? "-") phase=\(view.phase))")

        let edit = view.model.steps.first { $0.zone == .act }!
        view.pin(edit.id)
        _ = brainPump(0.3)
        try expect(
            readout.visibleText.contains(BrainWords.diff) || readout.visibleText.contains(NeuralReading.title(of: edit)),
            "an edit reads out its diff")
        view.clearSelection()

        view.dive(.shell)
        _ = brainPump(0.3)
        try expect(readout.reading.hasPrefix("zone"), "diving into a zone makes the readout its list")
        let zoneSize = (gtk_widget_get_width(readout.widget), gtk_widget_get_height(readout.widget))
        try expect(zoneSize == digestSize, "of the same size again")
        _ = brainPump(0.7)
        _ = view.escapePressed()
        _ = brainPump(0.7)
        try expect(view.stage?.diveZone == nil, "Esc surfaces")

        view.toggleReplay()
        view.scrub(to: 0.4)
        _ = brainPump(0.3)
        try expect(readout.reading.hasPrefix("replay"), "a replay makes the readout its log")
        view.toggleReplay()
        _ = brainPump(0.2)

        view.focusStage()
        _ = view.brainKey(keyval: UInt32(GDK_KEY_Down), state: 0)
        _ = brainPump(0.1)
        try expect(
            view.model.pinnedStep != nil && readout.reading.hasPrefix("step"),
            "an arrow key on the head walks the list to a step and the readout follows it")
        _ = view.escapePressed()
        view.pin(shell.id)
        _ = brainPump(0.15)
        _ = view.brainKey(keyval: UInt32(GDK_KEY_c), state: 0)
        try expect(view.list?.copiedID == shell.id, "and `c` copies its subject")
        _ = view.escapePressed()

        let tokens = view.answerChips
        let computations = view.tokenComputations
        for _ in 0..<40 { _ = view.answerChips }
        try expect(
            view.tokenComputations == computations && view.tokenComputations <= 2 && !tokens.isEmpty,
            "the words of the answer are searched for once per answer and revision (\(view.tokenComputations))")
        try expect(readout.page?.adjustment != nil && readout.bodyHeight > 0, "the body scrolls inside the panel")
        bed.close()

        let (waiting, _) = (brains, builder)
        _ = waiting
        BrainCompositors.dropIdle(olderThan: 0)
    }

    // MARK: moves

    private static func checkBrainMoves(_ expect: (Bool, String) throws -> Void) throws {
        let (brains, builder) = try brainRows()
        var closed = brains[1]
        closed.open = false
        var opened = closed
        opened.open = true
        let policy: () -> NeuralOpenPolicy? = { builder.brainPolicy }

        let metrics = NeuralStageMetrics.make(width: 1000, density: .comfortable)
        let open = NeuralTransition.make(.open, metrics: metrics, nodeCount: 23)
        let f0 = open.frame(at: 0)
        let f1 = open.frame(at: 1)
        try expect(
            f0.traveller == metrics.card.picture && f0.rowHeight == metrics.card.height
                && f1.traveller == metrics.stage && f1.rowHeight == metrics.rowHeight,
            "a move begins on the card's picture and ends on the stage, at the heights of each")
        let mid = open.frame(at: 0.4)
        let back = open.reversed(from: 0.4)
        try expect(
            back.frame(at: 0).traveller == mid.traveller && back.frame(at: 0).rowHeight == mid.rowHeight
                && back.frame(at: 1).traveller == f0.traveller,
            "pressed again in mid-move, it turns round from where it is and ends where it began")
        try expect(
            NeuralTransition.make(.open, metrics: metrics, nodeCount: 23, reduceMotion: true).fullDuration == 0.120
                && NeuralTransition.make(.open, metrics: metrics, nodeCount: 23, level: .strained).fullDuration == 0.160
                && NeuralTransition.make(.open, metrics: metrics, nodeCount: 23, level: .strained).frame(at: 0.3).sweepAmount == 0
                && open.fullDuration == 0.320
                && NeuralTransition.make(.close, metrics: metrics, nodeCount: 23).fullDuration == 0.220
                && NeuralTransition.make(.swap, metrics: metrics, nodeCount: 23).fullDuration == 0.280,
            "320, 220 and 280 ms; 120 for reduced motion; 160 with no sweep when the window is strained")

        BrainMoveLog.reset()
        let bed = try BrainBed(row: closed, width: 1000, key: "st-move", policy: policy)
        _ = brainPump(8) { bed.view.card.hasPicture && bed.view.card.hasContent }
        _ = brainPump(0.4)
        var heights: [Double] = []
        bed.view.restate(opened)
        let began = Date()
        var landed = false
        while Date().timeIntervalSince(began) < 20 {
            while g_main_context_iteration(nil, 0) != 0 {}
            heights.append(Double(gtk_widget_get_height(bed.widget)))
            if bed.view.phase == .open { landed = true; break }
            Thread.sleep(forTimeInterval: 0.004)
        }
        let took = Date().timeIntervalSince(began)
        try expect(landed, "the card opens into the stage (\(String(format: "%.2f", took)) s)")
        let final = Double(gtk_widget_get_height(bed.widget))
        let cardHeight = NeuralStageMetrics.make(width: 1000, density: bed.view.density).card.height
        try expect(
            final > cardHeight + 100 && abs(final - NeuralStageMetrics.make(width: 1000, density: bed.view.density).rowHeight) <= 2
                && zip(heights, heights.dropFirst()).allSatisfy { $1 >= $0 - 1.5 } && (heights.max() ?? 0) <= final + 1.5,
            "and the row's height only ever grows from the card's to the stage's on the way (\(heights.count) samples)")
        let gaps = BrainMoveLog.lastGaps.sorted()
        let median = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
        let slow = gaps.filter { $0 > median * 1.5 + 0.002 }.count
        report(
            "brain move: \(BrainMoveLog.lastFrames) frames in \(String(format: "%.0f", took * 1000)) ms, median gap \(String(format: "%.1f", median * 1000)) ms, worst \(String(format: "%.1f", (gaps.last ?? 0) * 1000)) ms, \(slow) over 1.5x")
        try expect(
            BrainMoveLog.moves == 1 && BrainMoveLog.lastFrames >= 6 && slow <= 1,
            "at most one frame of the move is slower than one and a half display intervals (\(slow) of \(BrainMoveLog.lastFrames))")
        try expect(
            bed.view.stage?.hasPicture == true && bed.view.readout != nil && bed.view.footer != nil,
            "and the stage, the readout and the footer stand where the move left them")

        bed.view.restate(closed)
        let shut = Date()
        var shrank = false
        while Date().timeIntervalSince(shut) < 2 {
            while g_main_context_iteration(nil, 0) != 0 {}
            if bed.view.phase == .closed { shrank = true; break }
            Thread.sleep(forTimeInterval: 0.004)
        }
        try expect(shrank && bed.view.stage == nil, "closing carries the head back into the card and lets go of the stage")
        _ = brainPump(0.3)
        try expect(
            abs(Double(gtk_widget_get_height(bed.widget)) - cardHeight) <= 1.5 && bed.view.card.hasPicture,
            "the row is the card's height again and the card has its picture")

        bed.view.restate(opened)
        _ = brainPump(0.12)
        let midway = bed.view.moveState?.progress ?? -1
        bed.view.restate(closed)
        var lows: [Double] = []
        let turned = Date()
        while Date().timeIntervalSince(turned) < 1.2 {
            while g_main_context_iteration(nil, 0) != 0 {}
            lows.append(Double(gtk_widget_get_height(bed.widget)))
            if bed.view.phase == .closed { break }
            Thread.sleep(forTimeInterval: 0.004)
        }
        let rising = zip(lows, lows.dropFirst()).filter { $1 > $0 + 8 }.count
        try expect(
            midway > 0 && midway < 1 && bed.view.phase == .closed && rising <= 1,
            "a press in the middle of the move reverses it without a jump (turned at \(String(format: "%.2f", midway)))")
        bed.close()

        tailscode_set_animations_enabled(0)
        tailscode_notify_animations()
        let still = try BrainBed(row: closed, width: 1000, key: "st-move-reduced", policy: policy)
        _ = brainPump(8) { still.view.card.hasPicture }
        BrainMoveLog.reset()
        still.view.restate(opened)
        let quick = Date()
        _ = brainPump(1.5) { still.view.phase == .open }
        let reduced = Date().timeIntervalSince(quick)
        try expect(still.view.phase == .open && reduced < 0.6, "with reduced motion it is a 120 ms crossfade (\(String(format: "%.2f", reduced)) s)")
        still.close()
        tailscode_set_animations_enabled(1)
        tailscode_notify_animations()

        let offscreen = try BrainBed(row: closed, width: 1000, key: "st-move-off", policy: policy)
        offscreen.host.onScreen = { _ in false }
        _ = brainPump(5) { offscreen.view.card.hasPicture }
        offscreen.view.restate(opened)
        _ = brainPump(0.05)
        try expect(
            offscreen.view.moveState == nil && offscreen.view.phase == .open,
            "a row nobody can see takes the end state with no move")
        offscreen.close()

        try checkBrainAnchorMove(expect, closed: closed, opened: opened, policy: policy)
        BrainCompositors.dropIdle(olderThan: 0)
    }

    /// The reader's place while a brain above it opens and closes, sampled on every frame.
    private static func checkBrainAnchorMove(
        _ expect: (Bool, String) throws -> Void, closed: BrainRow, opened: BrainRow,
        policy: @escaping () -> NeuralOpenPolicy?
    ) throws {
        let host = BrainHost()
        host.sessionKey = "st-anchor-move"
        host.policy = policy
        let context = TranscriptContext()
        context.brains = host
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), 1000, 700)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        let canvas = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        var rows: [ScrollAnchor.Row] = []
        func filler(_ key: String) {
            let box = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_widget_set_size_request(box, -1, 90)
            gtk_box_append(ptr(box), Gtk.label(key, css: nil, selectable: false))
            gtk_box_append(ptr(canvas), box)
            rows.append((key, UInt(bitPattern: box)))
        }
        for index in 0..<3 { filler("before-\(index)") }
        let widget = BrainView.make(closed, context: context)
        gtk_box_append(ptr(canvas), widget)
        rows.append(("brain", UInt(bitPattern: widget)))
        for index in 0..<14 { filler("after-\(index)") }
        gtk_scrolled_window_set_child(op(scroller), canvas)
        gtk_window_set_child(ptr(window), scroller)
        gtk_window_present(ptr(window))
        guard let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)),
            let view = BrainView.current(of: widget)
        else { throw SelfTestFailure("brain: no scroller") }
        _ = brainPump(5) { gtk_widget_get_mapped(widget) != 0 && gtk_widget_get_width(widget) > 8 }
        _ = brainPump(8) { view.card.hasPicture }
        _ = brainPump(0.4)
        let anchor = ScrollAnchor(
            adjustment: adjustment, canvas: canvas, rows: { rows },
            place: { gtk_adjustment_set_value(adjustment, $0) })
        Gtk.onNotify(UnsafeMutableRawPointer(adjustment), property: "upper") { anchor.reassert() }
        host.anchor = { anchor.capture() }
        host.onScreen = { _ in true }
        func top(of key: String) -> Double {
            guard let row = rows.first(where: { $0.key == key }),
                let raw = UnsafeMutableRawPointer(bitPattern: row.widget)
            else { return .nan }
            var x = 0.0
            var y = 0.0
            var w = 0.0
            var h = 0.0
            _ = tailscode_widget_bounds_in(ptr(raw), canvas, &x, &y, &w, &h)
            return y - gtk_adjustment_get_value(adjustment)
        }
        gtk_adjustment_set_value(adjustment, top(of: "brain") + gtk_adjustment_get_value(adjustment) - 40)
        _ = brainPump(0.4)
        let place = top(of: "brain")
        view.restate(opened)
        var worst = 0.0
        var samples = 0
        let began = Date()
        while Date().timeIntervalSince(began) < 3 {
            while g_main_context_iteration(nil, 0) != 0 {}
            worst = max(worst, abs(top(of: "brain") - place))
            samples += 1
            if view.phase == .open { break }
            Thread.sleep(forTimeInterval: 0.004)
        }
        _ = brainPump(0.3)
        worst = max(worst, abs(top(of: "brain") - place))
        try expect(
            worst <= 1.5 && samples > 6,
            "the row being opened keeps its place on the screen through every frame of the move (\(String(format: "%.1f", worst)) px over \(samples) samples)")
        view.restate(closed)
        let shut = Date()
        while Date().timeIntervalSince(shut) < 2 {
            while g_main_context_iteration(nil, 0) != 0 {}
            worst = max(worst, abs(top(of: "brain") - place))
            if view.phase == .closed { break }
            Thread.sleep(forTimeInterval: 0.004)
        }
        try expect(worst <= 1.5, "and again as it closes (\(String(format: "%.1f", worst)) px)")
        gtk_window_set_child(ptr(window), nil)
        gtk_window_destroy(ptr(window))
        _ = brainPump(0.3)
    }

    // MARK: what the performance work promised

    private static func checkBrainEfficiency(_ expect: (Bool, String) throws -> Void) throws {
        let (brains, builder) = try brainRows()
        var open = brains[1]
        open.open = true
        let policy: () -> NeuralOpenPolicy? = { builder.brainPolicy }
        let bed = try BrainBed(row: open, width: 900, key: "st-eff", policy: policy)
        _ = brainPump(10) { bed.view.stage?.hasPicture == true }
        _ = brainPump(0.4)
        guard let stage = bed.view.stage else { throw SelfTestFailure("brain: no stage") }

        let runs = BrainStage.Composer.runs
        let frames = stage.frames
        for _ in 0..<12 {
            stage.invalidate()
            stage.render(BrainClock.now)
        }
        _ = brainPump(1.0) { stage.isIdle }
        try expect(BrainStage.Composer.mainThreadRuns == 0 && BrainStage.Composer.runs > runs, "the head is composited off the main loop (\(BrainStage.Composer.runs - runs) runs, \(BrainStage.Composer.mainThreadRuns) on it)")
        try expect(stage.droppedJobs > 0, "a request that has not started is replaced by a newer one (\(stage.droppedJobs) replaced)")
        let perFrame = Double(stage.mainNanoseconds) / Double(max(1, stage.frames)) / 1000
        try expect(perFrame < 4000, "and the main loop's share of a frame is a request and a scene (\(Int(perFrame)) us a frame over \(stage.frames - frames) new)")

        stage.configure(width: 2400, height: 1560, scaleFactor: 2)
        let capped = stage.targetSize()
        try expect(
            capped.map { $0.width <= 1100 && $0.height <= 720 && $0.scale < 1 } ?? false,
            "a stage far larger than 760 is rendered no larger than 1100 by 720 device pixels (\(capped.map { "\($0.width)x\($0.height)" } ?? "none"))")
        stage.configure(width: 760, height: 554, scaleFactor: 2)
        let normal = stage.targetSize()
        try expect(
            normal.map { $0.width <= 1100 && $0.height <= 720 } ?? false,
            "and a 760 point stage at twice the density falls within it too (\(normal.map { "\($0.width)x\($0.height)" } ?? "none"))")
        stage.configure(width: Int(NeuralStageMetrics.make(width: 900, density: bed.view.density).stage.width), height: Int(NeuralStageMetrics.make(width: 900, density: bed.view.density).stage.height), scaleFactor: 1)

        var hits = 0
        var misses = 0
        var entries: Int32 = 0
        tailscode_text_cache_stats(&hits, &misses, &entries)
        let hit0 = hits
        for _ in 0..<20 {
            stage.refreshScene(BrainClock.now)
            gtk_widget_queue_draw(stage.nodes)
            stage.recompose()
            _ = brainPump(0.04)
        }
        tailscode_text_cache_stats(&hits, &misses, &entries)
        try expect(hits - hit0 > misses / 2 || hits - hit0 > 100, "the nodes' words are laid out once and reused (\(hits - hit0) reused, \(misses) made, \(entries) held)")

        let restates = bed.view.row
        let beforeFrames = stage.frames
        for _ in 0..<30 { bed.view.restate(restates) }
        try expect(stage.frames - beforeFrames <= 1, "thirty states in a row draw nothing themselves (\(stage.frames - beforeFrames) frames); the clock draws once")
        _ = brainPump(0.3)
        try expect(!bed.view.isClockRunning, "and the clock stops again when the head is settled")

        let dangling = try BrainBed(row: open, width: 900, key: "st-eff-dangling", policy: policy)
        _ = brainPump(8) { dangling.view.stage?.hasPicture == true }
        var steps = dangling.view.row.turn.steps
        steps[steps.count - 1].status = .running
        var turn = dangling.view.row.turn
        turn.steps = steps
        var held = dangling.view.row
        held = BrainRow(turn: turn, open: true, showRows: false, answer: held.answer, look: held.look, prompt: held.prompt)
        dangling.view.restate(held)
        _ = brainPump(0.6)
        try expect(
            dangling.view.model.turn.outcome != .running && !dangling.view.isClockRunning,
            "a settled turn with one tool call the record never closed owns no clock")
        dangling.host.onScreen = { _ in false }
        var running = held
        var liveTurn = turn
        liveTurn.outcome = .running
        running = BrainRow(turn: liveTurn, open: true, showRows: false, answer: "", look: held.look, prompt: nil)
        dangling.view.restate(running)
        dangling.view.viewportMoved()
        _ = brainPump(0.5)
        try expect(!dangling.view.isClockRunning, "and a running brain scrolled out of view owns none either")
        dangling.host.onScreen = { _ in true }
        dangling.view.viewportMoved()
        _ = brainPump(0.5)
        try expect(dangling.view.isClockRunning, "which comes back when it is in view")
        dangling.close()

        let messages = NeuralDemo.conversation()
        let leading = Array(messages.dropFirst(1))
        let ledger = BrainLedger()
        let pass = ledger.pass(
            messages: leading, running: false, awaiting: NeuralAwaiting(approvals: [], answers: [], interrupted: []),
            settings: BrainBuildSettings(style: .brain, choices: [:], rowsShown: [], look: "x"))
        let slid = BrainLedger().pass(
            messages: Array(messages.dropFirst(2)), running: false, awaiting: NeuralAwaiting(approvals: [], answers: [], interrupted: []),
            settings: BrainBuildSettings(style: .brain, choices: [:], rowsShown: [], look: "x"))
        try expect(
            pass?.turns.map(\.id) == ["b-m1"] && slid?.turns.map(\.id) == ["b-m1"],
            "a window that starts inside a turn keeps that turn's rows and gives the later turns ids that stay as it slides (\(pass?.turns.map(\.id) ?? []))")
        bed.close()
        BrainCompositors.dropIdle(olderThan: 0)
    }

    // MARK: the budget's hysteresis

    private static func checkBrainBudget(_ expect: (Bool, String) throws -> Void) throws {
        let (brains, builder) = try brainRows()
        var open = brains[1]
        open.open = true
        let bed = try BrainBed(row: open, width: 900, key: "st-budget", policy: { builder.brainPolicy })
        _ = brainPump(10) { bed.view.stage?.hasPicture == true }
        let held = bed.view.stage
        let widgets = widgetCount(bed.widget)
        BrainBudget.reset()
        BrainBudget.enterDelay = 0.25
        BrainBudget.leaveDelay = 0.5
        let flips = BrainBudget.flips
        let calm = TileGovernor.animation(level: .calm, reducedMotion: false)
        let critical = TileGovernor.animation(level: .critical, reducedMotion: false)
        CascadeBudget.apply(critical, level: .critical)
        bed.host.budgetChanged()
        _ = brainPump(0.1)
        try expect(BrainBudget.stageAllowed, "the critical level has to last before the head gives up its picture")
        CascadeBudget.apply(calm, level: .calm)
        bed.host.budgetChanged()
        _ = brainPump(0.5)
        try expect(BrainBudget.stageAllowed && BrainBudget.flips == flips, "and a level that comes back in time changes nothing")
        CascadeBudget.apply(critical, level: .critical)
        bed.host.budgetChanged()
        _ = brainPump(0.5)
        try expect(!BrainBudget.stageAllowed && bed.view.stage === held, "after the delay it stops drawing but keeps its widgets")
        try expect(widgetCount(bed.widget) == widgets && bed.view.phase == .open, "the stage is not rebuilt for it (\(widgetCount(bed.widget)) widgets)")
        CascadeBudget.apply(calm, level: .calm)
        bed.host.budgetChanged()
        _ = brainPump(0.25)
        try expect(!BrainBudget.stageAllowed, "and takes it back only after a longer calm")
        _ = brainPump(0.6)
        try expect(
            BrainBudget.stageAllowed && BrainBudget.flips == flips + 2 && bed.view.stage === held,
            "when it does, nothing is rebuilt either (\(BrainBudget.flips - flips) flips)")
        BrainBudget.enterDelay = 3
        BrainBudget.leaveDelay = 10
        BrainBudget.reset()
        CascadeBudget.apply(calm, level: .calm)
        bed.close()
        BrainCompositors.dropIdle(olderThan: 0)
        try expect(
            BrainCompositors.resident.compositors == 0 && NeuralAssetStore.shared.retainCount == 0,
            "closing the last brain frees the compositors and the decoded layers")
    }
}
