import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// One turn's brain in the transcript: a card while it is collapsed, and the stage with its
/// readout and footer while it is open, and the move that carries one into the other.
///
/// The row's widget is kept for the life of the turn. A step arriving, a tool ending or a theme
/// change is a new row value the pane hands to `restate`, which brings the model up to date and
/// redraws what changed; opening and closing is a move between two arrangements of the same
/// children. Every child is placed by rectangles Core's `NeuralStageMetrics` computes for the
/// row's width, at the moment the row is allocated, so a rect is never a frame late and a
/// resize between breakpoints rebuilds nothing.
///
/// The view lives on its root widget's own data, so a row torn down releases the stage, the
/// compositor and the clock without anyone remembering to.
final class BrainView: @unchecked Sendable {
    private static let key = "tailscode-brain-view"

    enum Phase: Sendable {
        case closed
        case open
        case moving
    }

    let widget: UnsafeMutablePointer<GtkWidget>
    weak var host: BrainHost?
    let turnID: String
    private(set) var row: BrainRow
    var model: NeuralBrainModel
    private(set) var inks: BrainInks
    private(set) var phase = Phase.closed
    private(set) var card: BrainCard!
    private(set) var stage: BrainStage?
    private(set) var readout: BrainReadout?
    private(set) var list: BrainList?
    private(set) var filters: BrainFilters?
    private(set) var account: BrainAccount?
    private(set) var readoutClip: UnsafeMutablePointer<GtkWidget>?
    var dimmedNodes: Set<String> = []
    var legendPopover: Gtk.WeakWidget?
    var pendingHover: (id: String?, delay: Double)?
    var hoverApplied: String?
    var hoverFlushScheduled = false
    var lastHoverApply = 0.0
    var menuPopover: Gtk.WeakWidget?
    private(set) var footer: BrainFooter?
    var moveCanvas: UnsafeMutablePointer<GtkWidget>?
    var edgeCanvas: UnsafeMutablePointer<GtkWidget>?
    lazy var clock = BrainClock { [weak self] time in self?.step(time) }
    private(set) var isSuspended = false
    private var context: TranscriptContext?
    private var replayWhenOpen = false
    var announcement: String?

    private var metricsMemo:
        (width: Double, density: ChatDensity, zones: Int, viewport: Int, need: Double, value: NeuralStageMetrics)?
    private var lastWidth = 0.0
    private var lastDensity = ChatDensity.comfortable
    private var scaleFactor = 1

    var moveState: BrainMove?
    var pendingOpen: PendingOpen?
    var revealOverride: BrainMove.Reveal?

    var readoutTicket = 0
    var leaderState = BrainLeaderState()
    var contentFade: Double?
    var contentFadeStart = 0.0
    private var prefetched: NeuralCompositor?
    private var prefetchTicket = 0
    var readoutHeld = false
    var needsDraw = false
    private var visibleCache: (time: Double, value: Bool)?
    private(set) var tokenComputations = 0
    var tickCosts: [String: UInt64] = [:]
    var tickCount = 0
    private var lastFooterSync = 0.0
    private var lastReadoutTick = 0.0
    private var tokenMemo: (answer: String, revision: Int, tokens: [String])?
    var frozen = false
    var readoutFadingUntil = 0.0
    private(set) var stageFocused = false
    private(set) var disposed = false

    struct PendingOpen {
        let started: Double
        let swapped: Bool
    }

    var isOpen: Bool { row.open }
    var hasStage: Bool { stage != nil }

    /// Whether this brain may build its stage: always when the person opened it, and otherwise
    /// only while the governor allows a head to be drawn. A shed window refuses to open the latest
    /// turn by itself; it never refuses a press.
    var stageMayOpen: Bool { BrainBudget.stageAllowed || (host?.choices[turnID] != nil) }
    /// A harness keeps the first picture from being ready, which is the renderer being too slow:
    /// the open then falls back to taking the stage with no move.
    var holdPictureForTest = false
    /// How long an open waits for the head's first picture before taking the stage with no move.
    nonisolated(unsafe) static var openFallbackMilliseconds: UInt32 = 1800
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

    private final class RowHost: @unchecked Sendable {
        weak var view: BrainView?
    }

    private init(row: BrainRow, context: TranscriptContext) {
        self.row = row
        self.context = context
        host = context.brains
        turnID = row.turn.id
        let brainContext = context.brains?.context(for: row.turn.id) ?? .none
        model = NeuralBrainModel(turn: row.turn, context: brainContext)
        inks = BrainInks(palette: MatrixTheme.palette, face: model.face)
        let holder = RowHost()
        _ = Gtk.releaseInstalled
        widget = tailscode_brain_row_new(
            { width, height, sink, raw in
                guard let raw, let sink else { return }
                Unmanaged<RowHost>.fromOpaque(raw).takeUnretainedValue().view?.solve(
                    width: Int(width), height: Int(height), sink: sink)
            },
            { width, raw in
                guard let raw else { return 1 }
                return Int32(
                    Unmanaged<RowHost>.fromOpaque(raw).takeUnretainedValue().view?.height(
                        forWidth: Int(width)) ?? 1)
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                let holder = Unmanaged<RowHost>.fromOpaque(raw)
                holder.takeUnretainedValue().view?.markDisposed()
                holder.release()
            })!
        holder.view = self
        Gtk.addClass(widget, "brain-row")
        card = BrainCard(owner: self)
    }

