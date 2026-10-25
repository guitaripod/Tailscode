import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension WorkerState {
    /// The state as the tile mark knows it. A worker that left the roster ended in a way nobody
    /// here saw, so it wears the mark for an ending of unknown kind, never a check.
    var wallState: WallState {
        switch self {
        case .working: return .working
        case .quiet(let since): return .quiet(since: since)
        case .background(let stuck): return .background(stuck: stuck)
        case .finished: return .finished(.unknown)
        }
    }
}

/// One sub-agent, or the count of those that did not fit, on the wall: a small glass card with the
/// state's mark, the agent's name, the one plain word for its state beside how long it has been in
/// it, what it is doing and how far through its todo list it is. It sits in its session's cell
/// beside the session's own tile and a press on it opens that session's peek.
final class WatchWorkerView: @unchecked Sendable {
    enum Face: Equatable {
        case worker(WallWorker)
        case more(count: Int, needsEyes: Bool)
    }

    struct Level {
        var glyph: Double
        var title: Double
        var status: Double
        var words: Double
        var titleLines: Int
        var wordLines: Int
        var bar: Bool
    }

    static let levels = [
        Level(glyph: 5.4, title: 2.3, status: 1.8, words: 2.0, titleLines: 2, wordLines: 3, bar: true),
        Level(glyph: 4.4, title: 2.0, status: 1.7, words: 1.8, titleLines: 2, wordLines: 2, bar: true),
        Level(glyph: 3.8, title: 1.8, status: 1.6, words: 1.6, titleLines: 1, wordLines: 1, bar: true),
        Level(glyph: 3.4, title: 1.7, status: 1.6, words: 0, titleLines: 1, wordLines: 0, bar: false),
    ]

    static let corner = 0.72
    static let narrowest = 24.0

    let container: TileCanvas
    let card = AgentsCanvas(width: 1, height: 1)
    let glyph = AgentsCanvas(width: 1, height: 1)
    let bar = AgentsCanvas(width: 1, height: 1)
    let title = WatchLabel()
    let status = WatchLabel()
    let words = WatchLabel()
    let figure = WatchLabel(wrap: false)
    let context: WatchContext
    private(set) var face: Face?
    private(set) var parentKey = ""
    private var signature = ""
    var unit: Double { context.unit }

    init(context: WatchContext) {
        self.context = context
        weak var host: WatchWorkerView?
        container = TileCanvas { width, height, sink in host?.solve(width: width, height: height, sink: sink) }
        host = self
        build()
    }

    var widget: UnsafeMutablePointer<GtkWidget> { container.widget }

