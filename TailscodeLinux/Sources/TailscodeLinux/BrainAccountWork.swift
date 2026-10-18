import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A run of the step list's own rows, drawn into the account: one canvas that paints exactly the
/// pixels the list beside the head paints, through the same painter, for the steps of a work line
/// that is unfolded. It owns the pointer's row and the Copy button of the row under it, and
/// nothing else; a press is the list's press.
final class WorkRows: @unchecked Sendable {
    let canvas: UnsafeMutablePointer<GtkWidget>
    let ref: WeakBrainView
    let ids: [String]
    let before: String?
    let after: String?
    private var painter: BrainRowPainter
    private var hoverID: String?
    private var hoverCopy = false
    private var copied: (id: String, until: Double)?
    private var pointer: (x: Double, y: Double)?

    init(owner: BrainView, ids: [String], before: String?, after: String?) {
        ref = WeakBrainView(owner)
        self.ids = ids
        self.before = before
        self.after = after
        painter = BrainRowPainter(fonts: BrainListFonts(), input: owner.currentMetrics.input)
        let holder = Holder()
        _ = Gtk.releaseInstalled
        canvas = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                Unmanaged<Holder>.fromOpaque(raw).takeUnretainedValue().rows?.paint(
                    cr, width: Double(width), height: Double(height))
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<Holder>.fromOpaque(raw).release()
            })!
        holder.rows = self
        gtk_widget_set_size_request(canvas, 40, Int32(totalHeight.rounded()))
        gtk_widget_set_hexpand(canvas, 1)
        Gtk.addClass(canvas, "bn-wrows-canvas")
        tailscode_set_accessible_label(canvas, BrainWords.stepList)
        Gtk.onPointer(
            canvas, move: { [weak self] x, y in self?.moved(x: x, y: y) }, leave: { [weak self] in self?.left() })
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

    private final class Holder: @unchecked Sendable {
        weak var rows: WorkRows?
    }

    private final class ClickBox: @unchecked Sendable {
        let handler: (Double, Double, Int32, Int32) -> Void
        init(_ handler: @escaping (Double, Double, Int32, Int32) -> Void) { self.handler = handler }
    }

    private var list: NeuralStepList? { ref.view?.model.browseState.list }

    private func row(_ id: String) -> NeuralStepList.Row? { list?.row(id: id) }

    private var input: ChatInput { painter.input }

    private func height(of id: String) -> Double {
        row(id)?.height(input: input) ?? painter.rowHeight
    }

    var totalHeight: Double { ids.reduce(0) { $0 + height(of: $1) } }

    private func rowIndex(atY y: Double) -> Int? {
        var top = 0.0
        for (index, id) in ids.enumerated() {
            let h = height(of: id)
            if y >= top, y < top + h { return index }
            top += h
        }
        return nil
    }

    private func top(of index: Int) -> Double {
        ids.prefix(index).reduce(0) { $0 + height(of: $1) }
    }

    private var touch: BrainRowPainter.Touch {
        BrainRowPainter.Touch(
            copiedID: copied.flatMap { BrainClock.now < $0.until ? $0.id : nil },
            copyHotID: hoverCopy ? hoverID : nil)
    }

    func retheme() {
        painter = BrainRowPainter(fonts: BrainListFonts(), input: painter.input)
        gtk_widget_queue_draw(canvas)
    }

    func flashCopied(_ id: String) {
        copied = (id, BrainClock.now + 1)
        gtk_widget_queue_draw(canvas)
        let hold = Gtk.WeakWidget(canvas)
        Gtk.after(1050) { Gtk.onMain { if let raw = hold.widget { gtk_widget_queue_draw(raw) } } }
    }

    func invalidate() { gtk_widget_queue_draw(canvas) }

    private func moved(x: Double, y: Double) {
        pointer = (x, y)
        guard let index = rowIndex(atY: y), let view = ref.view else {
            left()
            return
        }
        let id = ids[index]
        let width = Double(gtk_widget_get_width(canvas))
        let rect = painter.copyRect(for: row(id)!, width: width, touch: touch)
        let top = self.top(of: index)
        let onCopy = x >= rect.x && x <= rect.maxX && y - top >= rect.y && y - top <= rect.maxY
        gtk_widget_set_cursor_from_name(canvas, "pointer")
        let changed = hoverID != id || hoverCopy != onCopy
        hoverID = id
        hoverCopy = onCopy
        if changed {
            gtk_widget_queue_draw(canvas)
            view.hoverStep(id)
        }
    }

    private func left() {
        pointer = nil
        gtk_widget_set_cursor_from_name(canvas, nil)
        guard hoverID != nil else { return }
        hoverID = nil
        hoverCopy = false
        gtk_widget_queue_draw(canvas)
        ref.view?.hoverLeftStep()
    }

    private func clicked(x: Double, y: Double, presses: Int, button: Int) {
        guard let index = rowIndex(atY: y), let view = ref.view else { return }
        let id = ids[index]
        view.dismissLegendOnPress()
        if button == 3 {
            view.browse(.contextMenu(id), grabFocus: false, menuAt: (x, y), menuParent: canvas)
            return
        }
        guard button == 1, let found = row(id) else { return }
        let width = Double(gtk_widget_get_width(canvas))
        let rect = painter.copyRect(for: found, width: width, touch: touch)
        let top = self.top(of: index)
        if x >= rect.x, x <= rect.maxX, y - top >= rect.y, y - top <= rect.maxY, hoverID == id {
            view.copyStep(id)
            return
        }
        view.accountChooseStep(id, fromAccount: true, double: presses >= 2)
    }

    private func paint(_ cr: OpaquePointer, width: Double, height: Double) {
        guard let view = ref.view, !view.disposed, let list else { return }
        let inks = view.inks
        var low = 0.0
        var high = height
        var x1 = 0.0
        var x2 = 0.0
        cairo_clip_extents(cr, &x1, &low, &x2, &high)
        let model = view.model
        let cursor = model.pinnedStep
        let hovered = model.browseState.hovered
        let query = list.filter.query
        var y = 0.0
        for (index, id) in ids.enumerated() {
            guard let found = row(id) else { continue }
            let h = found.height(input: input)
            defer { y += h }
            if y + h < low - 1 { continue }
            if y > high + 1 { break }
            let previous = index > 0 ? row(ids[index - 1]) : before.flatMap { row($0) }
            let next = index + 1 < ids.count ? row(ids[index + 1]) : after.flatMap { row($0) }
            painter.paintRow(
                cr, row: found, previous: previous, next: next, y: y, height: h, width: width, inks: inks,
                isCursor: cursor == id, isHovered: hovered == id && cursor != id, pointerHere: hoverID == id,
                alpha: 1, query: query, touch: touch)
        }
    }
}

