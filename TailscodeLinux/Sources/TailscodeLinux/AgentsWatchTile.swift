import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// One agent on the wall: a glass card, the state's mark, the title, the one plain word for the
/// state, what it is doing in large type, the command or path under it, the heartbeat — and, for a
/// session that waits on a person, the two answers. Its sub-agents are tiles of their own beside it. It is one container
/// placed by the wall and lays its own parts out from the size it is given.
final class WatchTileView: @unchecked Sendable {
    let container: TileCanvas
    let card = AgentsCanvas(width: 1, height: 1)
    let glyph = AgentsCanvas(width: 1, height: 1)
    let beatCanvas = AgentsCanvas(width: 1, height: 1)
    let title = WatchLabel()
    let status = WatchLabel()
    let meta = WatchLabel()
    let words = WatchLabel()
    let detail = WatchLabel()
    let hint = WatchLabel()
    let steps = WatchLabel()
    let deny: UnsafeMutablePointer<GtkWidget>
    let approve: UnsafeMutablePointer<GtkWidget>
    let chat: UnsafeMutablePointer<GtkWidget>
    let denyLabel = WatchLabel(wrap: false)
    let approveLabel = WatchLabel(wrap: false)
    let chatLabel = WatchLabel(wrap: false)
    let ring = AgentsCanvas(width: 1, height: 1)
    let detailClamp = tailscode_tile_clamp_new()!
    let stepsClamp = tailscode_tile_clamp_new()!
    let context: WatchContext
    var tile: WallTile?
    private(set) var shownWords = ""
    private(set) var writtenByModel = false
    var gauge = HoldGauge()
    var holdPumping = false
    var hintUntil: Date?
    var truncated = false
    var glyphBox = TileRect(x: 0, y: 0, width: 0, height: 0)
    var beatBox: TileRect?
    private(set) var drainShare: Double?
    private(set) var pulse = 0.0
    private(set) var arrival = 1.0
    private(set) var focused = false
    private var beat: [Int] = []
    private var slideStart: Double?
    private var signature = ""
    var unit: Double { context.unit }

    init(context: WatchContext) {
        self.context = context
        weak var host: WatchTileView?
        container = TileCanvas { width, height, sink in host?.solve(width: width, height: height, sink: sink) }
        deny = gtk_button_new()!
        approve = gtk_button_new()!
        chat = gtk_button_new()!
        host = self
        build()
    }

    var widget: UnsafeMutablePointer<GtkWidget> { container.widget }

