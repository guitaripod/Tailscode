import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The zone filters: the digest's bars turned into the control. A panel of one row per zone
/// (glyph, name, bar, count, the key that toggles it) with a FAILED row under a rule beside the
/// head, or a row of glyph-and-count chips above the list when the row is too narrow or the turn
/// has fewer than three zones. One canvas; a press toggles, shift or a double press solos.
final class BrainFilters: @unchecked Sendable {
    let ref: WeakBrainView
    let canvas: UnsafeMutablePointer<GtkWidget>
    private(set) var layout: NeuralStageMetrics
    private var fonts = BrainListFonts()
    private var hover: Target?
    private var presses: [Target: Double] = [:]

    enum Target: Hashable {
        case zone(NeuralZone)
        case failed
    }

    init(owner: BrainView) {
        ref = WeakBrainView(owner)
        layout = owner.currentMetrics
        let holder = DrawHolder()
        _ = Gtk.releaseInstalled
        canvas = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                Unmanaged<DrawHolder>.fromOpaque(raw).takeUnretainedValue().filters?.paint(
                    cr, width: Double(width), height: Double(height))
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<DrawHolder>.fromOpaque(raw).release()
            })!
        holder.filters = self
        gtk_widget_set_can_focus(canvas, 0)
        Gtk.addClass(canvas, "brain-filters")
        tailscode_set_accessible_label(canvas, BrainWords.stepFilters)
        Gtk.onPointer(
            canvas,
            move: { [weak self] x, y in self?.moved(x: x, y: y) },
            leave: { [weak self] in self?.left() })
        let box = Unmanaged.passRetained(ClickBox { [weak self] x, y, presses, button in
            self?.clicked(x: x, y: y, presses: Int(presses), button: Int(button))
        }).toOpaque()
        tailscode_on_click_at(
            canvas,
            { x, y, presses, button, raw in
                guard let raw else { return }
                Unmanaged<ClickBox>.fromOpaque(raw).takeUnretainedValue().handler(x, y, presses, button)
            }, box)
    }

    private final class DrawHolder: @unchecked Sendable {
        weak var filters: BrainFilters?
    }

    private final class ClickBox: @unchecked Sendable {
        let handler: (Double, Double, Int32, Int32) -> Void
        init(_ handler: @escaping (Double, Double, Int32, Int32) -> Void) { self.handler = handler }
    }

    var isPanel: Bool { false }
    var rect: NeuralRect? { layout.filterChips ?? layout.filterPanel }

    func configure(metrics: NeuralStageMetrics) {
        guard metrics != layout else { return }
        layout = metrics
        gtk_widget_queue_draw(canvas)
    }

    func retheme() {
        fonts = BrainListFonts()
        gtk_widget_queue_draw(canvas)
    }

    func invalidate() { gtk_widget_queue_draw(canvas) }

    private struct Entry {
        let target: Target
        let zone: NeuralZone?
        let count: Int
        let isOn: Bool
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        /// The word a chip carries beside its count: only the one for what the agent said.
        var label: String? = nil
    }

    private func entries(width: Double, height: Double) -> [Entry] {
        guard let model = ref.view?.model else { return [] }
        let list = model.browseState.list
        let chips = list.zoneChips
        let offersFailed = false
        var widths = chips.map { chipWidth(count: $0.count, compact: false) + labelRoom(for: $0.zone) }
        if offersFailed { widths.append(chipWidth(count: list.failedCount, compact: false)) }
        let gap = 4.0
        let needed = widths.reduce(0, +) + gap * Double(max(widths.count - 1, 0))
        let compact = needed > width
        var made: [Entry] = []
        var x = 0.0
        for chip in chips {
            let w =
                (compact ? chipWidth(count: chip.count, compact: true) : chipWidth(count: chip.count, compact: false))
                + labelRoom(for: chip.zone)
            made.append(
                Entry(
                    target: .zone(chip.zone), zone: chip.zone, count: chip.count, isOn: chip.isOn, x: x, y: 0,
                    width: w, height: NeuralStageMetrics.chipsHeight,
                    label: chip.zone == .say ? chip.zone.displayLabel : nil))
            x += w + gap
        }
        if offersFailed {
            let w = chipWidth(count: list.failedCount, compact: compact)
            made.append(
                Entry(
                    target: .failed, zone: nil, count: list.failedCount, isOn: list.filter.failedOnly, x: x,
                    y: 0, width: w, height: NeuralStageMetrics.chipsHeight))
        }
        return made
    }

    /// What a labelled chip adds to a bare one: its word and the air before it.
    private func labelRoom(for zone: NeuralZone) -> Double {
        guard zone == .say else { return 0 }
        return BrainDraw.measure(zone.displayLabel, fonts.said) + 8
    }

    private func labelRoom(forLabel label: String?) -> Double {
        guard let label else { return 0 }
        return BrainDraw.measure(label, fonts.said) + 8
    }

    private func chipWidth(count: Int, compact: Bool) -> Double {
        let digits = BrainDraw.measure("\(count)", fonts.panelCount)
        return (compact ? 4 : 5) + 18 + 4 + digits + 8
    }

    private func target(atX x: Double, y: Double) -> (Target, Entry)? {
        guard let rect else { return nil }
        for entry in entries(width: rect.width, height: rect.height)
        where x >= entry.x && x <= entry.x + entry.width && y >= entry.y && y <= entry.y + entry.height {
            return (entry.target, entry)
        }
        return nil
    }

    private func moved(x: Double, y: Double) {
        let found = target(atX: x, y: y)?.0
        guard found != hover else { return }
        hover = found
        gtk_widget_set_cursor_from_name(canvas, found == nil ? nil : "pointer")
        gtk_widget_set_tooltip_text(canvas, found.map { tooltip(for: $0) })
        gtk_widget_queue_draw(canvas)
    }

    /// What a chip is called and the key that toggles it.
    private func tooltip(for target: Target) -> String {
        switch target {
        case .zone(let zone): return "\(zone.displayLabel) · \(zone.filterKey)"
        case .failed: return "\(BrainWords.failedWord) · !"
        }
    }

    private func left() {
        guard hover != nil else { return }
        hover = nil
        gtk_widget_set_cursor_from_name(canvas, nil)
        gtk_widget_queue_draw(canvas)
    }

    private func clicked(x: Double, y: Double, presses: Int, button: Int) {
        guard button == 1, let (found, _) = target(atX: x, y: y), let view = ref.view else { return }
        let solo = presses >= 2 || Gtk.shiftHeld(canvas)
        switch found {
        case .zone(let zone):
            view.browse(.zoneChip(zone, solo: solo), grabFocus: false)
        case .failed:
            view.browse(.failedToggle, grabFocus: false)
        }
        view.focusList()
    }

    /// Where a filter's row or chip stands in the row's own coordinates, for the harness.
    func centre(of zone: NeuralZone?) -> NeuralPoint? {
        guard let rect else { return nil }
        let target: Target = zone.map { .zone($0) } ?? .failed
        guard let entry = entries(width: rect.width, height: rect.height).first(where: { $0.target == target })
        else { return nil }
        return NeuralPoint(rect.x + entry.x + entry.width / 2, rect.y + entry.y + entry.height / 2)
    }

    /// The chips as they are drawn, left to right, for the harness: the zone, the word it carries
    /// beside its count (only the voice's), and the count.
    var chipSummary: [(zone: NeuralZone, label: String?, count: Int)] {
        guard let rect else { return [] }
        return entries(width: rect.width, height: rect.height).compactMap { entry in
            entry.zone.map { ($0, entry.label, entry.count) }
        }
    }

    var reading: String {
        guard let rect, let model = ref.view?.model else { return "-" }
        let list = model.browseState.list
        let on = NeuralZone.allCases.filter { list.filter.zones.contains($0) }.map(\.label).joined(separator: "+")
        return "\("chips") entries=\(entries(width: rect.width, height: rect.height).count) on=[\(on)] failed=\(list.filter.failedOnly)"
    }

    private func paint(_ cr: OpaquePointer, width: Double, height: Double) {
        guard let view = ref.view, !view.disposed else { return }
        let inks = view.inks
        for entry in entries(width: width, height: height) { paintChip(cr, entry, inks: inks) }
    }

    private func tone(_ entry: Entry, inks: BrainInks) -> BrainInks.RGB {
        entry.zone.map { inks.corrected($0) } ?? inks.cDanger
    }

    private func paintGlyph(_ cr: OpaquePointer, _ entry: Entry, cx: Double, cy: Double, inks: BrainInks) {
        let color = tone(entry, inks: inks)
        if let zone = entry.zone {
            BrainDraw.zoneGlyph(cr, zone: zone, cx: cx, cy: cy, color: color, alpha: 1)
        } else {
            BrainDraw.cross(cr, cx: cx, cy: cy, size: 5.5, color: color, alpha: 1)
        }
    }

    private func paintChip(_ cr: OpaquePointer, _ entry: Entry, inks: BrainInks) {
        let isSaid = entry.label != nil
        let color = isSaid ? inks.accent : tone(entry, inks: inks)
        let hot = hover == entry.target
        let height = NeuralStageMetrics.chipsHeight
        BrainDraw.roundedRect(cr, entry.x + 0.5, 0.5, entry.width - 1, height - 1, height / 2)
        BrainDraw.fill(cr, entry.isOn ? color : inks.card, entry.isOn ? 0.18 : 1)
        cairo_fill_preserve(cr)
        let rest = isSaid ? BrainInks.mix(inks.rule2, inks.accent, 0.55) : inks.rule2
        BrainDraw.fill(cr, entry.isOn ? color : (hot ? inks.accent : rest), 1)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        let compact = entry.width - labelRoom(forLabel: entry.label) < chipWidth(count: entry.count, compact: false) - 0.5
        let glyphX = entry.x + (compact ? 4 : 6) + 9
        paintGlyph(cr, entry, cx: glyphX, cy: height / 2, inks: inks)
        var textX = glyphX + 13
        if let word = entry.label {
            BrainDraw.line(
                cr, word, font: fonts.said, lineHeight: fonts.lineHeight, x: textX, top: 0, height: height,
                color: inks.accent)
            textX += BrainDraw.measure(word, fonts.said) + 8
        }
        BrainDraw.line(
            cr, "\(entry.count)", font: fonts.panelCount, lineHeight: fonts.lineHeight, x: textX,
            top: 0, height: height, color: entry.target == .failed ? inks.cDanger : inks.ink)
    }
}
