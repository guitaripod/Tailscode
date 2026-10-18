import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A wheel controller that sees each notch after the widgets inside have had it.
extension Gtk {
    static func onScrollBubble(
        _ widget: UnsafeMutablePointer<GtkWidget>, _ handler: @escaping @Sendable (Double) -> Bool
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(ScrollBox(handler)).toOpaque()
        let callback: @convention(c) (Double, UnsafeMutableRawPointer?) -> gboolean = { dy, raw in
            guard let raw else { return 0 }
            return Unmanaged<ScrollBox>.fromOpaque(raw).takeUnretainedValue().handler(dy) ? 1 : 0
        }
        tailscode_connect_scroll_bubble(widget, callback, box)
    }
}

/// The right side of an open brain: the agent talking to you. A column of what it said, what it
/// thought, the work it did folded to a line, and the answer that closes the turn, with whatever
/// it is waiting on you for pinned above it and the step under the cursor opened inside the story.
///
/// The column scrolls and never owns more widgets than the window it shows: items are measured
/// when they are made, estimated while they are not, and only the ones near the viewport exist at
/// all, so a turn of two thousand steps costs what a screenful costs. The scroll is the
/// account's own (a target the wheel moves and the clock eases toward), because an item that
/// changes height under a reader must move the offset with it, and only the thing that knows the
/// offset can do that.
final class BrainAccount: @unchecked Sendable {
    unowned let owner: BrainView
    let ref: WeakBrainView
    /// Holds the header, the pinned ask, the story, the footer and the pill.
    let root: UnsafeMutablePointer<GtkWidget>
    /// Holds the items that exist; places them by the offsets this class keeps.
    let story: UnsafeMutablePointer<GtkWidget>
    /// The entity's header, full width, with the rule under it; `headerBox` is what it holds.
    let header: UnsafeMutablePointer<GtkWidget>
    let headerBox: UnsafeMutablePointer<GtkWidget>
    let footer: UnsafeMutablePointer<GtkWidget>
    let pill: UnsafeMutablePointer<GtkWidget>
    let scrollbar: UnsafeMutablePointer<GtkWidget>

    /// A part of the account that stays above the story: the ask, the Now line, a running plan.
    final class Pin {
        let widget: UnsafeMutablePointer<GtkWidget>
        var height = 0.0
        let signature: String
        init(widget: UnsafeMutablePointer<GtkWidget>, signature: String) {
            self.widget = widget
            self.signature = signature
        }
    }

    var askPin: Pin?
    var nowPin: Pin?
    var planPin: Pin?
    var askWidget: UnsafeMutablePointer<GtkWidget>? { askPin?.widget }
    var askHeight: Double { askPin?.height ?? 0 }
    var askSignature: String { askPin?.signature ?? "" }
    var nowSignature = ""
    var planSignature = ""
    var planOpenOverride: Bool?
    var pinnedPlanCompact = false
    var askDotWidget: Gtk.WeakWidget?
    var nowDotWidget: Gtk.WeakWidget?
    var headerStamp = ""
    var filterWord: String?
    var lastActivityAt: Date?
    var lastActivityMark = ""
    var headerHeight = 40.0
    var headerWasNarrow = false
    var lastSecond = 0.0
    lazy var askedLine = Self.lineHeight("bn-asked-text")

    private(set) var account: NeuralAccount
    private(set) var entries: [AccountEntry] = []
    var entryIndex: [String: Int] = [:]
    var cells: [String: AccountCell] = [:]
    var heights: [String: Double] = [:]
    var offsets: [Double] = []
    var total = 0.0

    var unfolded = Set<String>()
    var expandedText = Set<String>()
    var rowCaps: [String: Int] = [:]

    private(set) var scroll = 0.0
    private(set) var target = 0.0
    var viewHeight = 0.0
    var storyWidth = 0.0
    var boxWidth = 0.0
    var lastTick = 0.0
    var arrivals: [String: Double] = [:]
    var justNow: [String: Double] = [:]
    var knownIDs = Set<String>()
    var seeded = false
    var pendingReveal: (id: String, pad: Double)?
    var lastCursor: String?
    var suppressReveal: String?
    var realizeScheduled = false
    var refreshTicket = 0
    var lastRefresh = 0.0
    var refreshPending = false
    var frameCache: Frame?
    var focusEntryID: String?
    var workStamps: [String: Int] = [:]
    var readStamp: ReadStamp?
    var holdAnchor: (id: String, delta: Double)?
    var copiedFlash: (stepID: String, until: Double)?
    var planStoryOverride: [String: Bool] = [:]
    var holdTicket = 0