    private func build() {
        for canvas in [card, glyph, bar] {
            gtk_widget_set_can_target(canvas.widget, canvas === card ? 1 : 0)
            gtk_widget_set_can_focus(canvas.widget, 0)
            tailscode_set_accessible_hidden(canvas.widget, 1)
        }
        card.paint = { [weak self] cr, width, height in self?.paintCard(cr, width, height) }
        glyph.paint = { [weak self] cr, width, _ in self?.paintGlyph(cr, width) }
        bar.paint = { [weak self] cr, width, height in self?.paintBar(cr, width, height) }
        container.add(card.widget, layer: .panes)
        for canvas in [glyph, bar] { container.add(canvas.widget, layer: .dividers) }
        for label in [title, status, words, figure] { container.add(label.widget, layer: .dividers) }
        Gtk.addClass(widget, "agents-wall-tile")
        tailscode_tile_canvas_set_minimum(widget, 1, 1)
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)
        Gtk.onPrimaryRelease(widget) { [weak self] in
            Gtk.onMain { [weak self] in self?.open() }
        }
        gtk_widget_set_cursor_from_name(widget, "pointer")
        gtk_widget_set_focusable(widget, 0)
    }

    /// Opens the peek of the session this worker belongs to.
    func open() {
        guard !parentKey.isEmpty else { return }
        context.touched()
        context.openPeek(parentKey)
    }

    func apply(_ next: WallWorker, parent: String, now: Date) {
        let before = face
        face = .worker(next)
        parentKey = parent
        title.set(text: next.title)
        words.set(text: next.words)
        status.set(text: Self.statusLine(next, now: now))
        figure.set(text: next.progress == nil ? "" : "\(next.todosDone)/\(next.todosTotal)")
        let sign = "\(next.state.ordinal)|\(next.title)|\(next.words)|\(next.progress != nil)"
        refresh(sign: sign, opacity: next.state.isFinished ? 1 - 0.7 * next.fade : 1, changed: before != face)
        tailscode_set_accessible_label(widget, spoken(now: now))
    }

    func apply(more count: Int, needsEyes: Bool, parent: String) {
        let before = face
        face = .more(count: count, needsEyes: needsEyes)
        parentKey = parent
        title.set(text: "")
        words.set(text: Localized.text("more sub-agents"))
        status.set(text: needsEyes ? Localized.text("some need a look") : "")
        figure.set(text: "+\(count)")
        refresh(sign: "more|\(count)|\(needsEyes)", opacity: 1, changed: before != face)
        tailscode_set_accessible_label(widget, spoken(now: Date()))
    }

    private func refresh(sign: String, opacity: Double, changed: Bool) {
        if sign != signature {
            signature = sign
            container.invalidate()
        }
        gtk_widget_set_opacity(widget, opacity)
        if changed { redrawAll() } else { bar.redraw() }
    }

    static func statusLine(_ worker: WallWorker, now: Date) -> String {
        let word = worker.statusWord(at: now)
        switch worker.state {
        case .working, .background(stuck: false):
            guard let started = worker.startedAt else { return word }
            return word + " · " + AgentsParts.age(started, now: now)
        case .quiet, .background(stuck: true), .finished:
            return word
        }
    }

    func spoken(now: Date) -> String {
        switch face {
        case .worker(let worker)?:
            return [worker.title, Self.statusLine(worker, now: now), worker.words]
                .filter { !$0.isEmpty }.joined(separator: ", ")
        case .more(let count, _)?:
            return "+\(count), " + Localized.text("more sub-agents")
        case nil:
            return ""
        }
    }

    func tick(now: Date) {
        guard case .worker(let worker)? = face else { return }
        status.set(text: Self.statusLine(worker, now: now))
        tailscode_set_accessible_label(widget, spoken(now: now))
        glyph.redraw()
    }

    func redrawAll() {
        for canvas in [card, glyph, bar] { canvas.redraw() }
    }

    var isCount: Bool {
        if case .more? = face { return true }
        return false
    }

    var state: WallState {
        switch face {
        case .worker(let worker)?: return worker.state.wallState
        case .more(_, let needsEyes)?: return needsEyes ? .background(stuck: true) : .finished(.unknown)
        case nil: return .finished(.unknown)
        }
    }

    var isAnimating: Bool {
        guard case .worker(let worker)? = face else { return false }
        if WatchTilePaint.breathPeriod(worker.state.wallState) != nil { return true }
        if case .quiet = worker.state { return true }
        return false
    }

    var glyphAnimates: Bool {
        guard case .worker(let worker)? = face else { return false }
        switch worker.state {
        case .finished, .background(stuck: true): return false
        default: return true
        }
    }

    func frame(card cardDue: Bool, glyph glyphDue: Bool) {
        if cardDue { card.redraw() }
        if glyphDue { glyph.redraw() }
    }

    private func paintCard(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        WatchTilePaint.card(
            cr, width: width, height: height, unit: unit, face: .init(state: state, focused: false),
            palette: context.palette, t: context.seconds, animated: context.animated,
            corner: Self.corner)
    }

    private func paintGlyph(_ cr: OpaquePointer, _ size: Double) {
        guard case .worker(let worker)? = face else { return }
        WatchGlyph.paint(
            cr, size: size, state: worker.state.wallState, share: nil, fade: worker.fade,
            palette: context.palette, t: context.seconds, animated: context.animated)
    }

    private func paintBar(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        guard case .worker(let worker)? = face, let share = worker.progress else { return }
        let palette = context.palette
        agentsRoundedRect(cr, x: 0, y: 0, width: width, height: height, radius: height / 2)
        palette.text.set(cr, alpha: 0.16)
        cairo_fill(cr)
        guard share > 0 else { return }
        agentsRoundedRect(cr, x: 0, y: 0, width: max(height, width * share), height: height, radius: height / 2)
        palette.ink(worker.state.wallState).set(cr, alpha: 0.95)
        cairo_fill(cr)
    }

    func solve(width: Int32, height: Int32, sink: TileSink) {
        sink.place(card.widget, TileRect(x: 0, y: 0, width: width, height: height))
        guard let face, width > 8, height > 8 else { return }
        switch face {
        case .worker(let worker):
            layout(worker, width: Double(width), height: Double(height), sink: sink)
        case .more(_, let needsEyes):
            layoutMore(needsEyes: needsEyes, width: Double(width), height: Double(height), sink: sink)
        }
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> TileRect {
        TileRect(
            x: Int32(x.rounded()), y: Int32(y.rounded()), width: Int32(max(1, width.rounded())),
            height: Int32(max(1, height.rounded())))
    }

    private func lines(_ label: WatchLabel, _ count: Int, size: Double, width: Double) -> Double {
        guard count > 0, !label.text.isEmpty else { return 0 }
        label.set(lines: count)
        return min(label.height(forWidth: max(width, Self.narrowest)), Double(count) * label.lineHeight(size: size))
    }

    private func layout(_ worker: WallWorker, width: Double, height: Double, sink: TileSink) {
        let u = unit
        let palette = context.palette
        let pad = 1.1 * u
        let inner = width - 2 * pad
        let tone = palette.ink(worker.state.wallState).lifted(0.18)
        let last = Self.levels.count - 1
        for (index, level) in Self.levels.enumerated() {
            let glyphSize = min(level.glyph * u, height * 0.45)
            let columnX = pad + glyphSize + 0.9 * u
            let columnWidth = width - columnX - pad
            if columnWidth < 5 * u && index < last { continue }
            title.set(style: context.label(level.title, bold: true))
            status.set(style: context.label(level.status, bold: true, ink: tone))
            words.set(style: context.label(level.words, ink: palette.text, alpha: 0.86))
            let titleHeight = lines(title, level.titleLines, size: context.size(level.title), width: columnWidth)
            let statusHeight = lines(status, 1, size: context.size(level.status), width: columnWidth)
            let head = max(glyphSize, titleHeight + 0.2 * u + statusHeight)
            let wordsHeight = level.words > 0
                ? lines(words, level.wordLines, size: context.size(level.words), width: inner) : 0
            let hasBar = level.bar && worker.progress != nil
            figure.set(style: context.label(1.6, bold: true, ink: palette.dim))
            let barRow = hasBar ? max(0.7 * u, figure.height(forWidth: 100 * u)) : 0
            let total = pad + head + (wordsHeight > 0 ? 0.7 * u + wordsHeight : 0)
                + (hasBar ? 0.8 * u + barRow : 0) + pad
            guard total <= height || index == last else { continue }
            sink.place(glyph.widget, rect(pad, pad, glyphSize, glyphSize))
            sink.place(title.widget, rect(columnX, pad, columnWidth, titleHeight))
            sink.place(status.widget, rect(columnX, pad + titleHeight + 0.2 * u, columnWidth, statusHeight))
            if wordsHeight > 0 { sink.place(words.widget, rect(pad, pad + head + 0.7 * u, inner, wordsHeight)) }
            if hasBar {
                let figureWidth = figure.naturalWidth
                let barHeight = max(2, 0.6 * u)
                let y = height - pad - barRow
                sink.place(figure.widget, rect(width - pad - figureWidth, y, figureWidth, barRow))
                sink.place(bar.widget, rect(pad, y + (barRow - barHeight) / 2, inner - figureWidth - 0.8 * u, barHeight))
            }
            return
        }
    }

    private func layoutMore(needsEyes: Bool, width: Double, height: Double, sink: TileSink) {
        let u = unit
        let palette = context.palette
        let pad = 1.1 * u
        let inner = width - 2 * pad
        figure.set(style: context.label(5.0, bold: true, ink: needsEyes ? palette.needs : palette.text))
        words.set(style: context.label(1.7, ink: palette.dim))
        status.set(style: context.label(1.6, bold: true, ink: palette.needs.lifted(0.18)))
        let figureHeight = figure.height(forWidth: max(inner, Self.narrowest))
        sink.place(figure.widget, rect(pad, pad, inner, figureHeight))
        var y = pad + figureHeight + 0.3 * u
        let wordsHeight = lines(words, 2, size: context.size(1.7), width: inner)
        if y + wordsHeight <= height - pad {
            sink.place(words.widget, rect(pad, y, inner, wordsHeight))
            y += wordsHeight + 0.4 * u
        }
        let statusHeight = lines(status, 2, size: context.size(1.6), width: inner)
        if statusHeight > 0, y + statusHeight <= height - pad {
            sink.place(status.widget, rect(pad, y, inner, statusHeight))
        }
    }
}
