import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The entity's window besides the story: who it is and how it is getting on, what it was asked,
/// what it plans, what it is doing this second, and what came of it. Every word and every verdict
/// is Core's (`NeuralAccount.header`, `vitals`, `asked`, `plan`, `result`, `live`); this decides
/// which widget says it. Amber and red are never told apart by colour alone: each carries its own
/// glyph and its own word.
extension BrainAccount {

    /// The step verdict whose mark stands for a turn's: a done turn wears the check, one that
    /// waits the pause bars, one that works the dot, a stuck one the dashed clock.
    static func stepVerdict(for turn: NeuralVerdict.Turn) -> NeuralVerdict.Step {
        switch turn {
        case .done, .doneAfterRetries: return .done
        case .needsYou: return .waiting
        case .working: return .running
        case .stuck: return .stalled
        case .stopped, .didntAnswer: return .stopped
        case .failed: return .failed
        }
    }

    static func toneClass(_ tone: NeuralTone) -> String {
        switch tone {
        case .live, .identity: return "bn-chip-live"
        case .attention: return "bn-chip-attention"
        case .danger: return "bn-chip-danger"
        case .quiet: return "bn-chip-quiet"
        }
    }


    /// The header made again when what it says or the room it has changed: the model's dot, name
    /// and effort, the verdict's pill with its glyph, the sentence (the amber clause carries the
    /// retry arrow), and the counts at the right, or on a second line in a narrow window.
    func refreshEntityHeader() {
        let narrow = owner.currentMetrics.arrangement == .accordion
        let header = account.header
        let vitals = account.vitals(now: Date(), lastActivity: lastActivityAt)
        let stamp = [
            header.speaker, header.pillWord, vitals.sentence, vitals.counts, "\(header.verdict)", "\(narrow)",
            "\(header.face.effort)", header.clause ?? "", owner.inks.hex.accent, filterWord ?? "",
        ].joined(separator: "|")
        guard stamp != headerStamp else { return }
        headerStamp = stamp
        headerWasNarrow = narrow
        Gtk.removeChildren(of: headerBox)
        let inks = owner.inks
        let identity = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8, "bn-ent-who")
        identity.addDot(for: header.family, inks: inks, owner: self)
        gtk_box_append(ptr(identity), BrainUI.label(header.speaker, "bn-ent-name"))
        gtk_box_append(ptr(identity), effortBars(header.face, inks: inks))
        let pill = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6, "bn-chip", Self.toneClass(header.tone), "bn-ent-pill")
        gtk_box_append(ptr(pill), BrainUI.verdictGlyph(Self.stepVerdict(for: header.verdict), size: 12, inks: inks))
        gtk_box_append(ptr(pill), BrainUI.label(header.pillWord.uppercased(), "bn-ent-pill-word"))
        gtk_widget_set_valign(pill, GTK_ALIGN_CENTER)
        let sentence = sentenceBox(header: header, vitals: vitals, inks: inks)
        let counts = BrainUI.label(vitals.counts, "bn-ac-count", ellipsize: true)
        gtk_label_set_xalign(op(counts), 1)
        gtk_widget_set_valign(counts, GTK_ALIGN_CENTER)
        if narrow {
            let top = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
            BrainUI.add(top, identity, pill)
            if let word = filterWord { gtk_box_append(ptr(top), filteredChipDetached(word)) }
            let second = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
            gtk_widget_set_hexpand(sentence, 1)
            BrainUI.add(second, sentence)
            gtk_label_set_xalign(op(counts), 0)
            let column = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
            BrainUI.add(column, top, second, counts)
            gtk_widget_set_hexpand(column, 1)
            gtk_box_append(ptr(headerBox), column)
        } else {
            gtk_widget_set_hexpand(sentence, 1)
            gtk_widget_set_hexpand(counts, 0)
            gtk_box_append(ptr(headerBox), identity)
            gtk_box_append(ptr(headerBox), pill)
            gtk_box_append(ptr(headerBox), sentence)
            if let word = filterWord { gtk_box_append(ptr(headerBox), filteredChipDetached(word)) }
            gtk_box_append(ptr(headerBox), counts)
        }
        tailscode_set_accessible_label(
            headerBox, "\(header.speaker), \(header.pillWord), \(vitals.sentence), \(vitals.counts)")
        tailscode_brain_row_invalidate(root)
    }

    private func filteredChipDetached(_ word: String) -> UnsafeMutablePointer<GtkWidget> {
        let chip = BrainUI.label(word, "bn-chip", "bn-chip-attention")
        gtk_widget_set_valign(chip, GTK_ALIGN_CENTER)
        return chip
    }

    private func sentenceBox(header: NeuralAccount.Header, vitals: NeuralAccount.Vitals, inks: BrainInks)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let box = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6, "bn-ent-sentence")
        gtk_widget_set_valign(box, GTK_ALIGN_CENTER)
        if !header.isRunning, let clause = header.clause {
            let elapsed = vitals.elapsedWords.map { Localized.text("in %@", $0) }
            if let elapsed {
                gtk_box_append(ptr(box), BrainUI.label(elapsed + " \u{00B7}", "bn-ent-time", ellipsize: true))
            }
            gtk_box_append(ptr(box), BrainUI.verdictGlyph(.fixed, size: 13, inks: inks))
            gtk_box_append(ptr(box), BrainUI.label(clause, "bn-ent-clause", ellipsize: true))
        } else {
            let tone = header.verdict == .needsYou || header.verdict == .stuck ? "bn-ent-warn" : "bn-ent-time"
            gtk_box_append(ptr(box), BrainUI.label(vitals.sentence, tone, ellipsize: true))
        }
        return box
    }

    /// The effort the turn ran at: five bars of rising height, lit up to its level, hollow when
    /// the server chose, a rainbow for a power.
    private func effortBars(_ face: NeuralFace, inks: BrainInks) -> UnsafeMutablePointer<GtkWidget> {
        let holder = BarsBox(face: face, inks: inks)
        _ = Gtk.releaseInstalled
        let bars = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let box = Unmanaged<BarsBox>.fromOpaque(raw).takeUnretainedValue()
                let heights = [4.0, 6.5, 9.0, 11.0, 12.0]
                for (index, h) in heights.enumerated() {
                    let x = Double(index) * 5
                    let lit = index < box.face.effort
                    var color = box.inks.ink
                    if box.face.rainbow {
                        let hue = Double(index) / 5
                        color = (0.5 + 0.5 * cos(2 * .pi * (hue + 0.0)), 0.5 + 0.5 * cos(2 * .pi * (hue + 0.33)), 0.5 + 0.5 * cos(2 * .pi * (hue + 0.67)))
                    } else if box.face.ember { color = box.inks.warn }
                    BrainDraw.roundedRect(cr, x, Double(height) - h, 3, h, 1.2)
                    if box.face.hollow {
                        BrainDraw.fill(cr, box.inks.dim, 0.7)
                        cairo_set_line_width(cr, 1)
                        cairo_stroke(cr)
                    } else {
                        BrainDraw.fill(cr, lit || box.face.rainbow ? color : box.inks.dim, lit || box.face.rainbow ? 1 : 0.32)
                        cairo_fill(cr)
                    }
                    _ = width
                }
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<BarsBox>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(bars, 24, 12)
        gtk_widget_set_valign(bars, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(bars, 0)
        tailscode_set_accessible_hidden(bars, 1)
        return bars
    }

    final class BarsBox: @unchecked Sendable {
        let face: NeuralFace
        let inks: BrainInks
        init(face: NeuralFace, inks: BrainInks) {
            self.face = face
            self.inks = inks
        }
    }


    /// The step in flight, under the header: its plain title, its argument, the last lines it
    /// printed with a caret and how long since it last spoke. After 40 seconds of silence it turns
    /// to the attention tone and says so.
    func buildNow(_ live: NeuralAccount.LiveStep, vitals: NeuralAccount.Vitals) -> UnsafeMutablePointer<GtkWidget> {
        let inks = owner.inks
        let silent = vitals.isSilent
        let box = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-now-box")
        if silent { Gtk.addClass(box, "bn-now-silent") }
        let head = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let dot = nowDot(silent: silent)
        let label = BrainUI.label(NeuralReading.nowLabel, "bn-now", silent ? "bn-now-attention" : "bn-now-live")
        let title = BrainUI.label(live.title, "bn-now-title", ellipsize: true)
        gtk_widget_set_hexpand(title, 1)
        BrainUI.add(head, dot, label, title)
        let right = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        if silent, let words = vitals.silentWords {
            gtk_box_append(ptr(right), BrainUI.verdictGlyph(.stalled, size: 12, inks: inks))
            gtk_box_append(ptr(right), BrainUI.label(words, "bn-now-silence"))
        } else if let words = vitals.lastOutputWords {
            gtk_box_append(ptr(right), BrainUI.label(words, "bn-now-since"))
        }
        gtk_box_append(ptr(head), right)
        gtk_box_append(ptr(box), head)
        if !live.argument.isEmpty {
            let argument = BrainUI.label(live.argument, "bn-now-arg", ellipsize: true)
            gtk_widget_set_margin_top(argument, 4)
            gtk_box_append(ptr(box), argument)
        }
        let tail = Array(live.tail.suffix(2))
        if !tail.isEmpty, let readout = owner.readout {
            let framed = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-out-box", "bn-now-tail")
            let markup = BrainUI.markup(
                readout.tailMarkup(tail.map { ($0.text, $0.tone) }, caret: true), "bn-out", wrap: true)
            gtk_widget_set_margin_top(framed, 6)
            gtk_box_append(ptr(framed), markup)
            gtk_box_append(ptr(box), framed)
        }
        tailscode_set_accessible_label(box, "\(NeuralReading.nowLabel). \(live.title)")
        return box
    }

    /// The Now line's dot: breathing while it works, still when it is silent.
    private func nowDot(silent: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let holder = NowDot(ref: ref, silent: silent)
        _ = Gtk.releaseInstalled
        let dot = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let held = Unmanaged<NowDot>.fromOpaque(raw).takeUnretainedValue()
                guard let view = held.ref.view else { return }
                let still = BrainBudget.reduceMotion || held.silent
                let level = still ? 1 : NeuralMotion.breath.level(at: BrainClock.now)
                let color = held.silent ? view.inks.warn : view.inks.accent
                cairo_new_path(cr)
                cairo_arc(cr, Double(width) / 2, Double(height) / 2, 3.4 * (still ? 1 : 0.9 + 0.2 * level), 0, 2 * .pi)
                cairo_set_source_rgba(cr, color.red, color.green, color.blue, still ? 1 : level)
                cairo_fill(cr)
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<NowDot>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(dot, 10, 10)
        gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(dot, 0)
        tailscode_set_accessible_hidden(dot, 1)
        nowDotWidget = Gtk.WeakWidget(dot)
        return dot
    }

    final class NowDot: @unchecked Sendable {
        let ref: WeakBrainView
        let silent: Bool
        init(ref: WeakBrainView, silent: Bool) {
            self.ref = ref
            self.silent = silent
        }
    }


    /// The agent's own task list as a block: its header with how many are done and a four point
    /// bar, and below it each item with its state. A finished plan folds to its header; a running
    /// turn's plan compacts to segments and the item in progress when the Now line is up.
    func buildPlan(_ plan: NeuralAccount.Plan, entryID: String?, compact: Bool, open: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let inks = owner.inks
        let block = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-plan")
        let head = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, "bn-plan-head")
        let showItems = open && !compact
        gtk_box_append(ptr(head), BrainUI.label(showItems ? "\u{25BE}" : "\u{25B8}", "bn-wl-chev"))
        gtk_box_append(ptr(head), BrainUI.label(Localized.text("PLAN"), "bn-label"))
        gtk_box_append(ptr(head), BrainUI.label(plan.label, "bn-plan-count"))
        let fraction = plan.total == 0 ? 0 : Double(plan.done) / Double(plan.total)
        if compact {
            gtk_box_append(ptr(head), planSegments(plan, inks: inks))
            if let current = plan.current {
                gtk_box_append(ptr(head), BrainUI.verdictGlyph(.running, size: 10, inks: inks))
                gtk_box_append(ptr(head), BrainUI.label(current.activeForm ?? current.text, "bn-plan-current", ellipsize: true))
            }
        } else {
            gtk_box_append(ptr(head), planBar(fraction, inks: inks))
        }
        gtk_box_append(ptr(block), head)
        if showItems {
            let list = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-plan-items")
            for item in plan.items.prefix(24) {
                let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, "bn-plan-row")
                gtk_box_append(ptr(row), planMark(item.state, inks: inks))
                let text = BrainUI.label(
                    item.isCurrent ? (item.activeForm ?? item.text) : item.text,
                    item.state == .done ? "bn-plan-done" : (item.isCurrent ? "bn-plan-now" : "bn-plan-todo"),
                    wrap: true)
                gtk_box_append(ptr(row), text)
                gtk_box_append(ptr(list), row)
            }
            if plan.items.count > 24 {
                gtk_box_append(ptr(list), BrainUI.label(Localized.text("+%lld more", plan.items.count - 24), "bn-fact"))
            }
            gtk_box_append(ptr(block), list)
        }
        gtk_widget_set_cursor_from_name(block, "pointer")
        let ref = self.ref
        let entryID = entryID
        Gtk.onPrimaryRelease(head) { Gtk.onMain { ref.view?.accountTogglePlan(entryID) } }
        tailscode_set_accessible_label(block, "\(Localized.text("PLAN")) \(plan.label)")
        return block
    }

    private func planMark(_ state: NeuralAccount.PlanState, inks: BrainInks) -> UnsafeMutablePointer<GtkWidget> {
        let holder = PlanMarkBox(state: state, inks: inks)
        _ = Gtk.releaseInstalled
        let mark = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let box = Unmanaged<PlanMarkBox>.fromOpaque(raw).takeUnretainedValue()
                let cx = Double(width) / 2
                let cy = Double(height) / 2
                switch box.state {
                case .done: BrainDraw.check(cr, cx: cx, cy: cy, size: 12, color: box.inks.accent, alpha: 1)
                case .inProgress:
                    BrainDraw.dot(cr, cx: cx, cy: cy, radius: 4, color: box.inks.accent, alpha: 1)
                case .pending:
                    cairo_new_path(cr)
                    cairo_arc(cr, cx, cy, 3.6, 0, 2 * .pi)
                    BrainDraw.fill(cr, box.inks.dim, 0.8)
                    cairo_set_line_width(cr, 1.3)
                    cairo_stroke(cr)
                }
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<PlanMarkBox>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(mark, 16, 16)
        gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(mark, 0)
        tailscode_set_accessible_hidden(mark, 1)
        return mark
    }

    final class PlanMarkBox: @unchecked Sendable {
        let state: NeuralAccount.PlanState
        let inks: BrainInks
        init(state: NeuralAccount.PlanState, inks: BrainInks) {
            self.state = state
            self.inks = inks
        }
    }

    private func planBar(_ fraction: Double, inks: BrainInks) -> UnsafeMutablePointer<GtkWidget> {
        let holder = FractionBox(fraction: fraction, inks: inks)
        _ = Gtk.releaseInstalled
        let bar = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let box = Unmanaged<FractionBox>.fromOpaque(raw).takeUnretainedValue()
                let h = Double(height)
                BrainDraw.roundedRect(cr, 0, 0, Double(width), h, h / 2)
                BrainDraw.fill(cr, BrainInks.mix(box.inks.canvas, box.inks.accent, 0.16), 1)
                cairo_fill(cr)
                if box.fraction > 0 {
                    BrainDraw.roundedRect(cr, 0, 0, max(h, Double(width) * box.fraction), h, h / 2)
                    BrainDraw.fill(cr, box.inks.accent, 1)
                    cairo_fill(cr)
                }
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<FractionBox>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(bar, 160, 4)
        gtk_widget_set_valign(bar, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(bar, 0)
        tailscode_set_accessible_hidden(bar, 1)
        return bar
    }

    final class FractionBox: @unchecked Sendable {
        let fraction: Double
        let inks: BrainInks
        init(fraction: Double, inks: BrainInks) {
            self.fraction = fraction
            self.inks = inks
        }
    }

    private func planSegments(_ plan: NeuralAccount.Plan, inks: BrainInks) -> UnsafeMutablePointer<GtkWidget> {
        let holder = SegmentsBox(states: plan.items.map(\.state), inks: inks)
        _ = Gtk.releaseInstalled
        let bar = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let box = Unmanaged<SegmentsBox>.fromOpaque(raw).takeUnretainedValue()
                let count = max(1, box.states.count)
                let gap = 3.0
                let w = (Double(width) - gap * Double(count - 1)) / Double(count)
                for (index, state) in box.states.enumerated() {
                    BrainDraw.roundedRect(cr, Double(index) * (w + gap), 0, w, 4, 2)
                    switch state {
                    case .done: BrainDraw.fill(cr, box.inks.accent, 1)
                    case .inProgress: BrainDraw.fill(cr, box.inks.accent, 0.6)
                    case .pending: BrainDraw.fill(cr, BrainInks.mix(box.inks.canvas, box.inks.dim, 0.4), 1)
                    }
                    cairo_fill(cr)
                }
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<SegmentsBox>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(bar, Int32(min(110, max(40, plan.items.count * 16))), 4)
        gtk_widget_set_valign(bar, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(bar, 0)
        tailscode_set_accessible_hidden(bar, 1)
        return bar
    }

    final class SegmentsBox: @unchecked Sendable {
        let states: [NeuralAccount.PlanState]
        let inks: BrainInks
        init(states: [NeuralAccount.PlanState], inks: BrainInks) {
            self.states = states
            self.inks = inks
        }
    }


    func buildAsked(_ entry: AccountEntry, _ asked: NeuralAccount.Asked, key: String) -> AccountCell {
        let root = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 2, "bn-it", "bn-asked")
        gtk_box_append(ptr(root), BrainUI.label(Localized.text("ASKED"), "bn-label"))
        let expanded = expandedText.contains(entry.id)
        let measure = max(120, min(proseProbe.em * 36, boxWidth - 8))
        let holder = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_halign(holder, GTK_ALIGN_START)
        gtk_widget_set_size_request(holder, Int32(measure.rounded()), -1)
        let text = BrainUI.label(asked.text, "bn-asked-text", wrap: true, selectable: true)
        if !expanded { gtk_label_set_lines(op(text), 2) }
        if !expanded { gtk_label_set_ellipsize(op(text), PANGO_ELLIPSIZE_END) }
        gtk_box_append(ptr(holder), text)
        gtk_box_append(ptr(root), holder)
        let cell = AccountCell(id: entry.id, key: key, widget: root)
        cell.holders.append((holder, 8))
        cell.holdersWidth = boxWidth
        gtk_label_set_lines(op(text), 0)
        gtk_label_set_ellipsize(op(text), PANGO_ELLIPSIZE_NONE)
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(text, GTK_ORIENTATION_VERTICAL, Int32(measure), &minimum, &natural, nil, nil)
        let lines = Int((Double(natural) / max(1, askedLine)).rounded())
        if lines > 2, !expanded {
            gtk_label_set_lines(op(text), 2)
            gtk_label_set_ellipsize(op(text), PANGO_ELLIPSIZE_END)
        }
        if lines > 2 {
            let id = entry.id
            let ref = self.ref
            let link = BrainUI.link(expanded ? BrainWords.hide : NeuralReading.showAllLabel) {
                ref.view?.accountToggleText(id)
            }
            gtk_box_append(ptr(root), link)
            cell.unfoldable = true
        }
        return cell
    }


    /// What came of the turn: the files it changed, the checks it ran with their own verdicts,
    /// what is still failing, and then its answer; nothing that the transcript does not show.
    func buildResult(_ entry: AccountEntry, _ result: NeuralAccount.Result, key: String) -> AccountCell {
        let inks = owner.inks
        let hex = inks.hex
        let block = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-it", "bn-result")
        let cell = AccountCell(id: entry.id, key: key, widget: block)
        gtk_box_append(ptr(block), BrainUI.label(Localized.text("RESULT"), "bn-label", "bn-result-title"))
        func group(_ title: String?) -> UnsafeMutablePointer<GtkWidget> {
            let box = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 6, "bn-res-group")
            if let title { gtk_box_append(ptr(box), BrainUI.label(title, "bn-label")) }
            gtk_box_append(ptr(block), box)
            return box
        }
        let ref = self.ref
        if !result.changes.isEmpty {
            let box = group(NeuralReading.changedLabel.uppercased())
            for change in result.changes.prefix(8) {
                let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, "bn-res-row")
                let path = BrainUI.markup(
                    "<span foreground=\"\(hex.dim)\">\(BrainUI.escape(change.shortDirectory))</span><span foreground=\"\(hex.text)\" weight=\"bold\">\(BrainUI.escape(change.fileName))</span>",
                    "bn-changed-path", wrap: false)
                gtk_label_set_ellipsize(op(path), PANGO_ELLIPSIZE_START)
                gtk_widget_set_hexpand(path, 1)
                let total = change.added + change.removed
                let meter = changeMeter(added: change.added, removed: change.removed, width: Double(min(64, max(12, total * 6))))
                let tally = BrainUI.markup(
                    "<span foreground=\"\(hex.accent)\">+\(change.added)</span> <span foreground=\"\(hex.danger)\">\u{2212}\(change.removed)</span>",
                    "bn-label-right", wrap: false)
                gtk_widget_set_hexpand(tally, 0)
                BrainUI.add(row, path, meter, tally, numberChips(change.numbers))
                gtk_box_append(ptr(box), row)
            }
            if result.changes.count > 8 {
                gtk_box_append(ptr(box), BrainUI.label(BrainWords.moreFiles(result.changes.count - 8), "bn-fact"))
            }
        } else if let words = result.changedWords {
            gtk_box_append(ptr(group(nil)), BrainUI.label(words, "bn-res-words", wrap: true))
        }
        if !result.checks.isEmpty {
            let box = group(Localized.text("CHECKS"))
            for check in result.checks {
                let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, "bn-res-row")
                gtk_box_append(ptr(row), BrainUI.verdictGlyph(check.verdict, size: 14, inks: inks))
                let label = BrainUI.label(check.label, "bn-res-check")
                gtk_widget_set_size_request(label, 44, -1)
                let command = BrainUI.label(check.command, "bn-res-command", ellipsize: true)
                gtk_widget_set_hexpand(command, 1)
                let tone = check.verdict == .failed ? "bn-tone-danger" : (check.verdict == .fixed ? "bn-tone-attention" : "bn-tone-live")
                let words = BrainUI.label(check.verdictWords, "bn-res-verdict", tone)
                BrainUI.add(row, label, command, words, numberChips(check.numbers))
                gtk_box_append(ptr(box), row)
            }
        }
        if !result.unfixed.isEmpty {
            let box = group(Localized.text("STILL FAILING"))
            if let title = gtk_widget_get_first_child(box) { Gtk.addClass(title, "bn-tone-danger") }
            for item in result.unfixed.prefix(6) {
                let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, "bn-res-row")
                gtk_box_append(ptr(row), BrainUI.verdictGlyph(.failed, size: 14, inks: inks))
                let title = BrainUI.label(item.title, "bn-res-check")
                let line = BrainUI.label(item.firstLine, "bn-res-command", ellipsize: true)
                gtk_widget_set_hexpand(line, 1)
                BrainUI.add(row, title, line, numberChips([item.number]))
                gtk_box_append(ptr(box), row)
            }
        }
        if let answer = result.answer ?? result.answerWords {
            let box = group(NeuralReading.thenItAnswered.uppercased())
            let holder = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_widget_set_halign(holder, GTK_ALIGN_START)
            let measure = max(120, min(proseProbe.em * 36, boxWidth - 24))
            gtk_widget_set_size_request(holder, Int32(measure.rounded()), -1)
            cell.holders.append((holder, 24))
            cell.holdersWidth = boxWidth
            gtk_box_append(ptr(holder), BrainUI.label(answer, "bn-said-text", wrap: true, selectable: false))
            gtk_box_append(ptr(box), holder)
            gtk_widget_set_cursor_from_name(box, "pointer")
            Gtk.onPrimaryRelease(box) { Gtk.onMain { ref.view?.accountGoToAnswer() } }
        }
        tailscode_set_accessible_label(block, Localized.text("RESULT"))
        return cell
    }

    /// Step numbers as small chips, each one setting the cursor to its step.
    private func numberChips(_ numbers: [Int]) -> UnsafeMutablePointer<GtkWidget> {
        let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2, "bn-res-nums")
        let steps = owner.model.steps
        for number in numbers.prefix(4) {
            guard number >= 1, number <= steps.count else { continue }
            gtk_box_append(ptr(row), stepChip("#\(number)", stepID: steps[number - 1].id))
        }
        gtk_widget_set_valign(row, GTK_ALIGN_CENTER)
        return row
    }

    private func changeMeter(added: Int, removed: Int, width: Double) -> UnsafeMutablePointer<GtkWidget> {
        let holder = MeterHolder(added: added, removed: removed, inks: owner.inks)
        _ = Gtk.releaseInstalled
        let canvas = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let meter = Unmanaged<MeterHolder>.fromOpaque(raw).takeUnretainedValue()
                let total = Double(max(1, meter.added + meter.removed))
                let w = Double(width)
                let addWidth = w * Double(meter.added) / total
                let a = meter.inks.accent
                let d = meter.inks.cDanger
                cairo_set_source_rgba(cr, a.red, a.green, a.blue, 1)
                BrainPainter.round(cr, 0, 0, max(0, addWidth - (meter.removed > 0 ? 0.5 : 0)), 6, 1)
                cairo_fill(cr)
                if meter.removed > 0 {
                    cairo_set_source_rgba(cr, d.red, d.green, d.blue, 1)
                    BrainPainter.round(cr, addWidth + 0.5, 0, max(0, w - addWidth - 0.5), 6, 1)
                    cairo_fill(cr)
                }
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<MeterHolder>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(canvas, Int32(width), 6)
        gtk_widget_set_valign(canvas, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(canvas, 0)
        return canvas
    }

    final class MeterHolder: @unchecked Sendable {
        let added: Int
        let removed: Int
        let inks: BrainInks
        init(added: Int, removed: Int, inks: BrainInks) {
            self.added = added
            self.removed = removed
            self.inks = inks
        }
    }
}

extension UnsafeMutablePointer where Pointee == GtkWidget {
    /// A family dot at the start of a box: the model's own hue.
    func addDot(for family: ModelTint.Family?, inks: BrainInks, owner: BrainAccount) {
        gtk_box_append(ptr(self), owner.familyDot(family))
    }
}