extension BrainAccount {

    func buildWork(_ entry: AccountEntry, _ work: AccountEntry.Work, key: String) -> AccountCell {
        let root = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-it", "bn-work")
        let cell = AccountCell(id: entry.id, key: key, widget: root)
        let open = isOpen(entry, work: work)
        if open { Gtk.addClass(root, "bn-open") }
        gtk_box_append(ptr(root), workLine(entry, work, open: open))
        let cards = cardSteps(for: entry, work: work)
        if open {
            gtk_box_append(ptr(root), workRows(entry, work, cards: cards, cell: cell))
        } else {
            for spec in cards {
                gtk_box_append(ptr(root), cardView(spec, cell: cell, hang: true))
            }
        }
        return cell
    }

    /// The fonts a work line measures its parts in, read from labels that wear its classes.
    struct WorkFonts {
        let clause: String
        let failure: String
        let file: String
        let chip: String

        init() {
            func probe(_ css: String) -> String { BrainUI.font(of: BrainUI.label("A", css)) }
            clause = probe("bn-wc")
            failure = probe("bn-wf-text")
            file = probe("bn-wfile")
            chip = probe("bn-sn-text")
        }
    }

    /// Whether a clause is a build, a test run or a lint that passed: the one kind of clause that
    /// wears a check, because those are the ones a result is judged by.
    private func isPassedCheck(_ clause: AccountEntry.Clause) -> Bool {
        guard clause.verdict == .done else { return false }
        return NeuralHuman.CheckKind.allCases.contains { $0.title == clause.text || $0.againTitle == clause.text }
    }

