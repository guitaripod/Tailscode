import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// One item of the account as it exists while it is near the viewport: its widget, what it was
/// made for (so a change of that is a rebuild and anything else is not), and the parts a press,
/// the hover or the harness reach.
final class AccountCell {
    let id: String
    let key: String
    let widget: UnsafeMutablePointer<GtkWidget>
    var stale = false
    var justNowLabel: UnsafeMutablePointer<GtkWidget>?
    var actions: UnsafeMutablePointer<GtkWidget>?
    var copyButton: UnsafeMutablePointer<GtkWidget>?
    var pages: [(stepID: String, page: BrainReadout.Page)] = []
    var rows: [WorkRows] = []
    var cursorPage: BrainReadout.Page?
    var unfoldable = false
    var holders: [(widget: UnsafeMutablePointer<GtkWidget>, inset: Double)] = []
    var holdersWidth = 0.0

    init(id: String, key: String, widget: UnsafeMutablePointer<GtkWidget>) {
        self.id = id
        self.key = key
        self.widget = widget
    }

    func measure(width: Double) -> Double {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(widget, GTK_ORIENTATION_VERTICAL, Int32(max(width, 1)), &minimum, &natural, nil, nil)
        return Double(max(minimum, natural))
    }

    func hideJustNow() {
        if let justNowLabel { gtk_widget_set_visible(justNowLabel, 0) }
    }

    func teardown() {
        rows = []
        pages = []
        cursorPage = nil
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
        return count(widget)
    }
}

extension BrainAccount {
    /// What an item was made for. A cell is rebuilt when this changes and kept while it does not:
    /// the words, the open and closed state, the cursor and the hover that decide what it shows,
    /// the width it was measured at and the colours it wears.
    func cellKey(_ entry: AccountEntry) -> String {
        let model = owner.model
        let cursor = model.pinnedStep
        let stamp = "\(Int(boxWidth))|\(owner.inks.hex.accent)|\(owner.density == .compact ? "c" : "n")"
        switch entry.kind {
        case .said(let said):
            return "s|\(said.id)|\(said.text.utf8.count)|\(said.showsSpeaker)|\(cursor == said.stepID)|\(expandedText.contains(entry.id))|\(stamp)|\(justNow[entry.id] != nil)"
        case .thought(let thought):
            return "t|\(thought.id)|\(thought.text.utf8.count)|\(cursor == thought.stepID)|\(expandedText.contains(entry.id))|\(stamp)"
        case .work(let work):
            let stamp = workStamps[entry.id] ?? 0
            let cards = cardSteps(for: entry, work: work)
            let open = isOpen(entry, work: work)
            return "w|\(entry.id)|\(stamp)|\(open)|\(cards.map { "\($0.id)\($0.live)\($0.preview)" }.joined(separator: ","))|\(rowCap(entry.id))|\(cursor ?? "-")|\(stamp)"
        case .asked(let asked):
            return "q|\(asked.id)|\(asked.text.utf8.count)|\(expandedText.contains(entry.id))|\(stamp)"
        case .plan(let plan):
            let open = planStoryOpen(entry, plan)
            return "p|\(entry.id)|\(plan.items.map { "\($0.text)\($0.state)" }.joined(separator: "|"))|\(open)|\(stamp)"
        case .result(let result):
            return "r|\(entry.id)|\(result.checks.map { "\($0.command)\($0.verdict)\($0.retries)" }.joined(separator: "|"))|\(result.changes.map { "\($0.path)\($0.added)\($0.removed)" }.joined(separator: "|"))|\(result.unfixed.count)|\(result.answer ?? "")|\(stamp)"
        }
    }

    struct CardSpec {
        let id: String
        let preview: Bool
        let live: Bool
    }

    /// The steps of a work line whose card is open under them: the cursor's, the hovered one's as
    /// a preview beside it, and the step a running turn is on while the account follows it.
    func cardSteps(for entry: AccountEntry, work: AccountEntry.Work) -> [CardSpec] {
        guard owner.currentMetrics.accountLayout == .single || owner.currentMetrics.arrangement == .accordion
        else { return [] }
        let model = owner.model
        var out: [CardSpec] = []
        let cursor = model.pinnedStep
        if let cursor, work.stepIDs.contains(cursor) {
            out.append(CardSpec(id: cursor, preview: false, live: isRunningStep(cursor)))
        }
        if let hovered = model.browseState.hovered, hovered != cursor, work.stepIDs.contains(hovered),
            owner.currentMetrics.arrangement != .accordion || true
        {
            out.append(CardSpec(id: hovered, preview: true, live: false))
        }
        if out.isEmpty, liveTip(work: work), let last = work.stepIDs.last, isRunningStep(last) {
            out.append(CardSpec(id: last, preview: false, live: true))
        }
        return out
    }