    private func build() {
        tailscode_set_accessible_hidden(card.widget, 1)
        for canvas in [card, glyph, beatCanvas, ring] {
            gtk_widget_set_can_target(canvas.widget, canvas === card ? 1 : 0)
            gtk_widget_set_can_focus(canvas.widget, 0)
            tailscode_set_accessible_hidden(canvas.widget, 1)
        }
        card.paint = { [weak self] cr, width, height in self?.paintCard(cr, width, height) }
        glyph.paint = { [weak self] cr, width, _ in self?.paintGlyph(cr, width) }
        beatCanvas.paint = { [weak self] cr, width, height in self?.paintBeat(cr, width, height) }
        ring.paint = { [weak self] cr, width, _ in self?.paintRing(cr, width) }
        container.add(card.widget, layer: .panes)
        for canvas in [glyph, beatCanvas] { container.add(canvas.widget, layer: .dividers) }
        for label in [title, status, meta, words, hint] { container.add(label.widget, layer: .dividers) }
        tailscode_tile_clamp_add(detailClamp, detail.widget)
        tailscode_tile_clamp_add(stepsClamp, steps.widget)
        container.add(detailClamp, layer: .dividers)
        container.add(stepsClamp, layer: .dividers)
        buildButton(deny, label: denyLabel, ring: nil)
        buildButton(approve, label: approveLabel, ring: ring)
        buildButton(chat, label: chatLabel, ring: nil)
        for button in [deny, approve, chat] { container.add(button, layer: .overlays) }
        Gtk.addClass(widget, "agents-wall-tile")
        tailscode_tile_canvas_set_minimum(widget, 1, 1)
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)
        Gtk.onPrimaryRelease(widget) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, let id = self.tile?.id else { return }
                self.context.touched()
                self.context.openPeek(id)
            }
        }
        gtk_widget_set_cursor_from_name(widget, "pointer")
        gtk_widget_set_focusable(widget, 0)
        wireButtons()
    }

    private func buildButton(
        _ button: UnsafeMutablePointer<GtkWidget>, label: WatchLabel, ring: AgentsCanvas?
    ) {
        Gtk.addClass(button, "agents-wall-btn")
        gtk_widget_set_focus_on_click(button, 0)
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_halign(row, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(row, GTK_ALIGN_CENTER)
        if let ring { gtk_box_append(ptr(row), ring.widget) }
        gtk_label_set_xalign(op(label.widget), 0.5)
        gtk_label_set_yalign(op(label.widget), 0.5)
        gtk_label_set_ellipsize(op(label.widget), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(row), label.widget)
        gtk_button_set_child(ptr(button), row)
    }

    func apply(_ next: WallTile, now: Date) {
        let previous = tile
        tile = next
        let state = next.statusWord(at: now)
        status.set(text: state)
        title.set(text: next.title)
        let line = Self.line(for: next, model: context.plainModel)
        shownWords = line.text
        writtenByModel = line.byModel
        words.set(text: line.text)
        detail.set(text: next.detail == next.words ? "" : (next.detail ?? ""))
        meta.set(text: Self.metaLine(next, countsWorkers: !context.style.showsSquads))
        steps.set(text: Self.stepLines(next))
        if let beat = next.beat, beat != self.beat {
            slideStart = Self.isShift(self.beat, beat) && context.animated ? context.seconds : nil
            self.beat = beat
        } else if next.beat == nil {
            beat = []
        }
        let sign = "\(next.state.rank)|\(next.title)|\(line.text)|\(next.detail ?? "")|\(beat.isEmpty)|\(next.span)|\(next.ask?.id ?? "")"
        if sign != signature {
            signature = sign
            container.invalidate()
        }
        gtk_widget_set_opacity(widget, Self.opacity(next) * arrival)
        tailscode_set_accessible_label(widget, spoken(now: now))
        if previous == nil || previous?.state != next.state { redrawAll() }
        refreshControls()
    }

    static func opacity(_ tile: WallTile) -> Double {
        switch tile.state {
        case .finished(.failed): return 1
        case .finished: return 1 - 0.7 * tile.fade
        case .away: return 0.62
        default: return 1
        }
    }

    /// What the tile's main line says: the rules' words, or, for a command no rule could read and
    /// only when the person has turned a local model on, the line it wrote, marked as its own.
    static func line(for tile: WallTile, model: PlainWordsModel?) -> (text: String, byModel: Bool) {
        guard let raw = tile.rewritable, let model else { return (tile.words, false) }
        if let said = model.said(for: raw) { return (said + PlainWordsModel.marker, true) }
        model.ask(raw)
        return (tile.words, false)
    }

    static func stepLines(_ tile: WallTile) -> String {
        tile.steps.map { ($0, $0.plain ?? $0.words) }.filter { $0.1 != tile.words }.prefix(3)
            .map { AgentsParts.outcomeGlyph($0.0.outcome).glyph + " " + $0.1 }.joined(separator: "\n")
    }

    static func metaLine(_ tile: WallTile, countsWorkers: Bool = false) -> String {
        var parts = [tile.machine]
        if let chip = tile.chip {
            parts.append(chip.effort.map { chip.name + " " + $0 } ?? chip.name)
        }
        if countsWorkers {
            let agents = tile.workers.filter { $0.kind == .agent && !$0.state.isFinished }.count
            if let count = WallWorker.count(agents) { parts.append(count) }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func isShift(_ old: [Int], _ new: [Int]) -> Bool {
        guard old.count == new.count, old.count > 1 else { return false }
        return Array(old.dropFirst()) == Array(new.dropLast())
    }

    func spoken(now: Date) -> String {
        guard let tile else { return "" }
        var parts = [tile.title, tile.statusWord(at: now), shownWords]
        if writtenByModel { parts.append(Localized.text("written by a model")) }
        if let detail = tile.detail, detail != tile.words { parts.append(detail) }
        return parts.joined(separator: ", ")
    }

    func tick(now: Date) {
        guard let tile else { return }
        status.set(text: tile.statusWord(at: now))
        tailscode_set_accessible_label(widget, spoken(now: now))
        if let until = hintUntil, now >= until { clearHint() }
        glyph.redraw()
    }

    func setFocused(_ on: Bool) {
        guard on != focused else { return }
        focused = on
        card.redraw()
    }

    func redrawAll() {
        for canvas in [card, glyph, beatCanvas] { canvas.redraw() }
    }

    /// What the effects playing on this tile ask of it now: the context ring's share while it drains,
    /// the flash of a step on the glass, and how far a newcomer has come in. Each redraws only the
    /// part that changed.
    func setEffects(drain: Double?, pulse nextPulse: Double, arrival nextArrival: Double) {
        if drain != drainShare {
            drainShare = drain
            glyph.redraw()
        }
        if nextPulse != pulse {
            pulse = nextPulse
            card.redraw()
        }
        if nextArrival != arrival, let tile {
            arrival = nextArrival
            gtk_widget_set_opacity(widget, Self.opacity(tile) * arrival)
        }
    }

    /// The style, the palette or the night changed: say the words again and lay the tile out anew.
    func styleChanged(now: Date) {
        if let tile { apply(tile, now: now) }
        container.invalidate()
        redrawAll()
        refreshControls()
    }

    var isAnimating: Bool {
        guard let tile else { return false }
        if WatchTilePaint.breathPeriod(tile.state) != nil || pulse > 0 { return true }
        switch tile.state {
        case .quiet: return true
        default: return gauge.isHolding
        }
    }

    var glyphAnimates: Bool {
        guard let tile else { return false }
        switch tile.state {
        case .finished, .away: return false
        case .background(let stuck): return !stuck
        default: return true
        }
    }

    func frame(card cardDue: Bool, glyph glyphDue: Bool, beat beatDue: Bool) {
        if cardDue { card.redraw() }
        if glyphDue { glyph.redraw() }
        if beatDue || slideStart != nil { beatCanvas.redraw() }
    }

    private func paintCard(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        guard let tile else { return }
        WatchTilePaint.card(
            cr, width: width, height: height, unit: unit,
            face: .init(state: tile.state, focused: focused, pulse: pulse),
            palette: context.palette, t: context.seconds, animated: context.animated)
    }

    private func paintGlyph(_ cr: OpaquePointer, _ size: Double) {
        guard let tile else { return }
        WatchGlyph.paint(
            cr, size: size, state: tile.state, share: drainShare ?? tile.contextShare, fade: tile.fade,
            palette: context.palette, t: context.seconds, animated: context.animated)
    }

    private func paintBeat(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        guard let tile else { return }
        var slide = 0.0
        if let start = slideStart {
            let progress = (context.seconds - start) / 0.45
            if progress >= 1 { slideStart = nil } else { slide = 1 - progress * progress * (3 - 2 * progress) }
        }
        WatchTilePaint.beat(
            cr, width: width, height: height, beat: beat, slide: slide,
            ink: context.palette.ink(tile.state), palette: context.palette)
    }

    var beatValues: [Int] { beat }
}
