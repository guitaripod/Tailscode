import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The wall: the Agents window's default lens, a full-window screen that is left up on a monitor.
/// It never scrolls and never grows its window; a grid of at most six tiles placed by Core's
/// columns, rows and spans, the situation in one sentence over them, the last hour and two rails
/// under them, a dark ambient ground, and a peek that comes over it and goes by itself.
final class AgentsWatchView: @unchecked Sendable {
    let context: WatchContext
    let stage: TileCanvas
    let ground = AgentsCanvas(width: 1, height: 1)
    let motes = AgentsCanvas(width: 1, height: 1)
    let vignette = AgentsCanvas(width: 1, height: 1)
    let scrim = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
    let top: WatchTopBand
    let calm: WatchCalmView
    let rails: WatchRails
    let ribbon: WatchRibbon
    let peekLayer: WatchPeekLayer
    let moteField = WatchMotes()
    var tiles: [String: WatchTileView] = [:]
    var wall = AgentWall.empty
    var geometry = WatchGeometry.make(width: 1920, height: 1080, tiles: [], columns: 0, rows: 0, isCalm: true)
    var board = AgentBoard.empty
    var hour: AgentHour?
    var scene: (name: String, wall: AgentWall)?
    var sceneStarted = Date.distantPast
    var cycleStarted: Date?
    var cycleVisited: [String] = []
    var dim = WatchDim()
    var focusedKey: String?
    var shape = 0
    var eventSignature = ""
    var isVisible = true
    var isLive = false
    var hourFetchedAt = Date.distantPast
    var lastSize = (width: 0.0, height: 0.0)
    var drift = (x: 0.0, y: 0.0)
    var cadence = WatchCadence()
    lazy var lap = RepeatingMotion { [weak self] in self?.frame() }
    var onHourWanted: () -> Void = {}
    var onPeekExpired: () -> Void = {}
    private(set) var rereads = 0
    var frames = 0

    var widget: UnsafeMutablePointer<GtkWidget> { stage.widget }

    init(context: WatchContext, peek: AgentPeekView) {
        self.context = context
        top = WatchTopBand(context: context)
        calm = WatchCalmView(context: context)
        rails = WatchRails(context: context)
        ribbon = WatchRibbon(context: context)
        peekLayer = WatchPeekLayer(peek: peek, context: context)
        var host: AgentsWatchView?
        stage = TileCanvas { width, height, sink in host?.solve(width: width, height: height, sink: sink) }
        host = self
        build()
    }

    private func build() {
        WatchStyle.install(context.palette)
        Gtk.addClass(stage.widget, "agents-wall")
        gtk_widget_set_hexpand(stage.widget, 1)
        gtk_widget_set_vexpand(stage.widget, 1)
        gtk_widget_set_overflow(stage.widget, GTK_OVERFLOW_HIDDEN)
        tailscode_tile_canvas_set_minimum(stage.widget, 320, 200)
        for canvas in [ground, motes, vignette] {
            gtk_widget_set_can_target(canvas.widget, 0)
            gtk_widget_set_can_focus(canvas.widget, 0)
            tailscode_set_accessible_hidden(canvas.widget, 1)
        }
        gtk_widget_set_can_target(scrim, 0)
        Gtk.addClass(scrim, "agents-wall-scrim")
        gtk_widget_set_opacity(scrim, 0)
        ground.paint = { [weak self] cr, width, height in self?.paintGround(cr, width, height) }
        motes.paint = { [weak self] cr, width, height in self?.paintMotes(cr, width, height) }
        vignette.paint = { [weak self] cr, width, height in self?.paintVignette(cr, width, height) }
        stage.add(ground.widget, layer: .panes)
        stage.add(motes.widget, layer: .panes)
        for widget in top.widgets + rails.widgets { stage.add(widget, layer: .dividers) }
        stage.add(calm.orb.widget, layer: .dividers)
        stage.add(calm.line.widget, layer: .dividers)
        stage.add(ribbon.canvas.widget, layer: .dividers)
        stage.add(vignette.widget, layer: .overlays)
        stage.add(scrim, layer: .overlays)
        for widget in peekLayer.widgets { stage.add(widget, layer: .overlays) }
        context.openPeek = { [weak self] key in self?.peekRequest(key) }
        for chip in rails.recentChips {
            chip.onPress = { [weak self] chip in self?.context.actions.openChat(chip.id) }
        }
        for chip in rails.listedChips {
            chip.onPress = { [weak self] chip in
                self?.context.actions.perform(.watch, key: chip.id, title: chip.title)
            }
        }
        applyWall(wall, now: context.clock.now, event: false)
    }

    var peekRequest: (String) -> Void = { _ in }

