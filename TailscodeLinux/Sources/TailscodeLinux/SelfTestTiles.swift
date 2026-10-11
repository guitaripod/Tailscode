import CAdw
import CGtkShim
import Foundation
import TailscodeCore

private final class Plan: @unchecked Sendable {
    var rects: [Int: TileRect] = [:]
    var children: [UnsafeMutablePointer<GtkWidget>] = []
}

private func tilePump(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        while g_main_context_iteration(nil, 0) != 0 {}
        if done() { return true }
        usleep(4000)
    }
    return done()
}

extension SelfTest {
    /// The canvas on its own, with plain boxes for children: every placed child lands on the rect
    /// the solver gave it, layers keep overlays above dividers above panes however they were added,
    /// an unplaced child is hidden and not moved, a hammer of placements never changes a parent, a
    /// child that already has one is refused and counted, a clamp holds a conversation that wants
    /// more room than its tile, a divider is an accessible separator with a resize cursor, and
    /// letting go of the canvas lets go of every child.
    static func checkTileCanvas() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("tile canvas: \(label)") }
            checks += 1
        }

        let watches = UnsafeMutablePointer<gpointer?>.allocate(capacity: 6)
        defer { watches.deallocate() }
        for index in 0..<6 { watches[index] = nil }
        let reparentsBefore = TileCanvas.reparents

        do {
            let plan = Plan()
            plan.children = (0..<5).map { _ in Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0) }
            let canvas = TileCanvas { _, _, sink in
                for (index, rect) in plan.rects { sink.place(plan.children[index], rect) }
            }
            let children = plan.children
            for (index, child) in children.enumerated() {
                watches[index] = UnsafeMutableRawPointer(child)
                g_object_add_weak_pointer(ptr(child), watches + index)
            }
            canvas.add(children[4], layer: .overlays)
            canvas.add(children[3], layer: .dividers)
            for index in 0..<3 { canvas.add(children[index], layer: .panes) }
            var order: [UnsafeMutablePointer<GtkWidget>] = []
            var walk = gtk_widget_get_first_child(canvas.widget)
            while let current = walk {
                order.append(current)
                walk = gtk_widget_get_next_sibling(current)
            }
            try expect(
                order == [children[0], children[1], children[2], children[3], children[4]],
                "an overlay added first still stands above the dividers above the panes")

            plan.rects = [
                0: TileRect(x: 0, y: 0, width: 300, height: 200),
                1: TileRect(x: 301, y: 0, width: 499, height: 200),
                2: TileRect(x: 0, y: 201, width: 800, height: 299),
                3: TileRect(x: 296, y: 0, width: 9, height: 200),
                4: TileRect(x: 10, y: 10, width: 100, height: 20),
            ]
            let window = gtk_window_new()!
            gtk_window_set_default_size(ptr(window), 800, 500)
            gtk_window_set_child(ptr(window), canvas.widget)
            gtk_window_present(ptr(window))
            canvas.invalidate()
            func bounds(_ index: Int) -> TileRect? {
                Gtk.bounds(of: children[index], in: canvas.widget).map {
                    TileRect(
                        x: Int32($0.x.rounded()), y: Int32($0.y.rounded()),
                        width: Int32($0.width.rounded()), height: Int32($0.height.rounded()))
                }
            }
            try expect(
                tilePump(3, until: { bounds(0)?.width == 300 }), "the canvas allocates its children")
            for index in 0..<5 {
                try expect(bounds(index) == plan.rects[index], "child \(index) stands on its rect")
            }

            plan.rects[1] = nil
            canvas.invalidate()
            try expect(
                tilePump(2, until: { gtk_widget_get_child_visible(children[1]) == 0 }),
                "a child the solver does not place is hidden")
            try expect(gtk_widget_get_mapped(children[1]) == 0, "a hidden child is not mapped")
            try expect(
                gtk_widget_get_parent(children[1]) == canvas.widget,
                "hiding a child does not take it out of the canvas")
            plan.rects[1] = TileRect(x: 301, y: 0, width: 499, height: 200)
            canvas.invalidate()
            try expect(
                tilePump(2, until: { gtk_widget_get_child_visible(children[1]) != 0 }),
                "and placing it again shows it where it was")
            try expect(bounds(1) == plan.rects[1], "on its rect")

            for round in 0..<50 {
                let shift = Int32(round % 7) * 10
                plan.rects[0] = TileRect(x: 0, y: 0, width: 300 - shift, height: 200)
                plan.rects[1] = round % 5 == 0 ? nil : TileRect(
                    x: 301 - shift, y: 0, width: 499 + shift, height: 200)
                canvas.invalidate()
                _ = tilePump(0.01)
            }
            try expect(
                TileCanvas.reparents == reparentsBefore, "fifty re-placements re-parent nothing")
            for child in children {
                try expect(
                    gtk_widget_get_parent(child) == canvas.widget, "every child kept its parent")
            }
            let before = canvas.childCount
            canvas.add(children[0], layer: .panes)
            try expect(
                TileCanvas.reparents == reparentsBefore + 1,
                "adding a child that already has a parent is refused and counted")
            try expect(canvas.childCount == before, "and adds nothing")

            let clamp = tailscode_tile_clamp_new()!
            let wide = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_widget_set_size_request(wide, 280, 200)
            tailscode_tile_clamp_add(clamp, wide)
            canvas.add(clamp, layer: .panes)
            plan.children.append(clamp)
            plan.rects[5] = TileRect(x: 20, y: 40, width: 200, height: 100)
            canvas.invalidate()
            try expect(
                tilePump(2, until: { Gtk.bounds(of: clamp, in: canvas.widget)?.width == 200 }),
                "a clamp takes a tile smaller than what is inside it")
            try expect(
                (Gtk.bounds(of: wide, in: clamp)?.width ?? 0) >= 280,
                "the conversation inside keeps the room it asked for")
            try expect(gtk_widget_get_overflow(clamp) == GTK_OVERFLOW_HIDDEN, "and is clipped")
            var minimum: Int32 = -1
            gtk_widget_measure(clamp, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, nil, nil, nil)
            try expect(minimum == 0, "a clamp has no minimum size of its own")

            let handlers = TileDivider.Handlers(
                began: { _, _ in }, moved: { _, _ in }, ended: { _, _ in }, equalize: {},
                key: { _ in true })
            let divider = TileDivider(id: SplitID(), axis: .horizontal, handlers: handlers)
            canvas.add(divider.widget, layer: .dividers)
            plan.children.append(divider.widget)
            plan.rects[6] = TileRect(x: 100, y: 300, width: 9, height: 100)
            canvas.invalidate()
            let placed = DividerPlacement(
                id: divider.id, axis: .horizontal,
                line: SplitRect(x: 104, y: 300, width: 1, height: 100),
                hit: SplitRect(x: 100, y: 300, width: 9, height: 100),
                parent: SplitRect(x: 0, y: 300, width: 400, height: 100), position: 104,
                lowest: 40, highest: 300)
            let label = "Divider between pane 1 and pane 2"
            divider.describe(placed, label: label)
            let reading = divider.reading(placed, label: label)
            try expect(reading.contains("role=separator"), "a divider is an accessible separator")
            try expect(
                reading.contains("label=ok") && reading.contains("min=ok")
                    && reading.contains("max=ok") && reading.contains("now=ok"),
                "it carries its label and where it stands between its extremes")
            try expect(
                tilePump(2, until: { Gtk.bounds(of: divider.widget, in: canvas.widget)?.width == 9 }),
                "it is nine points wide")
            let cursor = gtk_widget_get_cursor(divider.widget).flatMap { gdk_cursor_get_name($0) }
                .map { String(cString: $0) }
            try expect(cursor == "col-resize", "and wears the cursor that says it resizes")
            try expect(divider.focus(), "and takes the keyboard")
            try expect(
                gtk_widget_get_focusable(divider.widget) != 0 && tailscode_tile_divider_is(divider.widget) != 0,
                "it is focusable and says what it is")

            gtk_window_destroy(ptr(window))
            _ = tilePump(0.2)
        }
        _ = tilePump(0.3)
        for index in 0..<5 {
            try expect(watches[index] == nil, "child \(index) is finalized with the canvas")
        }
        try expect(
            TileCanvas.reparents == reparentsBefore + 1,
            "the whole run counted exactly the one refused add")
        return checks
    }
}

