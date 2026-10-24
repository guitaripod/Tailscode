import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The last hour as lanes: a ruler of minutes ago, a lane per session with its agents indented
/// beneath, bars in the activity tones, the wait for the person in amber, a mark where a turn
/// ended, a now line at the right edge, and the spans this device never saw hatched so a quiet gap
/// and a blind one never look alike. It draws on a change, a hover, a selection and the window's
/// own second tick, and at no other time.
final class AgentHourView: @unchecked Sendable {
    let widget = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let scroller = gtk_scrolled_window_new()!
    let canvas = AgentsCanvas(width: 300, height: 120)
    private let empty = Gtk.label("", css: "agents-empty", wrap: true, selectable: false)
    private let legend = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 18)
    private(set) var hour: AgentHour?
    private(set) var layout: AgentHourLayout
    private(set) var hovered: Int?
    private(set) var selectedID: String?
    private var pointer: (x: Double, y: Double)?
    private var tooltipFor = ""
    private var widthNow = 0.0
    var onSelect: @Sendable (AgentHourLane) -> Void = { _ in }

    var area: UnsafeMutablePointer<GtkWidget> { canvas.widget }
    var scrolled: UnsafeMutablePointer<GtkWidget> { scroller }
    var emptyLabel: UnsafeMutablePointer<GtkWidget> { empty }
    var draws: Int { canvas.draws }
    var laneCount: Int { layout.lanes.count }
    var laneIDs: [String] { layout.lanes.map(\.id) }
    var legendBox: UnsafeMutablePointer<GtkWidget> { legend }

    init() {
        layout = AgentHourLayout(
            width: 300, labelWidth: 220, rulerHeight: 30, rowHeight: 48, childHeight: 34, lanes: [])
        gtk_widget_set_hexpand(canvas.widget, 1)
        gtk_widget_set_vexpand(canvas.widget, 0)
        gtk_widget_set_focusable(canvas.widget, 1)
        Gtk.addClass(canvas.widget, "agents-hour")
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(scroller), canvas.widget)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_widget_set_hexpand(scroller, 1)
        gtk_label_set_text(
            op(empty), Localized.text("Nothing was running in the last hour that this device saw."))
        gtk_widget_set_visible(empty, 0)
        gtk_box_append(ptr(widget), scroller)
        gtk_box_append(ptr(widget), empty)
        buildLegend()
        gtk_box_append(ptr(widget), legend)
        canvas.paint = { [weak self] cr, width, height in self?.paint(cr, width: width, height: height) }
        tailscode_set_accessible_label(canvas.widget, Localized.text("The last hour of agents, one lane each"))
        Gtk.onAreaResize(canvas.widget) { [weak self] width, _ in
            Gtk.onMain { [weak self] in self?.resized(Double(width)) }
        }
        Gtk.onPointer(
            canvas.widget,
            move: { [weak self] x, y in self?.moved(x, y) },
            leave: { [weak self] in self?.left() })
        Gtk.onPrimaryRelease(canvas.widget) { [weak self] in
            Gtk.onMain { [weak self] in self?.clicked() }
        }
        Gtk.onKey(canvas.widget) { [weak self] keyval, _ in
            guard let self else { return false }
            return self.key(keyval)
        }
    }

    private func buildLegend() {
        Gtk.margins(legend, top: 4, bottom: 14, leading: 22, trailing: 22)
        let items: [(String, (OpaquePointer, Double, Double, AgentsInks) -> Void)] = [
            (Localized.text("working"), { cr, w, h, inks in
                agentsRoundedRect(cr, x: 0, y: h / 2 - 4, width: w, height: 8, radius: 3)
                inks.live.set(cr)
                cairo_fill(cr)
            }),
            (Localized.text("waiting on you"), { cr, w, h, inks in
                agentsRoundedRect(cr, x: 0, y: h / 2 - 4, width: w, height: 8, radius: 3)
                inks.attention.set(cr)
                cairo_fill(cr)
            }),
            (Localized.text("in the background"), { cr, w, h, inks in
                Self.dashedBar(cr, x: 0.5, y: h / 2 - 4, width: w - 1, height: 8, ink: inks.live)
            }),
            (Localized.text("not seen by this device"), { cr, w, h, inks in
                Self.hatch(cr, x: 0, y: h / 2 - 5, width: w, height: 10, inks: inks)
            }),
        ]
        var cells: [UnsafeMutablePointer<GtkWidget>] = []
        for (words, draw) in items {
            let cell = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
            let swatch = AgentsCanvas(width: 24, height: 14)
            swatch.paint = { cr, width, height in draw(cr, width, height, AgentsInks()) }
            gtk_widget_set_valign(swatch.widget, GTK_ALIGN_CENTER)
            tailscode_set_accessible_hidden(swatch.widget, 1)
            gtk_box_append(ptr(cell), swatch.widget)
            gtk_box_append(ptr(cell), Gtk.label(words, css: "agents-meta", selectable: false))
            cells.append(cell)
        }
        gtk_box_append(ptr(legend), Gtk.wrapRow(cells, spacing: 18))
    }

    /// A new hour: the lanes the log has, and a size to hold them. Only a different hour or a lane
    /// whose words moved is worth a draw, and the window's tick asks for one every second anyway.
    func apply(_ next: AgentHour, now: Date) {
        hour = next
        if let selected = selectedID, !next.lanes.contains(where: { $0.id == selected }) {
            selectedID = nil
        }
        remeasure(lanes: next.lanes)
        AgentsParts.setVisible(empty, next.lanes.isEmpty)
        canvas.redraw()
    }

    func tick() { canvas.redraw() }

    func select(id: String?) {
        guard selectedID != id else { return }
        selectedID = id
        canvas.redraw()
    }

    func lane(for id: String) -> AgentHourLane? { layout.lanes.first { $0.id == id } }

    /// The pointer on a lane, as the harness says it: the lane's index and where on the track.
    func hover(laneIndex: Int?) {
        hovered = laneIndex
        canvas.redraw()
    }

    private func remeasure(lanes: [AgentHourLane]) {
        let titleSize = AgentsText.size(canvas.widget, "Mg", style: .init(scale: 1, bold: true))
        let subSize = AgentsText.size(canvas.widget, "Mg", style: .init(scale: 0.86))
        let rowHeight = max(48, ceil(titleSize.height * 2 + subSize.height + 10))
        let child = max(34, ceil(titleSize.height + subSize.height + 10))
        let label = max(200, min(280, widthNow * 0.28))
        layout = AgentHourLayout(
            width: max(widthNow, 300), labelWidth: label, rulerHeight: max(30, ceil(subSize.height + 16)),
            rowHeight: rowHeight, childHeight: child, lanes: lanes)
        gtk_widget_set_size_request(canvas.widget, -1, Int32(max(layout.contentHeight + 8, 120)))
        var summary: [String] = []
        for lane in lanes { summary.append(lane.title + ", " + AgentHourWords.state(lane, now: Date())) }
        tailscode_set_accessible_description(canvas.widget, summary.joined(separator: "; "))
    }

    private func resized(_ width: Double) {
        guard abs(width - widthNow) > 0.5 else { return }
        widthNow = width
        remeasure(lanes: layout.lanes)
        canvas.redraw()
    }

    private func moved(_ x: Double, _ y: Double) {
        pointer = (x, y)
        let index = layout.lane(atY: y)
        let now = Date()
        if index != hovered {
            hovered = index
            canvas.redraw()
        }
        var words = ""
        if let index, let hour {
            words = AgentHourWords.tooltip(
                lane: layout.lanes[index], at: layout.date(atX: x, now: now), unseen: hour.unseen, now: now)
        }
        if words != tooltipFor {
            tooltipFor = words
            gtk_widget_set_tooltip_text(canvas.widget, words.isEmpty ? nil : words)
        }
    }

    private func left() {
        pointer = nil
        guard hovered != nil else { return }
        hovered = nil
        canvas.redraw()
    }

    private func clicked() {
        guard let pointer, let index = layout.lane(atY: pointer.y) else { return }
        choose(layout.lanes[index])
    }

    private func choose(_ lane: AgentHourLane) {
        selectedID = lane.id
        canvas.redraw()
        onSelect(lane)
    }

    /// Up and down walk the lanes, as they walk any list: the one selected is the one the peek shows.
    private func key(_ keyval: UInt32) -> Bool {
        let lanes = layout.lanes
        guard !lanes.isEmpty else { return false }
        let current = selectedID.flatMap { id in lanes.firstIndex { $0.id == id } }
        let next: Int
        switch keyval {
        case Keymap.down: next = min((current ?? -1) + 1, lanes.count - 1)
        case Keymap.up: next = max((current ?? lanes.count) - 1, 0)
        default: return false
        }
        Gtk.onMain { [weak self] in self?.choose(lanes[next]) }
        return true
    }

    func chooseLane(at index: Int) {
        guard layout.lanes.indices.contains(index) else { return }
        choose(layout.lanes[index])
    }
}