    private func isRunningStep(_ id: String) -> Bool {
        guard let step = owner.model.step(id: id) else { return false }
        return owner.model.turn.outcome == .running && step.status == .running
    }

    func buildCell(_ entry: AccountEntry, key: String) -> AccountCell {
        switch entry.kind {
        case .said(let said): return buildSaid(entry, said, key: key)
        case .thought(let thought): return buildThought(entry, thought, key: key)
        case .work(let work): return buildWork(entry, work, key: key)
        case .asked(let asked): return buildAsked(entry, asked, key: key)
        case .plan(let plan): return buildPlanCell(entry, plan, key: key)
        case .result(let result): return buildResult(entry, result, key: key)
        }
    }


    func familyDot(_ family: ModelTint.Family?) -> UnsafeMutablePointer<GtkWidget> {
        let hex = family.map { ModelTint.hex($0, in: MatrixTheme.palette) } ?? owner.inks.hex.accent
        let color = Contrast.channels(hex) ?? owner.inks.accent
        let holder = ColorHolder(color: color)
        _ = Gtk.releaseInstalled
        let dot = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let color = Unmanaged<ColorHolder>.fromOpaque(raw).takeUnretainedValue().color
                cairo_new_path(cr)
                cairo_arc(cr, Double(width) / 2, Double(height) / 2, 4, 0, 2 * .pi)
                cairo_set_source_rgba(cr, color.red, color.green, color.blue, 1)
                cairo_fill(cr)
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<ColorHolder>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(dot, 8, 8)
        gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(dot, 0)
        tailscode_set_accessible_hidden(dot, 1)
        return dot
    }

    final class ColorHolder: @unchecked Sendable {
        let color: BrainInks.RGB
        init(color: BrainInks.RGB) { self.color = color }
    }

