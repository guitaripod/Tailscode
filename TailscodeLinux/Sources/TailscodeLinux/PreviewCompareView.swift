import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The Compare lens: the pictures the host kept each time the app changed, newest first, and two
/// of them laid over each other with a handle to drag. The changed places are outlined and
/// numbered on the later picture and the sentence beneath says how much moved.
///
/// Two pictures are decoded at a time, inside the stage's drawing area, and released the moment
/// the selection changes. The list is asked for when the lens is opened, and again once when a
/// build finishes while it is showing; there is no clock.
final class PreviewCompareView: PreviewLensView, @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)

    private let context: PreviewLensContext
    private let list = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
    private let listScroller = gtk_scrolled_window_new()!
    private let pages = gtk_stack_new()!
    private let message = Gtk.label("", css: "preview-status", wrap: true, selectable: false)
    private let frame = gtk_aspect_frame_new(0.5, 0.5, 0.5, 0)!
    private let area = tailscode_compare_new()!
    private let summaryLabel = Gtk.label("", css: "preview-row-detail", wrap: true, selectable: false)
    private let sliderChip: UnsafeMutablePointer<GtkWidget>
    private let sideChip: UnsafeMutablePointer<GtkWidget>

    private(set) var history: [HistoryInfo] = []
    private(set) var pair: (before: Int, after: Int)?
    private(set) var report: DiffReport?
    private(set) var sideBySide = false
    private var picks: [Int] = []
    private var outlines: [Double] = []
    private var chose = false
    private var generation = 0
    private var rows: [Int: UnsafeMutablePointer<GtkWidget>] = [:]

    init(context: PreviewLensContext) {
        self.context = context
        sliderChip = Gtk.button(Localized.text("Slider"), css: ["preview-chip"]) {}
        sideChip = Gtk.button(Localized.text("Side by side"), css: ["preview-chip"]) {}
        build()
    }

    private func build() {
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)

        gtk_scrolled_window_set_policy(op(listScroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(listScroller), list)
        gtk_widget_set_size_request(listScroller, 250, -1)
        gtk_widget_set_vexpand(listScroller, 1)
        Gtk.margins(list, top: 8, bottom: 8, leading: 12, trailing: 8)
        gtk_box_append(ptr(root), listScroller)

        let overlay = gtk_overlay_new()!
        Gtk.addClass(overlay, "preview-picture")
        gtk_widget_set_overflow(overlay, GTK_OVERFLOW_HIDDEN)
        gtk_overlay_set_child(op(overlay), area)
        for (title, align) in [(Localized.text("Before"), GTK_ALIGN_START), (Localized.text("After"), GTK_ALIGN_END)] {
            let caption = Gtk.label(title, css: "preview-caption", selectable: false)
            gtk_widget_set_halign(caption, align)
            gtk_widget_set_valign(caption, GTK_ALIGN_END)
            gtk_widget_set_can_target(caption, 0)
            Gtk.margins(caption, 8)
            gtk_overlay_add_overlay(op(overlay), caption)
        }
        gtk_widget_set_hexpand(frame, 1)
        gtk_widget_set_vexpand(frame, 1)
        Gtk.margins(frame, top: 10, bottom: 6, leading: 12, trailing: 14)
        gtk_aspect_frame_set_child(op(frame), overlay)

        gtk_label_set_justify(op(summaryLabel), GTK_JUSTIFY_CENTER)
        gtk_label_set_xalign(op(summaryLabel), 0.5)
        gtk_widget_set_halign(summaryLabel, GTK_ALIGN_CENTER)

        let modes = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 4)
        gtk_widget_set_halign(modes, GTK_ALIGN_CENTER)
        Gtk.margins(modes, top: 4, bottom: 10, leading: 12, trailing: 12)
        gtk_box_append(ptr(modes), sliderChip)
        gtk_box_append(ptr(modes), sideChip)
        Gtk.connect(UnsafeMutableRawPointer(sliderChip), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.setSideBySide(false) }
        }
        Gtk.connect(UnsafeMutableRawPointer(sideChip), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.setSideBySide(true) }
        }

        let stage = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(stage, 1)
        gtk_widget_set_vexpand(stage, 1)
        gtk_box_append(ptr(stage), frame)
        gtk_box_append(ptr(stage), summaryLabel)
        gtk_box_append(ptr(stage), modes)

        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_valign(words, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(words, GTK_ALIGN_CENTER)
        Gtk.margins(words, 24)
        PreviewPane.capWidth(message, 36)
        gtk_label_set_justify(op(message), GTK_JUSTIFY_CENTER)
        gtk_label_set_xalign(op(message), 0.5)
        gtk_box_append(ptr(words), message)

        gtk_widget_set_hexpand(pages, 1)
        gtk_widget_set_vexpand(pages, 1)
        gtk_stack_set_transition_type(op(pages), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_add_named(op(pages), stage, "stage")
        gtk_stack_add_named(op(pages), words, "message")
        gtk_stack_set_visible_child_name(op(pages), "message")
        gtk_box_append(ptr(root), pages)
        paintModes()
    }

    /// In a narrow pane the list of pictures goes under the stage, as a short strip, instead of
    /// beside it, where it would leave the pictures a sliver.
    func fit(narrow: Bool) {
        gtk_orientable_set_orientation(
            OpaquePointer(root), narrow ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL)
        gtk_widget_set_size_request(listScroller, narrow ? -1 : 250, narrow ? 120 : -1)
        gtk_widget_set_vexpand(listScroller, narrow ? 0 : 1)
        if narrow {
            gtk_box_reorder_child_after(ptr(root), listScroller, pages)
        } else {
            gtk_box_reorder_child_after(ptr(root), listScroller, nil)
        }
    }

    func open() {
        refreshHistory()
    }

    func close() {
        generation += 1
        tailscode_compare_clear(area)
        history = []
        pair = nil
        report = nil
        picks = []
        rebuildList()
    }

    private var outlineInk: [Double] {
        let ink = PresenceRGB(hex: MatrixTheme.palette.special) ?? PresenceRGB(red: 0.9, green: 0.7, blue: 0.2)
        return [ink.red, ink.green, ink.blue]
    }

    func refreshHistory() {
        guard let runner = context.runner() else {
            show(message: PreviewLensFailure.unreachable)
            return
        }
        context.tasks.spawn(slot: "history") { [weak self] in
            do {
                let shots = try await runner.history()
                Gtk.onMain { [weak self] in self?.adopt(shots) }
            } catch {
                guard !Task.isCancelled else { return }
                Gtk.onMain { [weak self] in self?.show(message: PreviewLensFailure.words(for: error)) }
            }
        }
    }

    private var debounce = 0

    /// A build finished while this lens is showing: ask for the list once, shortly after the last
    /// such event, so two builds in a row are one request.
    func historyMayHaveChanged() {
        debounce += 1
        let ticket = debounce
        context.tasks.spawn(slot: "debounce") { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            Gtk.onMain { [weak self] in
                guard let self, self.debounce == ticket else { return }
                self.refreshHistory()
            }
        }
    }

    func adopt(_ shots: [HistoryInfo]) {
        history = shots.sorted { $0.id > $1.id }
        rebuildList()
        guard history.count >= 2, let fallback = PreviewCompareReading.defaultPair(history) else {
            tailscode_compare_clear(area)
            pair = nil
            report = nil
            show(message: Localized.text("Compare needs two pictures of the screen. One is kept each time your app changes, so change something, or press Rebuild on Look, and come back."))
            return
        }
        let ids = Set(history.map(\.id))
        if chose, let pair, ids.contains(pair.before), ids.contains(pair.after) {
            load(before: pair.before, after: pair.after)
        } else {
            chose = false
            load(before: fallback.before, after: fallback.after)
        }
    }

    private func load(before: Int, after: Int) {
        generation += 1
        let ticket = generation
        pair = (before, after)
        paintRows()
        guard let runner = context.runner() else { return }
        let newest = history.map(\.id).max()
        let live = after == newest ? context.livePicture() : nil
        context.tasks.spawn(slot: "pair") { [weak self] in
            do {
                let earlier = try await runner.historyPicture(before)
                let later: Data
                if let live { later = live } else { later = try await runner.historyPicture(after) }
                let against: Int? = live == nil ? after : nil
                let found = try await runner.diff(before: before, after: against)
                Gtk.onMain { [weak self] in
                    guard let self, self.generation == ticket else { return }
                    self.present(before: earlier, after: later, report: found)
                }
            } catch {
                guard !Task.isCancelled else { return }
                Gtk.onMain { [weak self] in
                    guard let self, self.generation == ticket else { return }
                    self.show(message: PreviewLensFailure.words(for: error))
                }
            }
        }
    }

    func present(before: Data, after: Data, report found: DiffReport) {
        let held = before.withUnsafeBytes { first in
            after.withUnsafeBytes { second in
                tailscode_compare_set_pictures(
                    area, first.baseAddress, gsize(before.count), second.baseAddress, gsize(after.count))
            }
        }
        guard held != 0 else {
            show(message: Localized.text("That picture could not be read"))
            return
        }
        report = found
        let fractions: [Double] =
            found.sameSize
            ? found.regions.flatMap { region -> [Double] in
                let place = PreviewCompareReading.fractions(of: region, in: found)
                return [place.x, place.y, place.width, place.height]
            } : []
        outlines = fractions
        paintOutlines()
        gtk_label_set_text(op(summaryLabel), PreviewCompareReading.summary(found))
        applyMode()
        gtk_stack_set_visible_child_name(op(pages), "stage")
        paintRows()
    }

    private func paintOutlines() {
        let ink = outlineInk
        outlines.withUnsafeBufferPointer { fractions in
            ink.withUnsafeBufferPointer { ink in
                tailscode_compare_set_regions(
                    area, fractions.baseAddress, Int32(outlines.count / 4), ink.baseAddress)
            }
        }
    }

    /// The desk changed its palette: the same outlines again, in the new standing-mark ink.
    func retheme() {
        paintOutlines()
    }

    private func show(message text: String) {
        gtk_label_set_text(op(message), text)
        gtk_stack_set_visible_child_name(op(pages), "message")
    }

    private var showsSideBySide: Bool { sideBySide || !(report?.sameSize ?? true) }

    private func setSideBySide(_ side: Bool) {
        sideBySide = side
        applyMode()
    }

    private func applyMode() {
        tailscode_compare_set_mode(area, showsSideBySide ? 1 : 0)
        var width: Int32 = 0
        var height: Int32 = 0
        tailscode_compare_size(area, &width, &height)
        if width > 0, height > 0 {
            let ratio = Float(width) / Float(height) * (showsSideBySide ? 2 : 1)
            gtk_aspect_frame_set_ratio(op(frame), ratio)
        }
        paintModes()
    }

    private func paintModes() {
        Gtk.setTone(sliderChip, showsSideBySide ? nil : "preview-chip-on", from: ["preview-chip-on"])
        Gtk.setTone(sideChip, showsSideBySide ? "preview-chip-on" : nil, from: ["preview-chip-on"])
    }

    private func rebuildList() {
        Gtk.removeChildren(of: list)
        rows = [:]
        for shot in history {
            let row = gtk_button_new()!
            Gtk.addClass(row, "preview-shot")
            let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
            let title = Gtk.label(
                PreviewCompareReading.title(of: shot), css: "preview-row-title", wrap: true, selectable: false)
            let detail = Gtk.label(
                PreviewCompareReading.detail(of: shot), css: "preview-row-detail", wrap: true, selectable: false)
            gtk_label_set_max_width_chars(op(title), 22)
            gtk_label_set_max_width_chars(op(detail), 22)
            gtk_box_append(ptr(words), title)
            gtk_box_append(ptr(words), detail)
            gtk_button_set_child(ptr(row), words)
            let id = shot.id
            Gtk.connect(UnsafeMutableRawPointer(row), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in self?.rowPressed(id) }
            }
            rows[id] = row
            gtk_box_append(ptr(list), row)
        }
        paintRows()
    }

    private func paintRows() {
        let marked = picks.isEmpty ? [pair?.before, pair?.after].compactMap { $0 } : picks
        for (id, row) in rows {
            Gtk.setTone(row, marked.contains(id) ? "preview-shot-on" : nil, from: ["preview-shot-on"])
        }
    }

    func rowPressed(_ id: Int) {
        if picks.count >= 2 { picks = [] }
        if let index = picks.firstIndex(of: id) {
            picks.remove(at: index)
        } else {
            picks.append(id)
        }
        chose = true
        guard picks.count == 2, let first = picks.min(), let second = picks.max() else {
            paintRows()
            return
        }
        picks = []
        load(before: first, after: second)
    }

    var handle: Double { tailscode_compare_handle(area) }

    func setHandle(_ fraction: Double) {
        tailscode_compare_set_handle(area, fraction)
    }

    func plan(width: Int, height: Int) -> [Double] {
        var out = [Double](repeating: 0, count: 12 + 4 * 64)
        let written = tailscode_compare_plan(area, Int32(width), Int32(height), &out, Int32(out.count))
        return written < 0 ? [] : Array(out.prefix(Int(written)))
    }

    func drag(to x: Double, width: Int, height: Int) {
        tailscode_compare_drag(area, x, Int32(width), Int32(height))
    }

    func clearForTest() {
        tailscode_compare_clear(area)
    }

    var summary: String {
        let chosen = pair.map { "\($0.before)>\($0.after)" } ?? "-"
        let count = report.map { String($0.regions.count) } ?? "-"
        return String(
            format: "compare shots=%d pair=%@ regions=%@ mode=%@ handle=%.2f", history.count, chosen, count,
            showsSideBySide ? "side" : "slider", handle)
    }

    func drive(_ command: String) -> Bool {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return false }
        let argument = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "handle":
            guard let value = Double(argument) else { return false }
            setHandle(value)
        case "mode":
            setSideBySide(argument == "side")
        case "pick":
            let ids = argument.split(separator: ",").compactMap { Int($0) }
            for id in ids { rowPressed(id) }
        default:
            return false
        }
        return true
    }
}