    func solve(width: Int32, height: Int32, sink: TileSink) {
        let w = Double(width)
        let h = Double(height)
        guard w > 1, h > 1 else { return }
        let unit = WatchGeometry.unit(width: w, height: h)
        if unit != context.unit {
            context.unit = unit
            restyle()
        }
        let first = lastSize.width <= 1
        lastSize = (w, h)
        if first { Gtk.onMain { [weak self] in self?.reread(now: self?.context.clock.now ?? Date()) } }
        let tilesNow = wall.tiles
        geometry = WatchGeometry.make(
            width: w, height: h, tiles: tilesNow, columns: wall.columns, rows: wall.rows,
            isCalm: wall.isCalm, drift: drift)
        let full = TileRect(x: 0, y: 0, width: width, height: height)
        for widget in [ground.widget, motes.widget, vignette.widget, scrim] { sink.place(widget, full) }
        placeTop(sink)
        for (index, tile) in tilesNow.enumerated() {
            guard let view = tiles[tile.id], geometry.tiles.indices.contains(index) else { continue }
            sink.place(view.widget, rect(geometry.tiles[index]))
        }
        if tilesNow.isEmpty {
            let side = geometry.centre
            sink.place(calm.orb.widget, rect(WatchRect(x: side.x, y: side.y - 2 * geometry.unit, width: side.width, height: side.height)))
            let lineY = side.maxY - 1.4 * geometry.unit
            sink.place(calm.line.widget, rect(WatchRect(x: geometry.grid.x, y: lineY, width: geometry.grid.width, height: 4 * geometry.unit)))
        }
        sink.place(ribbon.canvas.widget, rect(geometry.ribbon))
        rails.place(geometry, sink: sink)
        peekLayer.place(width: w, height: h, unit: geometry.unit, sink: sink)
        noteShape(aspect: w / h)
    }

    func restyle() {
        let now = context.clock.now
        top.apply(wall, now: now)
        calm.apply(wall)
        rails.apply(wall, now: now)
        ribbon.apply(hour: hour, calm: wall.isCalm && wall.tiles.isEmpty, unit: context.unit)
    }

    private func placeTop(_ sink: TileSink) {
        top.fit(in: geometry.headline, portrait: geometry.isPortrait)
        top.watchLine.set(style: context.label(2.4, ink: context.palette.dim))
        sink.place(top.headline.widget, rect(geometry.headline))
        sink.place(top.watchLine.widget, rect(geometry.watchLine))
        sink.place(top.clock.widget, rect(geometry.clock))
        sink.place(top.date.widget, rect(geometry.date))
    }

    func rect(_ value: WatchRect) -> TileRect {
        TileRect(
            x: Int32(value.x.rounded()), y: Int32(value.y.rounded()),
            width: Int32(max(1, value.width.rounded())), height: Int32(max(1, value.height.rounded())))
    }

    private func noteShape(aspect: Double) {
        let next = WatchGeometry.shape(aspect: aspect)
        guard next != shape else { return }
        shape = next
        Gtk.onMain { [weak self] in self?.reread(now: self?.context.clock.now ?? Date()) }
    }

    func apply(board next: AgentBoard) {
        board = next
        guard scene == nil else { return }
        reread(now: context.clock.now)
    }

    func apply(hour next: AgentHour) {
        hour = next
        hourFetchedAt = context.clock.now
        ribbon.apply(hour: next, calm: wall.isCalm && wall.tiles.isEmpty, unit: context.unit)
        guard scene == nil else { return }
        reread(now: context.clock.now)
    }

    func reread(now: Date) {
        guard scene == nil, lastSize.width > 1 else { return }
        rereads += 1
        let aspect = lastSize.width / lastSize.height
        let next = AgentWall.read(board: board, hour: hour, now: now, aspect: aspect, previous: wall)
        applyWall(next, now: now, event: true)
    }

    func applyWall(_ next: AgentWall, now: Date, event: Bool) {
        let moved = !next.sameShown(as: wall)
        let signature = Self.signature(next)
        let isEvent = event && signature != eventSignature
        eventSignature = signature
        let before = wall.mood
        let hadOverdue = wall.hasOverdue
        wall = next
        context.allowsBigType = next.tiles.count <= 3
        dim.observe(next.mood, at: now)
        if isEvent { dim.wake(at: now) }
        var seen = Set<String>()
        for tile in next.tiles {
            seen.insert(tile.id)
            let view = tiles[tile.id] ?? makeTile(tile.id)
            view.apply(tile, now: now)
        }
        for (key, view) in tiles where !seen.contains(key) {
            if focusedKey == key { focusedKey = nil }
            stage.remove(view.widget)
            tiles[key] = nil
        }
        top.apply(next, now: now)
        calm.apply(next)
        rails.apply(next, now: now)
        ribbon.apply(hour: hour, calm: next.isCalm && next.tiles.isEmpty, unit: context.unit)
        refreshFocus()
        if moved { stage.invalidate() }
        if before != next.mood { ground.redraw() }
        if hadOverdue != next.hasOverdue { vignette.redraw() }
        updateClock()
    }

    private func makeTile(_ key: String) -> WatchTileView {
        let view = WatchTileView(context: context)
        tiles[key] = view
        stage.add(view.widget, layer: .dividers)
        return view
    }

    static func signature(_ wall: AgentWall) -> String {
        let tiles = wall.tiles.map { "\($0.id)|\($0.state.rank)|\($0.words)|\($0.detail ?? "")" }
        let rails = (wall.listed.map(\.id) + wall.recent.map(\.id)).joined(separator: ",")
        return wall.headline + "#" + tiles.joined(separator: ";") + "#" + rails
    }

    func tileView(_ key: String) -> WatchTileView? { tiles[key] }

    var orderedKeys: [String] { wall.tiles.map(\.id) }

    func refreshFocus() {
        for (key, view) in tiles { view.setFocused(key == focusedKey) }
    }

    func moveFocus(_ step: Int) {
        let keys = orderedKeys
        guard !keys.isEmpty else { return }
        let current = focusedKey.flatMap { keys.firstIndex(of: $0) }
        let next = current.map { ($0 + step + keys.count) % keys.count } ?? (step > 0 ? 0 : keys.count - 1)
        focusedKey = keys[next]
        refreshFocus()
    }

    func refreshControls(for key: String) {
        tiles[key]?.refreshControls()
    }
}
