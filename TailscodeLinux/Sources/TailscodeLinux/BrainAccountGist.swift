import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The turn in short on the account's side of an open Megatron: the model's title and sentence,
/// the rail and the stages, standing as pins where the story would be, and a stage's part of the
/// account when one is opened. Every word and number is `NeuralGistPane`'s; this lays them out,
/// keeps which stage the keys are on, and asks the desk for a telling whenever the turn changes.
extension BrainAccount {
    var gistTurnKey: String { (owner.host?.sessionKey ?? "none") + "|" + owner.turnID }

    /// The telling leads the account: its title and sentence stand above everything else.
    var gistLeads: Bool {
        guard let pane = gistPane else { return false }
        let state = owner.model.browseState
        return pane.leads(
            told: gistTold, scope: gistScope, list: state.list, searchOpen: state.searchOpen,
            busy: owner.readoutHoldsBody)
    }

    /// The run of steps the list is the index of: the open stage, where a telling has a pane to
    /// open one in.
    private var gistRange: ClosedRange<Int>? {
        gistPane != nil && owner.currentMetrics.arrangement == .split ? gistScope : nil
    }

    /// Brings the telling to what a press, a key or a filter just did, before anything is drawn
    /// from it. A step chosen while the telling is the cover, or from another stage than the one
    /// open, opens the stage that holds it: a press on a row or a node asks about that step, and
    /// a cover has nowhere to answer. The list is then made the index of the open stage.
    func gistFollowBrowse() {
        let cursor = owner.model.pinnedStep
        defer { gistSeenCursor = cursor }
        if let pane = gistPane, !pane.isWriting, owner.currentMetrics.arrangement == .split, let cursor,
            cursor != gistSeenCursor, gistScope != nil || gistLeads,
            let row = pane.row(holding: cursor, in: owner.model.stepList), row.numbers != gistScope
        {
            gistCursor = row.index
            gistScope = row.numbers
            headerStamp = ""
            readStamp = nil
            scroll = 0
            target = 0
        }
        gistSyncRange()
    }

    /// Makes the list the index of the open stage, or of the whole turn when none is open.
    func gistSyncRange() {
        let range = gistRange
        guard owner.model.stepList.filter.range != range else { return }
        _ = owner.model.browse(.scope(range))
        owner.refreshDimming()
    }

    /// The telling stands in the story's place, stages and all. A narrow account has no room for
    /// that: there the telling only leads, and the story stays under it.
    var showsShort: Bool { gistLeads && owner.currentMetrics.arrangement == .split }

    /// What the header's switcher says, so the header is made again when it changes.
    var gistStamp: String {
        guard let pane = gistPane else { return "" }
        let scope = gistScope.map { "\($0.lowerBound)-\($0.upperBound)" } ?? ""
        return "\(showsShort)|\(scope)|\(fullAccount.utteranceCount)|\(account.utteranceCount)|\(pane.isWriting)"
    }

    func observeGist() {
        let ref = self.ref
        gistObserver = NotificationCenter.default.addObserver(
            forName: NeuralGistDesk.didChange, object: nil, queue: nil
        ) { _ in
            Gtk.onMain { ref.view?.account?.gistChanged() }
        }
        syncGistPane()
    }

    /// Says the turn is on screen as it stands, and takes what the desk holds for it.
    func gistWant() {
        NeuralGistDemo.placeIfNeeded(key: gistTurnKey, model: owner.model)
        NeuralGistDesk.shared.want(
            key: gistTurnKey, model: owner.model, answer: owner.row.answer.isEmpty ? nil : owner.row.answer,
            prompt: owner.row.prompt)
        syncGistPane()
    }

    /// The desk has something new: the pane is read again and the account drawn from it.
    func gistChanged() {
        guard !disposed, syncGistPane() else { return }
        readStamp = nil
        refresh(immediate: true)
        refreshChrome()
    }

    @discardableResult
    func syncGistPane() -> Bool {
        let next = NeuralGistPane.make(reading: NeuralGistDesk.shared.reading(for: gistTurnKey), model: owner.model)
        guard next != gistPane else { return false }
        gistPane = next
        if let next {
            if let scope = gistScope { gistScope = next.row(containing: scope.lowerBound)?.numbers }
            if let cursor = gistCursor { gistCursor = next.rows.isEmpty ? nil : min(cursor, next.rows.count - 1) }
        } else {
            gistScope = nil
            gistCursor = nil
        }
        headerStamp = ""
        return true
    }

