import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension BrainReadout {
    func section(first: Bool = false) -> UnsafeMutablePointer<GtkWidget> {
        let box = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 6, "bn-sec")
        if first { Gtk.addClass(box, "bn-sec-first") }
        return box
    }

    func labelRow(_ left: String, right: UnsafeMutablePointer<GtkWidget>? = nil, tone: Bool = false)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let label = BrainUI.label(left, "bn-label")
        if tone { Gtk.addClass(label, "bn-tone-text") }
        BrainUI.add(row, label, BrainUI.spacer())
        if let right { gtk_box_append(ptr(row), right) }
        return row
    }

    func rightLabel(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = BrainUI.label(text, "bn-label-right")
        gtk_label_set_xalign(op(label), 1)
        return label
    }

    func tallyLabel(added: Int, removed: Int) -> UnsafeMutablePointer<GtkWidget> {
        let hex = inks.hex
        let label = BrainUI.markup(
            "<span foreground=\"\(hex.accent)\">+\(added)</span> <span foreground=\"\(hex.danger)\">\u{2212}\(removed)</span>",
            "bn-label-right", wrap: false)
        gtk_widget_set_hexpand(label, 0)
        return label
    }

    // MARK: a step

    func buildStep(_ step: StepParts, in page: Page) {
        let body = page.body
        page.subject = SubjectParts(stepID: step.stepID, copyText: step.subject.copyText)
        gtk_box_append(ptr(body), subjectSection(step, page: page))
        if let detail = step.header.chip.detail {
            let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8, "bn-sec")
            gtk_box_append(
                ptr(row),
                BrainUI.verdictGlyph(.fixed, size: 12, inks: inks, color: BrainDraw.toneColor(.attention, inks: inks)))
            gtk_box_append(ptr(row), BrainUI.label(detail, "bn-fixed-detail", wrap: true, selectable: true))
            gtk_box_append(ptr(body), row)
        }
        if !step.relations.isEmpty {
            let relations = section()
            gtk_box_append(ptr(relations), BrainUI.label(BrainWords.relations, "bn-label"))
            gtk_box_append(ptr(relations), relationRow(step.relations))
            gtk_box_append(ptr(body), relations)
        }
        if let why = step.why { gtk_box_append(ptr(body), whySection(why)) }
        if let result = step.result {
            gtk_box_append(ptr(body), resultSection(result, step: step, page: page))
        }
    }

    func subjectSection(_ step: StepParts, page: Page) -> UnsafeMutablePointer<GtkWidget> {
        let subject = step.subject
        let box = section(first: true)
        let top = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        let title = BrainUI.label(subject.title, "bn-title")
        gtk_widget_set_valign(title, GTK_ALIGN_CENTER)
        BrainUI.add(top, title, BrainUI.spacer())
        if case .subagent(let agent)? = step.result, agent.canOpen {
            let stepID = step.stepID
            let ref = self.ref
            let button = Gtk.button(agent.openLabel, css: ["brain-pill", "bn-copy"]) {
                Gtk.onMain { ref.view?.openSubagent(of: stepID) }
            }
            gtk_widget_set_valign(button, GTK_ALIGN_START)
            gtk_box_append(ptr(top), button)
        } else if subject.copyText != nil {
            gtk_box_append(ptr(top), BrainUI.copyButton(NeuralReading.copyLabel) { subject.copyText })
        }
        gtk_box_append(ptr(box), top)
        let hex = inks.hex
        switch subject.kind {
        case .command:
            gtk_box_append(ptr(box), commandView(subject, page: page))
        case .path:
            let dir = BrainUI.escape(subject.directory ?? "")
            let file = BrainUI.escape(subject.fileName ?? subject.primary)
            gtk_box_append(
                ptr(box),
                BrainUI.markup(
                    "<span foreground=\"\(hex.dim)\">\(dir)</span><span foreground=\"\(hex.text)\" weight=\"bold\">\(file)</span>",
                    "bn-path", selectable: true))
        case .pattern:
            gtk_box_append(ptr(box), BrainUI.label(subject.primary, "bn-cmd", wrap: true, selectable: true))
            if let scope = subject.secondary, !scope.isEmpty {
                gtk_box_append(
                    ptr(box),
                    BrainUI.markup(
                        "<span foreground=\"\(hex.dim)\">\(BrainUI.escape(Localized.text("in")))</span> \(BrainUI.escape(scope))",
                        "bn-path", selectable: true))
            }
        case .url, .other:
            gtk_box_append(ptr(box), BrainUI.label(subject.primary, "bn-path", wrap: true, selectable: true))
        case .agent:
            gtk_box_append(ptr(box), BrainUI.label(subject.primary, "bn-agent", wrap: true, selectable: true))
            if let kind = subject.secondary, !kind.isEmpty {
                gtk_box_append(ptr(box), BrainUI.label(kind, "bn-fact", wrap: true))
            }
        case .thought, .note:
            gtk_box_append(ptr(box), BrainUI.label(subject.primary, "bn-thought", wrap: true, selectable: true))
        }
        return box
    }

    /// A shell command wrapped, never cut: its first four lines, and the rest behind Show all.
    func commandView(_ subject: R.Subject, page: Page) -> UnsafeMutablePointer<GtkWidget> {
        let box = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        let hex = inks.hex
        let lines = subject.primary.components(separatedBy: "\n")
        func markup(_ shown: [String]) -> String {
            "<span foreground=\"\(inks.correctedHex(zoneOf(subject)))\">$</span> "
                + BrainUI.escape(shown.joined(separator: "\n"))
        }
        _ = hex
        let label = BrainUI.markup(
            markup(Array(lines.prefix(subject.collapsedLines))), "bn-cmd", selectable: true)
        gtk_box_append(ptr(box), label)
        if subject.hasMore {
            let link = BrainUI.link(NeuralReading.showAllLabel) {}
            let linkHold = Gtk.WeakWidget(link)
            let labelHold = Gtk.WeakWidget(label)
            let full = markup(lines)
            Gtk.connect(UnsafeMutableRawPointer(link), "clicked") {
                Gtk.onMain {
                    guard let lraw = labelHold.widget, let braw = linkHold.widget else { return }
                    gtk_label_set_markup(op(lraw), full)
                    gtk_widget_set_visible(ptr(braw), 0)
                }
            }
            gtk_box_append(ptr(box), link)
        }
        return box
    }

    func zoneOf(_ subject: R.Subject) -> NeuralZone { .shell }

    func relationRow(_ relations: [R.Relation]) -> UnsafeMutablePointer<GtkWidget> {
        let buttons = relations.map { relation -> UnsafeMutablePointer<GtkWidget> in
            let button = gtk_button_new()!
            Gtk.addClass(button, "bn-rel")
            if relation.kind == .retriedAt { Gtk.addClass(button, "bn-rel-retry") }
            let hex = inks.hex
            let numbers = relation.numbers.map { String($0) }.joined(separator: ", ")
            let label = BrainUI.markup(
                "<span foreground=\"\(hex.dim)\">\(BrainUI.escape(relation.label.replacingOccurrences(of: numbers, with: "").trimmingCharacters(in: .whitespaces)))</span> <span weight=\"bold\">\(BrainUI.escape(numbers))</span>",
                wrap: false)
            gtk_widget_set_hexpand(label, 0)
            gtk_button_set_child(ptr(button), label)
            let ids = relation.stepIDs
            let ref = self.ref
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked") {
                Gtk.onMain { if let first = ids.first { ref.view?.pin(first) } }
            }
            let box = Unmanaged.passRetained(RelationBox(ids: ids, owner: owner)).toOpaque()
            _ = Gtk.releaseInstalled
            tailscode_on_hover_focus(
                button,
                { raw in
                    guard let raw else { return }
                    let held = Unmanaged<RelationBox>.fromOpaque(raw).takeUnretainedValue()
                    held.owner?.relationHover(held.ids)
                },
                { raw in
                    guard let raw else { return }
                    Unmanaged<RelationBox>.fromOpaque(raw).takeUnretainedValue().owner?.relationHover(nil)
                }, box)
            gtk_widget_set_cursor_from_name(button, "pointer")
            tailscode_set_accessible_label(button, relation.label)
            return button
        }
        return Gtk.wrapRow(buttons, spacing: 6)
    }

    final class WeakReadout: @unchecked Sendable {
        weak var value: BrainReadout?
        init(_ value: BrainReadout) { self.value = value }
    }

    final class RelationBox: @unchecked Sendable {
        let ids: [String]
        weak var owner: BrainView?
        init(ids: [String], owner: BrainView) {
            self.ids = ids
            self.owner = owner
        }
    }

    func whySection(_ why: R.Why) -> UnsafeMutablePointer<GtkWidget> {
        let outer = section()
        let box = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 2, "bn-why", "bn-tone-rule")
        gtk_box_append(ptr(box), BrainUI.label(why.label, "bn-label", "bn-tone-text"))
        let text = BrainUI.label(why.text, "bn-why-text", wrap: true, selectable: true)
        gtk_box_append(ptr(box), text)
        if why.isTruncated {
            let link = BrainUI.link(NeuralReading.showMoreLabel) {}
            let linkHold = Gtk.WeakWidget(link)
            let textHold = Gtk.WeakWidget(text)
            let full = why.full
            Gtk.connect(UnsafeMutableRawPointer(link), "clicked") {
                Gtk.onMain {
                    guard let traw = textHold.widget, let lraw = linkHold.widget else { return }
                    gtk_label_set_text(op(traw), full)
                    gtk_widget_set_visible(ptr(lraw), 0)
                }
            }
            gtk_box_append(ptr(box), link)
        }
        gtk_box_append(ptr(outer), box)
        return outer
    }

    func resultSection(_ result: R.Result, step: StepParts, page: Page) -> UnsafeMutablePointer<GtkWidget> {
        let box = section()
        let failed = step.header.chip.kind == .failed || step.header.chip.kind == .fixed
        switch result {
        case .shell(let output):
            gtk_box_append(
                ptr(box), labelRow(BrainWords.output, right: rightLabel(BrainWords.lines(output.total))))
            gtk_box_append(
                ptr(box),
                outputBlock(
                    output.lines.map { ($0.text, $0.tone) }, hidden: output.hiddenCount, more: output.moreLabel, failed: failed,
                    stepID: step.stepID, page: page))
        case .edit(let edit):
            gtk_box_append(
                ptr(box),
                labelRow(BrainWords.diff, right: tallyLabel(added: edit.added, removed: edit.removed)))
            gtk_box_append(ptr(box), diffBlock(edit, stepID: step.stepID, page: page))
        case .read(let read):
            let right = read.lines.map { rightLabel(BrainWords.lines($0)) }
            gtk_box_append(ptr(box), labelRow(BrainWords.readLabel, right: right))
        case .search(let search):
            gtk_box_append(
                ptr(box), labelRow(BrainWords.matches, right: rightLabel(String(search.total))))
            let lines: [BodyLine] = search.matches.map { ($0, R.LineTone.dim) }
            gtk_box_append(
                ptr(box),
                outputBlock(
                    lines, hidden: max(0, search.total - search.matches.count), more: search.moreLabel,
                    failed: false, stepID: step.stepID, page: page))
        case .subagent(let agent):
            gtk_box_append(ptr(box), labelRow(BrainWords.result))
            let lines: [BodyLine] = agent.summary.map { ($0, R.LineTone.dim) }
            gtk_box_append(
                ptr(box),
                outputBlock(
                    lines, hidden: max(0, agent.total - agent.summary.count), more: nil, failed: false,
                    stepID: step.stepID, page: page))
        case .text(let text):
            if step.subject.kind != .thought && step.subject.kind != .note {
                gtk_box_append(ptr(box), BrainUI.label(text.text, "bn-thought", wrap: true, selectable: true))
            } else {
                gtk_widget_set_visible(box, 0)
            }
        }
        return box
    }

    /// The first lines of a call's output, and "N more lines" which opens the whole of it in a
    /// region of its own that scrolls.
    func outputBlock(
        _ lines: [BodyLine], hidden: Int, more: String?, failed: Bool, stepID: String, page: Page
    ) -> UnsafeMutablePointer<GtkWidget> {
        let holder = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        let framed = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 6, "bn-out-box")
        if failed { Gtk.addClass(framed, "bn-out-bad") }
        let label = BrainUI.markup(outputMarkup(lines, failed: failed), "bn-out", selectable: true)
        gtk_box_append(ptr(framed), label)
        gtk_box_append(ptr(holder), framed)
        guard hidden > 0, let more else { return holder }
        let link = BrainUI.link(more) {}
        let linkHold = Gtk.WeakWidget(link)
        let framedHold = Gtk.WeakWidget(framed)
        let model = owner.model
        let failedNow = failed
        let collapsed = outputMarkup(lines, failed: failed)
        let state = OutputToggle(current: Gtk.WeakWidget(label))
        let toggle: @Sendable () -> Void = { [reader = WeakReadout(self)] in
            Gtk.onMain {
                guard let self = reader.value, let lraw = linkHold.widget, let fraw = framedHold.widget,
                    let currentWidget = state.current.widget, let step = model.step(id: stepID)
                else { return }
                let box: UnsafeMutablePointer<GtkWidget> = ptr(fraw)
                let outer = state.scroller?.widget ?? currentWidget
                gtk_box_remove(ptr(box), outer)
                state.scroller = nil
                if state.expanded {
                    let label = BrainUI.markup(collapsed, "bn-out", selectable: true)
                    gtk_box_append(ptr(box), label)
                    state.current = Gtk.WeakWidget(label)
                    gtk_widget_set_visible(ptr(lraw), 1)
                } else {
                    let all = R.fullOutput(of: step).map { ($0.text, $0.tone) }
                    let label = BrainUI.markup(self.outputMarkup(all, failed: failedNow), "bn-out", selectable: true)
                    let scroller = Gtk.boundedScroller(label, minimum: 0, maximum: 280)
                    gtk_box_append(ptr(box), scroller)
                    state.current = Gtk.WeakWidget(label)
                    state.scroller = Gtk.WeakWidget(scroller)
                    gtk_widget_set_visible(ptr(lraw), 0)
                }
                state.expanded.toggle()
                reader.value?.owner.model.setBrowseOutputExpanded(state.expanded)
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(link), "clicked", toggle)
        gtk_box_append(ptr(holder), link)
        page.subject?.toggleOutput = toggle
        return holder
    }

    final class OutputToggle: @unchecked Sendable {
        var current: Gtk.WeakWidget
        var scroller: Gtk.WeakWidget?
        var expanded = false
        init(current: Gtk.WeakWidget) { self.current = current }
    }

    /// The first lines of an edit or a written file, and under them a button that opens the whole
    /// of it in a reader that scrolls, with a button that copies the whole of it. Space and `o`
    /// open and close it from the keyboard, as they do a call's output.
    func diffBlock(_ edit: R.Edit, stepID: String, page: Page) -> UnsafeMutablePointer<GtkWidget> {
        let holder = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_box_append(ptr(holder), diffFrame(edit.lines))
        guard edit.hiddenCount > 0 else { return holder }
        let model = owner.model
        let bar = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let link = BrainUI.link(NeuralReading.showAllLines(edit.total)) {}
        gtk_box_append(ptr(bar), link)
        let spacer = BrainUI.spacer()
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(bar), spacer)
        gtk_box_append(
            ptr(bar),
            BrainUI.copyButton(NeuralReading.copyAllLabel) {
                model.step(id: stepID).map { NeuralReading.pasteText(of: R.fullDiff(of: $0)) }
            })
        gtk_box_append(ptr(holder), bar)
        let state = DiffToggle(current: Gtk.WeakWidget(gtk_widget_get_first_child(holder)!))
        let holderHold = Gtk.WeakWidget(holder)
        let linkHold = Gtk.WeakWidget(link)
        let scrollerHold = Gtk.WeakWidget(page.scroller)
        let bodyHold = Gtk.WeakWidget(page.body)
        let shown = edit.lines
        let total = edit.total
        let toggle: @Sendable () -> Void = { [reader = WeakReadout(self)] in
            Gtk.onMain {
                guard let self = reader.value, let holderRaw = holderHold.widget, let linkRaw = linkHold.widget,
                    let currentRaw = state.current.widget, let step = model.step(id: stepID)
                else { return }
                let box: UnsafeMutablePointer<GtkWidget> = ptr(holderRaw)
                let next: UnsafeMutablePointer<GtkWidget>
                if state.expanded {
                    next = self.diffFrame(shown)
                    gtk_button_set_label(ptr(linkRaw), NeuralReading.showAllLines(total))
                } else {
                    let reader = BrainDiffReader(
                        lines: R.fullDiff(of: step), inks: self.inks,
                        maxHeight: self.readerHeight(in: scrollerHold.widget))
                    state.reader = reader
                    next = reader.widget
                    gtk_button_set_label(ptr(linkRaw), NeuralReading.showFewerLines)
                }
                gtk_box_remove(ptr(box), currentRaw)
                gtk_box_prepend(ptr(box), next)
                state.current = Gtk.WeakWidget(next)
                state.expanded.toggle()
                if !state.expanded { state.reader = nil }
                self.owner.model.setBrowseOutputExpanded(state.expanded)
                self.bringReaderIntoView(
                    holder: holderRaw, scroller: scrollerHold.widget, body: bodyHold.widget, state: state)
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(link), "clicked", toggle)
        page.subject?.toggleOutput = toggle
        if diffToggles.count > 12 { diffToggles.removeAll() }
        diffToggles[stepID] = state
        return holder
    }

    final class DiffToggle: @unchecked Sendable {
        var current: Gtk.WeakWidget
        var reader: BrainDiffReader?
        var expanded = false
        var scrolledFrom: Double?
        init(current: Gtk.WeakWidget) { self.current = current }
    }

    /// How tall the reader may be: what the card's own scroller shows less the lines above the
    /// diff that are scrolled out of view to make room and the bar under it, so the whole file and
    /// both of its buttons are in view at once; the window's own height where the card is not in a
    /// scroller of its own.
    func readerHeight(in scroller: UnsafeMutablePointer<GtkWidget>?) -> Double {
        let shown = scroller.map { Double(gtk_widget_get_height($0)) } ?? 0
        let ownScroller = scroller.map { gtk_scrolled_window_get_propagate_natural_height(op($0)) == 0 } ?? false
        if ownScroller, shown > 160 { return max(200, min(640, shown - 82)) }
        let viewport = owner.host?.viewportHeight ?? 800
        return max(300, min(640, (viewport * 0.8).rounded()))
    }

    /// Opening the file scrolls the card until its diff leads, so the reader is what is in view;
    /// closing it puts the card back where it was.
    func bringReaderIntoView(
        holder: UnsafeMutablePointer<GtkWidget>, scroller: UnsafeMutablePointer<GtkWidget>?,
        body: UnsafeMutablePointer<GtkWidget>?, state: DiffToggle
    ) {
        guard let scroller, let body else { return }
        let hold = Gtk.WeakWidget(scroller)
        let holderHold = Gtk.WeakWidget(holder)
        let bodyHold = Gtk.WeakWidget(body)
        Gtk.after(60) {
            Gtk.onMain {
                guard let scroller = hold.widget, let holder = holderHold.widget, let body = bodyHold.widget,
                    let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
                else { return }
                if state.expanded {
                    var x = 0.0
                    var y = 0.0
                    guard gtk_widget_translate_coordinates(holder, body, 0, 0, &x, &y) != 0 else { return }
                    state.scrolledFrom = gtk_adjustment_get_value(adjustment)
                    gtk_adjustment_set_value(adjustment, max(0, y - 28))
                } else if let back = state.scrolledFrom {
                    gtk_adjustment_set_value(adjustment, back)
                    state.scrolledFrom = nil
                }
            }
        }
    }

    /// The reader a step's diff has open now, for the harness.
    func diffReader(of stepID: String) -> BrainDiffReader? { diffToggles[stepID]?.reader }

    /// The lines of a diff as rows: a mark, and the text, wrapped, washed for what was added or taken
    /// away.
    func diffFrame(_ lines: [R.DiffLine]) -> UnsafeMutablePointer<GtkWidget> {
        let frame = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-diff")
        for line in lines {
            let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0, "bn-diff-line")
            switch line.kind {
            case .add: Gtk.addClass(row, "bn-diff-add")
            case .remove: Gtk.addClass(row, "bn-diff-del")
            case .context: break
            }
            let mark: String
            switch line.kind {
            case .add: mark = "+"
            case .remove: mark = "\u{2212}"
            case .context: mark = " "
            }
            let markLabel = BrainUI.label(mark, "bn-diff-mark")
            gtk_widget_set_valign(markLabel, GTK_ALIGN_START)
            gtk_widget_set_size_request(markLabel, 22, -1)
            gtk_label_set_xalign(op(markLabel), 0.5)
            BrainUI.add(
                row, markLabel,
                BrainUI.label(line.text.isEmpty ? " " : line.text, "bn-diff-text", wrap: true, selectable: true))
            gtk_box_append(ptr(frame), row)
        }
        return frame
    }

    // MARK: the digest
}
