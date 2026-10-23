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

    func soFarSection(headline: String, chips: [NeuralBrainCard.ZoneChip])
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

    func zoneRow(_ row: R.ZoneRow, selected: Bool) -> UnsafeMutablePointer<GtkWidget> {
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

    static func dotClass(_ tone: NeuralTone) -> String {
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
