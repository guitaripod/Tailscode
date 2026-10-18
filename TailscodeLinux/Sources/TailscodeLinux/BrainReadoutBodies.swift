import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// What each subject of the readout is made of. Every word is `NeuralReadout`'s; this file decides
/// only which widget says it.
extension BrainReadout {
    typealias R = NeuralReadout
    typealias BodyLine = (text: String, tone: R.LineTone)

    /// A step's parts as the panel draws them, whether they came from a step that was read or
    /// from the one a running turn is on.
    struct StepParts {
        let stepID: String
        let header: R.Header
        let subject: R.Subject
        let relations: [R.Relation]
        let why: R.Why?
        let result: R.Result?
        let facts: R.Facts

        init(
            stepID: String, header: R.Header, subject: R.Subject, relations: [R.Relation],
            why: R.Why?, result: R.Result?, facts: R.Facts
        ) {
            self.stepID = stepID
            self.header = header
            self.subject = subject
            self.relations = relations
            self.why = why
            self.result = result
            self.facts = facts
        }

        init(_ step: R.Step) {
            stepID = step.stepID
            header = step.header
            subject = step.subject
            relations = step.relations
            why = step.why
            result = step.result
            facts = step.facts
        }
    }

    private func section(first: Bool = false) -> UnsafeMutablePointer<GtkWidget> {
        let box = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 6, "bn-sec")
        if first { Gtk.addClass(box, "bn-sec-first") }
        return box
    }

    private func labelRow(_ left: String, right: UnsafeMutablePointer<GtkWidget>? = nil, tone: Bool = false)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let label = BrainUI.label(left, "bn-label")
        if tone { Gtk.addClass(label, "bn-tone-text") }
        BrainUI.add(row, label, BrainUI.spacer())
        if let right { gtk_box_append(ptr(row), right) }
        return row
    }

    private func rightLabel(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = BrainUI.label(text, "bn-label-right")
        gtk_label_set_xalign(op(label), 1)
        return label
    }

    private func tallyLabel(added: Int, removed: Int) -> UnsafeMutablePointer<GtkWidget> {
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

    private func subjectSection(_ step: StepParts, page: Page) -> UnsafeMutablePointer<GtkWidget> {
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
    private func commandView(_ subject: R.Subject, page: Page) -> UnsafeMutablePointer<GtkWidget> {
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

    private func zoneOf(_ subject: R.Subject) -> NeuralZone { .shell }

    private func relationRow(_ relations: [R.Relation]) -> UnsafeMutablePointer<GtkWidget> {
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

    private final class RelationBox: @unchecked Sendable {
        let ids: [String]
        weak var owner: BrainView?
        init(ids: [String], owner: BrainView) {
            self.ids = ids
            self.owner = owner
        }
    }

    private func whySection(_ why: R.Why) -> UnsafeMutablePointer<GtkWidget> {
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

    private func resultSection(_ result: R.Result, step: StepParts, page: Page) -> UnsafeMutablePointer<GtkWidget> {
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
    private func outputBlock(
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

    private final class OutputToggle: @unchecked Sendable {
        var current: Gtk.WeakWidget
        var scroller: Gtk.WeakWidget?
        var expanded = false
        init(current: Gtk.WeakWidget) { self.current = current }
    }

    /// The first lines of an edit or a written file, and under them a button that opens the whole
    /// of it in a reader that scrolls, with a button that copies the whole of it. Space and `o`
    /// open and close it from the keyboard, as they do a call's output.
    private func diffBlock(_ edit: R.Edit, stepID: String, page: Page) -> UnsafeMutablePointer<GtkWidget> {
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
    private func readerHeight(in scroller: UnsafeMutablePointer<GtkWidget>?) -> Double {
        let shown = scroller.map { Double(gtk_widget_get_height($0)) } ?? 0
        let ownScroller = scroller.map { gtk_scrolled_window_get_propagate_natural_height(op($0)) == 0 } ?? false
        if ownScroller, shown > 160 { return max(200, min(640, shown - 82)) }
        let viewport = owner.host?.viewportHeight ?? 800
        return max(300, min(640, (viewport * 0.8).rounded()))
    }

    /// Opening the file scrolls the card until its diff leads, so the reader is what is in view;
    /// closing it puts the card back where it was.
    private func bringReaderIntoView(
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
    private func diffFrame(_ lines: [R.DiffLine]) -> UnsafeMutablePointer<GtkWidget> {
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

    func digestHeader(_ digest: R.Digest, in page: Page) {
        let turn = owner.model.turn
        let label = BrainUI.label(BrainWords.turn, "bn-zone", "bn-dim")
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        let verdict = NeuralVerdict.read(turn).verdict
        let tone = verdict.pillTone
        let chip = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6, "bn-chip", Self.toneClass(tone), "bn-chip-mark")
        gtk_box_append(
            ptr(chip),
            BrainUI.verdictGlyph(
                BrainAccount.stepVerdict(for: verdict), size: 12, inks: inks,
                color: BrainDraw.toneColor(tone, inks: inks)))
        gtk_box_append(ptr(chip), BrainUI.label(verdict.pillWord.uppercased(), "bn-chip-word"))
        gtk_widget_set_valign(chip, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(chip, verdict.word)
        let duration = NeuralReading.line(for: turn).duration
        let right = BrainUI.label(
            BrainWords.count(digest.ticks.count, steps: BrainWords.steps(digest.ticks.count), duration: duration),
            "bn-counter", ellipsize: true)
        gtk_widget_set_hexpand(right, 1)
        gtk_label_set_xalign(op(right), 1)
        BrainUI.add(page.header, label, chip, right)
    }

    func digestFoot(_ digest: R.Digest, in page: Page) {
        let steps = BrainUI.label(BrainWords.steps(digest.ticks.count), "bn-fact")
        var began = ""
        if let at = owner.model.turn.startedAt ?? owner.model.steps.compactMap(\.at).min() {
            began = NeuralReading.clock(at)
        }
        let clock = BrainUI.label(began, "bn-fact")
        let hint = BrainUI.label(BrainWords.hoverHint, "bn-fact", ellipsize: true)
        gtk_label_set_xalign(op(hint), 1)
        BrainUI.add(page.foot, steps, clock, BrainUI.spacer(), hint)
    }

    func buildDigest(_ digest: R.Digest, in page: Page) {
        let body = page.body
        let hex = inks.hex
        let headline = section(first: true)
        gtk_box_append(ptr(headline), BrainUI.markup(headlineMarkup(digest), "bn-headline", selectable: true))
        gtk_box_append(ptr(body), headline)

        let bars = section()
        gtk_box_append(
            ptr(bars),
            labelRow(
                BrainWords.whereTheWorkWent, right: rightLabel(BrainWords.steps(digest.ticks.count))))
        for bar in digest.zoneBars { gtk_box_append(ptr(bars), zoneBarRow(bar)) }
        gtk_box_append(ptr(bars), timeline(digest))
        gtk_box_append(ptr(body), bars)

        if !digest.failures.isEmpty {
            let box = section()
            gtk_box_append(
                ptr(box), labelRow(digest.failuresTitle, right: rightLabel(String(digest.failures.count))))
            for failure in digest.failures.prefix(Self.digestRows) { gtk_box_append(ptr(box), failureRow(failure)) }
            if digest.failures.count > Self.digestRows {
                let ref = self.ref
                gtk_box_append(
                    ptr(box),
                    BrainUI.link(BrainWords.moreFailures(digest.failures.count - Self.digestRows)) {
                        ref.view?.browse(.failedToggle, grabFocus: false)
                    })
            }
            gtk_box_append(ptr(body), box)
        }
        if !digest.changed.isEmpty {
            let box = section()
            let model = owner.model
            let added = model.steps.reduce(0) { $0 + ($1.added ?? 0) }
            let removed = model.steps.reduce(0) { $0 + ($1.removed ?? 0) }
            gtk_box_append(
                ptr(box), labelRow(BrainWords.changed, right: tallyLabel(added: added, removed: removed)))
            for change in digest.changed.prefix(Self.digestRows) { gtk_box_append(ptr(box), changedRow(change)) }
            if digest.changed.count > Self.digestRows {
                gtk_box_append(
                    ptr(box),
                    BrainUI.label(BrainWords.moreFiles(digest.changed.count - Self.digestRows), "bn-fact"))
            }
            gtk_box_append(ptr(body), box)
        }
        if let answer = digest.answer, !answer.isEmpty {
            let box = section()
            gtk_box_append(ptr(box), labelRow(BrainWords.answer))
            gtk_box_append(ptr(box), BrainUI.label(answer, "bn-answer", wrap: true, selectable: true))
            gtk_box_append(ptr(body), box)
        }
        _ = hex
    }

    /// How many failures and changed files the digest lists before saying how many more there are:
    /// a turn of two thousand steps is not two thousand widgets.
    static let digestRows = 6

    /// The headline with its last sentence in the warning colour when the turn had a failure to
    /// tell, the way the mock sets it.
    private func headlineMarkup(_ digest: R.Digest) -> String {
        let model = owner.model
        let card = model.brainCard(now: Date())
        let sentence = card.digest.isEmpty ? digest.headline : card.digest
        guard let clause = card.headline.piece(.failure)?.text else { return BrainUI.escape(sentence) }
        let word = clause.prefix(1).uppercased() + clause.dropFirst() + "."
        return BrainUI.escape(sentence) + " <span foreground=\"\(inks.hex.warn)\">\(BrainUI.escape(word))</span>"
    }

    private func zoneBarRow(_ bar: R.ZoneBar) -> UnsafeMutablePointer<GtkWidget> {
        let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, "bn-bar-row", "bn-z-\(BrainUI.zoneName(bar.zone))")
        let name = BrainUI.label(bar.label, "bn-bar-name", "bn-tone-text")
        gtk_widget_set_size_request(name, 72, -1)
        let tone = inks.corrected(bar.zone)
        let canvas = barCanvas(fraction: bar.fraction, color: tone, height: 6)
        let count = BrainUI.label(String(bar.count), "bn-bar-count")
        gtk_widget_set_size_request(count, 28, -1)
        gtk_label_set_xalign(op(count), 1)
        BrainUI.add(row, name, canvas, count)
        let zone = bar.zone
        let ref = self.ref
        BrainUI.clickable(row) { ref.view?.dive(into: zone) }
        tailscode_set_accessible_label(row, "\(bar.label) \(bar.count)")
        return row
    }

    /// A horizontal bar: a quiet track and the fill, both in the zone's colour.
    private func barCanvas(fraction: Double, color: BrainInks.RGB, height: Double)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let canvasColor = inks.canvas
        let box = Unmanaged.passRetained(BarBox(fraction: fraction, color: color, ground: canvasColor)).toOpaque()
        _ = Gtk.releaseInstalled
        let canvas = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let bar = Unmanaged<BarBox>.fromOpaque(raw).takeUnretainedValue()
                let h = Double(height)
                let track = BrainInks.mix(bar.ground, bar.color, 0.12)
                BrainPainter.round(cr, 0, 0, Double(width), h, h / 2)
                cairo_set_source_rgba(cr, track.red, track.green, track.blue, 1)
                cairo_fill(cr)
                BrainPainter.round(cr, 0, 0, max(h, Double(width) * bar.fraction), h, h / 2)
                cairo_set_source_rgba(cr, bar.color.red, bar.color.green, bar.color.blue, 1)
                cairo_fill(cr)
            }, box,
            { raw in
                guard let raw else { return }
                Unmanaged<BarBox>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(canvas, 20, Int32(height))
        gtk_widget_set_hexpand(canvas, 1)
        gtk_widget_set_valign(canvas, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(canvas, 0)
        return canvas
    }

    private final class BarBox: @unchecked Sendable {
        let fraction: Double
        let color: BrainInks.RGB
        let ground: BrainInks.RGB
        init(fraction: Double, color: BrainInks.RGB, ground: BrainInks.RGB) {
            self.fraction = fraction
            self.color = color
            self.ground = ground
        }
    }

    // MARK: the timeline strip

    private func timeline(_ digest: R.Digest) -> UnsafeMutablePointer<GtkWidget> {
        let strip = TimelineStrip(digest: digest, owner: owner, inks: inks)
        let canvas = strip.make()
        gtk_widget_set_size_request(canvas, -1, 32)
        gtk_widget_set_margin_top(canvas, 8)
        return canvas
    }

    private final class TimelineStrip: @unchecked Sendable {
        let digest: R.Digest
        weak var owner: BrainView?
        let inks: BrainInks
        var hovered: Int?
        var font = "Sans Bold 9"
        var scrubbing = false
        var canvas: UnsafeMutablePointer<GtkWidget>?

        init(digest: R.Digest, owner: BrainView, inks: BrainInks) {
            self.digest = digest
            self.owner = owner
            self.inks = inks
        }

        private var slots: Double {
            Double(digest.ticks.count) + (digest.answerBegins == nil ? 0 : 1.6)
        }

        func x(_ index: Int, width: Double) -> Double {
            (Double(index) + 0.5) / max(1, slots) * width
        }

        func index(at x: Double, width: Double) -> Int? {
            guard !digest.ticks.isEmpty, width > 0 else { return nil }
            let raw = Int((x / width * slots - 0.5).rounded())
            let clamped = min(max(0, raw), digest.ticks.count - 1)
            return abs(self.x(clamped, width: width) - x) <= 7 ? clamped : nil
        }

        func make() -> UnsafeMutablePointer<GtkWidget> {
            let box = Unmanaged.passRetained(self).toOpaque()
            _ = Gtk.releaseInstalled
            let area = tailscode_canvas_new(
                { cr, width, height, raw in
                    guard let cr, let raw else { return }
                    Unmanaged<TimelineStrip>.fromOpaque(raw).takeUnretainedValue()
                        .paint(cr, width: Double(width), height: Double(height))
                }, box,
                { raw in
                    guard let raw else { return }
                    Unmanaged<TimelineStrip>.fromOpaque(raw).release()
                })!
            canvas = area
            font = BrainUI.font(of: BrainUI.label("A", "bn-label"))
            Gtk.onPointer(
                area,
                move: { [weak self] x, _ in self?.moved(x: x) },
                leave: { [weak self] in self?.left() })
            let click = Unmanaged.passRetained(ClickBox { [weak self] x in self?.pressed(x: x) }).toOpaque()
            _ = Gtk.releaseInstalled
            tailscode_on_click_at(
                area,
                { x, _, _, button, raw in
                    guard let raw, button == 1 else { return }
                    Unmanaged<ClickBox>.fromOpaque(raw).takeUnretainedValue().handler(x)
                }, click)
            Gtk.onPressHold(
                area, down: {}, up: { [weak self] in Gtk.onMain { [weak self] in self?.released() } })
            gtk_widget_set_cursor_from_name(area, "pointer")
            tailscode_set_accessible_label(
                area, Localized.text("Timeline of %lld steps", digest.ticks.count))
            return area
        }

        private final class ClickBox: @unchecked Sendable {
            let handler: (Double) -> Void
            init(_ handler: @escaping (Double) -> Void) { self.handler = handler }
        }

        private func width() -> Double {
            canvas.map { Double(gtk_widget_get_width($0)) } ?? 0
        }

        private func moved(x: Double) {
            if scrubbing {
                scrub(x: x)
                return
            }
            let found = index(at: x, width: width())
            guard found != hovered else { return }
            hovered = found
            owner?.stripHover(found.map { digest.ticks[$0].stepID })
            canvas.map { gtk_widget_queue_draw($0) }
        }

        private func left() {
            guard hovered != nil, !scrubbing else { return }
            hovered = nil
            owner?.stripHover(nil)
            canvas.map { gtk_widget_queue_draw($0) }
        }

        private func pressed(x: Double) {
            scrubbing = true
            scrub(x: x)
        }

        private func released() {
            guard scrubbing else { return }
            scrubbing = false
            owner?.stripScrubEnded()
        }

        private func scrub(x: Double) {
            let wide = width()
            guard wide > 0, !digest.ticks.isEmpty else { return }
            let raw = Int((x / wide * slots - 0.5).rounded())
            let target = min(max(0, raw), digest.ticks.count - 1)
            owner?.stripScrub(toStep: digest.ticks[target].stepID)
            hovered = target
            canvas.map { gtk_widget_queue_draw($0) }
        }

        func paint(_ cr: OpaquePointer, width: Double, height: Double) {
            let baseline = height - 4
            let rule = inks.rule2
            cairo_set_source_rgba(cr, rule.red, rule.green, rule.blue, 1)
            cairo_set_line_width(cr, 1)
            cairo_new_path(cr)
            cairo_move_to(cr, 0, baseline + 0.5)
            cairo_line_to(cr, width, baseline + 0.5)
            cairo_stroke(cr)
            for tick in digest.ticks {
                let center = x(tick.index, width: width)
                let tall = tick.isFailure && !tick.isRecovered
                let h = tick.isFailure ? 28.0 : 14.0
                let color = tick.isFailure ? inks.cDanger : inks.corrected(tick.zone)
                cairo_set_source_rgba(cr, color.red, color.green, color.blue, tall || !tick.isFailure ? 1 : 0.85)
                BrainPainter.round(cr, center - 2, baseline - 4 - h + 4, 4, h, 2)
                cairo_fill(cr)
                if hovered == tick.index {
                    cairo_set_source_rgba(cr, inks.ink.red, inks.ink.green, inks.ink.blue, 1)
                    cairo_set_line_width(cr, 2)
                    BrainPainter.round(cr, center - 3, baseline - h, 6, h + 2, 3)
                    cairo_stroke(cr)
                }
            }
            if let begins = digest.answerBegins {
                let center = x(begins, width: width)
                let ink = inks.dim
                cairo_set_source_rgba(cr, ink.red, ink.green, ink.blue, 1)
                cairo_set_line_width(cr, 1)
                cairo_new_path(cr)
                cairo_move_to(cr, center + 0.5, 0)
                cairo_line_to(cr, center + 0.5, height)
                cairo_stroke(cr)
                var measured = 0.0
                var textHeight = 0.0
                let word = BrainWords.answer
                tailscode_text_measure(word, font, 0, 1, &measured, &textHeight)
                _ = tailscode_text_draw(
                    cr, word, font, center - measured - 6, 0, 0, 0, 1, ink.red, ink.green, ink.blue, 1)
            }
        }
    }

    // MARK: failures and changes

    private func failureRow(_ failure: R.Failure) -> UnsafeMutablePointer<GtkWidget> {
        let hex = inks.hex
        let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, "bn-list-row")
        let number = BrainUI.label(String(failure.number), "bn-fail-no")
        gtk_widget_set_size_request(number, 28, -1)
        gtk_widget_set_valign(number, GTK_ALIGN_START)
        let text = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(text, 1)
        let title = BrainUI.label(failure.title, "bn-fail-title", ellipsize: true)
        let first = BrainUI.label(failure.firstLine, "bn-fail-line", ellipsize: true)
        BrainUI.add(text, title, first)
        let retried = BrainUI.label(failure.label, "bn-fail-re")
        if failure.verdict == .failed { Gtk.addClass(retried, "bn-fail-never") }
        gtk_widget_set_valign(retried, GTK_ALIGN_CENTER)
        let mark = BrainUI.verdictGlyph(failure.verdict, size: 14, inks: inks)
        BrainUI.add(row, number, text, mark, retried)
        tailscode_set_accessible_label(row, "\(failure.verdictWord), \(failure.label)")
        let id = failure.stepID
        let ref = self.ref
        BrainUI.clickable(row) { ref.view?.pin(id) }
        _ = hex
        return row
    }

    private func changedRow(_ change: R.Changed) -> UnsafeMutablePointer<GtkWidget> {
        let hex = inks.hex
        let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, "bn-list-row")
        let path = BrainUI.markup(
            "<span foreground=\"\(hex.dim)\">\(BrainUI.escape(change.shortDirectory))</span><span foreground=\"\(hex.text)\" weight=\"bold\">\(BrainUI.escape(change.fileName))</span>",
            "bn-changed-path", wrap: false)
        gtk_label_set_ellipsize(op(path), PANGO_ELLIPSIZE_START)
        gtk_widget_set_hexpand(path, 1)
        let total = change.added + change.removed
        let meter = changeMeter(added: change.added, removed: change.removed, width: Double(min(72, max(12, total * 6))))
        let tally = tallyLabel(added: change.added, removed: change.removed)
        gtk_widget_set_size_request(tally, 56, -1)
        BrainUI.add(row, path, meter, tally)
        let id = change.stepID
        let ref = self.ref
        BrainUI.clickable(row) { ref.view?.pin(id) }
        return row
    }

    private func changeMeter(added: Int, removed: Int, width: Double) -> UnsafeMutablePointer<GtkWidget> {
        let box = Unmanaged.passRetained(MeterBox(added: added, removed: removed, inks: inks)).toOpaque()
        _ = Gtk.releaseInstalled
        let canvas = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let meter = Unmanaged<MeterBox>.fromOpaque(raw).takeUnretainedValue()
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
            }, box,
            { raw in
                guard let raw else { return }
                Unmanaged<MeterBox>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(canvas, Int32(width), 6)
        gtk_widget_set_valign(canvas, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(canvas, 0)
        return canvas
    }

    private final class MeterBox: @unchecked Sendable {
        let added: Int
        let removed: Int
        let inks: BrainInks
        init(added: Int, removed: Int, inks: BrainInks) {
            self.added = added
            self.removed = removed
            self.inks = inks
        }
    }

    // MARK: now, the ask, a zone, the replay

    func buildNow(_ now: R.Now, in page: Page) {
        let body = page.body
        let step = now.step
        var parts = NowParts(
            stepID: step?.stepID, counter: nil, chip: nil, tail: nil, tailLabel: nil, soFar: nil,
            factsLeft: nil, factsRight: nil)
        let nowLabel = BrainUI.label(now.label, "bn-now")
        gtk_widget_set_valign(nowLabel, GTK_ALIGN_CENTER)
        let lead = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        BrainUI.add(lead, pulse(attention: false, in: page), nowLabel)
        if let step {
            applyZone(step.header.zone, to: page)
            header(for: step.header, to: page, lead: lead)
            parts = NowParts(
                stepID: step.stepID, counter: page.counterLabel, chip: nil, tail: nil, tailLabel: nil,
                soFar: nil, factsLeft: nil, factsRight: nil)
            buildStep(
                StepParts(
                    stepID: step.stepID, header: step.header, subject: step.subject, relations: [],
                    why: step.why, result: nil, facts: step.facts), in: page)
        } else {
            gtk_box_append(ptr(page.header), lead)
        }
        var tailLabel: UnsafeMutablePointer<GtkWidget>?
        if !now.tail.lines.isEmpty {
            let box = section()
            gtk_box_append(
                ptr(box),
                labelRow(BrainWords.output, right: rightLabel(BrainWords.lastLines(now.tail.lines.count))))
            let framed = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-out-box")
            let label = BrainUI.markup(tailMarkup(now.tail.lines.map { ($0.text, $0.tone) }, caret: true), "bn-out", selectable: true)
            tailLabel = label
            gtk_box_append(ptr(framed), label)
            gtk_box_append(ptr(box), framed)
            gtk_box_append(ptr(body), box)
        }
        let soFar = soFarSection(headline: now.soFar.headline, chips: now.soFar.chips)
        gtk_box_append(ptr(body), soFar.section)
        if let step { footFacts(step.facts, in: page, right: step.facts.started) }
        parts = NowParts(
            stepID: parts.stepID, counter: page.counterLabel, chip: nil, tail: nil,
            tailLabel: tailLabel, soFar: soFar.content, factsLeft: page.factsLeft,
            factsRight: page.factsRight)
        page.now = parts
    }

    private func soFarSection(headline: String, chips: [NeuralBrainCard.ZoneChip])
        -> (section: UnsafeMutablePointer<GtkWidget>, content: UnsafeMutablePointer<GtkWidget>)
    {
        let outer = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-sofar")
        let content = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        gtk_box_append(ptr(outer), BrainUI.label(BrainWords.soFar, "bn-label"))
        gtk_box_append(ptr(outer), content)
        rebuildSoFar(content, headline: headline, chips: chips)
        return (outer, content)
    }

    func rebuildSoFar(
        _ content: UnsafeMutablePointer<GtkWidget>, headline: String, chips: [NeuralBrainCard.ZoneChip]
    ) {
        BrainUI.clear(content)
        gtk_box_append(ptr(content), BrainUI.label(headline, "bn-sofar-h", wrap: true, selectable: true))
        guard !chips.isEmpty else { return }
        let inks = self.inks
        gtk_box_append(
            ptr(content),
            Gtk.wrapRow(chips.map { BrainUI.zoneChip($0, inks: inks, compact: true) }, spacing: 6))
    }

    func buildAsk(_ ask: R.Ask, in page: Page) {
        let body = page.body
        let step = ask.step
        applyZone(step.header.zone, to: page)
        let label = BrainUI.label(BrainWords.needsYou, "bn-now", "bn-now-attention")
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        let lead = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        BrainUI.add(lead, pulse(attention: true, in: page), label)
        header(for: step.header, to: page, lead: lead)
        let outer = section(first: true)
        let card = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 8, "bn-ask")
        gtk_box_append(ptr(card), BrainUI.label(ask.sentence, "bn-ask-title", wrap: true))
        let subject = step.subject
        if !subject.primary.isEmpty {
            let hex = inks.hex
            let text =
                subject.kind == .command
                ? "<span foreground=\"\(hex.warn)\">$</span> \(BrainUI.escape(subject.primary))"
                : BrainUI.escape(subject.primary)
            gtk_box_append(ptr(card), BrainUI.markup(text, "bn-cmd", selectable: true))
        }
        if let why = step.why {
            gtk_box_append(ptr(card), BrainUI.label(why.text, "bn-why-text", wrap: true, selectable: true))
        }
        let ref = self.ref
        let go = Gtk.button(ask.actionLabel + " \u{2193}", css: ["bn-ask-button"]) {
            Gtk.onMain { ref.view?.goToApproval() }
        }
        gtk_widget_set_halign(go, GTK_ALIGN_START)
        gtk_widget_set_cursor_from_name(go, "pointer")
        gtk_box_append(ptr(card), go)
        gtk_box_append(ptr(outer), card)
        gtk_box_append(ptr(body), outer)
        if let clock = step.facts.clock {
            let note = section()
            gtk_box_append(ptr(note), BrainUI.label(BrainWords.waitingSince(clock).uppercased(), "bn-label", wrap: true))
            gtk_box_append(ptr(body), note)
        }
        let model = owner.model
        let card2 = model.brainCard(now: Date())
        let soFar = soFarSection(headline: NeuralReading.headline(for: model.turn), chips: card2.chips)
        gtk_box_append(ptr(body), soFar.section)
        footFacts(step.facts, in: page, right: step.facts.clock.map(BrainWords.asked))
    }

    func buildZone(_ list: R.ZoneList, in page: Page) {
        let zone = list.zone
        let inks = self.inks
        gtk_box_append(ptr(page.header), BrainUI.shapeGlyph(zone, size: 18) { inks.corrected(zone) })
        let name = BrainUI.label(list.label, "bn-zone", "bn-tone-text")
        gtk_widget_set_valign(name, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(page.header), name)
        gtk_box_append(
            ptr(page.header),
            BrainUI.label(BrainWords.steps(list.rows.count).uppercased(), "bn-chip", "bn-chip-live"))
        let failed = list.rows.filter { $0.status == .failed }.count
        if failed > 0 {
            gtk_box_append(
                ptr(page.header),
                BrainUI.label(
                    Localized.text("%lld FAILED", failed), "bn-chip", "bn-chip-danger"))
        }
        let hint = BrainUI.label(BrainWords.surfaceHint, "bn-counter", ellipsize: true)
        gtk_widget_set_hexpand(hint, 1)
        gtk_label_set_xalign(op(hint), 1)
        gtk_box_append(ptr(page.header), hint)
        let box = section(first: true)
        gtk_box_append(ptr(box), labelRow(BrainWords.zoneSteps(list.label)))
        let rows = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-zlist")
        let pinned = owner.model.pinnedStep
        for row in list.rows { gtk_box_append(ptr(rows), zoneRow(row, selected: row.stepID == pinned)) }
        gtk_box_append(ptr(box), rows)
        gtk_box_append(ptr(page.body), box)
        let total = owner.model.steps.count
        BrainUI.add(
            page.foot, BrainUI.label(BrainWords.stepsOf(list.rows.count, total), "bn-fact"),
            BrainUI.spacer(), BrainUI.label(BrainWords.zoneHint, "bn-fact", ellipsize: true))
    }

    private func zoneRow(_ row: R.ZoneRow, selected: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let line = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8, "bn-zrow")
        if selected { Gtk.addClass(line, "bn-zrow-sel") }
        if row.status == .failed { Gtk.addClass(line, "bn-zrow-bad") }
        let number = BrainUI.label(String(row.number), "bn-zrow-no")
        gtk_widget_set_size_request(number, 28, -1)
        gtk_label_set_xalign(op(number), 1)
        let title = BrainUI.label(row.title, "bn-zrow-title")
        gtk_widget_set_size_request(title, 56, -1)
        let argument = BrainUI.label(row.argument, "bn-zrow-arg", ellipsize: true)
        gtk_widget_set_hexpand(argument, 1)
        let dot = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(dot, "bn-zrow-dot")
        Gtk.addClass(dot, Self.dotClass(row.tone))
        gtk_widget_set_size_request(dot, 8, 8)
        gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
        BrainUI.add(line, number, title, argument, dot)
        let id = row.stepID
        let ref = self.ref
        BrainUI.clickable(line) { ref.view?.pin(id) }
        tailscode_set_accessible_label(line, "\(row.number) \(row.title) \(row.argument)")
        return line
    }

    private static func dotClass(_ tone: NeuralTone) -> String {
        switch tone {
        case .danger: return "bn-dot-danger"
        case .attention: return "bn-dot-attention"
        case .quiet: return "bn-dot-quiet"
        case .live, .identity: return "bn-dot-live"
        }
    }

    func buildReplay(_ replay: R.Replay, in page: Page) {
        let lead = BrainUI.label("\u{25B6} " + BrainWords.replaying, "bn-now")
        gtk_widget_set_valign(lead, GTK_ALIGN_CENTER)
        if let current = replay.current {
            applyZone(current.header.zone, to: page)
            header(for: current.header, to: page, lead: lead)
            buildStep(StepParts(current), in: page)
            footFacts(current.facts, in: page)
        } else {
            gtk_box_append(ptr(page.header), lead)
            BrainUI.add(page.foot, BrainUI.label(NeuralReading.replayLabel, "bn-fact"))
        }
        if !replay.log.isEmpty {
            let box = section()
            gtk_box_append(ptr(box), labelRow(BrainWords.log))
            let rows = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "bn-zlist")
            for row in replay.log { gtk_box_append(ptr(rows), zoneRow(row, selected: false)) }
            gtk_box_append(ptr(box), rows)
            if replay.hiddenBefore > 0 {
                gtk_box_append(ptr(box), BrainUI.label(BrainWords.earlier(replay.hiddenBefore), "bn-fact"))
            }
            gtk_box_append(ptr(page.body), box)
        }
    }
}
