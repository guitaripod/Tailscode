import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The step list beside the head: one canvas that draws the rows the window can see and nothing
/// else, so a turn of two thousand steps costs what nine rows cost. It owns the scroll (the wheel
/// adds to a target the list eases toward, and a key's `scrollTo` is the same ease, never a jump),
/// the pointer's row, the copy button of the hovered row, the Following pill, the empty-filter
/// state and the search field, which is a real entry laid over the header while it is open.
///
/// What a row says comes from Core's `NeuralStepList`, what a key or a click does comes from
/// `NeuralBrowse` through `BrainView.browse`, and this draws and measures.
final class BrainList: @unchecked Sendable {
    let ref: WeakBrainView
    let canvas: UnsafeMutablePointer<GtkWidget>
    let entry: UnsafeMutablePointer<GtkWidget>

    private(set) var layout: NeuralStageMetrics
    private var fonts = BrainListFonts()
    private(set) var scroll = 0.0
    private(set) var target = 0.0
    private(set) var extra = 0.0
    private(set) var extraTarget = 0.0
    private var lastTick = 0.0
    private var lastHoverEval = 0.0
    private var pointer: (x: Double, y: Double)?
    private(set) var hoverRow: String?
    private var hoverCopy = false
    private var hoverKind: Hit = .none
    private var copied: (id: String, until: Double)?
    var copiedID: String? { copied?.id }
    private var arrival: (from: Int, start: Double)?
    private var lastTotal = 0
    private var syncingEntry = false
    private(set) var reveal: NeuralRowReveal?
    private(set) var headerAlpha = 1.0
    private(set) var expandedID: String?

    private(set) var rowsDrawn = 0
    private(set) var paints = 0
    private(set) var paintNanoseconds: UInt64 = 0
    private(set) var worstPaintNanoseconds: UInt64 = 0

    static let headerHeight = NeuralStageMetrics.listHeaderHeight
    static let scrollEase = 0.075
    static let extraEase = 0.06
    static let wheelStep = 56.0
    static let arrivalDuration = 0.12

    enum Hit: Equatable {
        case none
        case search
        case row(String)
        case copy(String)
        case pill
        case clearFilters
        case hintKeys
    }