    /// The mark a clause wears after its words: a check for a passed build or test, the retry
    /// arrow in amber for a fixed error, a cross for one that stayed failed, and the verdict's
    /// own mark for a step still in motion. Nothing for plain done.
    private func clauseMark(_ clause: AccountEntry.Clause, fixedSaid: Bool) -> NeuralVerdict.Step? {
        if isPassedCheck(clause) { return .done }
        if clause.verdict == .fixed, fixedSaid { return nil }
        return clause.verdict.isMarked ? clause.verdict : nil
    }

    /// What a work line says in the room it has: the zone marks first, then the work as clauses
    /// in plain words, each wearing its verdict where it has one, the fixed and failed errors
    /// after, the file last, and "+N more" for what did not fit.
    private func workLine(_ entry: AccountEntry, _ work: AccountEntry.Work, open: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let line = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 14, "bn-wl")
        let inks = owner.inks
        let fonts = workFonts
        let chevron = BrainUI.label(open ? "\u{25BE}" : "\u{25B8}", "bn-wl-chev")
        gtk_widget_set_size_request(chevron, 10, -1)
        gtk_box_append(ptr(line), chevron)
        let chipText = BrainWords.stepRange(work.numbers)
        let target = work.chipStepID ?? work.firstStepID
        let chip = stepChip(chipText, stepID: target)
        func minimum(_ widget: UnsafeMutablePointer<GtkWidget>) -> Double {
            var least: Int32 = 0
            var natural: Int32 = 0
            gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, &least, &natural, nil, nil)
            return Double(least)
        }
        let gap = 14.0
        var room = boxWidth - 2 - 22 - 10 - minimum(chip) - gap * 4 - 4
        let markBox = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 4, "bn-wms")
        for zone in work.zones {
            let glyph = BrainUI.shapeGlyph(zone, size: 18) { inks.corrected(zone) }
            tailscode_set_accessible_label(glyph, zone.displayLabel)
            gtk_box_append(ptr(markBox), glyph)
        }
        gtk_box_append(ptr(line), markBox)
        room -= minimum(markBox)

        var summaries: [(words: String, verdict: NeuralVerdict.Step)] = []
        if work.fixedCount > 0 {
            let words = work.fixedCount == 1
                ? (work.fixedWords.first ?? BrainWords.fixedErrors(1)) : BrainWords.fixedErrors(work.fixedCount)
            summaries.append((words, .fixed))
        }
        if work.unfixedCount > 0 { summaries.append((BrainWords.failedCount(work.unfixedCount), .failed)) }
        func markWidth(_ verdict: NeuralVerdict.Step?) -> Double { verdict == nil ? 0 : 6 + 14 }
        summaries = summaries.filter { item in
            let whole = gap + 14 + 6 + BrainDraw.measure(item.words, fonts.failure)
            guard whole <= room * 0.5 else { return false }
            room -= whole
            return true
        }

        let clauseBox = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0, "bn-wcs")
        var taken = 0
        var used = 0.0
        let moreReserve = BrainDraw.measure(BrainWords.moreClauses(99), fonts.clause) + 20
        for clause in work.clauses {
            let mark = clauseMark(clause, fixedSaid: summaries.contains { $0.verdict == .fixed })
            let width = BrainDraw.measure(clause.text, fonts.clause) + markWidth(mark) + (taken == 0 ? 0 : 20)
            let remaining = work.clauses.count - taken - 1 + work.more
            let reserve = remaining > 0 ? moreReserve : 0
            if used + width + reserve > room { break }
            if taken > 0 { gtk_box_append(ptr(clauseBox), BrainUI.label("\u{00B7}", "bn-wc-dot")) }
            let item = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6, "bn-wc-item")
            let label = BrainUI.label(clause.text, "bn-wc")
            gtk_widget_set_hexpand(label, 0)
            gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_END)
            if taken == 0 { gtk_label_set_max_width_chars(op(label), 48) }
            gtk_box_append(ptr(item), label)
            var spoken = clause.text
            if let mark {
                gtk_box_append(ptr(item), BrainUI.verdictGlyph(mark, size: 14, inks: inks))
                spoken += ", " + mark.word.lowercased()
            }
            tailscode_set_accessible_label(item, spoken)
            gtk_box_append(ptr(clauseBox), item)
            used += width
            taken += 1
        }
        let hidden = work.clauses.count - taken + work.more
        if hidden > 0, room - used >= moreReserve - 6 {
            if taken > 0 { gtk_box_append(ptr(clauseBox), BrainUI.label("\u{00B7}", "bn-wc-dot")) }
            gtk_box_append(ptr(clauseBox), BrainUI.label(BrainWords.moreClauses(hidden), "bn-wc-more"))
        }
        gtk_box_append(ptr(line), clauseBox)
        for item in summaries where item.words.isEmpty == false {
            let box = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6, "bn-wf")
            gtk_box_append(ptr(box), BrainUI.verdictGlyph(item.verdict, size: 14, inks: inks))
            let label = BrainUI.label(item.words, item.verdict == .failed ? "bn-wf-text bn-wf-failed" : "bn-wf-text bn-wf-fixed")
            gtk_widget_set_hexpand(label, 0)
            gtk_box_append(ptr(box), label)
            tailscode_set_accessible_label(box, item.words)
            gtk_box_append(ptr(line), box)
        }
        gtk_box_append(ptr(line), BrainUI.spacer())
        gtk_box_append(ptr(line), chip)
        gtk_widget_set_cursor_from_name(line, "pointer")
        let id = entry.id
        let ref = self.ref
        Gtk.onPrimaryRelease(line) { Gtk.onMain { ref.view?.accountToggleWork(id) } }
        tailscode_set_accessible_label(line, work.clauses.map(\.text).joined(separator: ", "))
        return line
    }

    /// The work's steps as the list's own rows, with the card of a chosen step open right under
    /// its row, and a line that raises the cap on a work too long to draw whole.
    private func workRows(
        _ entry: AccountEntry, _ work: AccountEntry.Work, cards: [CardSpec], cell: AccountCell
    ) -> UnsafeMutablePointer<GtkWidget> {
        let frame = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-wrows")
        let ids = work.stepIDs
        var cap = min(ids.count, rowCap(entry.id))
        for spec in cards {
            if let at = ids.firstIndex(of: spec.id) { cap = max(cap, min(ids.count, at + 1)) }
        }
        let shown = Array(ids.prefix(cap))
        let ordered = cards.compactMap { spec in shown.firstIndex(of: spec.id).map { ($0, spec) } }.sorted { $0.0 < $1.0 }
        var start = 0
        func segment(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            let part = Array(shown[range])
            let before = range.lowerBound > 0 ? shown[range.lowerBound - 1] : nil
            let after = range.upperBound < shown.count ? shown[range.upperBound] : nil
            let rows = WorkRows(owner: owner, ids: part, before: before, after: after)
            cell.rows.append(rows)
            gtk_box_append(ptr(frame), rows.canvas)
        }
        for (index, spec) in ordered {
            segment(start..<(index + 1))
            gtk_box_append(ptr(frame), cardView(spec, cell: cell, hang: true))
            start = index + 1
        }
        segment(start..<shown.count)
        if cap < ids.count {
            let remaining = ids.count - cap
            let id = entry.id
            let ref = self.ref
            let more = cap >= Self.rowMax
                ? BrainUI.label(Localized.text("%lld more steps are in the list", remaining), "bn-fact")
                : BrainUI.link(BrainWords.moreSteps(min(remaining, Self.rowStride))) {
                    ref.view?.accountMoreRows(id)
                }
            gtk_widget_set_margin_start(more, 14)
            gtk_widget_set_margin_top(more, 6)
            gtk_widget_set_margin_bottom(more, 4)
            gtk_box_append(ptr(frame), more)
        }
        return frame
    }


    /// The step's card in place: what the readout used to say about it, under its row. A step
    /// that is running gets the compact one, with the output tail and a caret, because the note
    /// above it already says why.
    func cardView(_ spec: CardSpec, cell: AccountCell, hang: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let model = owner.model
        let metrics = owner.currentMetrics
        guard let readout = owner.readout, let step = model.step(id: spec.id) else {
            return gtk_label_new("")!
        }
        let page = BrainReadout.Page()
        _ = Gtk.releaseInstalled
        g_object_set_data_full(
            ptr(page.root), "bn-page", Unmanaged.passRetained(page).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<BrainReadout.Page>.fromOpaque(raw).release()
            })
        Gtk.addClass(page.root, "bn-dcard")
        if spec.preview { Gtk.addClass(page.root, "bn-dcard-preview") }
        if spec.live { Gtk.addClass(page.root, "bn-dcard-live") }
        if !hang { Gtk.addClass(page.root, "bn-dcard-flat") }
        gtk_scrolled_window_set_policy(op(page.scroller), GTK_POLICY_NEVER, GTK_POLICY_NEVER)
        gtk_scrolled_window_set_propagate_natural_height(op(page.scroller), 1)
        gtk_widget_set_vexpand(page.scroller, 0)
        gtk_widget_set_vexpand(page.overlay, 0)
        gtk_widget_set_vexpand(page.root, 0)
        gtk_widget_set_size_request(page.header, -1, spec.live ? 32 : 36)
        gtk_widget_set_size_request(page.foot, -1, 28)
        readout.applyZone(step.zone, to: page)
        let lines = metrics.outputLinesShown
        if spec.live {
            let value = NeuralReadout.make(
                model: model, subject: .now, now: Date(), tz: .current, clock: BrainClock.now,
                answer: nil, outputLines: lines)
            if case .now(let now) = value.body, let running = now.step {
                readout.header(for: running.header, to: page)
                readout.buildStep(
                    BrainReadout.StepParts(
                        stepID: running.stepID, header: running.header, subject: running.subject,
                        relations: [], why: nil, result: nil, facts: running.facts), in: page)
                appendTail(now.tail, to: page, readout: readout)
                readout.footFacts(running.facts, in: page, right: running.facts.started)
            }
        } else {
            let value = NeuralReadout.make(
                model: model, subject: .step(spec.id), now: Date(), tz: .current, clock: BrainClock.now,
                answer: nil, outputLines: lines)
            if case .step(let parts) = value.body {
                readout.header(for: parts.header, to: page)
                readout.buildStep(BrainReadout.StepParts(parts), in: page)
                readout.footFacts(parts.facts, in: page)
            }
        }
        gtk_widget_set_visible(page.fade, 0)
        cell.pages.append((spec.id, page))
        if !spec.preview { cell.cursorPage = page }
        return page.root
    }

    /// The last lines a running call printed, in the output box with a caret at the end.
    private func appendTail(_ tail: NeuralReadout.Tail, to page: BrainReadout.Page, readout: BrainReadout) {
        guard !tail.lines.isEmpty else { return }
        let box = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 6, "bn-sec")
        let head = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let label = BrainUI.label(BrainWords.output, "bn-label")
        let right = BrainUI.label(BrainWords.lastLines(tail.lines.count), "bn-label-right")
        gtk_label_set_xalign(op(right), 1)
        BrainUI.add(head, label, BrainUI.spacer(), right)
        gtk_box_append(ptr(box), head)
        let framed = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-out-box")
        let text = BrainUI.markup(
            readout.tailMarkup(tail.lines.map { ($0.text, $0.tone) }, caret: true), "bn-out", selectable: true)
        gtk_box_append(ptr(framed), text)
        gtk_box_append(ptr(box), framed)
        gtk_box_append(ptr(page.body), box)
    }

    /// Folds or unfolds the output of the card under the cursor, when there is one.
    func toggleCardOutput() -> Bool {
        for (_, cell) in cells {
            if let toggle = cell.cursorPage?.subject?.toggleOutput {
                toggle()
                return true
            }
        }
        return false
    }


    func buildAsk(_ ask: NeuralAccount.Ask) -> UnsafeMutablePointer<GtkWidget> {
        let card = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-ask-card")
        let hex = owner.inks.hex
        let head = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, "bn-ask-head")
        let dot = askDot()
        let label = BrainUI.label(BrainWords.needsYou, "bn-now", "bn-now-attention")
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        let step = owner.model.step(id: ask.stepID)
        var meta = step.map { $0.zone.displayLabel } ?? ""
        if let clock = step?.at.map({ NeuralReading.clock($0) }) {
            meta += (meta.isEmpty ? "" : " \u{00B7} ") + Localized.text("waiting since %@", clock)
        }
        let right = BrainUI.label(meta, "bn-counter", ellipsize: true)
        gtk_widget_set_hexpand(right, 1)
        gtk_label_set_xalign(op(right), 1)
        BrainUI.add(head, dot, label, right)
        gtk_box_append(ptr(card), head)
        let words = ask.why?.text ?? ask.sentence
        let say = BrainUI.label(words, "bn-said-text", wrap: true, selectable: true)
        gtk_widget_set_margin_top(say, 8)
        gtk_box_append(ptr(card), say)
        if ask.subjectKind == .command, !ask.subject.isEmpty {
            let box = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8, "bn-ask-cmd")
            let prompt = BrainUI.markup("<span foreground=\"\(hex.warn)\">$</span>", "bn-cmd", wrap: false)
            gtk_widget_set_hexpand(prompt, 0)
            gtk_widget_set_valign(prompt, GTK_ALIGN_START)
            let command = BrainUI.label(ask.subject, "bn-cmd", wrap: true, selectable: true)
            BrainUI.add(box, prompt, command)
            gtk_widget_set_margin_top(box, 10)
            gtk_box_append(ptr(card), box)
        } else if !ask.subject.isEmpty, ask.subject != words {
            let question = BrainUI.label(ask.subject, "bn-ask-title", wrap: true, selectable: true)
            gtk_widget_set_margin_top(question, 8)
            gtk_box_append(ptr(card), question)
        }
        if !ask.options.isEmpty {
            let chips = ask.options.map { option -> UnsafeMutablePointer<GtkWidget> in
                let chip = BrainUI.label(option, "bn-ask-option")
                return chip
            }
            let row = Gtk.wrapRow(chips, spacing: 6)
            gtk_widget_set_margin_top(row, 10)
            gtk_box_append(ptr(card), row)
        }
        let buttons = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_margin_top(buttons, 12)
        let ref = self.ref
        let go = Gtk.button(ask.actionLabel + " \u{2193}", css: ["bn-ask-button"]) {
            Gtk.onMain { ref.view?.accountGoToAsk() }
        }
        let show = Gtk.button(BrainWords.showStep(ask.number), css: ["bn-ask-ghost"]) {
            Gtk.onMain { ref.view?.accountChooseStep(ask.stepID, fromAccount: false) }
        }
        for button in [go, show] { gtk_widget_set_cursor_from_name(button, "pointer") }
        BrainUI.add(buttons, go, show)
        gtk_box_append(ptr(card), buttons)
        tailscode_set_accessible_label(card, "\(BrainWords.needsYou). \(words)")
        return card
    }

    private func askDot() -> UnsafeMutablePointer<GtkWidget> {
        let box = Unmanaged.passRetained(AskDot(ref: ref)).toOpaque()
        _ = Gtk.releaseInstalled
        let dot = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let held = Unmanaged<AskDot>.fromOpaque(raw).takeUnretainedValue()
                guard let view = held.ref.view else { return }
                let still = BrainBudget.reduceMotion
                let level = still ? 1 : NeuralMotion.heartbeat.level(at: BrainClock.now)
                let floor = 0.42
                let swing = still ? 1 : (level - floor) / (1 - floor)
                let color = view.inks.warn
                cairo_new_path(cr)
                cairo_arc(cr, Double(width) / 2, Double(height) / 2, 3.2 * (0.9 + 0.25 * swing), 0, 2 * .pi)
                cairo_set_source_rgba(cr, color.red, color.green, color.blue, still ? 1 : level)
                cairo_fill(cr)
            }, box,
            { raw in
                guard let raw else { return }
                Unmanaged<AskDot>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(dot, 10, 10)
        gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(dot, 0)
        tailscode_set_accessible_hidden(dot, 1)
        askDotWidget = Gtk.WeakWidget(dot)
        return dot
    }

    private final class AskDot: @unchecked Sendable {
        let ref: WeakBrainView
        init(ref: WeakBrainView) { self.ref = ref }
    }

    func tickPulses() {
        if let dot = askDotWidget?.widget { gtk_widget_queue_draw(dot) }
        if let dot = nowDotWidget?.widget { gtk_widget_queue_draw(dot) }
    }
}
