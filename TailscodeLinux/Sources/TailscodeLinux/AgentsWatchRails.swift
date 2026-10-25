import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A chip in a rail: the outcome's own mark, a title and how long ago, or what is running past the
/// watch cap. A recent one opens its chat; a listed one is watched when it is pressed.
final class WatchChipView: @unchecked Sendable {
    let button = gtk_button_new()!
    let mark = WatchLabel(wrap: false)
    let words = WatchLabel(wrap: false)
    private(set) var chip: WallChip?
    private(set) var isCount = false
    private let context: WatchContext
    var onPress: (WallChip) -> Void = { _ in }

    init(context: WatchContext) {
        self.context = context
        Gtk.addClass(button, "agents-wall-chip")
        gtk_widget_set_focus_on_click(button, 0)
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_halign(row, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(row, GTK_ALIGN_CENTER)
        for label in [mark, words] {
            gtk_label_set_ellipsize(op(label.widget), PANGO_ELLIPSIZE_NONE)
            gtk_label_set_yalign(op(label.widget), 0.5)
        }
        gtk_widget_set_margin_start(mark.widget, 14)
        gtk_widget_set_margin_end(words.widget, 14)
        gtk_box_append(ptr(row), mark.widget)
        gtk_box_append(ptr(row), words.widget)
        gtk_button_set_child(ptr(button), row)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, let chip = self.chip, !self.isCount else { return }
                self.context.touched()
                self.onPress(chip)
            }
        }
    }

    func apply(_ next: WallChip, now: Date) {
        chip = next
        isCount = false
        let palette = context.palette
        let glyph: (String, PartyInk)
        switch next.outcome {
        case .done?: glyph = (StatusMark.done, palette.finished)
        case .failed?: glyph = (StatusMark.failed, palette.failed)
        case .stopped?: glyph = ("■", palette.dim)
        case .unknown?: glyph = ("–", palette.dim)
        case nil: glyph = ("●", palette.working)
        }
        mark.set(text: glyph.0 + " ")
        var text = next.title
        if next.outcome != nil, let at = next.at {
            text += " · " + Localized.text("%@ ago", AgentsParts.age(at, now: now))
        } else if !next.machine.isEmpty {
            text += " · " + next.machine
        }
        if next.outcome == nil, let agents = next.agentsLine { text += " · " + agents }
        words.set(text: text)
        mark.set(style: context.label(2.0, bold: true, ink: glyph.1))
        words.set(style: context.label(2.0, ink: palette.text))
        gtk_widget_set_sensitive(button, 1)
        gtk_widget_set_tooltip_text(button, next.outcome == nil ? Localized.text("Watch this one") : nil)
        tailscode_set_accessible_label(button, next.title + ", " + words.text)
    }

    func apply(count: Int, listed: Bool) {
        chip = nil
        isCount = true
        mark.set(text: "")
        words.set(text: listed ? Localized.text("+%d listed", count) : Localized.text("+%d more", count))
        mark.set(style: context.label(2.0, ink: context.palette.dim))
        words.set(style: context.label(2.0, ink: context.palette.dim))
        gtk_widget_set_tooltip_text(button, nil)
        tailscode_set_accessible_label(button, words.text)
    }

    var width: Double { mark.naturalWidth + words.naturalWidth + 28 + context.unit * 0.4 }
}

/// The two rails under the grid: the last endings, and the sessions running past the watch cap.
final class WatchRails: @unchecked Sendable {
    static let poolSize = 8

    let recentTitle = WatchLabel(wrap: false)
    let listedTitle = WatchLabel(wrap: false)
    let recentChips: [WatchChipView]
    let listedChips: [WatchChipView]
    private let context: WatchContext
    private var wall = AgentWall.empty
    private var recentShown = 0
    private var listedShown = 0

    init(context: WatchContext) {
        self.context = context
        recentChips = (0..<Self.poolSize).map { _ in WatchChipView(context: context) }
        listedChips = (0..<Self.poolSize).map { _ in WatchChipView(context: context) }
        recentTitle.set(text: Localized.text("Recent"))
        listedTitle.set(text: Localized.text("Also running"))
        for label in [recentTitle, listedTitle] {
            gtk_label_set_ellipsize(op(label.widget), PANGO_ELLIPSIZE_NONE)
            gtk_label_set_yalign(op(label.widget), 0.5)
        }
    }

    var widgets: [UnsafeMutablePointer<GtkWidget>] {
        [recentTitle.widget, listedTitle.widget] + recentChips.map(\.button) + listedChips.map(\.button)
    }

    func apply(_ next: AgentWall, now: Date) {
        wall = next
        let palette = context.palette
        recentTitle.set(style: context.label(1.7, bold: true, ink: palette.dim))
        listedTitle.set(style: context.label(1.7, bold: true, ink: palette.dim))
        for (index, chip) in recentChips.enumerated() where index < next.recent.count {
            chip.apply(next.recent[index], now: now)
        }
        for (index, chip) in listedChips.enumerated() where index < next.listed.count {
            chip.apply(next.listed[index], now: now)
        }
    }

    var titles: (recent: Int, listed: Int) { (recentShown, listedShown) }

    func place(_ geometry: WatchGeometry, sink: TileSink) {
        let left = geometry.recentRail
        let right = geometry.listedRail
        let whole = WatchRect(x: left.x, y: left.y, width: right.maxX - left.x, height: left.height)
        let listedEmpty = wall.listed.isEmpty && wall.listedOverflow == 0
        recentShown = flow(
            wall.recent.count, chips: recentChips, title: recentTitle, in: listedEmpty ? whole : left,
            geometry: geometry, overflow: 0, listed: false, sink: sink)
        listedShown = flow(
            wall.listed.count, chips: listedChips, title: listedTitle, in: wall.recent.isEmpty ? whole : right,
            geometry: geometry, overflow: wall.listedOverflow, listed: true, sink: sink)
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> TileRect {
        TileRect(
            x: Int32(x.rounded()), y: Int32(y.rounded()), width: Int32(max(1, width.rounded())),
            height: Int32(max(1, height.rounded())))
    }

    private func flow(
        _ count: Int, chips: [WatchChipView], title: WatchLabel, in rail: WatchRect,
        geometry: WatchGeometry, overflow: Int, listed: Bool, sink: TileSink
    ) -> Int {
        guard count > 0 || overflow > 0 else { return 0 }
        let u = geometry.unit
        let chipHeight = rail.height
        let titleWidth = title.naturalWidth + 1.4 * u
        sink.place(title.widget, rect(rail.x, rail.y, titleWidth, chipHeight))
        var x = rail.x + titleWidth
        var shown = 0
        var hidden = overflow
        for index in 0..<min(count, chips.count) {
            let width = chips[index].width
            let reserve = index < count - 1 || overflow > 0 ? 9 * u : 0
            if x + width + reserve > rail.maxX {
                hidden += count - index
                break
            }
            sink.place(chips[index].button, rect(x, rail.y, width, chipHeight))
            x += width + 0.9 * u
            shown += 1
        }
        if hidden > 0, shown < chips.count {
            let counter = chips[shown]
            counter.apply(count: hidden, listed: listed)
            let width = counter.width
            if x + width <= rail.maxX + 1 { sink.place(counter.button, rect(x, rail.y, width, chipHeight)) }
        }
        return shown
    }
}