extension SelfTest {
    /// The canvas as the app builds it: real panes in real shells under a real window. Every
    /// placed shell stands on the rectangle Core's placement gives it; a structural verb is a
    /// different answer from the solver and never a new parent; a pane the window has no room for
    /// is hidden, named in the strip and back exactly where it was when there is room; density
    /// follows the governor and the room, with hysteresis; dividers answer a key and a drag through
    /// Core's clamp; a pin, a pause and a resume do what they say; and the snapshot still
    /// carries both generations of itself.
    static func checkTileHost() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("tile host: \(label)") }
            checks += 1
        }

        let host = MainWindow()
        let tile = TileHost(host: host)
        host.installTiling(tile)
        defer { Seatbelts.shared.onDecision = nil }
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), 1200, 800)
        gtk_window_set_child(ptr(window), tile.container)
        gtk_window_present(ptr(window))

        func resize(_ width: Int32, _ height: Int32) throws {
            gtk_window_set_default_size(ptr(window), width, height)
            let settled = tilePump(
                4, until: {
                    Int32(tile.canvas.size.width) == width && Int32(tile.canvas.size.height) == height
                })
            try expect(settled, "the window takes \(width)x\(height)")
            _ = tilePump(0.25)
        }
        func settle() { _ = tilePump(0.3) }

        let reparentsBefore = TileCanvas.reparents
        let layout = SplitEven.layout(count: 5, as: .grid)!
        _ = tile.restore(SplitSnapshot(layout: layout, contents: [:]))
        for pane in tile.orderedPanes { pane.kindOverride = .chat }
        try expect(
            tilePump(4, until: { Int32(tile.canvas.size.width) == 1200 }), "the canvas has the window's size")
        settle()

        func expectedPlacement() -> PanePlacement {
            tile.layout.placement(in: tile.canvas.size) { id in
                PaneSizing.layoutMinimum(kind: tile.panes[id]?.paneKind(held: false) ?? .empty)
            }
        }
        func rect(of id: PaneID) -> TileRect? {
            tile.shells[id].flatMap { Gtk.bounds(of: $0.widget, in: tile.canvas.widget) }.map {
                TileRect(
                    x: Int32($0.x.rounded()), y: Int32($0.y.rounded()),
                    width: Int32($0.width.rounded()), height: Int32($0.height.rounded()))
            }
        }
        func matchesCore() -> Bool {
            let placement = expectedPlacement()
            for id in tile.layout.paneIDs {
                guard let shell = tile.shells[id] else { return false }
                if let frame = placement.frames[id] {
                    if rect(of: id) != TileRect(frame) { return false }
                    if gtk_widget_get_child_visible(shell.widget) == 0 { return false }
                } else if gtk_widget_get_child_visible(shell.widget) != 0 {
                    return false
                }
            }
            return true
        }
        func faces() -> [TileShell.Face] {
            tile.layout.paneIDs.compactMap { tile.shells[$0]?.face }
        }
        func count(_ face: TileShell.Face) -> Int { faces().filter { $0 == face }.count }

        try expect(matchesCore(), "every shell stands on the rectangle Core's placement gives it")
        try expect(tile.canvasChildCount == 5 + 4 + 3, "five shells, four dividers and three overlays")
        try expect(count(.full) == 5, "with room and no budget set, every chat is whole")
        let whole = tile.layout.paneIDs.map { rect(of: $0) }

        var governor = TileGovernor(cores: 8)
        func decide(_ setting: LiveBudget, at now: TimeInterval) -> GovernorDecision {
            governor.evaluate(
                now: now, sample: GovernorSample(),
                panes: tile.seatbeltPanes(waiting: [:]).facts, setting: setting)
        }
        let narrowed = decide(.auto, at: 100)
        try expect(narrowed.fullBudget == 2, "eight cores give a budget of two")
        tile.applyGovernor(narrowed)
        settle()
        try expect(count(.full) == 2 && count(.glance) == 3, "the rest of the chats become glances")
        let focusedID = tile.layout.focusedPane
        try expect(tile.shells[focusedID]?.face == .full, "the focused chat stays whole")
        for id in tile.layout.paneIDs where tile.shells[id]?.face == .glance {
            try expect(tile.panes[id]?.isParked == true, "a glance owns no stream")
            try expect(
                tile.shells[id].map { gtk_widget_get_visible($0.glance!.widget) != 0 } == true,
                "and wears its tile")
        }
        try expect(tile.liveCounts == (2, 5), "the chip counts two whole chats of five")
        try expect(matchesCore(), "demoting a pane moves no rectangle")

        let kept = tile.layout.paneIDs.first { tile.shells[$0]?.face == .glance }!
        tile.togglePin(kept)
        settle()
        try expect(
            tile.shells[kept]?.face == .full && tile.activePinned(kept),
            "keeping a pane live gives it a whole slot before the other peers")
        try expect(count(.full) == 2, "inside the same budget")
        let pinnedSnapshot = tile.snapshot()
        try expect(pinnedSnapshot.pinned == [kept.raw], "and the snapshot remembers it")

        var strained = TileGovernor(cores: 8)
        strained.hold(atLeast: .strained, until: 10_000)
        let held = strained.evaluate(
            now: 100, sample: GovernorSample(), panes: tile.seatbeltPanes(waiting: [:]).facts,
            setting: .all)
        try expect(held.level == .strained && held.fullBudget == 1, "a strained machine allows one")
        tile.applyGovernor(held)
        settle()
        try expect(
            count(.full) == 1 && tile.shells[focusedID]?.face == .full,
            "and ignores both the pin and Keep all live")
        tile.togglePin(kept)
        settle()

        tile.applyGovernor(decide(.all, at: 200))
        settle()
        try expect(count(.full) == 5, "Keep all live brings every chat back whole")
        for pane in tile.orderedPanes {
            try expect(!pane.isParked, "and every chat takes its stream back")
        }
        try expect(matchesCore(), "promoting moves no rectangle")

        try resize(866, 800)
        try expect(count(.full) == 5, "a chat 288 wide that was whole stays whole")
        try resize(700, 800)
        try expect(
            count(.glance) == 3 && count(.full) == 2,
            "233 wide is a glance whatever the governor says, and the wider row stays whole")
        try expect(matchesCore(), "at 700 wide")
        try resize(866, 800)
        try expect(
            count(.glance) == 3, "and 288 is not enough to come back: it needs 296")
        try resize(1200, 800)
        try expect(count(.full) == 5, "room brings every chat back whole")
        try expect(tile.layout.paneIDs.map { rect(of: $0) } == whole, "exactly where it was")

        let tree = tile.snapshot()
        try resize(420, 300)
        try expect(!(tile.placement?.hidden.isEmpty ?? true), "a window too small hides panes")
        try expect(tile.placement?.hiddenReason == .noRoom, "for want of room")
        try expect(matchesCore(), "the placed ones stand on Core's rectangles")
        let hidden = tile.placement?.hidden ?? []
        try expect(
            tilePump(2, until: { tile.strip.chips.count == hidden.count }),
            "the strip names every hidden pane")
        try expect(tile.placement?.strip != nil, "and is placed along the bottom")
        try expect(
            tile.layout.paneIDs.filter { tile.panes[$0]?.isParked == true }.count >= hidden.count,
            "hidden panes are parked")
        for id in hidden {
            try expect(
                tile.shells[id].map { gtk_widget_get_child_visible($0.widget) == 0 } == true,
                "a hidden pane is not drawn")
        }
        try expect(
            tile.snapshot() == tree, "and the tree, ratios and focus are untouched")
        let chosen = hidden[0]
        tile.strip.press(chosen)
        settle()
        try expect(tile.layout.focusedPane == chosen, "pressing a chip focuses its pane")
        try expect(tile.placement?.isPlaced(chosen) == true, "and swaps it in")
        try resize(1200, 800)
        try expect(tile.placement?.hidden.isEmpty == true, "growing the window brings the rest back")
        try expect(matchesCore(), "on Core's rectangles")
        try expect(tile.placement?.strip == nil, "and the strip steps away")

        tile.zoomActive()
        settle()
        try expect(tile.placement?.hiddenReason == .zoomed, "a zoom hides every other pane")
        try expect(
            tilePump(2, until: { tile.strip.chips.count == 4 }), "and names them in the strip")
        try expect(matchesCore(), "the zoomed pane fills the canvas less the strip")
        tile.zoomActive()
        settle()
        try expect(tile.placement?.hidden.isEmpty == true, "unzooming shows every pane")

        let shellParents = tile.layout.paneIDs.compactMap { tile.shells[$0]?.widget }
        let bodies = tile.layout.paneIDs.compactMap { tile.panes[$0]?.root }
        tile.equalize()
        for round in 0..<50 {
            switch round % 10 {
            case 0: tile.arrange(.mainStack)
            case 1: tile.arrange(.grid)
            case 2: _ = tile.perform(.rotateSplits(true))
            case 3: tile.exchangeActive()
            case 4: _ = tile.perform(.promoteSplit)
            case 5: _ = tile.perform(.arrangeSplits)
            case 6: tile.zoomActive()
            case 7: tile.zoomActive()
            case 8: _ = tile.perform(.moveSplitToEdge(.left))
            default: tile.equalize()
            }
            if round % 10 == 9 { settle() }
        }
        settle()
        try expect(
            TileCanvas.reparents == reparentsBefore, "fifty structural verbs never re-parent")
        for widget in shellParents {
            try expect(
                gtk_widget_get_parent(widget) == tile.canvas.widget, "every shell kept the canvas")
        }
        for (index, body) in bodies.enumerated() {
            try expect(
                gtk_widget_get_parent(body) == shellParents[index], "every conversation kept its shell")
        }
        try expect(tile.canvasChildCount == 5 + 4 + 3, "and the canvas holds the same children")
        try expect(matchesCore(), "after the hammer every shell is on Core's rectangle")
        try expect(tile.layout.isValid && tile.paneCount == 5, "the tree is valid with every pane")

        tile.equalize()
        settle()
        let beforeKey = tile.placement?.dividers.first
        try expect(beforeKey != nil, "there is a divider to move")
        let id0 = tile.layout.splitIDs[0]
        _ = tile.driveDivider(0, key: .forward(large: false))
        settle()
        let afterKey = tile.placement?.divider(id0)
        try expect(
            afterKey.map { abs($0.position - ((beforeKey?.position ?? 0) + 16)) < 1.01 } == true,
            "an arrow moves a divider sixteen points")
        _ = tile.driveDivider(0, key: .back(large: true))
        settle()
        try expect(
            tile.placement?.divider(id0).map { abs($0.position - ((beforeKey?.position ?? 0) - 48)) < 1.01 }
                == true,
            "shift and an arrow, sixty-four")
        _ = tile.driveDivider(0, key: .highest)
        settle()
        let top = tile.placement?.divider(id0)
        try expect(top.map { $0.position == $0.highest } == true, "End goes to the extreme")
        _ = tile.driveDivider(0, key: .lowest)
        settle()
        let bottom = tile.placement?.divider(id0)
        try expect(bottom.map { $0.position == $0.lowest } == true, "Home to the other")
        try expect(matchesCore(), "no pane is squeezed under its minimum at either")

        let dragged = tile.simulateDrag(0, by: 5000)
        settle()
        try expect(
            dragged.map { $0.to == (tile.placement?.divider(id0)?.highest ?? -1) } == true,
            "a pointer past the end stops at Core's clamp")
        let shoved = tile.simulateDrag(0, by: -5000)
        settle()
        try expect(
            shoved.map { $0.to == (tile.placement?.divider(id0)?.lowest ?? -1) } == true,
            "and past the other end")
        tile.equalize()
        settle()
        let start = tile.placement?.divider(id0)?.position ?? 0
        let live = tile.simulateDrag(0, by: 37, ghost: false)
        settle()
        try expect(
            live.map { abs($0.to - (start + 37)) < 1.01 && !$0.ghosted } == true,
            "a live drag moves the divider where the pointer went")
        let ghosted = tile.simulateDrag(0, by: -60, ghost: true)
        settle()
        try expect(
            ghosted.map { $0.ghosted && abs($0.to - ($0.from - 60)) < 1.01 } == true,
            "a ghost drag commits once, to the same place a live one would")
        try expect(matchesCore(), "the drags left every shell on Core's rectangle")
        let encoded = tile.snapshot().encoded ?? ""
        try expect(
            encoded.contains("\"schema\":2") && encoded.contains("\"contents\"")
                && encoded.contains("\"pinned\"") && encoded.contains("\"sessions\""),
            "the snapshot is schema two and still carries the fields schema one read")

        let centers = tile.handleCenters(in: tile.container)
        try expect(centers.count == 4, "four dividers have a place to be pressed")
        for (_, x, y) in centers {
            try expect(
                tile.pane(at: x, y: y, in: tile.container) == nil,
                "a press on a divider activates no pane")
        }
        if let inside = tile.layout.paneIDs.first.flatMap({ tile.shells[$0] }),
            let box = Gtk.bounds(of: inside.widget, in: tile.container)
        {
            let found = tile.pane(at: box.x + box.width / 2, y: box.y + box.height / 2, in: tile.container)
            try expect(found === tile.orderedPanes.first, "a press in a pane lands in that pane")
        }

        tile.applyGovernor(decide(.auto, at: 300))
        settle()
        let parkedID = tile.layout.paneIDs.first { tile.shells[$0]?.face == .glance }!
        let paneIndex = tile.layout.paneIDs.firstIndex(of: parkedID)!
        tile.togglePark(parkedID)
        settle()
        try expect(
            tile.shells[parkedID]?.face == .paused && tile.shells[parkedID]?.parked != nil,
            "a paused chat wears the paused face")
        try expect(tile.panes[parkedID]?.isParked == true, "and owns no stream")
        try expect(tile.drivePark(paneIndex) == true, "pausing again is a toggle")
        settle()
        try expect(tile.shells[parkedID]?.face != .paused, "which takes it back")
        tile.togglePark(parkedID)
        settle()
        try expect(tile.pressResume(paneIndex), "Resume is a button")
        settle()
        try expect(tile.shells[parkedID]?.face != .paused, "and brings the chat back")

        let session = SplitPaneSession(profileID: "p", sessionID: "s")
        tile.setHeld([parkedID: session])
        settle()
        try expect(tile.shells[parkedID]?.face == .paused, "a chat a safe restore holds is paused")
        tile.setHeld([:])
        settle()
        try expect(tile.shells[parkedID]?.face != .paused, "until it is let go")

        let weakClosing: WeakChat = {
            let closing = tile.orderedPanes.last!
            tile.focus(closing, grabKeyboard: false)
            return WeakChat(closing)
        }()
        tile.closeActive()
        settle()
        try expect(tile.paneCount == 4 && tile.canvasChildCount == 4 + 3 + 3, "closing removes one shell")
        try expect(
            TileCanvas.reparents == reparentsBefore, "and still re-parents nothing")
        _ = tilePump(0.3)
        try expect(weakClosing.pane == nil, "a closed pane is freed")

        gtk_window_destroy(ptr(window))
        _ = tilePump(0.2)
        withExtendedLifetime(host) {}
        return checks
    }

    /// The old nested panes still boot behind `TAILSCODE_LEGACY_TILING=1`, build the same tree and
    /// answer the same verbs.
    static func checkLegacyTiling() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("legacy tiling: \(label)") }
            checks += 1
        }
        let host = MainWindow()
        let legacy = SplitHost(host: host)
        host.installTiling(legacy)
        let layout = SplitEven.layout(count: 3, as: .sideBySide)!
        _ = legacy.restore(SplitSnapshot(layout: layout, contents: [:]))
        try expect(legacy.paneCount == 3 && legacy.layout.isValid, "the nested host builds the tree")
        try expect(legacy.supportsDensity == false, "and says it has no densities")
        _ = legacy.perform(.arrangeSplits)
        try expect(legacy.paneCount == 3 && legacy.layout.isValid, "and answers a pane chord")
        legacy.closeActive()
        try expect(legacy.paneCount == 2, "and closes a pane")
        withExtendedLifetime(host) {}
        return checks
    }
}

private final class WeakChat: @unchecked Sendable {
    weak var pane: ChatPane?
    init(_ pane: ChatPane) { self.pane = pane }
}