    /// The two-part switch in the header: in short, and what it told you with how much of it
    /// is showing. Nil when nothing is told, which leaves the header as it always was.
    func gistSwitcher() -> UnsafeMutablePointer<GtkWidget>? {
        guard let pane = gistPane, owner.currentMetrics.arrangement == .split else { return nil }
        let box = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0, "bn-gs-switch")
        gtk_widget_set_valign(box, GTK_ALIGN_CENTER)
        let short = BrainUI.label("\(NeuralGistWords.mark) \(NeuralGistWords.title)", "bn-gs-seg")
        let total = fullAccount.utteranceCount
        let shown = gistScope == nil ? total : account.utteranceCount
        let told = BrainUI.label(NeuralGistWords.told(shown, of: gistScope == nil ? nil : total), "bn-gs-seg")
        Gtk.addClass(showsShort ? short : told, showsShort ? "bn-gs-seg-short" : "bn-gs-seg-told")
        let ref = self.ref
        BrainUI.clickable(short) { ref.view?.account?.gistShow(short: true) }
        BrainUI.clickable(told) { ref.view?.account?.gistShow(short: false) }
        Tip.set(
            short, NeuralGistWords.provenance(writer: pane.byline, place: ""))
        BrainUI.add(box, short, told)
        return box
    }

    /// The pins a telling adds: its head and its stages while it stands in the story's place, the
    /// way back while a stage is open, and nothing otherwise.
    func refreshGistPins() {
        guard let pane = gistPane, !owner.readoutHoldsBody else {
            setPin(&gistPin, signature: "") { nil }
            setPin(&stagesPin, signature: "") { nil }
            return
        }
        let width = Int(boxWidth)
        let tint = owner.inks.hex.special
        if gistLeads {
            let fallback = fullAccount.vitals(now: Date(), lastActivity: lastActivityAt).counts
            let whole = showsShort
            let head = "short|\(pane.title)|\(pane.now)|\(pane.byline)|\(pane.isWriting)|\(fallback)|\(whole)|\(width)|\(tint)"
            setPin(&gistPin, signature: head) { self.buildGistHead(pane, fallback: fallback, lines: whole ? 3 : 2) }
            guard whole else {
                setPin(&stagesPin, signature: "") { nil }
                return
            }
            let rows = pane.rows.map {
                "\($0.says)\($0.mark)\($0.stepCount)\($0.fixed)\($0.unfixed)\($0.added)\($0.removed)\($0.costWords ?? "")"
            }
            let result = gistResultWords()
            let stages = "stages|\(rows.joined(separator: "|"))|\(gistCursor ?? -1)|\(pane.isWriting)|\(result)|\(width)|\(tint)"
            setPin(&stagesPin, signature: stages) { self.buildGistStages(pane, result: result) }
        } else if let scope = gistScope, let row = pane.row(containing: scope.lowerBound) {
            let crumb = "crumb|\(row.says)|\(row.from)|\(row.to)|\(pane.rows.count)|\(row.fixed)|\(row.unfixed)|\(row.added)|\(row.removed)|\(row.costWords ?? "")|\(width)|\(tint)"
            setPin(&gistPin, signature: crumb) { self.buildGistCrumb(pane, row: row) }
            setPin(&stagesPin, signature: "") { nil }
        } else {
            setPin(&gistPin, signature: "") { nil }
            setPin(&stagesPin, signature: "") { nil }
        }
    }

    /// The step in flight as one line under the telling's sentence, where the whole Now box
    /// would push the stages off the pane.
    func refreshShortNow(ask: Bool, vitals: NeuralAccount.Vitals) {
        var signature = ""
        let live = fullAccount.live
        if !ask, let live {
            signature = "line|\(live.stepID)|\(live.title)|\(live.argument)|\(vitals.isSilent)|\(vitals.lastOutputWords ?? "")|\(vitals.silentWords ?? "")|\(Int(boxWidth))|\(owner.inks.hex.accent)"
        }
        setPin(&nowPin, signature: signature) { live.map { self.buildGistLive($0, vitals: vitals) } }
    }

    private func gistResultWords() -> String { NeuralGistWords.result(of: fullAccount) }

    private func buildGistHead(
        _ pane: NeuralGistPane, fallback: String, lines: Int
    ) -> UnsafeMutablePointer<GtkWidget> {
        let box = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 6, "bn-gs-head")
        let top = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        let title = BrainUI.label(
            "\(NeuralGistWords.mark) \(pane.title.uppercased())", "bn-gs-title", ellipsize: true)
        if pane.isWriting { Gtk.addClass(title, "bn-gs-dim") }
        gtk_label_set_xalign(op(title), 0)
        gtk_widget_set_hexpand(title, 1)
        let byline = BrainUI.label(pane.byline, "bn-gs-by")
        gtk_widget_set_valign(byline, GTK_ALIGN_CENTER)
        Tip.set(byline, NeuralGistWords.provenance(writer: pane.byline, place: ""))
        BrainUI.add(top, title, byline)
        let sentence = BrainUI.label(pane.isWriting ? fallback : pane.now, "bn-gs-now", wrap: true, lines: lines)
        if pane.isWriting { Gtk.addClass(sentence, "bn-gs-dim") }
        gtk_label_set_xalign(op(sentence), 0)
        BrainUI.add(box, top, sentence)
        tailscode_set_accessible_label(
            box, "\(NeuralGistWords.title). \(pane.title). \(pane.now). \(NeuralGistWords.provenance(writer: pane.byline, place: ""))")
        return box
    }

    private func buildGistLive(
        _ live: NeuralAccount.LiveStep, vitals: NeuralAccount.Vitals
    ) -> UnsafeMutablePointer<GtkWidget> {
        let silent = vitals.isSilent
        let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8, "bn-gs-live")
        let label = BrainUI.label(NeuralReading.nowLabel, "bn-now", silent ? "bn-now-attention" : "bn-now-live")
        let title = BrainUI.label(live.title, "bn-gs-live-title")
        let argument = BrainUI.label(live.argument, "bn-now-arg", ellipsize: true)
        gtk_label_set_xalign(op(argument), 0)
        gtk_widget_set_hexpand(argument, 1)
        BrainUI.add(row, nowDot(silent: silent), label, title, argument)
        if silent, let words = vitals.silentWords {
            gtk_box_append(ptr(row), BrainUI.label(words, "bn-now-silence"))
        } else if let words = vitals.lastOutputWords {
            gtk_box_append(ptr(row), BrainUI.label(words, "bn-now-since"))
        }
        tailscode_set_accessible_label(row, "\(NeuralReading.nowLabel). \(live.title)")
        return row
    }

    private func buildGistStages(_ pane: NeuralGistPane, result: String) -> UnsafeMutablePointer<GtkWidget> {
        let box = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-gs-stages")
        gtk_widget_set_focusable(box, 1)
        gtk_widget_set_can_focus(box, 1)
        tailscode_set_accessible_label(box, NeuralGistWords.title)
        gtk_box_append(ptr(box), gistRailCanvas(selected: nil))
        if pane.isWriting {
            for width in [0.62, 0.48, 0.55] {
                let line = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12, "bn-gs-row")
                let mark = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0, "bn-gs-skel", "bn-gs-skel-dot")
                gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
                let bar = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0, "bn-gs-skel")
                gtk_widget_set_size_request(bar, Int32(max(120, boxWidth * width)), 12)
                gtk_widget_set_valign(bar, GTK_ALIGN_CENTER)
                gtk_widget_set_halign(bar, GTK_ALIGN_START)
                BrainUI.add(line, mark, bar)
                gtk_box_append(ptr(box), line)
            }
            return box
        }
        let ref = self.ref
        for row in pane.rows {
            let line = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12, "bn-gs-row")
            if gistCursor == row.index { Gtk.addClass(line, "bn-cursor") }
            let glyph: String
            let markClass: String
            switch row.mark {
            case .done:
                glyph = "\u{2713}"
                markClass = "bn-gs-mark-done"
            case .now:
                glyph = "\u{25CF}"
                markClass = "bn-gs-mark-now"
            }
            let mark = BrainUI.label(glyph, "bn-gs-mark", markClass)
            gtk_label_set_xalign(op(mark), 0.5)
            gtk_label_set_justify(op(mark), GTK_JUSTIFY_CENTER)
            gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
            let says = BrainUI.label(row.says, row.mark == .now ? "bn-gs-says-now" : "bn-gs-says", ellipsize: true)
            gtk_label_set_xalign(op(says), 0)
            gtk_widget_set_hexpand(says, 1)
            BrainUI.add(line, mark, says)
            if row.mark == .now { gtk_box_append(ptr(line), BrainUI.label(NeuralReading.nowLabel, "bn-now", "bn-now-live")) }
            if let words = row.failedWords { gtk_box_append(ptr(line), BrainUI.label(words, "bn-gs-fact", "bn-gs-failed")) }
            if let words = row.fixedWords { gtk_box_append(ptr(line), BrainUI.label(words, "bn-gs-fact", "bn-gs-fixed")) }
            if let tally = row.tally { gtk_box_append(ptr(line), BrainUI.label(tally, "bn-gs-fact")) }
            if let cost = row.costWords {
                let money = BrainUI.label(cost, "bn-gs-fact", "bn-gs-cost")
                gtk_label_set_xalign(op(money), 1)
                gtk_box_append(ptr(line), money)
            }
            let steps = BrainUI.label(row.stepsWords, "bn-gs-fact", "bn-gs-steps")
            gtk_label_set_xalign(op(steps), 1)
            gtk_box_append(ptr(line), steps)
            let index = row.index
            BrainUI.clickable(line) { ref.view?.account?.gistOpen(index) }
            tailscode_set_accessible_label(line, "\(row.says). \(row.facts(of: pane.rows.count))")
            gtk_box_append(ptr(box), line)
        }
        if !result.isEmpty {
            let words = BrainUI.label(result, "bn-gs-result", ellipsize: true)
            gtk_label_set_xalign(op(words), 0)
            gtk_box_append(ptr(box), words)
        }
        return box
    }

    private func buildGistCrumb(_ pane: NeuralGistPane, row: NeuralGistPane.Row) -> UnsafeMutablePointer<GtkWidget> {
        let box = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 2, "bn-gs-crumb")
        gtk_box_append(ptr(box), gistRailCanvas(selected: row.index))
        let line = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let back = BrainUI.label("\u{2039} \(NeuralGistWords.backToShort)", "bn-gs-back")
        let ref = self.ref
        BrainUI.clickable(back) { ref.view?.account?.gistBack() }
        let says = BrainUI.label("\(NeuralGistWords.mark) \(row.says)", "bn-gs-crumb-says", ellipsize: true)
        gtk_label_set_xalign(op(says), 0)
        gtk_widget_set_hexpand(says, 1)
        let facts = BrainUI.label(row.facts(of: pane.rows.count), "bn-gs-fact")
        BrainUI.add(line, back, says, facts)
        gtk_box_append(ptr(box), line)
        return box
    }

    /// The rail: one stretch a stage, as long as its share of the steps, with a tick where an
    /// error was fixed and a taller one where it stayed.
    private func gistRailCanvas(selected: Int?) -> UnsafeMutablePointer<GtkWidget> {
        let holder = RailHolder(ref: ref, selected: selected)
        _ = Gtk.releaseInstalled
        let canvas = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let held = Unmanaged<RailHolder>.fromOpaque(raw).takeUnretainedValue()
                held.ref.view?.account?.paintGistRail(cr, width: Double(width), height: Double(height), selected: held.selected)
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<RailHolder>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(canvas, -1, 22)
        gtk_widget_set_hexpand(canvas, 1)
        gtk_widget_set_can_target(canvas, 0)
        tailscode_set_accessible_hidden(canvas, 1)
        gistRail = Gtk.WeakWidget(canvas)
        return canvas
    }

    final class RailHolder: @unchecked Sendable {
        let ref: WeakBrainView
        let selected: Int?
        init(ref: WeakBrainView, selected: Int?) {
            self.ref = ref
            self.selected = selected
        }
    }

    private func paintGistRail(_ cr: OpaquePointer, width: Double, height: Double, selected: Int?) {
        guard let view = ref.view, let pane = gistPane, width > 4 else { return }
        let inks = view.inks
        let thick = 6.0
        let top = (height - thick) / 2
        guard !pane.rows.isEmpty else {
            BrainDraw.fill(cr, inks.dim, 0.22)
            BrainDraw.roundedRect(cr, 0, top, width, thick, thick / 2)
            cairo_fill(cr)
            return
        }
        let gap = 3.0
        let usable = width - gap * Double(pane.rows.count - 1)
        var x = 0.0
        for row in pane.rows {
            let length = max(4, usable * row.weight)
            if let selected {
                if selected == row.index { BrainDraw.fill(cr, inks.special, 1) } else { BrainDraw.fill(cr, inks.dim, 0.22) }
            } else {
                switch row.mark {
                case .now: BrainDraw.fill(cr, inks.accent, 1)
                case .done: BrainDraw.fill(cr, inks.info, 0.6)
                }
            }
            BrainDraw.roundedRect(cr, x, top, length, thick, thick / 2)
            cairo_fill(cr)
            if selected == nil || selected == row.index {
                for tick in row.ticks {
                    let tall = tick.failed ? 16.0 : 12.0
                    BrainDraw.fill(cr, tick.failed ? inks.cDanger : inks.warn, 1)
                    BrainDraw.roundedRect(cr, x + length * tick.at - 1, (height - tall) / 2, 2, tall, 1)
                    cairo_fill(cr)
                }
            }
            x += length + gap
        }
    }

    /// Switches between the telling and the account: the header's two parts and `i`. Going to
    /// the telling lets go of a filter and a search, which it would otherwise stand behind.
    func gistShow(short: Bool) {
        guard gistPane != nil else { return }
        gistTold = !short
        gistScope = nil
        if short, owner.model.stepList.isNarrowed || owner.model.browseState.searchOpen { owner.clearAllFilters() }
        gistApplied(focusStages: short)
    }

    func gistToggle() {
        guard gistPane != nil else { return }
        gistShow(short: !gistLeads)
    }

    /// Opens a stage: its part of the account as a story, every run of work folded, and the
    /// list beside it the index of its steps. No step is chosen for the person: a cursor opens
    /// the work it stands in and the step's whole detail, which is the far end of the stage and
    /// not its beginning.
    func gistOpen(_ index: Int) {
        guard let pane = gistPane, pane.rows.indices.contains(index) else { return }
        let row = pane.rows[index]
        gistCursor = index
        gistScope = row.numbers
        gistApplied(focusStages: false)
    }

    func gistBack() {
        guard gistScope != nil else { return }
        gistScope = nil
        gistTold = false
        gistApplied(focusStages: true)
    }

    func gistNeighbour(_ delta: Int) {
        guard let pane = gistPane, let scope = gistScope, let row = pane.row(containing: scope.lowerBound),
            let next = pane.index(moving: delta, from: row.index), next != row.index
        else { return }
        gistOpen(next)
    }

    func gistMove(_ delta: Int) {
        guard let pane = gistPane, showsShort, let next = pane.index(moving: delta, from: gistCursor) else { return }
        gistCursor = next
        refreshPins()
        tailscode_brain_row_invalidate(root)
    }

    private func gistApplied(focusStages: Bool) {
        headerStamp = ""
        readStamp = nil
        scroll = 0
        target = 0
        gistSyncRange()
        owner.listScopeChanged()
        refresh(immediate: true)
        refreshChrome()
        if focusStages, let widget = stagesPin?.widget { gtk_widget_grab_focus(widget) } else { gtk_widget_grab_focus(story) }
    }

    /// The telling's keys that work wherever in the Megatron the keys are: `i` switches, and Esc
    /// leaves an open stage once the search, the filters and the cursor are already let go, so
    /// the way back is one rung at a time and the cover comes before the card.
    func gistKeyAnywhere(_ key: NeuralBrowse.Key) -> Bool {
        guard gistPane != nil, owner.currentMetrics.arrangement == .split else { return false }
        if key == .character("i") {
            gistToggle()
            return true
        }
        guard key == .escape, gistScope != nil else { return false }
        let state = owner.model.browseState
        guard !state.legend, !state.searchOpen, !state.list.filter.isChosen, state.cursor == nil else { return false }
        gistBack()
        return true
    }

    /// What a key does to the telling, before the account sees it. False for a key that is the
    /// account's.
    func gistKey(_ key: NeuralBrowse.Key) -> Bool {
        guard gistPane != nil else { return false }
        if gistKeyAnywhere(key) { return true }
        if showsShort {
            switch key {
            case .up, .character("k"): gistMove(-1)
            case .down, .character("j"): gistMove(1)
            case .home: gistMove(-NeuralGistPolicy.mostStages)
            case .end: gistMove(NeuralGistPolicy.mostStages)
            case .enter, .right:
                guard let pane = gistPane, !pane.rows.isEmpty else { return true }
                gistOpen(gistCursor ?? pane.rows.count - 1)
            default: return false
            }
            return true
        }
        guard gistScope != nil else { return false }
        switch key {
        case .character("["): gistNeighbour(-1)
        case .character("]"): gistNeighbour(1)
        default: return false
        }
        return true
    }
}