    /// A small flat button that sets the cursor to a step: the number a reader presses to go
    /// where the item is in the list and the head.
    func stepChip(_ text: String, stepID: String?) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "bn-sn")
        gtk_button_set_child(ptr(button), BrainUI.label(text, "bn-sn-text"))
        gtk_widget_set_cursor_from_name(button, "pointer")
        tailscode_set_accessible_label(button, Localized.text("Step %@", text))
        let ref = self.ref
        if let stepID {
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked") {
                Gtk.onMain { ref.view?.accountChooseStep(stepID, fromAccount: true) }
            }
        } else {
            gtk_widget_set_sensitive(button, 0)
        }
        return button
    }

    /// The text as Pango markup: a word between backticks is code, in the mono face and the
    /// info colour, and nothing else is rewritten.
    func proseMarkup(_ text: String) -> String {
        let hex = owner.inks.hex
        var out = ""
        var inCode = false
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            let escaped = BrainUI.escape(run)
            out += inCode
                ? "<span font_family=\"monospace\" foreground=\"\(hex.info)\">\(escaped)</span>" : escaped
            run = ""
        }
        for character in text {
            if character == "`" {
                flush()
                inCode.toggle()
            } else {
                run.append(character)
            }
        }
        flush()
        return out
    }

    func hoverWatch(
        _ widget: UnsafeMutablePointer<GtkWidget>, enter: @escaping @Sendable () -> Void,
        leave: @escaping @Sendable () -> Void
    ) {
        let box = Unmanaged.passRetained(HoverBox(enter: enter, leave: leave)).toOpaque()
        _ = Gtk.releaseInstalled
        tailscode_on_hover_focus(
            widget,
            { raw in
                guard let raw else { return }
                Unmanaged<HoverBox>.fromOpaque(raw).takeUnretainedValue().enter()
            },
            { raw in
                guard let raw else { return }
                Unmanaged<HoverBox>.fromOpaque(raw).takeUnretainedValue().leave()
            }, box)
    }

    final class HoverBox: @unchecked Sendable {
        let enter: @Sendable () -> Void
        let leave: @Sendable () -> Void
        init(enter: @escaping @Sendable () -> Void, leave: @escaping @Sendable () -> Void) {
            self.enter = enter
            self.leave = leave
        }
    }

    /// A press anywhere in an item, before the widget under the pointer acts on it, sets the
    /// cursor: selecting its words and pressing its buttons keep their own meaning.
    func pressWatch(_ widget: UnsafeMutablePointer<GtkWidget>, stepID: String) {
        let ref = self.ref
        Gtk.onPressCapture(widget) { _, _ in
            Gtk.onMain { ref.view?.accountChooseStep(stepID, fromAccount: true) }
        }
    }


    private func buildSaid(_ entry: AccountEntry, _ said: NeuralAccount.Said, key: String) -> AccountCell {
        let overlay = gtk_overlay_new()!
        Gtk.addClass(overlay, "bn-it")
        Gtk.addClass(overlay, "bn-said")
        let isCursor = owner.model.pinnedStep == said.stepID
        if isCursor { Gtk.addClass(overlay, "bn-cursor") }
        let content = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-said-body")
        let cell = AccountCell(id: entry.id, key: key, widget: overlay)
        if said.showsSpeaker {
            let head = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8, "bn-spk")
            let name = BrainUI.label(said.speaker.uppercased(), "bn-spk-name")
            let clock = BrainUI.label(said.clock ?? "", "bn-spk-clock")
            BrainUI.add(head, familyDot(said.family), name, clock)
            if justNow[entry.id] != nil {
                let tag = BrainUI.label(BrainWords.justNow.uppercased(), "bn-just")
                BrainUI.add(head, tag)
                cell.justNowLabel = tag
            }
            gtk_box_append(ptr(content), head)
        }
        let measure = max(120, min(proseProbe.em * 36, boxWidth - 16 - 3 - 56))
        let holder = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_halign(holder, GTK_ALIGN_START)
        gtk_widget_set_size_request(holder, Int32(measure.rounded()), -1)
        cell.holders.append((holder, 16 + 3 + 56))
        cell.holdersWidth = boxWidth
        let text = BrainUI.label("", "bn-said-text", wrap: true, selectable: true)
        gtk_label_set_markup(op(text), proseMarkup(said.text))
        gtk_box_append(ptr(holder), text)
        gtk_box_append(ptr(content), holder)
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(text, GTK_ORIENTATION_VERTICAL, Int32(measure), &minimum, &natural, nil, nil)
        let lines = Int((Double(natural) / max(1, proseProbe.line)).rounded())
        let clamp = lines > NeuralAccount.saidCollapsedLines
        let expanded = expandedText.contains(entry.id)
        if clamp, !expanded {
            gtk_label_set_lines(op(text), Int32(NeuralAccount.saidCollapsedLines))
            gtk_label_set_ellipsize(op(text), PANGO_ELLIPSIZE_END)
        }
        if clamp {
            let id = entry.id
            let ref = self.ref
            let link = BrainUI.link(expanded ? BrainWords.hide : NeuralReading.showAllLabel) {
                ref.view?.accountToggleText(id)
            }
            gtk_widget_set_margin_top(link, 2)
            gtk_box_append(ptr(content), link)
            cell.unfoldable = true
        }
        gtk_overlay_set_child(op(overlay), content)
        let actions = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 6, "bn-acts")
        gtk_widget_set_halign(actions, GTK_ALIGN_END)
        gtk_widget_set_valign(actions, GTK_ALIGN_START)
        let numbers = stepChip("#\(said.number)", stepID: said.stepID)
        gtk_widget_set_halign(numbers, GTK_ALIGN_END)
        let stepID = said.stepID
        let ref = self.ref
        let copy = Gtk.button(copyWord(for: said.stepID), css: ["brain-pill", "bn-copy", "bn-act"]) {
            Gtk.onMain { ref.view?.accountCopy(stepID) }
        }
        let reply = Gtk.button(NeuralReading.replyLabel, css: ["brain-pill", "bn-copy", "bn-act"]) {
            Gtk.onMain { ref.view?.accountReply(stepID) }
        }
        for button in [copy, reply] {
            gtk_widget_set_cursor_from_name(button, "pointer")
            gtk_widget_set_halign(button, GTK_ALIGN_END)
        }
        tailscode_set_accessible_label(copy, NeuralReading.copyLabel)
        tailscode_set_accessible_label(reply, NeuralReading.replyLabel)
        let buttons = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        BrainUI.add(buttons, copy, reply)
        gtk_widget_set_visible(buttons, isCursor ? 1 : 0)
        BrainUI.add(actions, numbers, buttons)
        gtk_overlay_add_overlay(op(overlay), actions)
        cell.actions = buttons
        cell.copyButton = copy
        let hold = Gtk.WeakWidget(buttons)
        hoverWatch(
            overlay,
            enter: { [ref] in
                Gtk.onMain {
                    if let raw = hold.widget { gtk_widget_set_visible(raw, 1) }
                    ref.view?.accountHover(stepID)
                }
            },
            leave: { [ref] in
                Gtk.onMain {
                    if let raw = hold.widget, ref.view?.model.pinnedStep != stepID { gtk_widget_set_visible(raw, 0) }
                    ref.view?.accountHover(nil)
                }
            })
        pressWatch(overlay, stepID: said.stepID)
        return cell
    }


    private func buildThought(_ entry: AccountEntry, _ thought: NeuralAccount.Thought, key: String) -> AccountCell {
        let expanded = expandedText.contains(entry.id)
        let root = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, "bn-it", "bn-thought-row")
        let isCursor = owner.model.pinnedStep == thought.stepID
        if isCursor { Gtk.addClass(root, "bn-cursor") }
        let cell = AccountCell(id: entry.id, key: key, widget: root)
        let inks = owner.inks
        let glyph = BrainUI.shapeGlyph(.think, size: 18) { inks.corrected(.think) }
        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        gtk_widget_set_margin_top(glyph, 3)
        gtk_box_append(ptr(root), glyph)
        let text: UnsafeMutablePointer<GtkWidget>
        if expanded {
            text = BrainUI.label(thought.text, "bn-thought-text", wrap: true, selectable: true)
        } else {
            text = BrainUI.label(thought.firstLine, "bn-thought-text", ellipsize: true)
            gtk_label_set_ellipsize(op(text), PANGO_ELLIPSIZE_END)
        }
        gtk_widget_set_hexpand(text, 1)
        gtk_widget_set_valign(text, expanded ? GTK_ALIGN_START : GTK_ALIGN_CENTER)
        gtk_box_append(ptr(root), text)
        let room = boxWidth - 19 - 8 - 18 - 10 - 44 - 10
        let truncated = BrainDraw.measure(thought.firstLine, fonts.noteNatural) > room
        if thought.canUnfold || truncated {
            let id = entry.id
            let ref = self.ref
            let link = BrainUI.link(expanded ? BrainWords.hide : BrainWords.show) { ref.view?.accountToggleText(id) }
            gtk_widget_set_valign(link, GTK_ALIGN_START)
            gtk_widget_set_margin_top(link, 2)
            gtk_box_append(ptr(root), link)
            cell.unfoldable = true
        }
        let chip = stepChip("#\(thought.number)", stepID: thought.stepID)
        gtk_widget_set_valign(chip, GTK_ALIGN_START)
        gtk_box_append(ptr(root), chip)
        let stepID = thought.stepID
        let ref = self.ref
        hoverWatch(
            root, enter: { Gtk.onMain { ref.view?.accountHover(stepID) } },
            leave: { Gtk.onMain { ref.view?.accountHover(nil) } })
        pressWatch(root, stepID: thought.stepID)
        return cell
    }


    /// A settled turn's plan sits in the story, folded to its header once every item is done.
    func planStoryOpen(_ entry: AccountEntry, _ plan: NeuralAccount.Plan) -> Bool {
        if let override = planStoryOverride[entry.id] { return override }
        return plan.done < plan.total
    }

    private func buildPlanCell(_ entry: AccountEntry, _ plan: NeuralAccount.Plan, key: String) -> AccountCell {
        let widget = buildPlan(plan, entryID: entry.id, compact: false, open: planStoryOpen(entry, plan))
        Gtk.addClass(widget, "bn-it")
        return AccountCell(id: entry.id, key: key, widget: widget)
    }
}