    private func finishBuilding() {
        for part in card.widgets { tailscode_brain_row_add(widget, part) }
        gtk_widget_set_cursor_from_name(widget, "pointer")
        Gtk.onRelease(widget) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.disposed else { return }
                self.cardPressed()
            }
        }
        Gtk.onKey(widget) { [weak self] keyval, state in
            self?.cardKey(keyval: keyval, state: state) ?? false
        }
        Gtk.onPointer(
            widget,
            move: { [weak self] _, _ in self?.pointerOverRow(true) },
            leave: { [weak self] in self?.pointerOverRow(false) })
        let focus = Unmanaged.passRetained(FocusWatch { [weak self] entered in
            self?.frameFocus(entered)
        }).toOpaque()
        _ = Gtk.releaseInstalled
        tailscode_on_focus_change(
            widget,
            { raw in
                guard let raw else { return }
                Unmanaged<FocusWatch>.fromOpaque(raw).takeUnretainedValue().handler(true)
            },
            { raw in
                guard let raw else { return }
                Unmanaged<FocusWatch>.fromOpaque(raw).takeUnretainedValue().handler(false)
            }, focus)
        host?.register(self)
        RepeatingMotion.watch(widget) { [weak self] in self?.motionChanged() }
        gtk_widget_set_focusable(widget, 1)
        gtk_widget_set_can_focus(widget, 1)
        card.refresh()
        if row.open, stageMayOpen, NeuralAssetFiles.isAvailable {
            showStage()
        } else {
            setPhase(.closed)
        }
        updateClock()
    }

    private final class FocusWatch: @unchecked Sendable {
        let handler: (Bool) -> Void
        init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
    }

    func teardown() {
        clock.stop()
        stage?.teardown()
        stage = nil
        host?.forget(self)
        readoutTicket += 1
        prefetchTicket += 1
        if let held = prefetched {
            BrainCompositors.release(held)
            prefetched = nil
        }
    }

    deinit { teardown() }

    /// The row's widget is being disposed: its children are about to be unparented and freed, so
    /// nothing a posted hop or a timer does from here on may touch a part of it. Called by the
    /// row itself before it lets go of any child, which is the one moment the parts are still real.
    fileprivate func markDisposed() {
        disposed = true
        dropPopovers()
        teardown()
        account?.teardown()
        account = nil
        readout = nil
        list = nil
        filters = nil
        readoutClip = nil
        footer = nil
        moveCanvas = nil
        edgeCanvas = nil
        moveState = nil
    }

    /// Whether a part of the stage may still be measured or drawn: the row is alive and sits in a
    /// window.
    func isLive(_ part: UnsafeMutablePointer<GtkWidget>) -> Bool {
        !disposed && gtk_widget_get_root(part) != nil
    }

    // MARK: metrics and layout

    var density: ChatDensity { Preferences.chatDensity }

    func metrics(forWidth width: Double) -> NeuralStageMetrics {
        let zones = model.browseState.list.zoneChips.count
        let viewport = host?.viewportHeight
        let bucket = Int((viewport ?? 0) / 8)
        let need = BrainCard.neededHeight(for: self, width: width)
        if let memo = metricsMemo, memo.width == width, memo.density == density, memo.zones == zones,
            memo.viewport == bucket, memo.need == need
        {
            return memo.value
        }
        let made = NeuralStageMetrics.make(
            width: width, density: density, zonesWithSteps: max(zones, 1), viewportHeight: viewport,
            cardMinHeight: need)
        metricsMemo = (width, density, zones, bucket, need, made)
        return made
    }

    /// The metrics for the width the row has now.
    var currentMetrics: NeuralStageMetrics {
        let width = Double(gtk_widget_get_width(widget))
        return metrics(forWidth: width > 0 ? width : lastWidth > 0 ? lastWidth : 600)
    }

    /// How much taller a narrow brain is than the step list it replaces: the account there is as
    /// tall as the window allows, not as tall as eight rows.
    func narrowExtra(_ m: NeuralStageMetrics) -> Double {
        guard m.arrangement == .accordion else { return 0 }
        return max(0, narrowAccountHeight(m) - m.list.height)
    }

    /// The account of a narrow brain: 62 percent of what the reader sees, between 340 and 640.
    func narrowAccountHeight(_ m: NeuralStageMetrics) -> Double {
        let viewport = host?.viewportHeight ?? 700
        return min(max((viewport * 0.62).rounded(), 340), 640)
    }

    func height(forWidth width: Int) -> Int {
        let m = metrics(forWidth: Double(max(width, 1)))
        switch phase {
        case .closed:
            return Int(m.card.height.rounded())
        case .open:
            return Int((m.rowHeight + narrowExtra(m)).rounded())
        case .moving:
            return Int((moveState?.frame.rowHeight ?? m.rowHeight).rounded())
        }
    }

    private func solve(width: Int, height: Int, sink: OpaquePointer) {
        let m = metrics(forWidth: Double(max(width, 1)))
        if Double(width) != lastWidth || m.density != lastDensity {
            lastWidth = Double(width)
            lastDensity = m.density
            Gtk.onMain { [weak self] in
                guard let self, !self.disposed else { return }
                self.widthChanged()
            }
        }
        switch phase {
        case .closed: placeCard(sink, m, offset: 0)
        case .open: placeOpen(sink, m)
        case .moving: placeMoving(sink, m)
        }
    }

    private func place(
        _ sink: OpaquePointer, _ child: UnsafeMutablePointer<GtkWidget>?,
        _ rect: NeuralRect, dx: Double = 0, dy: Double = 0
    ) {
        guard let child else { return }
        tailscode_brain_row_place(
            sink, child, Int32((rect.x + dx).rounded()), Int32((rect.y + dy).rounded()),
            Int32(rect.width.rounded()), Int32(rect.height.rounded()))
    }

    private func naturalSize(_ widget: UnsafeMutablePointer<GtkWidget>, width: Int32 = -1) -> (Double, Double) {
        var w: Int32 = 0
        var h: Int32 = 0
        gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, nil, &w, nil, nil)
        gtk_widget_measure(widget, GTK_ORIENTATION_VERTICAL, width >= 0 ? width : w, nil, &h, nil, nil)
        return (Double(w), Double(h))
    }

    func placeCard(
        _ sink: OpaquePointer, _ m: NeuralStageMetrics, offset: Double,
        height: Double? = nil
    ) {
        let cardHeight = height ?? m.card.height
        place(sink, card.surface, NeuralRect(x: 0, y: 0, width: m.width, height: cardHeight))
        place(sink, card.edgeLive, NeuralRect(x: 0, y: 0, width: 3, height: cardHeight))
        place(sink, card.picture, m.card.picture)
        let textRect = m.card.text
        if m.card.layout == .wide {
            let (buttonsWidth, buttonsHeight) = naturalSize(card.buttons)
            place(
                sink, card.text,
                NeuralRect(x: textRect.x, y: 0, width: textRect.width, height: cardHeight), dx: offset)
            place(
                sink, card.buttons,
                NeuralRect(
                    x: m.width - 12 - buttonsWidth, y: 8, width: buttonsWidth, height: buttonsHeight),
                dx: offset)
        } else {
            let (_, buttonsHeight) = naturalSize(card.buttons)
            let (buttonsWidth, _) = naturalSize(card.buttons)
            let (_, textHeight) = naturalSize(card.text, width: Int32(textRect.width))
            let total = textHeight + 6 + buttonsHeight
            let top = max(4, (cardHeight - total) / 2)
            place(
                sink, card.text,
                NeuralRect(x: textRect.x, y: top, width: textRect.width, height: textHeight), dx: offset)
            place(
                sink, card.buttons,
                NeuralRect(
                    x: textRect.x, y: top + textHeight + 6, width: buttonsWidth, height: buttonsHeight),
                dx: offset)
        }
    }

    func placeOpen(_ sink: OpaquePointer, _ m: NeuralStageMetrics) {
        guard let stage else {
            placeCard(sink, m, offset: 0)
            return
        }
        for layer in stage.visibleLayers { place(sink, layer, m.stage) }
        placeLeader(sink, m, stage: stage)
        place(sink, stage.hit, m.stageHover)
        placeBrowse(sink, m, readoutRect: nil)
        place(sink, footer?.widget, m.footer, dy: narrowExtra(m))
    }

    /// The leader's own canvas covers the head and the gutter, in the head's coordinates, so the
    /// route it draws starts at the node and ends on the readout's hairline.
    private func placeLeader(_ sink: OpaquePointer, _ m: NeuralStageMetrics, stage: BrainStage) {
        let leaderWidth = m.arrangement == .split ? m.readout.x + 6 - m.stage.x : m.stage.width
        let region = m.arrangement == .split ? m.readout.height : m.stage.height
        place(
            sink, stage.leader,
            NeuralRect(x: m.stage.x, y: m.stage.y, width: leaderWidth, height: region))
    }

    /// The filter chips, the list with its search field, the account beside them, and the detail of
    /// the open step in the account's second column. A narrow brain has no list: its account stands
    /// where the list would, and the search field opens in the account's header.
    private func placeBrowse(_ sink: OpaquePointer, _ m: NeuralStageMetrics, readoutRect: NeuralRect?) {
        if let rect = m.filterPanel ?? m.filterChips { place(sink, filters?.canvas, rect) }
        guard let list else { return }
        let narrow = m.arrangement == .accordion
        list.configure(metrics: m)
        filters?.configure(metrics: m)
        if !narrow {
            let canvasRect = NeuralRect(
                x: m.list.x, y: m.list.y, width: list.canvasWidth, height: list.canvasHeight)
            place(sink, list.canvas, canvasRect)
        }
        var base = narrow
            ? NeuralRect(x: 0, y: m.list.y, width: m.width, height: narrowAccountHeight(m)) : m.readout
        if let moved = readoutRect {
            base = narrow ? base.offsetBy(dx: moved.x, dy: moved.y) : moved
        }
        if list.searchOpen {
            if narrow {
                place(
                    sink, list.entry,
                    NeuralRect(x: base.x + 16, y: base.y + 6, width: min(240, base.width - 32), height: 28))
            } else {
                place(
                    sink, list.entry,
                    NeuralRect(x: m.list.x + 4, y: m.list.y + 4, width: min(240, m.list.width - 90), height: 28))
            }
        }
        if let account {
            place(sink, account.root, base)
            account.touchFrame(width: base.width, height: base.height)
        }
        guard let clip = readoutClip else { return }
        var inside: NeuralRect?
        if m.arrangement == .split, m.accountLayout == .split, let detail = account?.detailRect() {
            inside = detail
        } else if readoutHoldsBody, let body = account?.bodyRect() {
            inside = body
        }
        if let inside {
            let rect = inside.offsetBy(dx: base.x, dy: base.y)
            place(sink, clip, rect)
            readout?.fit(width: rect.width, height: rect.height, at: (0, 0), inline: true)
            readout?.setDetail(m.accountLayout == .split && !readoutHoldsBody)
        }
    }

    private func placeMoving(_ sink: OpaquePointer, _ m: NeuralStageMetrics) {
        guard let move = moveState else {
            placeOpen(sink, m)
            return
        }
        let f = move.frame
        placeCard(sink, m, offset: f.cardTextOffsetX)
        place(sink, moveCanvas, f.traveller)
        let picture = m.card.picture
        place(
            sink, edgeCanvas,
            NeuralRect(x: f.edge.x, y: picture.y, width: 3, height: picture.height))
        let target = move.openingGeometry
        if let stage { placeLeader(sink, m, stage: stage) }
        placeBrowse(
            sink, m,
            readoutRect: target.readout.offsetBy(dx: f.readoutOffset.x, dy: f.readoutOffset.y))
        place(sink, footer?.widget, target.footer)
    }

    private func widthChanged() {
        let m = currentMetrics
        card.configure(metrics: m)
        stage?.configure(
            width: Int(m.stage.width.rounded()), height: Int(m.stage.height.rounded()),
            scaleFactor: max(1, Int(gtk_widget_get_scale_factor(widget))))
        footer?.configure(width: m.width, running: model.turn.outcome == .running)
        footer?.rebuildChips(width: m.width)
        readout?.retheme()
        list?.configure(metrics: m)
        filters?.configure(metrics: m)
        account?.geometryChanged()
        refreshReadout(animate: false)
        refreshAccordion()
        if let move = moveState, abs(move.metricsWidth - m.width) > 0.5 { finishMove(snapTo: move.opening) }
    }

    func relayout() {
        tailscode_brain_row_remeasure(widget)
        tailscode_brain_row_invalidate(widget)
    }

    func setPhase(_ next: Phase) {
        phase = next
        gtk_widget_set_focusable(widget, next == .closed ? 1 : 0)
        gtk_widget_set_cursor_from_name(widget, next == .closed ? "pointer" : nil)
        gtk_widget_set_tooltip_text(widget, next == .closed ? card.card.spoken : nil)
        tailscode_set_accessible_expanded(widget, next == .closed ? 0 : 1)
        if next == .closed {
            gtk_widget_add_css_class(widget, "bn-closed")
        } else {
            gtk_widget_remove_css_class(widget, "bn-closed")
        }
        relayout()
    }

    // MARK: restating

    /// Brings the view to a new row value; the widget stays.
    func restate(_ next: BrainRow) {
        let old = row
        row = next
        refreshContextInto()
        if old.look != next.look || old.turn.modelID != next.turn.modelID {
            inks = BrainInks(palette: MatrixTheme.palette, face: model.face)
            stage?.retheme()
            card.retheme()
            readout?.retheme()
            list?.retheme()
            filters?.retheme()
            account?.retheme()
        }
        card.refresh()
        if old.open != next.open {
            host?.anchor?()
            if next.open { open(animated: true) } else { close(animated: true) }
        } else if old.showRows != next.showRows {
            footer?.sync(BrainClock.now)
        }
        stage?.modelChanged()
        footer?.rebuildChips(width: currentMetrics.width)
        footer?.configure(width: currentMetrics.width, running: model.turn.outcome == .running)
        refreshReadout(animate: false)
        redrawNow()
        updateClock()
    }

    private func refreshContextInto() {
        let brainContext = host?.context(for: turnID) ?? .none
        model.update(turn: row.turn, context: brainContext)
        syncBrowse()
    }

    /// The steps moved under the list: it redraws, follows a running turn, and the head dims what
    /// the filters hide.
    func syncBrowse() {
        let effects = model.drainBrowseEffects()
        list?.modelChanged()
        filters?.invalidate()
        account?.refresh()
        if model.stepList.isFiltered { refreshDimming() }
        if !effects.isEmpty { applyBrowse(effects, grabFocus: false) }
    }

    /// The conversation's account of the live turn changed.
    func refreshContext() {
        let brainContext = host?.context(for: turnID) ?? .none
        model.update(turn: row.turn, context: brainContext)
        syncBrowse()
        stage?.modelChanged()
        card.refresh()
        refreshReadout(animate: false)
        redrawNow()
        updateClock()
    }

    /// The palette or the face changed: the colours are made again and the head is drawn afresh.
    func rethemed() {
        metricsMemo = nil
        inks = BrainInks(palette: MatrixTheme.palette, face: model.face)
        stage?.retheme()
        card.retheme()
        readout?.retheme()
        list?.retheme()
        filters?.retheme()
        account?.retheme()
        refreshReadout(animate: false)
        redrawNow()
    }


    func handleKey(keyval: UInt32, state: UInt32) -> Bool {
        guard hasBrainFocus else { return false }
        return brainKey(keyval: keyval, state: state)
    }

    /// The governor's debounced verdict moved. The stage's widgets stay as they are: a head that
    /// may not be drawn keeps its last picture and stops asking for frames, and takes them again
    /// when it may, so a window at the edge of the threshold cannot make anything flap.
    func budgetChanged() {
        let allowed = BrainBudget.stageAllowed
        stage?.drawing = allowed
        if allowed {
            stage?.invalidate()
            needsDraw = true
        }
        if row.open, stage == nil, phase == .closed, allowed, !isSuspended, moveState == nil {
            showStage()
        }
        motionChanged()
    }

    func motionChanged() {
        stage?.invalidate()
        redrawNow()
        updateClock()
    }

    /// Whether the brain is in the part of the transcript the reader can see, which decides
    /// whether it owns a clock at all. Asked at most four times a second.
    var isVisible: Bool {
        guard gtk_widget_get_mapped(widget) != 0, !isSuspended else { return false }
        let now = BrainClock.now
        if let cached = visibleCache, now - cached.time < 0.25 { return cached.value }
        let value = host?.isOnScreen(self) ?? true
        visibleCache = (now, value)
        return value
    }

    /// The reader scrolled: the brain may have come into view or left it.
    func viewportMoved() {
        visibleCache = nil
        let nowVisible = isVisible
        if nowVisible, stage != nil { needsDraw = true }
        if nowVisible { card.ensureContent() }
        updateClock()
    }

    /// The answer's literal path-like words that a step carries, which the footer's chips and the
    /// harness read: worked out once for an answer and a revision of the turn, not once a hover.
    var answerChips: [String] {
        if let memo = tokenMemo, memo.answer == row.answer, memo.revision == model.revision {
            return memo.tokens
        }
        tokenComputations += 1
        let words = row.answer.isEmpty ? [] : model.answerTokens(in: row.answer).map(\.text)
        var seen = Set<String>()
        let unique = words.filter { seen.insert($0).inserted }
        tokenMemo = (row.answer, model.revision, unique)
        return unique
    }

    // MARK: opening and closing

    private var canMove: Bool {
        !isSuspended && BrainBudget.stageAllowed && NeuralAssetFiles.isAvailable
            && gtk_widget_get_mapped(widget) != 0 && gtk_widget_get_width(widget) > 8
            && (host?.isOnScreen(self) ?? true)
    }

    func open(animated: Bool) {
        if let move = moveState {
            if !move.opening { reverseMove() }
            return
        }
        guard phase == .closed else { return }
        guard stageMayOpen, NeuralAssetFiles.isAvailable else { return }
        let swapped = host?.consumeSwap(turnID) ?? false
        guard animated, canMove else {
            showStage()
            return
        }
        makeParts()
        pendingOpen = PendingOpen(started: BrainClock.now, swapped: swapped)
        stage?.ensureRenderer()
        startOpeningIfReady()
        if pendingOpen != nil {
            Gtk.after(Self.openFallbackMilliseconds) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, !self.disposed, let pending = self.pendingOpen else { return }
                    _ = pending
                    self.pendingOpen = nil
                    self.showStage()
                }
            }
        }
    }

    func close(animated: Bool) {
        if pendingOpen != nil {
            pendingOpen = nil
            dropParts()
            return
        }
        if let move = moveState {
            if move.opening { reverseMove() }
            return
        }
        guard phase == .open else { return }
        let swapped = host?.consumeSwap(turnID) ?? false
        guard animated, canMove, stage?.hasPicture == true else {
            hideStage()
            return
        }
        startClosing(swapped: swapped)
    }

    /// Builds the stage, readout and footer without showing them: what a move needs in hand.
    func makeParts() {
        guard stage == nil else { return }
        let listPart = BrainList(owner: self)
        self.list = listPart
        let filterPart = BrainFilters(owner: self)
        filters = filterPart
        for part in listPart.widgets { tailscode_brain_row_add(widget, part) }
        tailscode_brain_row_add(widget, filterPart.canvas)
        let made = BrainStage(owner: self)
        made.drawing = BrainBudget.stageAllowed
        stage = made
        for part in made.widgets { tailscode_brain_row_add(widget, part) }
        let readout = BrainReadout(owner: self)
        self.readout = readout
        let accountPart = BrainAccount(owner: self)
        account = accountPart
        tailscode_brain_row_add(widget, accountPart.root)
        let clip = gtk_fixed_new()!
        gtk_widget_set_overflow(clip, GTK_OVERFLOW_HIDDEN)
        gtk_fixed_put(ptr(clip), readout.widget, 0, 0)
        readoutClip = clip
        tailscode_brain_row_add(widget, clip)
        let footer = BrainFooter(owner: self)
        self.footer = footer
        tailscode_brain_row_add(widget, footer.widget)
        installMoveCanvas()
        let m = currentMetrics
        made.configure(
            width: Int(m.stage.width.rounded()), height: Int(m.stage.height.rounded()),
            scaleFactor: max(1, Int(gtk_widget_get_scale_factor(widget))))
        footer.configure(width: m.width, running: model.turn.outcome == .running)
        footer.rebuildChips(width: m.width)
        accountPart.proseProbe = BrainAccount.probe()
        accountPart.refresh(immediate: true)
        if isSuspended { made.suspend() }
    }

    private func dropParts() {
        guard let held = stage else { return }
        stage = nil
        held.releaseSurfaces()
        held.teardown()
        returnFocusFromBrain()
        dropPopovers()
        for part in held.widgets { tailscode_brain_row_remove(widget, part) }
        if let list { for part in list.widgets { tailscode_brain_row_remove(widget, part) } }
        if let filters { tailscode_brain_row_remove(widget, filters.canvas) }
        if let readoutClip { tailscode_brain_row_remove(widget, readoutClip) }
        if let account {
            account.teardown()
            tailscode_brain_row_remove(widget, account.root)
        }
        if let footer { tailscode_brain_row_remove(widget, footer.widget) }
        if let moveCanvas { tailscode_brain_row_remove(widget, moveCanvas) }
        if let edgeCanvas { tailscode_brain_row_remove(widget, edgeCanvas) }
        account = nil
        readout = nil
        list = nil
        filters = nil
        readoutClip = nil
        dimmedNodes = []
        hoverApplied = nil
        pendingHover = nil
        footer = nil
        moveCanvas = nil
        edgeCanvas = nil
        model.clearSelection()
        model.browse(.hoverLeft)
        model.setBrowseFocus(.list)
        model.setProvenance(token: nil)
        model.setDiving(false)
        model.setDive(zone: nil)
        leaderState = BrainLeaderState()
        if model.isReplaying { model.stopReplay() }
        announcement = nil
        updateClock()
        relayout()
    }

    /// The stage, readout and footer, in place with no move.
    func showStage() {
        guard stage == nil || phase != .open else { return }
        guard stageMayOpen, NeuralAssetFiles.isAvailable else {
            setPhase(.closed)
            return
        }
        makeParts()
        guard let made = stage else { return }
        pendingOpen = nil
        host?.anchor?()
        setPhase(.open)
        if isSuspended { made.suspend() } else { made.ensureRenderer() }
        footer?.rebuildChips(width: currentMetrics.width)
        footer?.configure(width: currentMetrics.width, running: model.turn.outcome == .running)
        if replayWhenOpen {
            replayWhenOpen = false
            model.startReplay(now: BrainClock.now)
        }
        made.render(BrainClock.now)
        refreshReadout(animate: false)
        footer?.sync(BrainClock.now)
        refitFooterSoon()
        applyPendingDive()
        relayout()
        updateClock()
    }

    /// The footer's chips are fitted again once the row has been laid out and styled, because
    /// their widths are not true before the first frame.
    func refitFooterSoon() {
        Gtk.after(160) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.disposed, let footer = self.footer,
                    self.isLive(footer.widget)
                else { return }
                let width = self.currentMetrics.width
                footer.rebuildChips(width: width)
                footer.configure(width: width, running: self.model.turn.outcome == .running)
            }
        }
    }

    func hideStage() {
        guard stage != nil || phase != .closed else { return }
        host?.anchor?()
        moveState = nil
        revealOverride = nil
        dropParts()
        setPhase(.closed)
        card.refresh()
        card.redraw()
    }

    func stageRendererReady() {
        stage?.render(BrainClock.now)
        redrawNow()
    }

    /// The compositor finished the first picture: a move that was waiting for it begins.
    func stagePictureReady() {
        startOpeningIfReady()
        footer?.sync(BrainClock.now)
        updateClock()
    }

    /// Builds the parts of the stage and draws the head once, for a frozen move a screenshot
    /// is taken of: the move cannot be drawn without the stage's own two pictures.
    func makeFrozenParts() {
        makeParts()
        stage?.ensureRenderer()
    }

    func cardPictureReady() {
        if let move = moveState, !move.opening { gtk_widget_queue_draw(moveCanvas ?? widget) }
    }

    // MARK: the card as a button

    private func cardPressed() {
        guard phase == .closed else { return }
        toggleOpen()
    }

    private func cardKey(keyval: UInt32, state: UInt32) -> Bool {
        guard phase == .closed, gtk_widget_has_focus(widget) != 0 else { return false }
        let modifiers = state & (GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue)
        guard modifiers == 0 else { return false }
        switch Int32(keyval) {
        case GDK_KEY_Return, GDK_KEY_KP_Enter, GDK_KEY_space:
            toggleOpen()
            return true
        default:
            return false
        }
    }

    private func pointerOverRow(_ over: Bool) {
        guard phase == .closed else {
            card.setHovered(false)
            return
        }
        card.setHovered(over)
        if over { prefetchStage() }
    }

    private func frameFocus(_ entered: Bool) {
        guard phase == .closed else { return }
        if entered { prefetchStage() }
        card.redraw()
    }

    /// The compositor the stage will want, started while the pointer is on the card, so the move
    /// begins on the press rather than after a build.
    private func prefetchStage() {
        guard prefetched == nil, canMove, NeuralAssetFiles.isAvailable else {
            prefetchTicket += 1
            scheduleRelease()
            return
        }
        let m = currentMetrics
        let scale = max(1, Int(gtk_widget_get_scale_factor(widget)))
        let width = Int(
            (m.stage.width * NeuralDesign.width / NeuralStageMetrics.designWidth).rounded())
        let cap = max(1, NeuralAssetName.fullWidth / max(1, width))
        let used = min(scale, cap)
        let table = NeuralToneTable(palette: MatrixTheme.palette, face: model.face)
        BrainCompositors.acquire(
            width: width * used, height: Int(m.stage.height.rounded()) * used, table: table
        ) { [weak self] built in
            guard let self else {
                if let built { BrainCompositors.release(built) }
                return
            }
            guard let built else { return }
            if self.prefetched != nil || self.phase != .closed {
                BrainCompositors.release(built)
                return
            }
            self.prefetched = built
            self.scheduleRelease()
        }
    }

    private func scheduleRelease() {
        prefetchTicket += 1
        let ticket = prefetchTicket
        Gtk.after(5000) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.prefetchTicket == ticket, let held = self.prefetched else { return }
                BrainCompositors.release(held)
                self.prefetched = nil
            }
        }
    }

    // MARK: pointer and keyboard on the stage

    /// The pointer is over a node of the head, or over none for nil: the readout previews it and
    /// the list marks its row, and the cursor stays where it is.
    func stagePointer(over id: String?) {
        routeHover(id, delay: 0)
    }

    func stageFocus(_ entered: Bool) {
        stageFocused = entered
        if entered, model.browseFocus != .list { model.setBrowseFocus(.list) }
        afterSelection()
    }

    func readoutPointer(inside: Bool) {
        model.readoutPointer(inside: inside, at: BrainClock.now)
        readoutHeld = inside
        refreshReadout(animate: true)
    }

    /// A relation chip under the pointer lights the steps it names, without taking the panel.
    func relationHover(_ ids: [String]?) {
        if let ids, let first = ids.first {
            model.setHover(first)
        } else {
            model.setHover(nil)
        }
        stage?.invalidate()
        redrawNow()
    }

    func stripHover(_ id: String?) {
        routeHover(id, delay: NeuralHoverGrace.intentDelay)
    }

    func stripScrub(toStep id: String) {
        guard let index = model.steps.firstIndex(where: { $0.id == id }) else { return }
        let fires = model.timeline.fireTimes
        guard index < fires.count else { return }
        scrub(to: model.timeline.fraction(forTime: fires[index]))
    }

    func stripScrubEnded() {
        endScrub()
    }

    func hover(_ id: String?) {
        stagePointer(over: id)
    }

    /// Puts the cursor on a step: what a click on its row or its node does.
    func pin(_ id: String) {
        browse(.click(id, double: false))
    }

    func clearSelection() {
        hoverApplied = nil
        pendingHover = nil
        model.pointer(over: nil, at: BrainClock.now - 10)
        browse(.hoverLeft, grabFocus: false)
        model.clearSelection()
        model.setProvenance(token: nil)
        announcement = nil
        afterSelection()
    }

    func point(at token: String?) {
        model.setProvenance(token: token)
        afterSelection()
    }

    /// The Esc ladder, for the harness: the legend, the search, the filters, the cursor, then the
    /// brain itself.
    func escapePressed() -> Bool {
        _ = brainKey(keyval: UInt32(GDK_KEY_Escape), state: 0)
        return true
    }

    func afterSelection() {
        stage?.modelChanged()
        refreshReadout(animate: true)
        redrawNow()
        updateClock()
    }

    /// Whether a double press on this node opens a sub-agent rather than only taking the cursor.
    func opensSubagent(_ id: String) -> Bool {
        guard let step = model.step(id: id) else { return false }
        return step.isCard && step.zone == .delegate
    }

    /// The node that rings a step and the number its callout shows beside it.
    func ringed(_ id: String?) -> BrainScene.Ring? {
        guard let id, let row = model.browseState.list.row(id: id) else { return nil }
        return BrainScene.Ring(node: model.browseState.list.nodeID(of: id), number: row.number)
    }

    func openSubagent(of id: String) {
        guard let step = model.step(id: id), step.isCard, step.zone == .delegate else {
            pin(id)
            return
        }
        context?.openSubagent?(step.id)
    }

    func goToApproval() {
        host?.revealApproval?()
    }

    func diveChanged() {
        refreshReadout(animate: true)
        relayout()
    }

    func dive(into zone: NeuralZone) {
        stage?.dive(into: zone)
    }

    /// Opens the brain already diving into a zone, from the card's chip.
    func openDiving(into zone: NeuralZone) {
        host?.pendingDive[turnID] = zone
        toggleOpen()
    }

    func applyPendingDive() {
        guard let zone = host?.pendingDive.removeValue(forKey: turnID) else { return }
        stage?.dive(into: zone)
    }

    /// Opens the poster sheet for this turn as it stands at rest.
    func presentShare() {
        guard model.turn.outcome != .running, let root = gtk_widget_get_root(widget) else { return }
        BrainShareDialog.present(
            model: model, prompt: row.prompt, parent: ptr(UnsafeMutableRawPointer(root)))
    }

    func toggleRows() {
        host?.toggleRows(turnID: turnID)
    }

    func focusStage() {
        if let stage { gtk_widget_grab_focus(stage.hit) }
    }

    func walkStep(_ direction: Int) {
        browse(.key(direction < 0 ? .up : .down))
    }

    func dive(_ zone: NeuralZone?) {
        stage?.dive(into: zone)
    }

    func driveChip(_ index: Int?) {
        guard let index else {
            point(at: nil)
            return
        }
        let unique = answerChips
        guard index >= 1, index <= unique.count else { return }
        point(at: unique[index - 1])
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
        card.refresh()
        stage?.invalidate()
        refreshReadout(animate: false)
        footer?.sync(BrainClock.now)
        relayout()
        redrawNow()
        updateClock()
    }

    func toggleOpen() {
        host?.toggleOpen(turnID: turnID)
    }

    var accessibleLabel: String { announcement ?? model.spoken }

    // MARK: the clock

    /// Marks the picture stale and lets the clock draw it on its next frame, which is at most
    /// thirty a second whatever number of states arrive between.
    func redrawNow() {
        card.redraw()
        guard stage != nil else { return }
        needsDraw = true
        updateClock()
    }

    private func step(_ time: Double) {
        card.tickLive(time)
        if moveState != nil {
            moveStep(time)
            return
        }
        if model.replayDone(now: time) {
            model.stopReplay()
            card.refresh()
            stage?.invalidate()
            relayout()
        }
        needsDraw = false
        var mark = DispatchTime.now().uptimeNanoseconds
        func lap(_ name: String) {
            let now = DispatchTime.now().uptimeNanoseconds
            tickCosts[name, default: 0] += now - mark
            mark = now
        }
        if let stage { stage.step(time) }
        lap("stage")
        if model.isReplaying || time - lastFooterSync > 0.5 {
            lastFooterSync = time
            footer?.sync(time)
        }
        lap("footer")
        readout?.tickPulses()
        account?.tickPulses()
        lap("pulses")
        list?.tick(time)
        account?.tick(time)
        account?.tickSecond(time)
        lap("list")
        tickLeader(time)
        lap("leader")
        if model.isReplaying || (model.turn.outcome == .running && time - lastReadoutTick > 0.25) {
            lastReadoutTick = time
            refreshReadout(animate: false)
        }
        lap("readout")
        tickCount += 1
        if contentFade != nil {
            let alpha = NeuralTransition.firstContentAlpha(after: time - contentFadeStart)
            readout?.setBodyAlpha(alpha)
            if alpha >= 1 { contentFade = nil }
        }
        updateClock()
    }

    func updateClock() {
        guard !isSuspended else {
            clock.stop()
            return
        }
        if frozen {
            clock.stop()
            return
        }
        var tempo: NeuralTempo = .stopped
        if stage != nil, BrainBudget.stageAllowed {
            tempo = model.tempo(reduceMotion: BrainBudget.reduceMotion)
            if tempo == .activity, model.turn.outcome != .running, !model.isReplaying {
                tempo = .stopped
            }
            if needsDraw, tempo == .stopped { tempo = .activity }
        }
        let busy = leaderAnimating || contentFade != nil || (list?.isAnimating ?? false) || (account?.isAnimating ?? false)
        let moving = moveState != nil || (busy && isVisible)
        let now = BrainClock.now
        if tempo == .stopped, isVisible, card.needsLiveClock(at: now) {
            tempo = card.isSettling(at: now) ? .display : .activity
        }
        if moving { tempo = .display }
        if tempo != .stopped, !moving, !isVisible { tempo = .stopped }
        clock.run(on: widget, tempo: tempo)
    }

    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        clock.stop()
        stage?.suspend()
        readoutTicket += 1
        if let move = moveState { finishMove(snapTo: move.opening) }
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        stage?.resume()
        card.refresh()
        redrawNow()
        updateClock()
    }

    // MARK: harness readings

    /// How many widgets this brain's row holds right now.
    var widgetCount: Int {
        func count(_ node: UnsafeMutablePointer<GtkWidget>) -> Int {
            var total = 1
            var child = gtk_widget_get_first_child(node)
            while let held = child {
                total += count(held)
                child = gtk_widget_get_next_sibling(held)
            }
            return total
        }
        return count(widget)
    }

    var performance: String {
        guard let stage else { return "no stage" }
        let timings = stage.timings
        return String(
            format: "full=%.0fus x%d delta=%.0fus x%d size=%dx%d surfaces=%dKB renderer=%d",
            timings.full, timings.fulls, timings.delta, timings.deltas, stage.size.width,
            stage.size.height, stage.footprint / 1024, stage.hasRenderer ? 1 : 0)
    }

    /// What each part of a clock tick has cost on average, for the harness.
    var tickReading: String {
        guard tickCount > 0 else { return "no ticks" }
        return tickCosts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value / UInt64(tickCount) / 1000)us" }.joined(separator: " ") + " ticks=\(tickCount)"
    }

    var reading: String {
        let timings = stage?.timings
        return "turn=\(turnID) open=\(row.open) phase=\(phase) stage=\(stage != nil) renderer=\(stage?.hasRenderer == true) visible=\(isVisible) mapped=\(gtk_widget_get_mapped(widget)) "
            + "clock=\(clock.isRunning)/\(clock.tempo) steps=\(model.steps.count) nodes=\(model.nodeCount) "
            + "selected=\(model.selected ?? "-") pinned=\(model.pinned ?? "-") "
            + "focus=\(stage.map { gtk_widget_has_focus($0.hit) != 0 } ?? false) "
            + "state=\(model.state.label) running=\(model.steps.filter { $0.status == .running }.count) "
            + "outcome=\(model.turn.outcome) replay=\(model.isReplaying) frames=\(stage?.frames ?? 0) fulls=\(timings?.fulls ?? 0) "
            + "deltas=\(timings?.deltas ?? 0) height=\(gtk_widget_get_height(widget)) \(card.reading) "
            + "readout=[\(readout?.reading ?? "-")] leader=\(leaderState.reading) account=[\(account?.reading ?? "-")]"
    }
}