    /// What the entries were made from: when none of it changed, a new cursor or hover is a change
    /// of what exists and not of what is said.
    struct ReadStamp: Equatable {
        var reads: Int
        var filter: NeuralStepList.Filter
        var total: Int
        var visible: Int
        var following: Bool
        var outcome: NeuralOutcome
        var answer: Int
    }
    var fonts = BrainListFonts()
    lazy var workFonts = WorkFonts()
    var proseProbe = (line: 24.0, em: 15.0)
    var themeStamp = ""
    var disposed = false
    private(set) var realizeCount = 0
    private(set) var buildCount = 0
    private(set) var solveNanoseconds: UInt64 = 0
    private(set) var solves = 0
    private(set) var refreshNanoseconds: UInt64 = 0
    private(set) var realizeNanoseconds: UInt64 = 0
    private(set) var refreshes = 0
    private(set) var worstSolve: UInt64 = 0

    static let footerHeight = 32.0
    static let padLeft = 20.0
    static let padRight = 12.0
    static let said12 = 12.0
    static let gap = 20.0
    static let wheelStep = 56.0
    static let scrollEase = 0.075
    static let arrivalDuration = 0.12
    static let justNowDuration = 6.0
    static let storyMax = NeuralStageMetrics.storyMax

    /// Where the account's parts stand in its own coordinates.
    struct Frame {
        var width: Double
        var height: Double
        var header: NeuralRect
        var pins: [(pin: Pin, rect: NeuralRect)]
        var story: NeuralRect
        var footer: NeuralRect?
        var detail: NeuralRect?
        var boxWidth: Double
        var padLeft: Double
        var split: Bool
        var twoColumns: Bool
    }

