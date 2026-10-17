import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// One turn's brain in the transcript: the collapsed line, and under it the stage while it is open.
///
/// The row's widget is kept for the life of the turn. A step arriving, a tool ending or a theme
/// change is a new row value the pane hands to `restate`, which brings the model up to date and
/// redraws what changed; only opening, closing and Rows change the widget's shape. The view lives
/// on its root widget's own data, so a row torn down releases the stage, the compositor and the
/// clock without anyone remembering to.
final class BrainView: @unchecked Sendable {
    private static let key = "tailscode-brain-view"

    let widget: UnsafeMutablePointer<GtkWidget>
    weak var host: BrainHost?
    let turnID: String
    private(set) var row: BrainRow
    var model: NeuralBrainModel
    private var inks: BrainInks
    private let glyphArea: UnsafeMutablePointer<GtkWidget>
    private let glyphHolder: GlyphHolder
    private let lead: UnsafeMutablePointer<GtkWidget>
    private let countLabel: UnsafeMutablePointer<GtkWidget>
    private let detailLabel: UnsafeMutablePointer<GtkWidget>
    private let addLabel: UnsafeMutablePointer<GtkWidget>
    private let removeLabel: UnsafeMutablePointer<GtkWidget>
    private let failureLabel: UnsafeMutablePointer<GtkWidget>
    private let replayButton: UnsafeMutablePointer<GtkWidget>
    private let rowsButton: UnsafeMutablePointer<GtkWidget>
    private let chevron: UnsafeMutablePointer<GtkWidget>
    private(set) var stage: BrainStage?
    private lazy var clock = BrainClock { [weak self] time in self?.step(time) }
    private(set) var isSuspended = false
    private var replayWhenOpen = false
    private var announcement: String?
    private var lineTicket = 0
    private var lastLine = ""
    private var lastFailure = ""
    private var lastTally = ""
    private var context: TranscriptContext?

    var isOpen: Bool { row.open }
    var hasStage: Bool { stage != nil }
    var isClockRunning: Bool { clock.isRunning }

    static func current(of widget: UnsafeMutablePointer<GtkWidget>) -> BrainView? {
        guard let raw = g_object_get_data(ptr(widget), key) else { return nil }
        return Unmanaged<BrainView>.fromOpaque(raw).takeUnretainedValue()
    }

    static func make(_ row: BrainRow, context: TranscriptContext) -> UnsafeMutablePointer<GtkWidget> {
        let view = BrainView(row: row, context: context)
        let box = Unmanaged.passRetained(view).toOpaque()
        g_object_set_data_full(
            ptr(view.widget), key, box,
            { raw in
                guard let raw else { return }
                let view = Unmanaged<BrainView>.fromOpaque(raw).takeRetainedValue()
                view.teardown()
            })
        view.finishBuilding()
        return view.widget
    }