    init(owner: BrainView) {
        ref = WeakBrainView(owner)
        layout = owner.currentMetrics
        let holder = DrawHolder()
        _ = Gtk.releaseInstalled
        canvas = tailscode_list_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                Unmanaged<DrawHolder>.fromOpaque(raw).takeUnretainedValue().list?.paint(
                    cr, width: Double(width), height: Double(height))
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<DrawHolder>.fromOpaque(raw).release()
            })!
        entry = gtk_entry_new()!
        holder.list = self
        build()
    }

    private final class DrawHolder: @unchecked Sendable {
        weak var list: BrainList?
    }

    var widgets: [UnsafeMutablePointer<GtkWidget>] { [canvas, entry] }

    private func build() {
        gtk_widget_set_focusable(canvas, 1)
        gtk_widget_set_can_focus(canvas, 1)
        gtk_widget_set_hexpand(canvas, 1)
        Gtk.addClass(canvas, "brain-list")
        tailscode_set_accessible_label(canvas, BrainWords.stepList)
        Gtk.addClass(entry, "bn-search")
        gtk_entry_set_placeholder_text(ptr(entry), BrainWords.search)
        gtk_entry_set_max_length(ptr(entry), 120)
        tailscode_set_accessible_label(entry, BrainWords.search)
        Gtk.onPointer(
            canvas,
            move: { [weak self] x, y in self?.pointerMoved(x: x, y: y) },
            leave: { [weak self] in self?.pointerLeft() })
        let box = Unmanaged.passRetained(ClickBox { [weak self] x, y, presses, button in
            self?.clicked(x: x, y: y, presses: Int(presses), button: Int(button))
        }).toOpaque()
        tailscode_on_click_at(
            canvas,
            { x, y, presses, button, raw in
                guard let raw else { return }
                Unmanaged<ClickBox>.fromOpaque(raw).takeUnretainedValue().handler(x, y, presses, button)
            }, box)
        Gtk.onScroll(canvas) { [weak self] dy in self?.wheel(dy) ?? false }
        let ref = self.ref
        Gtk.onKey(canvas) { keyval, state in ref.view?.brainKey(keyval: keyval, state: state) ?? false }
        let focus = Unmanaged.passRetained(FocusBox { [ref] entered in
            ref.view?.listFocusChanged(entered)
        }).toOpaque()
        tailscode_on_focus_change(
            canvas,
            { raw in
                guard let raw else { return }
                Unmanaged<FocusBox>.fromOpaque(raw).takeUnretainedValue().handler(true)
            },
            { raw in
                guard let raw else { return }
                Unmanaged<FocusBox>.fromOpaque(raw).takeUnretainedValue().handler(false)
            }, focus)
        let entryHold = Gtk.WeakWidget(entry)
        Gtk.connect(UnsafeMutableRawPointer(entry), "changed") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.syncingEntry, let held = entryHold.widget else { return }
                let text = String(cString: gtk_editable_get_text(op(held)))
                self.ref.view?.browse(.searchText(text), grabFocus: false)
            }
        }
        Gtk.onKey(entry) { keyval, state in
            ref.view?.searchKey(keyval: keyval, state: state) ?? false
        }
        let searchFocus = Unmanaged.passRetained(FocusBox { [ref] entered in
            ref.view?.searchFocusChanged(entered)
        }).toOpaque()
        tailscode_on_focus_change(
            entry,
            { raw in
                guard let raw else { return }
                Unmanaged<FocusBox>.fromOpaque(raw).takeUnretainedValue().handler(true)
            },
            { raw in
                guard let raw else { return }
                Unmanaged<FocusBox>.fromOpaque(raw).takeUnretainedValue().handler(false)
            }, searchFocus)
    }

    private final class ClickBox: @unchecked Sendable {
        let handler: (Double, Double, Int32, Int32) -> Void
        init(_ handler: @escaping (Double, Double, Int32, Int32) -> Void) { self.handler = handler }
    }

    private final class FocusBox: @unchecked Sendable {
        let handler: (Bool) -> Void
        init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
    }

    // MARK: geometry

    var model: NeuralBrainModel? { ref.view?.model }
    var rowHeight: Double { layout.listRowHeight }
    var isAccordion: Bool { layout.arrangement == .accordion }
    var scrollbarRoom: Double { isAccordion ? 0 : NeuralStageMetrics.listScrollbarRoom }

    /// The rows' own viewport: the metrics' rows, and the expanded row's content when an
    /// accordion has one open.
    var viewportHeight: Double { layout.listRows.height + extra }

    /// The canvas's height: the header, the viewport, the foot padding and the hint.
    var canvasHeight: Double {
        let hint = layout.listHint == nil ? 0 : NeuralStageMetrics.listHintHeight
        return Self.headerHeight + viewportHeight + NeuralStageMetrics.listFootPadding + hint
    }

    var canvasWidth: Double { layout.list.width + scrollbarRoom }

    private var total: Int { model?.browseState.list.visibleCount ?? 0 }

    private var input: ChatInput { layout.input }

    private var contentHeight: Double {
        (model?.browseState.list.contentHeight(input: input) ?? 0) + extra
    }
    private var maxScroll: Double { max(0, contentHeight - viewportHeight) }

    /// The position the expanded row holds in the visible list, if any.
    private var expandedPosition: Int? {
        guard isAccordion, let id = expandedID else { return nil }
        return model?.browseState.list.visibleIndex(of: id)
    }

    /// Where a position's row starts in content coordinates.
    private func top(ofPosition position: Int) -> Double {
        var y = model?.browseState.list.offset(ofVisible: position, input: input) ?? 0
        if let expanded = expandedPosition, position > expanded { y += extra }
        return y
    }

    /// How tall the row at a position is: a said message is two lines, every other row one.
    private func height(ofPosition position: Int) -> Double {
        model?.browseState.list.row(atVisible: position)?.height(input: input) ?? rowHeight
    }

    /// The content-space range of the expanded row's content, for the accordion.
    private var expandedContent: (top: Double, height: Double)? {
        guard let position = expandedPosition, extra > 0.5 else { return nil }
        return (top(ofPosition: position) + height(ofPosition: position), extra)
    }

    /// Where the expanded row's content stands in the row's own coordinates, clipped to the rows
    /// viewport, for the view to place the readout.
    func accordionRect() -> NeuralRect? {
        guard let content = expandedContent else { return nil }
        let y = layout.list.y + Self.headerHeight + content.top - scroll
        return NeuralRect(x: layout.list.x, y: y, width: layout.list.width, height: content.height)
    }

    /// The rows viewport in the row's own coordinates.
    var viewportRect: NeuralRect {
        NeuralRect(
            x: layout.list.x, y: layout.list.y + Self.headerHeight, width: layout.list.width,
            height: viewportHeight)
    }

    func configure(metrics: NeuralStageMetrics) {
        let changed = metrics != layout
        layout = metrics
        if changed {
            clampScroll()
            gtk_widget_queue_draw(canvas)
        }
    }

    private func clampScroll() {
        target = min(max(target, 0), maxScroll)
        scroll = min(max(scroll, 0), maxScroll)
    }

    func retheme() {
        fonts = BrainListFonts()
        gtk_widget_queue_draw(canvas)
    }

    func invalidate() { gtk_widget_queue_draw(canvas) }

    // MARK: state from the model

    /// The steps or the filters changed under the list.
    func modelChanged() {
        guard let model else { return }
        let list = model.browseState.list
        if list.total > lastTotal, lastTotal > 0, list.isLive {
            arrival = (lastTotal, BrainClock.now)
        }
        lastTotal = list.total
        clampScroll()
        syncEntry()
        refreshLabel()
        gtk_widget_queue_draw(canvas)
    }

    /// The accessible name: the row the cursor is on, said the way a step is announced.
    private func refreshLabel() {
        guard let model else { return }
        let list = model.browseState.list
        if let row = list.cursorRow {
            tailscode_set_accessible_label(
                canvas,
                BrainWords.stepList + ": "
                    + BrainWords.stepRowLabel(
                        number: row.number, total: list.total, title: row.title, argument: row.argument,
                        status: NeuralReading.statusWord(row.status)))
        } else {
            tailscode_set_accessible_label(canvas, BrainWords.stepList + ": " + list.countLabel)
        }
    }

    /// Keeps the search entry's text what the filter holds.
    private func syncEntry() {
        guard let model else { return }
        let query = model.browseState.list.filter.search
        let current = String(cString: gtk_editable_get_text(op(entry)))
        guard current != query else { return }
        syncingEntry = true
        gtk_editable_set_text(op(entry), query)
        syncingEntry = false
    }

    var searchOpen: Bool { model?.browseState.searchOpen ?? false }

    /// The cursor's row opens in an accordion; any other layout, or no cursor, has none.
    func setExpanded(_ id: String?, contentHeight: Double) {
        expandedID = isAccordion ? id : nil
        let wanted = expandedID == nil ? 0 : contentHeight
        if wanted != extraTarget { ref.view?.host?.anchor?() }
        extraTarget = wanted
        if BrainBudget.reduceMotion { extra = extraTarget }
        clampScroll()
    }

    func setReveal(_ rows: NeuralRowReveal?, headerAlpha: Double) {
        reveal = rows
        self.headerAlpha = headerAlpha
        gtk_widget_queue_draw(canvas)
    }

    // MARK: scrolling

    private func wheel(_ dy: Double) -> Bool {
        guard maxScroll > 0 else { return false }
        let next = min(max(target + dy * Self.wheelStep, 0), maxScroll)
        guard next != target else { return true }
        target = next
        if BrainBudget.reduceMotion { scroll = target }
        ref.view?.browse(.scrolled(manual: true), grabFocus: false)
        ref.view?.listAnimationChanged()
        gtk_widget_queue_draw(canvas)
        return true
    }

    /// Scrolls by `pixels` the way the wheel does, for the harness.
    func driveScroll(_ pixels: Double) {
        target = min(max(target + pixels, 0), maxScroll)
        if BrainBudget.reduceMotion { scroll = target }
        ref.view?.browse(.scrolled(manual: true), grabFocus: false)
        ref.view?.listAnimationChanged()
        gtk_widget_queue_draw(canvas)
    }

    /// Scrolls so the row is in view: the least that shows it, or the middle when it is far.
    func scrollTo(_ id: String, jump: Bool = false) {
        guard let model, let position = model.browseState.list.visibleIndex(of: id) else { return }
        let rowTop = top(ofPosition: position)
        let rowTall = height(ofPosition: position)
        var rowBottom = rowTop + rowTall
        if position == expandedPosition { rowBottom += extraTarget }
        var wanted = target
        let view = viewportHeight
        if rowTop < scroll - view || rowBottom > scroll + 2 * view {
            wanted = ((rowTop - (view - rowTall) / 2) / rowHeight).rounded() * rowHeight
        } else if rowTop < target {
            wanted = rowTop
        } else if rowBottom > target + view {
            wanted = rowBottom - view
        }
        target = min(max(wanted, 0), maxScroll)
        if jump || BrainBudget.reduceMotion { scroll = target }
        ref.view?.listAnimationChanged()
        gtk_widget_queue_draw(canvas)
    }

    /// The list's own animations that need frames: the scroll, the accordion's opening, rows
    /// arriving and the Copied word. Called from the brain's clock.
    var isAnimating: Bool {
        abs(scroll - target) > 0.4 || abs(extra - extraTarget) > 0.4
            || (arrival.map { BrainClock.now - $0.start < Self.arrivalDuration } ?? false)
            || (copied.map { BrainClock.now < $0.until } ?? false)
    }

    func tick(_ time: Double) {
        let dt = lastTick == 0 ? 1.0 / 60 : min(0.1, time - lastTick)
        lastTick = time
        var changed = false
        if abs(scroll - target) > 0.4 {
            scroll += (target - scroll) * (1 - exp(-dt / Self.scrollEase))
            if abs(scroll - target) <= 0.4 { scroll = target }
            changed = true
        } else if scroll != target {
            scroll = target
            changed = true
        }
        if abs(extra - extraTarget) > 0.4 {
            ref.view?.host?.anchor?()
            extra += (extraTarget - extra) * (1 - exp(-dt / Self.extraEase))
            if abs(extra - extraTarget) <= 0.4 { extra = extraTarget }
            clampScroll()
            changed = true
            ref.view?.relayout()
        } else if extra != extraTarget {
            extra = extraTarget
            changed = true
            ref.view?.relayout()
        }
        if let arrival, time - arrival.start >= Self.arrivalDuration {
            self.arrival = nil
            changed = true
        }
        if let held = copied, time >= held.until {
            copied = nil
            changed = true
        }
        if changed {
            if time - lastHoverEval > 0.12, pointer != nil {
                lastHoverEval = time
                reevaluateHover()
            }
            gtk_widget_queue_draw(canvas)
        }
        if lastTick != 0, !isAnimating { lastTick = 0 }
    }

    // MARK: copy

    func flashCopied(_ id: String) {
        copied = (id, BrainClock.now + 1.0)
        ref.view?.listAnimationChanged()
        gtk_widget_queue_draw(canvas)
    }

    // MARK: pointer

    private func hit(x: Double, y: Double) -> Hit {
        guard let model else { return .none }
        let list = model.browseState.list
        let width = layout.list.width
        if y < Self.headerHeight {
            if x < 130, !searchOpen { return .search }
            return .none
        }
        let hintTop = Self.headerHeight + viewportHeight + NeuralStageMetrics.listFootPadding
        if layout.listHint != nil, y >= hintTop {
            return x >= hintKeysX && x <= hintKeysX + 70 ? .hintKeys : .none
        }
        guard y < Self.headerHeight + viewportHeight else { return .none }
        if list.showsFollowPill, pillRect.contains(NeuralPoint(x, y)) { return .pill }
        if list.visibleCount == 0, list.total > 0 {
            return clearRect.contains(NeuralPoint(x, y)) ? .clearFilters : .none
        }
        let contentY = y - Self.headerHeight + scroll
        guard let position = position(atContentY: contentY), let row = list.row(atVisible: position)
        else { return .none }
        let local = NeuralPoint(x, y - (top(ofPosition: position) - scroll + Self.headerHeight))
        if copyRect(for: row, width: width).contains(local) { return .copy(row.id) }
        return .row(row.id)
    }

    /// The visible position whose row holds a content-space y; nil inside the expanded content.
    private func position(atContentY y: Double) -> Int? {
        guard y >= 0, let list = model?.browseState.list, list.visibleCount > 0 else { return nil }
        if y >= list.contentHeight(input: input) + extra { return nil }
        if let expanded = expandedPosition {
            let start = list.offset(ofVisible: expanded + 1, input: input)
            if y >= start, y < start + extra { return nil }
            if y >= start + extra { return list.position(atOffset: y - extra, input: input) }
        }
        return list.position(atOffset: y, input: input)
    }

    private var hintKeysX: Double { 0 }
    private var pillRect: NeuralRect {
        let width = BrainDraw.measure(BrainWords.followingPaused, fonts.pill) + 20 + 40
        let x = (layout.list.width - width) / 2
        let y = Self.headerHeight + viewportHeight - 8 - 26
        return NeuralRect(x: x, y: y, width: width, height: 26)
    }

    private var clearRect: NeuralRect {
        let width = BrainDraw.measure(BrainWords.clearFilters, fonts.status) + 24
        let x = (layout.list.width - width) / 2
        let y = Self.headerHeight + viewportHeight / 2 + 4
        return NeuralRect(x: x, y: y, width: width, height: 26)
    }

    private func copyRect(for row: NeuralStepList.Row, width: Double) -> NeuralRect {
        let label = copied?.id == row.id ? BrainWords.copied : BrainWords.copy
        let size = BrainDraw.measure(label, fonts.status) + 18
        return NeuralRect(x: width - 6 - size, y: (row.height(input: input) - 24) / 2, width: size, height: 24)
    }

    private func pointerMoved(x: Double, y: Double) {
        pointer = (x, y)
        evaluate(x: x, y: y)
    }

    private func reevaluateHover() {
        guard let pointer else { return }
        evaluate(x: pointer.x, y: pointer.y)
    }

    private func evaluate(x: Double, y: Double) {
        let found = hit(x: x, y: y)
        let previous = hoverRow
        var rowID: String?
        switch found {
        case .row(let id), .copy(let id): rowID = id
        default: break
        }
        let pointing: Bool
        switch found {
        case .none: pointing = false
        default: pointing = true
        }
        let copyNow: Bool
        if case .copy = found { copyNow = true } else { copyNow = false }
        if found != hoverKind || copyNow != hoverCopy {
            hoverKind = found
            hoverCopy = copyNow
            gtk_widget_set_cursor_from_name(canvas, pointing ? "pointer" : nil)
            gtk_widget_queue_draw(canvas)
        }
        if rowID != previous {
            hoverRow = rowID
            if let rowID {
                ref.view?.hoverStep(rowID)
            } else {
                ref.view?.hoverLeftStep()
            }
        }
    }

    private func pointerLeft() {
        pointer = nil
        hoverKind = .none
        hoverCopy = false
        gtk_widget_set_cursor_from_name(canvas, nil)
        if hoverRow != nil {
            hoverRow = nil
            ref.view?.hoverLeftStep()
        }
        gtk_widget_queue_draw(canvas)
    }

    private func clicked(x: Double, y: Double, presses: Int, button: Int) {
        gtk_widget_grab_focus(canvas)
        pointer = (x, y)
        hoverKind = .none
        let found = hit(x: x, y: y)
        guard let view = ref.view else { return }
        view.dismissLegendOnPress()
        if button == 3 {
            if case .row(let id) = found {
                view.browse(.contextMenu(id), grabFocus: false, menuAt: (x, y))
            } else if case .copy(let id) = found {
                view.browse(.contextMenu(id), grabFocus: false, menuAt: (x, y))
            }
            return
        }
        guard button == 1 else { return }
        switch found {
        case .search: view.openSearch()
        case .row(let id): view.browse(.click(id, double: presses >= 2))
        case .copy(let id): view.copyStep(id)
        case .pill: view.browse(.jumpToLatest)
        case .clearFilters: view.clearAllFilters()
        case .hintKeys: view.toggleLegend()
        case .none: break
        }
    }

    // MARK: painting

    private func paint(_ cr: OpaquePointer, width: Double, height: Double) {
        guard let view = ref.view, !view.disposed else { return }
        let begun = DispatchTime.now().uptimeNanoseconds
        let model = view.model
        let list = model.browseState.list
        let inks = view.inks
        let listWidth = layout.list.width
        paintHeader(cr, list: list, inks: inks, width: listWidth)
        let viewTop = Self.headerHeight
        let viewHeight = viewportHeight
        cairo_save(cr)
        cairo_rectangle(cr, 0, viewTop, listWidth + scrollbarRoom, viewHeight)
        cairo_clip(cr)
        var drawn = 0
        if list.visibleCount == 0 {
            if list.total > 0 { paintEmpty(cr, list: list, inks: inks, width: listWidth) }
        } else {
            let cursor = model.pinnedStep
            let hovered = model.browseState.hovered
            let query = list.filter.query
            let firstContent = max(0, scroll - 1)
            var position = position(atContentY: firstContent) ?? (expandedPosition.map { $0 + 1 } ?? 0)
            position = max(0, min(position, list.visibleCount - 1))
            let first = max(0, position - 1)
            var previous = first > 0 ? list.row(atVisible: first - 1) : nil
            position = first
            let revealRows = reveal
            while position < list.visibleCount {
                let rowTop = top(ofPosition: position) - scroll
                if rowTop > viewHeight { break }
                guard let row = list.row(atVisible: position) else { break }
                let rowH = row.height(input: input)
                if rowTop + rowH >= 0 {
                    let next = list.row(atVisible: position + 1)
                    var slide = 0.0
                    var alpha = 1.0
                    if let revealRows {
                        let index = min(position, max(0, revealRows.count - 1))
                        alpha = position < revealRows.count ? revealRows.alpha(index) : revealRows.alpha(revealRows.count - 1)
                        slide = position < revealRows.count ? revealRows.offset(index) : 0
                    }
                    if let arrival, row.index >= arrival.from {
                        let t = min(1, (BrainClock.now - arrival.start) / Self.arrivalDuration)
                        slide = NeuralRowReveal.travel * (1 - NeuralTransition.easeOutCubic(t))
                        alpha = t
                    }
                    paintRow(
                        cr, row: row, previous: previous, next: next, y: viewTop + rowTop + slide,
                        height: rowH, width: listWidth, inks: inks, isCursor: cursor == row.id,
                        isHovered: hovered == row.id, pointerHere: hoverRow == row.id, alpha: alpha,
                        query: query)
                    drawn += 1
                }
                previous = row
                position += 1
                if top(ofPosition: position) - scroll > viewHeight + 48 { break }
            }
        }
        if list.showsFollowPill { paintPill(cr, inks: inks) }
        paintScrollbar(cr, inks: inks, width: listWidth)
        cairo_restore(cr)
        if let content = expandedContent { paintExpandedEdge(cr, content: content, inks: inks, model: model) }
        if gtk_widget_has_visible_focus(canvas) != 0 { paintFocusRing(cr, inks: inks, width: listWidth) }
        if layout.listHint != nil { paintHint(cr, inks: inks, y: viewTop + viewHeight + NeuralStageMetrics.listFootPadding) }
        rowsDrawn = drawn
        let spent = DispatchTime.now().uptimeNanoseconds - begun
        paintNanoseconds += spent
        worstPaintNanoseconds = max(worstPaintNanoseconds, spent)
        paints += 1
    }

    private func paintHeader(_ cr: OpaquePointer, list: NeuralStepList, inks: BrainInks, width: Double) {
        let alpha = headerAlpha
        guard alpha > 0.002 else { return }
        let mid = Self.headerHeight / 2
        if !searchOpen {
            let hot = hoverKind == .search
            BrainDraw.magnifier(cr, x: 8, midY: mid, color: hot ? inks.ink : inks.dim, alpha: alpha)
            let wordX = 28.0
            BrainDraw.line(
                cr, BrainWords.search, font: fonts.status, lineHeight: fonts.lineHeight, x: wordX, top: 0,
                height: Self.headerHeight, color: hot ? inks.ink : inks.dim, alpha: alpha)
            let wordWidth = BrainDraw.measure(BrainWords.search, fonts.status)
            BrainDraw.keyCap(
                cr, "/", x: wordX + wordWidth + 8, midY: mid, fonts: fonts, inks: inks, alpha: alpha)
        }
        let label = list.countLabel
        let color = list.isFiltered ? inks.accent : inks.dim
        BrainDraw.line(
            cr, label, font: fonts.count, lineHeight: fonts.lineHeight, x: 0, top: 0,
            height: Self.headerHeight, width: width - 8, align: 2, color: color, alpha: alpha)
    }

    private func paintRow(
        _ cr: OpaquePointer, row: NeuralStepList.Row, previous: NeuralStepList.Row?,
        next: NeuralStepList.Row?, y: Double, height rowH: Double, width: Double, inks: BrainInks,
        isCursor: Bool, isHovered: Bool, pointerHere: Bool, alpha: Double, query: String
    ) {
        let zone = inks.corrected(row.zone)
        cairo_save(cr)
        if row.status == .failed {
            BrainDraw.fill(cr, inks.cDanger, 0.08 * alpha)
            cairo_rectangle(cr, 0, y, width, rowH)
            cairo_fill(cr)
        }
        if isCursor {
            BrainDraw.fill(cr, inks.accent, 0.14 * alpha)
            cairo_rectangle(cr, 0, y, width, rowH)
            cairo_fill(cr)
        } else if isHovered {
            BrainDraw.fill(cr, inks.ink, 0.06 * alpha)
            cairo_rectangle(cr, 0, y, width, rowH)
            cairo_fill(cr)
        }
        BrainDraw.fill(cr, zone, alpha)
        cairo_rectangle(cr, 0, y, 3, rowH)
        cairo_fill(cr)
        if isCursor {
            BrainDraw.fill(cr, inks.accent, alpha)
            cairo_rectangle(cr, 3, y, 2, rowH)
            cairo_fill(cr)
            cairo_set_line_width(cr, 1)
            BrainDraw.roundedRect(cr, 0.5, y + 0.5, width - 1, rowH - 1, 2)
            BrainDraw.fill(cr, inks.accent, 0.9 * alpha)
            cairo_stroke(cr)
        }
        paintBracket(cr, row: row, previous: previous, next: next, y: y, height: rowH, inks: inks, alpha: alpha)
        let said = row.isSaid
        let lineBand = said ? 28.0 : rowH
        let mid = y + lineBand / 2
        BrainDraw.zoneGlyph(cr, zone: row.zone, cx: 34, cy: mid, color: zone, alpha: alpha)
        BrainDraw.line(
            cr, "\(row.number)", font: fonts.number, lineHeight: fonts.lineHeight, x: 51, top: y,
            height: lineBand, width: 24, align: 2, color: inks.dim, alpha: alpha)
        let statusLeft = paintStatus(
            cr, row: row, y: y, height: rowH, width: width, inks: inks, alpha: alpha,
            showCopy: pointerHere || copied?.id == row.id)
        let textLimit = statusLeft - 12
        if row.kind == .tool {
            BrainDraw.line(
                cr, row.title, font: fonts.title, lineHeight: fonts.lineHeight, x: 83, top: y, height: rowH,
                width: 60, color: inks.ink, alpha: alpha)
            let argumentX = 151.0
            let room = max(0, textLimit - argumentX)
            let chars = max(0, Int(room / fonts.monoWidth))
            let shown = row.argument(fittingChars: chars)
            if !query.isEmpty { highlight(cr, text: shown, x: argumentX, y: y, query: query, inks: inks, alpha: alpha) }
            BrainDraw.line(
                cr, shown, font: fonts.argument, lineHeight: fonts.lineHeight, x: argumentX, top: y,
                height: rowH, width: room, color: inks.dim, alpha: alpha)
        } else if said {
            let room = max(0, textLimit - 83)
            for (index, line) in row.lines.prefix(2).enumerated() {
                BrainDraw.text(
                    cr, line, font: fonts.note, x: 83, y: y + 4 + Double(index) * fonts.lineHeight, width: room,
                    color: inks.ink, alpha: alpha)
            }
        } else {
            let room = max(0, textLimit - 83)
            BrainDraw.line(
                cr, row.argument, font: fonts.note, lineHeight: fonts.lineHeight, x: 83, top: y,
                height: rowH, width: room, color: inks.dim, alpha: alpha)
        }
        cairo_restore(cr)
    }

    private func highlight(
        _ cr: OpaquePointer, text: String, x: Double, y: Double, query: String, inks: BrainInks, alpha: Double
    ) {
        guard let range = text.range(of: query, options: .caseInsensitive) else { return }
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        BrainDraw.fill(cr, inks.warn, 0.34 * alpha)
        BrainDraw.roundedRect(
            cr, x + Double(start) * fonts.monoWidth - 1, y + 5, Double(length) * fonts.monoWidth + 2,
            rowHeight - 10, 3)
        cairo_fill(cr)
    }

    private func paintBracket(
        _ cr: OpaquePointer, row: NeuralStepList.Row, previous: NeuralStepList.Row?,
        next: NeuralStepList.Row?, y: Double, height rowH: Double, inks: BrainInks, alpha: Double
    ) {
        guard row.bracket != .none else { return }
        let joinsAbove = previous.map { $0.group == row.group && $0.bracket != .none } ?? false
        let joinsBelow = next.map { $0.group == row.group && $0.bracket != .none } ?? false
        guard joinsAbove || joinsBelow else { return }
        let mid = y + rowH / 2
        cairo_save(cr)
        BrainDraw.fill(cr, inks.dim, 0.75 * alpha)
        cairo_set_line_width(cr, 1)
        cairo_new_path(cr)
        let x = 9.5
        cairo_move_to(cr, x, joinsAbove ? y : mid)
        cairo_line_to(cr, x, joinsBelow ? y + rowH : mid)
        cairo_move_to(cr, x, mid)
        cairo_line_to(cr, x + 6, mid)
        cairo_stroke(cr)
        cairo_restore(cr)
    }

    /// The mark on the right of a row and the left edge it begins at; the copy button of a
    /// hovered row stands in its place.
    private func paintStatus(
        _ cr: OpaquePointer, row: NeuralStepList.Row, y: Double, height rowH: Double, width: Double,
        inks: BrainInks, alpha: Double, showCopy: Bool
    ) -> Double {
        let band = row.isSaid ? 28.0 : rowH
        let mid = y + band / 2
        if showCopy {
            let rect = copyRect(for: row, width: width)
            let label = copied?.id == row.id ? BrainWords.copied : BrainWords.copy
            BrainDraw.roundedRect(cr, rect.x + 0.5, y + rect.y + 0.5, rect.width - 1, rect.height - 1, 12)
            BrainDraw.fill(cr, inks.card, 0.95 * alpha)
            cairo_fill_preserve(cr)
            BrainDraw.fill(cr, hoverCopy && hoverRow == row.id ? inks.accent : inks.rule2, alpha)
            cairo_set_line_width(cr, 1)
            cairo_stroke(cr)
            BrainDraw.line(
                cr, label, font: fonts.status, lineHeight: fonts.lineHeight, x: rect.x, top: y + rect.y,
                height: rect.height, width: rect.width, align: 1, color: inks.ink, alpha: alpha)
            return rect.x
        }
        let right = width - 10
        switch row.mark {
        case .none:
            return right
        case .failed:
            let word = NeuralReading.statusWord(.failed)
            let size = BrainDraw.measure(word, fonts.status)
            BrainDraw.line(
                cr, word, font: fonts.status, lineHeight: fonts.lineHeight, x: right - size, top: y,
                height: band, color: inks.cDanger, alpha: alpha)
            BrainDraw.cross(cr, cx: right - size - 12, cy: mid, size: 3.5, color: inks.cDanger, alpha: alpha)
            return right - size - 20
        case .retried:
            let word = row.related?.label ?? NeuralReading.retriedWord
            let size = BrainDraw.measure(word, fonts.status)
            BrainDraw.line(
                cr, word, font: fonts.status, lineHeight: fonts.lineHeight, x: right - size, top: y,
                height: band, color: inks.accent, alpha: alpha)
            BrainDraw.dashedRing(cr, cx: right - size - 12, cy: mid, radius: 4.5, color: inks.accent, alpha: alpha)
            return right - size - 20
        case .waiting:
            return markWord(cr, NeuralReading.statusWord(row.status), color: inks.warn, y: y, band: band, right: right, inks: inks, alpha: alpha, dot: true)
        case .running:
            return markWord(cr, NeuralReading.statusWord(.running), color: inks.live, y: y, band: band, right: right, inks: inks, alpha: alpha, dot: true)
        case .stopped:
            let word = NeuralReading.statusWord(.stopped)
            let size = BrainDraw.measure(word, fonts.status)
            BrainDraw.line(
                cr, word, font: fonts.status, lineHeight: fonts.lineHeight, x: right - size, top: y,
                height: band, color: inks.dim, alpha: alpha)
            BrainDraw.dashedRing(cr, cx: right - size - 12, cy: mid, radius: 4.5, color: inks.dim, alpha: alpha)
            return right - size - 20
        }
    }

    private func markWord(
        _ cr: OpaquePointer, _ word: String, color: BrainInks.RGB, y: Double, band: Double, right: Double,
        inks: BrainInks, alpha: Double, dot: Bool
    ) -> Double {
        let size = BrainDraw.measure(word, fonts.status)
        BrainDraw.line(
            cr, word, font: fonts.status, lineHeight: fonts.lineHeight, x: right - size, top: y,
            height: band, color: inks.dim, alpha: alpha)
        BrainDraw.dot(cr, cx: right - size - 10, cy: y + band / 2, radius: 3.5, color: color, alpha: alpha)
        return right - size - 18
    }

    private func paintEmpty(_ cr: OpaquePointer, list: NeuralStepList, inks: BrainInks, width: Double) {
        let message = BrainWords.noMatch(BrainWords.filterDescription(list.filter))
        let mid = Self.headerHeight + viewportHeight / 2 - 26
        BrainDraw.line(
            cr, message, font: fonts.title, lineHeight: fonts.lineHeight, x: 8, top: mid - 10, height: 24,
            width: width - 16, align: 1, color: inks.ink, alpha: 1)
        let rect = clearRect
        BrainDraw.roundedRect(cr, rect.x + 0.5, rect.y + 0.5, rect.width - 1, rect.height - 1, 13)
        BrainDraw.fill(cr, inks.card, 1)
        cairo_fill_preserve(cr)
        BrainDraw.fill(cr, hoverKind == .clearFilters ? inks.accent : inks.rule2, 1)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        BrainDraw.line(
            cr, BrainWords.clearFilters, font: fonts.status, lineHeight: fonts.lineHeight, x: rect.x,
            top: rect.y, height: rect.height, width: rect.width, align: 1, color: inks.ink)
        let orWidth = BrainDraw.measure(BrainWords.orPress, fonts.status)
        let capWidth = BrainDraw.keyCap(cr, "esc", x: 0, midY: 0, fonts: fonts, inks: inks, draw: false)
        let startX = rect.maxX + 12
        _ = capWidth
        BrainDraw.line(
            cr, BrainWords.orPress, font: fonts.status, lineHeight: fonts.lineHeight, x: startX, top: rect.y,
            height: rect.height, color: inks.dim)
        BrainDraw.keyCap(cr, "esc", x: startX + orWidth + 6, midY: rect.y + rect.height / 2, fonts: fonts, inks: inks)
    }

    private func paintPill(_ cr: OpaquePointer, inks: BrainInks) {
        let rect = pillRect
        BrainDraw.roundedRect(cr, rect.x + 0.5, rect.y + 0.5, rect.width - 1, rect.height - 1, 13)
        BrainDraw.fill(cr, inks.card, 0.97)
        cairo_fill_preserve(cr)
        BrainDraw.fill(cr, hoverKind == .pill ? inks.accent : inks.rule2, 1)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        BrainDraw.line(
            cr, BrainWords.followingPaused, font: fonts.pill, lineHeight: fonts.lineHeight, x: rect.x + 12,
            top: rect.y, height: rect.height, color: inks.ink)
        let textWidth = BrainDraw.measure(BrainWords.followingPaused, fonts.pill)
        BrainDraw.keyCap(cr, "End", x: rect.x + 12 + textWidth + 8, midY: rect.y + rect.height / 2, fonts: fonts, inks: inks)
    }

    private func paintScrollbar(_ cr: OpaquePointer, inks: BrainInks, width: Double) {
        guard maxScroll > 0 else { return }
        let viewHeight = viewportHeight
        let thumb = max(24, viewHeight * viewHeight / contentHeight)
        let travel = viewHeight - thumb
        let y = Self.headerHeight + (maxScroll > 0 ? scroll / maxScroll : 0) * travel
        let x = isAccordion ? width - 5 : width + 4
        BrainDraw.fill(cr, inks.dim, 0.35)
        BrainDraw.roundedRect(cr, x, y, 3, thumb, 1.5)
        cairo_fill(cr)
    }

    private func paintExpandedEdge(
        _ cr: OpaquePointer, content: (top: Double, height: Double), inks: BrainInks, model: NeuralBrainModel
    ) {
        guard let id = expandedID, let row = model.browseState.list.row(id: id) else { return }
        let y = Self.headerHeight + content.top - scroll
        let low = max(y, Self.headerHeight)
        let high = min(y + content.height, Self.headerHeight + viewportHeight)
        guard high > low else { return }
        cairo_save(cr)
        BrainDraw.fill(cr, inks.corrected(row.zone), 1)
        cairo_rectangle(cr, 0, low, 3, high - low)
        cairo_fill(cr)
        cairo_restore(cr)
    }

    private func paintFocusRing(_ cr: OpaquePointer, inks: BrainInks, width: Double) {
        cairo_save(cr)
        BrainDraw.roundedRect(
            cr, 1, Self.headerHeight + 1, width - 2, viewportHeight - 2, 8)
        BrainDraw.fill(cr, inks.accent, 0.95)
        cairo_set_line_width(cr, 2)
        cairo_stroke(cr)
        cairo_restore(cr)
    }

    private func paintHint(_ cr: OpaquePointer, inks: BrainInks, y: Double) {
        let mid = y + NeuralStageMetrics.listHintHeight / 2
        var x = 4.0
        func item(_ keys: [String], _ verb: String, alpha: Double = 1) {
            for key in keys {
                x += BrainDraw.keyCap(cr, key, x: x, midY: mid, fonts: fonts, inks: inks, alpha: alpha) + 3
            }
            x += 3
            BrainDraw.line(
                cr, verb, font: fonts.status, lineHeight: fonts.lineHeight, x: x, top: y,
                height: NeuralStageMetrics.listHintHeight, color: inks.dim, alpha: alpha)
            x += BrainDraw.measure(verb, fonts.status) + 14
        }
        item(["\u{2191}", "\u{2193}"], BrainWords.browseVerb)
        item(["/"], BrainWords.filterVerb)
        item(["c"], BrainWords.copyVerb)
        item(["?"], BrainWords.keysVerb)
    }

    // MARK: harness

    /// The rows the last paint drew, and the cost of the paints since the list was made.
    var paintReading: String {
        String(
            format: "rows=%d paints=%d mean=%.0fus worst=%.0fus scroll=%.1f/%.1f extra=%.0f",
            rowsDrawn, paints, paints == 0 ? 0 : Double(paintNanoseconds) / Double(paints) / 1000,
            Double(worstPaintNanoseconds) / 1000, scroll, target, extra)
    }

    func resetPaintStats() {
        paints = 0
        paintNanoseconds = 0
        worstPaintNanoseconds = 0
    }

    /// The ids of the rows in view, top to bottom, for the harness.
    var visibleIDs: [String] {
        guard let model else { return [] }
        let list = model.browseState.list
        var ids: [String] = []
        var position = max(0, list.position(atOffset: max(0, scroll - 1), input: input))
        while position < list.visibleCount {
            let rowTop = top(ofPosition: position) - scroll
            if rowTop >= viewportHeight { break }
            if rowTop + height(ofPosition: position) > 0, let row = list.row(atVisible: position) { ids.append(row.id) }
            position += 1
        }
        return ids
    }

    /// Where a row is painted, in the row's own coordinates, for the harness to click it.
    func rowCentre(of id: String) -> NeuralPoint? {
        guard let position = model?.browseState.list.visibleIndex(of: id) else { return nil }
        let y = layout.list.y + Self.headerHeight + top(ofPosition: position) - scroll + height(ofPosition: position) / 2
        return NeuralPoint(layout.list.x + 120, y)
    }

    var hoverReading: String { hoverRow ?? "-" }
}