    init(owner: BrainView) {
        self.owner = owner
        ref = WeakBrainView(owner)
        account = owner.model.account(
            answer: owner.row.answer.isEmpty ? nil : owner.row.answer, prompt: owner.row.prompt)
        let rootHolder = Holder()
        let storyHolder = Holder()
        _ = Gtk.releaseInstalled
        root = tailscode_brain_row_new(
            { width, height, sink, raw in
                guard let raw, let sink else { return }
                Unmanaged<Holder>.fromOpaque(raw).takeUnretainedValue().account?.solveRoot(
                    width: Int(width), height: Int(height), sink: sink)
            },
            { _, _ in 1 }, Unmanaged.passRetained(rootHolder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<Holder>.fromOpaque(raw).release()
            })!
        story = tailscode_brain_row_new(
            { width, height, sink, raw in
                guard let raw, let sink else { return }
                Unmanaged<Holder>.fromOpaque(raw).takeUnretainedValue().account?.solveStory(
                    width: Int(width), height: Int(height), sink: sink)
            },
            { _, _ in 1 }, Unmanaged.passRetained(storyHolder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<Holder>.fromOpaque(raw).release()
            })!
        header = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0, "bn-ac-head")
        headerBox = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12, "bn-ac-head-row")
        gtk_widget_set_hexpand(headerBox, 1)
        gtk_box_append(ptr(header), headerBox)
        let footerHolder = PaintHolder(kind: 0)
        let scrollHolder = PaintHolder(kind: 1)
        footer = Self.paintCanvas(footerHolder)
        pill = gtk_button_new()!
        scrollbar = Self.paintCanvas(scrollHolder)
        rootHolder.account = self
        storyHolder.account = self
        footerHolder.account = self
        scrollHolder.account = self
        build()
    }

    private final class Holder: @unchecked Sendable {
        weak var account: BrainAccount?
    }


    private func build() {
        Gtk.addClass(root, "bn-account")
        Gtk.addClass(story, "bn-story")
        gtk_widget_set_focusable(story, 1)
        gtk_widget_set_can_focus(story, 1)
        tailscode_set_accessible_label(story, BrainWords.accountLabel)
        gtk_widget_set_can_target(footer, 0)
        gtk_widget_set_can_target(scrollbar, 0)
        tailscode_set_accessible_hidden(footer, 1)
        tailscode_set_accessible_hidden(scrollbar, 1)
        buildPill()
        for part in [header, story, footer, scrollbar, pill] { tailscode_brain_row_add(root, part) }
        installInput()
    }

    private func buildPill() {
        Gtk.addClass(pill, "bn-follow")
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        BrainUI.add(row, BrainUI.label(BrainWords.followingPaused, "bn-follow-text"), BrainUI.label("End", "bn-follow-key"))
        gtk_button_set_child(ptr(pill), row)
        gtk_widget_set_cursor_from_name(pill, "pointer")
        gtk_widget_set_visible(pill, 0)
        let ref = self.ref
        Gtk.connect(UnsafeMutableRawPointer(pill), "clicked") {
            Gtk.onMain { ref.view?.accountJumpToLatest() }
        }
        tailscode_set_accessible_label(pill, BrainWords.followingPaused)
    }


    /// The account's parts for a root of `size`, from the row's metrics: the header, the story
    /// beside the open step's detail when there is room for two columns, and the footer's key
    /// hints, which the narrow account drops.
    func frame(width: Double, height: Double) -> Frame {
        let m = owner.currentMetrics
        let split = m.arrangement == .split
        let twoColumns = split && m.accountLayout == .split
        let headerRect = NeuralRect(x: 0, y: 0, width: width, height: headerHeight)
        let footerH = split ? Self.footerHeight : 0
        let bodyTop = headerHeight
        let bodyHeight = max(0, height - bodyTop - footerH)
        let region = twoColumns ? m.story.width : width
        let padLeft = split ? Self.padLeft : 16
        let cap = split ? Self.storyMax : width
        let box = max(120, min(region, cap) - padLeft - Self.padRight)
        var pins: [(pin: Pin, rect: NeuralRect)] = []
        var cursor = bodyTop
        for pin in [askPin, nowPin, planPin].compactMap({ $0 }) {
            let rect = NeuralRect(x: padLeft, y: cursor + 8, width: box, height: pin.height)
            pins.append((pin, rect))
            cursor = rect.maxY
        }
        let storyTop = pins.isEmpty ? bodyTop : cursor + 8
        let storyRect = NeuralRect(x: 0, y: storyTop, width: region, height: max(0, bodyTop + bodyHeight - storyTop))
        let detail: NeuralRect? = twoColumns
            ? NeuralRect(
                x: m.story.width + NeuralStageMetrics.gutter, y: bodyTop + 4,
                width: max(0, width - m.story.width - NeuralStageMetrics.gutter), height: max(0, bodyHeight - 4))
            : nil
        return Frame(
            width: width, height: height, header: headerRect, pins: pins, story: storyRect,
            footer: split ? NeuralRect(x: 0, y: height - footerH, width: width, height: footerH) : nil,
            detail: detail, boxWidth: box, padLeft: padLeft, split: split, twoColumns: twoColumns)
    }

    /// The part of the root the open step's detail occupies, in the account's own coordinates; nil
    /// when the story holds it in place.
    func detailRect() -> NeuralRect? { frameCache?.detail }

    /// The body, for a dive or a replay that takes the whole of it.
    func bodyRect() -> NeuralRect? {
        guard let frame = frameCache else { return nil }
        return NeuralRect(
            x: 0, y: headerHeight, width: frame.width,
            height: max(0, frame.height - headerHeight - (frame.footer?.height ?? 0)))
    }

    private func solveRoot(width: Int, height: Int, sink: OpaquePointer) {
        measureChrome(width: Double(width))
        let f = frame(width: Double(width), height: Double(height))
        frameCache = f
        place(sink, header, NeuralRect(x: 0, y: 0, width: f.width, height: f.header.height))
        for entry in f.pins { place(sink, entry.pin.widget, entry.rect) }
        let takenOver = owner.readoutHoldsBody
        if !takenOver {
            place(sink, story, f.story)
        }
        if let footer = f.footer { place(sink, self.footer, footer) }
        if !takenOver {
            place(sink, scrollbar, NeuralRect(x: f.story.maxX - 8, y: f.story.y, width: 8, height: f.story.height))
            if pillShown {
                let width = pillWidth
                place(
                    sink, pill,
                    NeuralRect(
                        x: f.story.x + (f.story.width - width) / 2,
                        y: f.story.maxY - 12 - 28, width: width, height: 28))
            }
        }
        let first = storyWidth != f.story.width || boxWidth != f.boxWidth || viewHeight != f.story.height
        storyWidth = f.story.width
        boxWidth = f.boxWidth
        setViewHeight(f.story.height)
        if first {
            Gtk.onMain { [weak self] in
                guard let self, !self.disposed else { return }
                self.geometryChanged()
            }
        }
    }

    /// The account's parts for the size the row is about to give it, so the detail beside the story
    /// is placed in the same pass.
    func touchFrame(width: Double, height: Double) {
        frameCache = frame(width: width, height: height)
    }

    /// How visible the story, the pinned ask and the footer are, for the first content landing
    /// after a move.
    func setBodyAlpha(_ alpha: Double) {
        for part in [story, footer, scrollbar] { gtk_widget_set_opacity(part, alpha) }
        for pin in [askPin, nowPin, planPin].compactMap({ $0 }) { gtk_widget_set_opacity(pin.widget, alpha) }
    }

    /// Says Copied on the note's button for a moment, and on the button of the item that replaces
    /// it if the item is made again meanwhile.
    func flashCopied(_ stepID: String) {
        copiedFlash = (stepID, BrainClock.now + 1.4)
        setCopyLabel(for: stepID)
        Gtk.after(1450) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.disposed, let flash = self.copiedFlash, flash.stepID == stepID,
                    BrainClock.now >= flash.until
                else { return }
                self.copiedFlash = nil
                self.setCopyLabel(for: stepID)
            }
        }
    }

    func setCopyLabel(for stepID: String) {
        guard let item = account.item(containing: stepID), let button = cells[item.id]?.copyButton else { return }
        gtk_button_set_label(ptr(button), copyWord(for: stepID))
    }

    /// What a note's Copy button says: Copied while the press is a moment old.
    func copyWord(for stepID: String) -> String {
        if let flash = copiedFlash, flash.stepID == stepID, BrainClock.now < flash.until { return BrainWords.copied }
        return NeuralReading.copyLabel
    }

    func invalidateFocus() {
        gtk_widget_queue_draw(story)
    }

    var pillShown: Bool { gtk_widget_get_visible(pill) != 0 }

    var pillWidth: Double {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(pill, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, nil, nil)
        return Double(natural)
    }

    func place(
        _ sink: OpaquePointer, _ child: UnsafeMutablePointer<GtkWidget>?, _ rect: NeuralRect, dx: Double = 0,
        dy: Double = 0
    ) {
        guard let child else { return }
        tailscode_brain_row_place(
            sink, child, Int32((rect.x + dx).rounded()), Int32((rect.y + dy).rounded()),
            Int32(rect.width.rounded()), Int32(rect.height.rounded()))
    }

    /// The width or height the account's row changed: every item is measured again at the new
    /// width, and the items that exist are made again for it.
    func geometryChanged() {
        if holdAnchor == nil, let held = anchor(), held.index < entries.count {
            holdAnchor = (entries[held.index].id, held.delta)
        }
        holdFor(0.45)
        heights = [:]
        for (_, cell) in cells { cell.stale = true }
        scheduleRealize()
    }


    /// Keeps the item at the top of the viewport where it is until the heights have settled: after a
    /// resize every item is measured again at its new width, and the page must not move under the
    /// reader while the estimates are replaced by measurements.
    func holdFor(_ seconds: Double) {
        holdTicket += 1
        let ticket = holdTicket
        Gtk.after(UInt32(seconds * 1000)) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.holdTicket == ticket else { return }
                self.holdAnchor = nil
            }
        }
    }

    func gap(before index: Int) -> Double {
        guard index > 0 else { return 0 }
        if entries[index].isSaid, entries[index - 1].isSaid { return Self.said12 }
        if entries[index].isResult { return Self.gap }
        return Self.gap
    }

    func estimate(_ entry: AccountEntry) -> Double {
        let measure = max(160, min(boxWidth - 72, proseProbe.em * 36))
        let perLine = max(8, measure / (proseProbe.em * 0.52))
        switch entry.kind {
        case .said(let said):
            let lines = said.text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) {
                $0 + max(1, Int((Double($1.count) / perLine).rounded(.up)))
            }
            let shown = expandedText.contains(entry.id) ? lines : min(lines, 6)
            return 4 + (said.showsSpeaker ? 20 : 0) + Double(shown) * proseProbe.line + (lines > 6 ? 22 : 0)
        case .thought:
            return expandedText.contains(entry.id) ? 64 : 24
        case .work(let work):
            guard isOpen(entry, work: work) else { return 36 }
            return 36 + Double(min(work.stepIDs.count, rowCap(entry.id))) * 28 + 10
        case .asked:
            return 52
        case .plan(let plan):
            return planStoryOpen(entries[0], plan) ? Double(24 + plan.items.count * 24 + 16) : 36
        case .result(let result):
            return Double(40 + (result.changes.count + result.checks.count + result.unfixed.count) * 28 + 90)
        }
    }

    func isOpen(_ entry: AccountEntry, work: AccountEntry.Work) -> Bool {
        if unfolded.contains(entry.id) { return true }
        if let cursor = owner.model.pinnedStep, work.stepIDs.contains(cursor) { return true }
        return liveTip(work: work)
    }

    /// The work line the running turn is writing into stays open while the account follows it.
    func liveTip(work: AccountEntry.Work) -> Bool {
        let model = owner.model
        guard model.turn.outcome == .running, model.stepList.isFollowing, model.pinnedStep == nil,
            let last = model.steps.last?.id
        else { return false }
        return work.stepIDs.last == last
    }

    func rowCap(_ id: String) -> Int { rowCaps[id] ?? Self.initialRows }

    static let initialRows = 40
    static let rowStride = 40
    static let rowMax = 400

    func recomputeOffsets() {
        var y = 0.0
        var made: [Double] = []
        made.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            y += gap(before: index)
            made.append(y)
            y += heights[entry.id] ?? estimate(entry)
        }
        offsets = made
        total = y + 16
    }

    var maxScroll: Double { max(0, total - viewHeight) }

    /// The entry at the top of the viewport and how far it stands below the top: held across a
    /// change of heights so what is being read does not move.
    func anchor() -> (index: Int, delta: Double)? {
        guard !entries.isEmpty, offsets.count == entries.count else { return nil }
        var low = 0
        var high = entries.count - 1
        while low < high {
            let mid = (low + high) / 2
            let bottom = offsets[mid] + (heights[entries[mid].id] ?? estimate(entries[mid]))
            if bottom > scroll { high = mid } else { low = mid + 1 }
        }
        return (low, scroll - offsets[low])
    }

    func clampScroll() {
        target = min(max(target, 0), maxScroll)
        scroll = min(max(scroll, 0), maxScroll)
    }

    /// Measures the items that exist at the width they are laid out at; when any is not the height
    /// it was thought to be, the offsets are made again with the reader's place held.
    private func syncHeights() {
        var changed = false
        for (id, cell) in cells {
            guard entryIndex[id] != nil else { continue }
            fitHolders(cell)
            let h = cell.measure(width: boxWidth)
            if abs((heights[id] ?? -1) - h) > 0.5 {
                heights[id] = h
                changed = true
            }
        }
        guard changed || offsets.count != entries.count else { return }
        let held = anchor()
        let wasAtEnd = maxScroll > 0 && scroll >= maxScroll - 0.5
        let aimedAtEnd = maxScroll > 0 && target >= maxScroll - 0.5
        recomputeOffsets()
        if let held, held.index < offsets.count {
            let moved = offsets[held.index] + held.delta - scroll
            scroll += moved
            target += moved
        }
        if let hold = holdAnchor, let at = entryIndex[hold.id], pendingReveal == nil {
            scroll = offsets[at] + hold.delta
            target = scroll
        }
        if let reveal = pendingReveal, let at = entryIndex[reveal.id] {
            target = min(max(offsets[at] - reveal.pad, 0), maxScroll)
        } else if owner.model.stepList.isFollowing {
            if wasAtEnd {
                scroll = maxScroll
                target = maxScroll
            } else if aimedAtEnd {
                target = maxScroll
            }
        }
        clampScroll()
    }

    /// Narrows a cell's prose to the box the instant the box narrows, before the cell is made
    /// again for the new width, so the toolkit is never asked to lay a measure out in less room
    /// than it asked for.
    private func fitHolders(_ cell: AccountCell) {
        guard !cell.holders.isEmpty, cell.holdersWidth != boxWidth else { return }
        cell.holdersWidth = boxWidth
        for held in cell.holders {
            let measure = max(120, min(proseProbe.em * 36, boxWidth - held.inset))
            gtk_widget_set_size_request(held.widget, Int32(measure.rounded()), -1)
        }
    }

    /// Sets how tall the story's window is. A story that is following its end and was sitting at it
    /// stays there when the window shrinks or grows, which is what a Now line appearing above it
    /// does, rather than being left a few points short of the newest item.
    private func setViewHeight(_ height: Double) {
        guard height != viewHeight else { return }
        let atEnd = maxScroll > 0 && scroll >= maxScroll - 0.5 && target >= maxScroll - 0.5
        let aimedAtEnd = maxScroll > 0 && target >= maxScroll - 0.5
        viewHeight = height
        guard owner.model.stepList.isFollowing else { return }
        if atEnd, scroll < maxScroll {
            scroll = maxScroll
            target = maxScroll
        } else if aimedAtEnd {
            target = maxScroll
        }
    }

    private func solveStory(width: Int, height: Int, sink: OpaquePointer) {
        let begun = DispatchTime.now().uptimeNanoseconds
        setViewHeight(Double(height))
        syncHeights()
        let now = BrainClock.now
        for index in 0..<entries.count {
            let entry = entries[index]
            guard let cell = cells[entry.id], index < offsets.count else { continue }
            fitHolders(cell)
            let h = heights[entry.id] ?? cell.measure(width: boxWidth)
            var dy = 0.0
            var alpha = 1.0
            if let start = arrivals[entry.id] {
                let t = min(1, max(0, (now - start) / Self.arrivalDuration))
                dy = 12 * (1 - NeuralTransition.easeOutCubic(t))
                alpha = 0.55 + 0.45 * t
            }
            let top = offsets[index] - scroll + dy
            guard top + h > -40, top < Double(height) + 40 else { continue }
            gtk_widget_set_opacity(cell.widget, alpha)
            fitHolders(cell)
            let pad = frameCache?.padLeft ?? Self.padLeft
            tailscode_brain_row_place(sink, cell.widget, Int32(pad), Int32(top.rounded()), Int32(boxWidth.rounded()), Int32(h.rounded()))
        }
        if needsRealizeNow() { scheduleRealize() }
        let spent = DispatchTime.now().uptimeNanoseconds - begun
        solveNanoseconds += spent
        worstSolve = max(worstSolve, spent)
        solves += 1
    }


    /// The range of entries within a screen of the viewport on either side.
    func wanted() -> Range<Int> {
        guard !entries.isEmpty, offsets.count == entries.count else { return 0..<0 }
        let overscan = max(480, viewHeight * 0.8)
        let top = scroll - overscan
        let bottom = scroll + viewHeight + overscan
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            let end = offsets[mid] + (heights[entries[mid].id] ?? estimate(entries[mid]))
            if end < top { low = mid + 1 } else { high = mid }
        }
        var upper = low
        while upper < entries.count, offsets[upper] <= bottom { upper += 1 }
        return low..<max(low, upper)
    }

    private func needsRealizeNow() -> Bool {
        guard viewHeight > 0 else { return false }
        let range = wanted()
        let want = Set(range.map { entries[$0].id })
        return want != Set(cells.keys)
    }

    func scheduleRealize() {
        guard !realizeScheduled, !disposed else { return }
        realizeScheduled = true
        Gtk.onMain { [weak self] in
            guard let self, !self.disposed else { return }
            self.realizeScheduled = false
            self.realize()
        }
    }

    /// Makes the items near the viewport and lets go of the rest, then lays out once more.
    func realize() {
        guard !disposed, viewHeight > 0, boxWidth > 0 else { return }
        let begun = DispatchTime.now().uptimeNanoseconds
        defer { realizeNanoseconds += DispatchTime.now().uptimeNanoseconds - begun }
        realizeCount += 1
        if offsets.count != entries.count { recomputeOffsets() }
        let range = wanted()
        let want = Set(range.map { entries[$0].id })
        for id in Array(cells.keys) where !want.contains(id) || entryIndex[id] == nil { drop(id) }
        for index in range {
            let entry = entries[index]
            let key = cellKey(entry)
            if let held = cells[entry.id] {
                if held.key == key, !held.stale { continue }
                drop(entry.id)
            }
            make(entry, key: key)
        }
        syncHeights()
        clampScroll()
        let again = wanted()
        if Set(again.map { entries[$0].id }) != Set(cells.keys) { scheduleRealize() }
        tailscode_brain_row_invalidate(story)
        tailscode_brain_row_invalidate(root)
    }

    private func make(_ entry: AccountEntry, key: String) {
        buildCount += 1
        let cell = buildCell(entry, key: key)
        cells[entry.id] = cell
        tailscode_brain_row_add(story, cell.widget)
    }

    /// Takes an item off the story. The keyboard is moved to the story itself first, so no widget
    /// that has focus is ever unparented.
    func drop(_ id: String) {
        guard let cell = cells.removeValue(forKey: id) else { return }
        releaseFocus(in: cell.widget)
        cell.teardown()
        tailscode_brain_row_remove(story, cell.widget)
    }

    private func releaseFocus(in widget: UnsafeMutablePointer<GtkWidget>) {
        guard let window = gtk_widget_get_root(story),
            let focused = gtk_root_get_focus(OpaquePointer(UnsafeMutableRawPointer(window)))
        else { return }
        guard focused == widget || gtk_widget_is_ancestor(focused, widget) != 0 else { return }
        gtk_widget_grab_focus(story)
    }

    func teardown() {
        disposed = true
        for id in Array(cells.keys) {
            cells[id]?.teardown()
            cells[id] = nil
        }
    }


    /// The model changed: a step arrived, a status moved, a filter was set, the cursor or the hover
    /// went elsewhere. The account is read again, and what is on screen is brought to it.
    func refresh(immediate: Bool = false) {
        guard !disposed else { return }
        let begun = DispatchTime.now().uptimeNanoseconds
        defer {
            refreshNanoseconds += DispatchTime.now().uptimeNanoseconds - begun
            refreshes += 1
        }
        let now = BrainClock.now
        if !immediate, now - lastRefresh < 0.06 {
            guard !refreshPending else { return }
            refreshPending = true
            Gtk.after(60) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, !self.disposed else { return }
                    self.refreshPending = false
                    self.refresh(immediate: true)
                }
            }
            return
        }
        lastRefresh = now
        let model = owner.model
        let list = model.browseState.list
        let next = model.account(
            answer: owner.row.answer.isEmpty ? nil : owner.row.answer, prompt: owner.row.prompt)
        let stamp = ReadStamp(
            reads: model.accountReads, filter: list.filter, total: list.total, visible: list.visibleCount,
            following: list.isFollowing, outcome: model.turn.outcome, answer: owner.row.answer.utf8.count)
        guard stamp != readStamp || entries.isEmpty else {
            followCursor()
            clampScroll()
            scheduleRealize()
            owner.listAnimationChanged()
            return
        }
        readStamp = stamp
        account = next
        let made = AccountEntries.make(model: model, account: next, list: list)
        let live = model.turn.outcome == .running
        let fresh = made.filter { !knownIDs.contains($0.id) }
        if seeded, live, list.isFollowing, !BrainBudget.reduceMotion {
            for entry in fresh {
                arrivals[entry.id] = now
                if entry.isSaid { justNow[entry.id] = now }
            }
        }
        knownIDs.formUnion(made.map(\.id))
        seeded = true
        entries = made
        entryIndex = Dictionary(uniqueKeysWithValues: made.enumerated().map { ($1.id, $0) })
        heights = heights.filter { entryIndex[$0.key] != nil }
        workStamps = [:]
        for entry in made {
            guard case .work(let work) = entry.kind else { continue }
            var hasher = Hasher()
            for id in work.stepIDs {
                guard let step = model.step(id: id) else { continue }
                hasher.combine(id)
                hasher.combine(step.status)
                hasher.combine(step.outputLines.count)
                hasher.combine(step.call?.call.output?.utf8.count ?? 0)
            }
            workStamps[entry.id] = hasher.finalize()
        }
        recomputeOffsets()
        refreshChrome()
        followCursor()
        followNewest()
        clampScroll()
        scheduleRealize()
        tailscode_brain_row_invalidate(root)
        tailscode_brain_row_invalidate(story)
        gtk_widget_queue_draw(scrollbar)
        owner.listAnimationChanged()
    }

    /// While a turn runs and the reader has not scrolled away, the account sits at its newest item.
    private func followNewest() {
        let model = owner.model
        guard model.turn.outcome == .running, model.stepList.isFollowing else { return }
        pendingReveal = nil
        target = maxScroll
        if BrainBudget.reduceMotion || (scroll == 0 && target > viewHeight * 3) { scroll = target }
    }

    /// A cursor that moved from somewhere else (a row, a node, a key) brings its item into view:
    /// aligned to the note that came before the work, so what it said is read with what it did.
    private func followCursor() {
        let cursor = owner.model.pinnedStep
        defer { lastCursor = cursor }
        guard let cursor, cursor != lastCursor else { return }
        if suppressReveal == cursor {
            suppressReveal = nil
            return
        }
        revealStep(cursor)
    }

    func revealStep(_ stepID: String) {
        guard let item = account.item(containing: stepID), var at = entryIndex[item.id] else {
            return
        }
        if entries[at].isWork, at > 0, entries[at - 1].isSaid { at -= 1 }
        pendingReveal = (entries[at].id, 8)
        target = min(max(offsets[at] - 8, 0), maxScroll)
        if BrainBudget.reduceMotion { scroll = target }
        owner.listAnimationChanged()
    }


    func wheel(_ dy: Double) -> Bool {
        guard maxScroll > 0 else { return false }
        holdAnchor = nil
        let next = min(max(target + dy * Self.wheelStep, 0), maxScroll)
        guard next != target else { return true }
        pendingReveal = nil
        target = next
        if BrainBudget.reduceMotion { scroll = target }
        owner.browse(.scrolled(manual: true), grabFocus: false)
        owner.listAnimationChanged()
        tailscode_brain_row_invalidate(story)
        return true
    }

    func driveScroll(_ pixels: Double) {
        target = min(max(target + pixels, 0), maxScroll)
        pendingReveal = nil
        if BrainBudget.reduceMotion { scroll = target }
        owner.browse(.scrolled(manual: true), grabFocus: false)
        owner.listAnimationChanged()
        tailscode_brain_row_invalidate(story)
    }

    func scrollToEnd(jump: Bool = false) {
        pendingReveal = nil
        target = maxScroll
        if jump || BrainBudget.reduceMotion { scroll = target }
        owner.listAnimationChanged()
        tailscode_brain_row_invalidate(story)
    }

    func scrollToStart() {
        pendingReveal = nil
        target = 0
        if BrainBudget.reduceMotion { scroll = 0 }
        owner.listAnimationChanged()
        tailscode_brain_row_invalidate(story)
    }

    var isAnimating: Bool {
        if abs(scroll - target) > 0.4 { return true }
        let now = BrainClock.now
        if arrivals.values.contains(where: { now - $0 < Self.arrivalDuration }) { return true }
        return justNow.values.contains { now - $0 < Self.justNowDuration + 0.05 }
    }

    func tick(_ time: Double) {
        guard !disposed else { return }
        let dt = lastTick == 0 ? 1.0 / 60 : min(0.1, time - lastTick)
        lastTick = time
        var changed = false
        if abs(scroll - target) > 0.4 {
            let before = scroll
            scroll += (target - scroll) * (1 - exp(-dt / Self.scrollEase))
            if abs(scroll - target) <= 0.4 {
                scroll = target
                pendingReveal = nil
            }
            changed = changed || before != scroll
        } else if scroll != target {
            scroll = target
            pendingReveal = nil
            changed = true
        }
        let expired = arrivals.filter { time - $0.value >= Self.arrivalDuration }.map(\.key)
        for id in expired {
            arrivals[id] = nil
            changed = true
        }
        let old = justNow.filter { time - $0.value >= Self.justNowDuration }.map(\.key)
        for id in old {
            justNow[id] = nil
            cells[id]?.hideJustNow()
        }
        if changed || !arrivals.isEmpty {
            tailscode_brain_row_invalidate(story)
            gtk_widget_queue_draw(scrollbar)
            if abs(scroll - target) < 0.5 || changed { scheduleRealizeIfNeeded() }
        }
        if lastTick != 0, !isAnimating { lastTick = 0 }
    }

    private func scheduleRealizeIfNeeded() {
        if needsRealizeNow() { scheduleRealize() }
    }


    /// What the harness reads: how many items exist, how long the story is, where it is scrolled.
    var reading: String {
        let held = cells.keys.compactMap { entryIndex[$0] }.sorted()
        let range = held.isEmpty ? "-" : "\(held.first!)...\(held.last!)"
        let widgets = cells.values.reduce(0) { $0 + $1.widgetCount }
        return String(
            format: "items=%d realized=%d range=%@ widgets=%d total=%.0f scroll=%.0f/%.0f view=%.0f box=%.0f solves=%d mean=%.0fus worst=%.0fus refreshes=%d refresh=%.0fus realizes=%d realize=%.0fms",
            entries.count, cells.count, range, widgets, total, scroll, target, viewHeight, boxWidth, solves,
            solves == 0 ? 0 : Double(solveNanoseconds) / Double(solves) / 1000, Double(worstSolve) / 1000,
            refreshes, refreshes == 0 ? 0 : Double(refreshNanoseconds) / Double(refreshes) / 1000, realizeCount,
            Double(realizeNanoseconds) / 1_000_000)
    }

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
        return count(root)
    }

    /// The text of every label of the items that exist, in story order, for the harness to read
    /// what the account says.
    var visibleText: String {
        var words: [String] = []
        func walk(_ widget: UnsafeMutablePointer<GtkWidget>) {
            let instance = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self)
            if g_type_check_instance_is_a(instance, gtk_label_get_type()) != 0,
                let raw = gtk_label_get_text(op(widget))
            {
                words.append(String(cString: raw))
            }
            var child = gtk_widget_get_first_child(widget)
            while let held = child {
                walk(held)
                child = gtk_widget_get_next_sibling(held)
            }
        }
        walk(header)
        for pin in [askPin, nowPin, planPin].compactMap({ $0 }) { walk(pin.widget) }
        for entry in entries { if let cell = cells[entry.id] { walk(cell.widget) } }
        return words.joined(separator: "\n")
    }

    /// Every widget of the items that exist whose own minimum width is wider than the box they
    /// are laid out in, which the toolkit complains of: for the harness.
    func overflowReading() -> String {
        var lines: [String] = []
        func walk(_ node: UnsafeMutablePointer<GtkWidget>, depth: Int, id: String) {
            if gtk_widget_get_visible(node) == 0 { return }
            var minimum: Int32 = 0
            var natural: Int32 = 0
            gtk_widget_measure(node, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, nil, nil)
            if Double(minimum) > boxWidth + 0.5 {
                var classes = ""
                if let list = gtk_widget_get_css_classes(node) {
                    var index = 0
                    while let item = list[index] {
                        classes += String(cString: item) + "."
                        index += 1
                    }
                    g_strfreev(list)
                }
                lines.append("\(id) \(String(repeating: " ", count: depth))\(String(cString: gtk_widget_get_css_name(node))).\(classes) min=\(minimum) nat=\(natural)")
            }
            var child = gtk_widget_get_first_child(node)
            while let held = child {
                walk(held, depth: depth + 1, id: id)
                child = gtk_widget_get_next_sibling(held)
            }
        }
        for entry in entries { if let cell = cells[entry.id] { walk(cell.widget, depth: 0, id: entry.id) } }
        for (name, pin) in [("ask", askPin), ("now", nowPin), ("plan", planPin)] { if let pin { walk(pin.widget, depth: 0, id: name) } }
        return lines.joined(separator: " ; ")
    }

    func resetSolveStats() {
        solveNanoseconds = 0
        worstSolve = 0
        solves = 0
    }
}