    private init(row: BrainRow, context: TranscriptContext) {
        self.row = row
        self.context = context
        host = context.brains
        turnID = row.turn.id
        let brainContext = context.brains?.context(for: row.turn.id) ?? .none
        model = NeuralBrainModel(turn: row.turn, context: brainContext)
        inks = BrainInks(palette: MatrixTheme.palette, face: model.face)
        widget = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(widget, "brain-row")
        lead = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.addClass(lead, "brain-lead")
        gtk_widget_set_hexpand(lead, 1)
        let holder = GlyphHolder()
        glyphHolder = holder
        glyphArea = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw,
                    let view = Unmanaged<GlyphHolder>.fromOpaque(raw).takeUnretainedValue().view
                else { return }
                view.drawGlyph(cr, width: Double(width), height: Double(height))
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<GlyphHolder>.fromOpaque(raw).release()
            })!
        countLabel = Gtk.label("", css: "tool-name", selectable: false)
        detailLabel = Gtk.label("", css: "tool-detail", selectable: false)
        addLabel = Gtk.label("", css: "diff-add", selectable: false)
        removeLabel = Gtk.label("", css: "diff-remove", selectable: false)
        failureLabel = Gtk.label("", css: "brain-failure", selectable: false)
        replayButton = Gtk.button(NeuralReading.replayLabel, css: ["brain-pill"]) {}
        rowsButton = Gtk.button(NeuralReading.rowsLabel, css: ["brain-pill"]) {}
        chevron = Gtk.button(Gtk.chevronShut, css: ["brain-chevron", "flat"]) {}
        holder.view = self
    }

    private final class GlyphHolder: @unchecked Sendable {
        weak var view: BrainView?
    }

    private func finishBuilding() {
        gtk_widget_set_size_request(glyphArea, 28, Int32(NeuralGlyph.height(forWidth: 28)))
        gtk_widget_set_valign(glyphArea, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(lead), glyphArea)
        for label in [countLabel, addLabel, removeLabel, failureLabel, detailLabel] {
            gtk_box_append(ptr(lead), label)
        }
        gtk_widget_set_hexpand(detailLabel, 1)
        gtk_label_set_ellipsize(op(detailLabel), PANGO_ELLIPSIZE_END)
        gtk_label_set_single_line_mode(op(detailLabel), 1)
        gtk_widget_set_visible(addLabel, 0)
        gtk_widget_set_visible(removeLabel, 0)
        gtk_widget_set_visible(failureLabel, 0)
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(header), lead)
        gtk_box_append(ptr(header), replayButton)
        gtk_box_append(ptr(header), rowsButton)
        gtk_box_append(ptr(header), chevron)
        gtk_box_append(ptr(widget), header)
        gtk_widget_set_cursor_from_name(lead, "pointer")
        Gtk.onRelease(lead) { [weak self] in
            Gtk.onMain { [weak self] in self?.toggleOpen() }
        }
        Gtk.connect(UnsafeMutableRawPointer(chevron), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.toggleOpen() }
        }
        Gtk.connect(UnsafeMutableRawPointer(rowsButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self.map { $0.host?.toggleRows(turnID: $0.turnID) } }
        }
        Gtk.connect(UnsafeMutableRawPointer(replayButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.toggleReplay() }
        }
        host?.register(self)
        RepeatingMotion.watch(widget) { [weak self] in self?.motionChanged() }
        refreshChrome()
        if row.open { showStage() }
        updateClock()
        startLineTimer()
    }

    func teardown() {
        clock.stop()
        stage?.teardown()
        stage = nil
        host?.forget(self)
        lineTicket += 1
    }

    deinit { teardown() }

    /// Brings the view to a new row value; the widget stays.
    func restate(_ next: BrainRow) {
        let old = row
        row = next
        refreshContextInto()
        if old.look != next.look || old.turn.modelID != next.turn.modelID {
            inks = BrainInks(palette: MatrixTheme.palette, face: model.face)
            stage?.retheme()
        }
        if old.open != next.open {
            if next.open { showStage() } else { hideStage() }
        }
        stage?.modelChanged()
        refreshChrome()
        redrawNow()
        updateClock()
    }

    private func refreshContextInto() {
        let brainContext = host?.context(for: turnID) ?? .none
        model.update(turn: row.turn, context: brainContext)
    }

    /// The conversation's account of the live turn changed.
    func refreshContext() {
        let brainContext = host?.context(for: turnID) ?? .none
        model.update(turn: row.turn, context: brainContext)
        stage?.modelChanged()
        redrawNow()
        updateClock()
    }

    /// The palette or the face changed: the colours are made again and the head is drawn afresh.
    func rethemed() {
        inks = BrainInks(palette: MatrixTheme.palette, face: model.face)
        stage?.retheme()
        redrawNow()
    }

    var stageHasFocus: Bool { stage.map { gtk_widget_has_focus($0.overlay) != 0 } ?? false }

    func handleKey(keyval: UInt32, state: UInt32) -> Bool {
        stage?.handleKey(keyval, state: state) ?? false
    }

    func budgetChanged() {
        if row.open, stage == nil, BrainBudget.stageAllowed, !isSuspended {
            showStage()
        } else if stage != nil, !BrainBudget.stageAllowed {
            hideStage()
        }
        motionChanged()
    }

    func motionChanged() {
        stage?.invalidate()
        redrawNow()
        updateClock()
    }

    private func drawGlyph(_ cr: OpaquePointer, width: Double, height: Double) {
        BrainPainter.glyph(
            cr, glyph: model.glyph(dim: !row.open && model.turn.outcome != .running),
            width: width, height: height, inks: inks, time: BrainClock.now,
            reduceMotion: BrainBudget.reduceMotion)
    }

    private func refreshChrome() {
        let line = model.line(now: Date())
        let detail = [line.toolMix.isEmpty ? nil : line.toolMix, line.duration, line.thoughts, line.notes]
            .compactMap { $0 }.joined(separator: " · ")
        let summary = line.count + "|" + detail
        if summary != lastLine {
            lastLine = summary
            gtk_label_set_text(op(countLabel), line.count)
            gtk_label_set_text(op(detailLabel), detail)
        }
        let tally = line.tally ?? ""
        if tally != lastTally {
            lastTally = tally
            gtk_widget_set_visible(addLabel, line.added > 0 ? 1 : 0)
            gtk_widget_set_visible(removeLabel, line.removed > 0 ? 1 : 0)
            gtk_label_set_text(op(addLabel), "+\(line.added)")
            gtk_label_set_text(op(removeLabel), "\u{2212}\(line.removed)")
        }
        let failure = line.failure ?? ""
        if failure != lastFailure {
            lastFailure = failure
            gtk_widget_set_visible(failureLabel, failure.isEmpty ? 0 : 1)
            gtk_label_set_text(op(failureLabel), failure)
        }
        let unrecovered = model.steps.contains { $0.status == .failed && !$0.recovered }
        gtk_widget_remove_css_class(failureLabel, "brain-failure-hard")
        if unrecovered { gtk_widget_add_css_class(failureLabel, "brain-failure-hard") }
        let settled = model.turn.outcome != .running
        gtk_widget_set_visible(replayButton, settled && model.steps.count > 1 ? 1 : 0)
        gtk_button_set_label(ptr(replayButton), model.isReplaying ? replayStopLabel : NeuralReading.replayLabel)
        gtk_widget_remove_css_class(rowsButton, "on")
        if row.showRows { gtk_widget_add_css_class(rowsButton, "on") }
        tailscode_set_accessible_pressed(rowsButton, row.showRows ? 1 : 0)
        gtk_button_set_label(ptr(chevron), row.open ? Gtk.chevronOpen : Gtk.chevronShut)
        tailscode_set_accessible_expanded(chevron, row.open ? 1 : 0)
        let spoken = model.spoken
        gtk_widget_set_tooltip_text(lead, spoken)
        tailscode_set_accessible_label(lead, spoken)
        tailscode_set_accessible_label(chevron, row.open ? Localized.text("Close") : Localized.text("Open"))
    }

    private var replayStopLabel: String { Localized.text("Stop") }

    /// A running turn's duration moves once a second whether or not anything else does.
    private func startLineTimer() {
        lineTicket += 1
        let ticket = lineTicket
        guard model.turn.outcome == .running else { return }
        Gtk.after(1000) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.lineTicket == ticket, !self.isSuspended else { return }
                self.refreshChrome()
                self.startLineTimer()
            }
        }
    }

    func redrawNow() {
        gtk_widget_queue_draw(glyphArea)
        stage?.render(BrainClock.now)
        stage?.syncScrubber(BrainClock.now)
    }

    var accessibleLabel: String { announcement ?? model.spoken }

    func toggleOpen() {
        host?.toggleOpen(turnID: turnID)
    }

    private func showStage() {
        guard stage == nil, BrainBudget.stageAllowed, NeuralAssetFiles.isAvailable else { return }
        let made = BrainStage(owner: self)
        stage = made
        gtk_box_append(ptr(widget), made.root)
        if isSuspended { made.suspend() } else { made.ensureRenderer() }
        made.rebuildChips()
        if replayWhenOpen {
            replayWhenOpen = false
            model.startReplay(now: BrainClock.now)
        }
        made.render(BrainClock.now)
    }

    private func hideStage() {
        guard let held = stage else { return }
        stage = nil
        held.releaseSurfaces()
        held.teardown()
        gtk_box_remove(ptr(widget), held.root)
        announcement = nil
        model.clearSelection()
        model.setProvenance(token: nil)
        model.setDiving(false)
        if model.isReplaying { model.stopReplay() }
        updateClock()
    }

    func hover(_ id: String?) {
        model.setHover(id)
        afterSelection()
    }

    func pin(_ id: String) {
        model.togglePin(id)
        afterSelection()
    }

    func clearSelection() {
        model.clearSelection()
        model.setProvenance(token: nil)
        announcement = nil
        afterSelection()
    }

    func walk(to id: String) {
        if let pinned = model.pinned { model.togglePin(pinned) }
        model.setHover(id)
        if let step = model.step(id: id) {
            announcement = NeuralReading.announcement(for: step, of: model.steps.count)
        }
        afterSelection()
    }

    func point(at token: String?) {
        model.setProvenance(token: token)
        afterSelection()
    }

    private func afterSelection() {
        stage?.modelChanged()
        redrawNow()
        updateClock()
    }

    func openSubagent(of id: String) {
        guard let step = model.step(id: id), step.isCard, step.zone == .delegate else {
            pin(id)
            return
        }
        context?.openSubagent?(step.id)
    }

    func escape() {
        if stage?.diveZone != nil {
            stage?.dive(into: nil)
        } else {
            clearSelection()
        }
    }

    func focusStage() {
        if let stage { gtk_widget_grab_focus(stage.overlay) }
    }

    func walkStep(_ direction: Int) {
        stage?.walkFromHarness(direction)
    }

    func dive(_ zone: NeuralZone?) {
        stage?.dive(into: zone)
    }

    func driveChip(_ index: Int?) {
        stage?.driveChip(index)
    }

    func scrub(to fraction: Double) {
        model.scrub(to: fraction)
        afterReplayChange()
    }

    func endScrub() {
        model.endScrub()
        afterReplayChange()
    }

    func toggleReplay() {
        if model.isReplaying {
            model.stopReplay()
            afterReplayChange()
            return
        }
        guard model.turn.outcome != .running else { return }
        if !row.open {
            replayWhenOpen = true
            host?.setOpen(true, turnID: turnID)
            return
        }
        model.startReplay(now: BrainClock.now)
        afterReplayChange()
    }

    private func afterReplayChange() {
        refreshChrome()
        stage?.invalidate()
        redrawNow()
        updateClock()
    }

    private func step(_ time: Double) {
        if model.replayDone(now: time) {
            model.stopReplay()
            refreshChrome()
            stage?.invalidate()
        }
        gtk_widget_queue_draw(glyphArea)
        if let stage { stage.step(time) }
        updateClock()
    }

    func updateClock() {
        guard !isSuspended else {
            clock.stop()
            return
        }
        let tempo = model.tempo(reduceMotion: BrainBudget.reduceMotion)
        clock.run(on: widget, tempo: tempo)
    }

    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        clock.stop()
        stage?.suspend()
        lineTicket += 1
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        stage?.resume()
        refreshChrome()
        startLineTimer()
        redrawNow()
        updateClock()
    }

    func stageRendererReady() {
        redrawNow()
        updateClock()
    }

    var performance: String {
        guard let stage else { return "no stage" }
        let timings = stage.timings
        return String(
            format: "full=%.0fus x%d delta=%.0fus x%d size=%dx%d surfaces=%dKB renderer=%d",
            timings.full, timings.fulls, timings.delta, timings.deltas, stage.size.width,
            stage.size.height, stage.footprint / 1024, stage.hasRenderer ? 1 : 0)
    }

    var reading: String {
        let timings = stage?.timings
        return "turn=\(turnID) open=\(row.open) stage=\(stage != nil) renderer=\(stage?.hasRenderer == true) "
            + "clock=\(clock.isRunning)/\(clock.tempo) steps=\(model.steps.count) nodes=\(model.nodeCount) "
            + "selected=\(model.selected ?? "-") pinned=\(model.pinned ?? "-") "
            + "focus=\(stage.map { gtk_widget_has_focus($0.overlay) != 0 } ?? false) "
            + "state=\(model.state.label) running=\(model.steps.filter { $0.status == .running }.count) "
            + "outcome=\(model.turn.outcome) replay=\(model.isReplaying) frames=\(stage?.frames ?? 0) fulls=\(timings?.fulls ?? 0) "
            + "deltas=\(timings?.deltas ?? 0)"
    }
}
