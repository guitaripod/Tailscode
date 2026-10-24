import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A read-only monitor of one agent: what it is doing in large type, its last steps, the agents it
/// has out, the files it touched and three meters — and the verbs a person has toward it: open its
/// chat, stop it (asked first) or nudge it. It is built once and told what changed, so a second of
/// streaming never rebuilds it.
final class AgentPeekView: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    private let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 14)
    private let glyph = AgentsParts.glyph()
    private let title = Gtk.label("", css: "agents-peek-title", wrap: true, selectable: false)
    private let elapsed = Gtk.label("", css: "agents-elapsed", selectable: false)
    private let facts = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let modelHolder = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    private let machine = Gtk.label("", css: "agents-meta", wrap: true, selectable: false)
    private let askHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let doingBlock = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
    private let doing = Gtk.label("", css: "agents-doing", wrap: true, selectable: false)
    private let object = AgentsParts.monospaced("")
    private let changes = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let added = Gtk.label("", css: "agents-added", selectable: false)
    private let removed = Gtk.label("", css: "agents-removed", selectable: false)
    private let listed = Gtk.label("", css: "agents-note", wrap: true, selectable: false)
    private let watchButton: UnsafeMutablePointer<GtkWidget>
    private let stepsBlock = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private let stepsList = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private let agentsBlock = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private let agentsList = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private let touchedBlock = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private let touchedList = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let meters = AgentsMeters()
    private let beat = AgentBeatStrip()
    private let beatBlock = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let note = Gtk.label("", css: "agents-note", wrap: true, selectable: false)
    private let error = Gtk.label("", css: "agents-error", wrap: true, selectable: true)
    private let openButton: UnsafeMutablePointer<GtkWidget>
    private let stopButton: UnsafeMutablePointer<GtkWidget>
    private let nudgeEntry = gtk_entry_new()!
    private let nudgeButton: UnsafeMutablePointer<GtkWidget>
    private let nudgeRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let actions: AgentsActions
    private var ask: AgentsAskCard?
    private var subject: AgentPeekSubject?
    private var current: AgentFacts?
    private var stepsFor: [AgentStep] = []
    private var childrenFor: [AgentChild] = []
    private var touchedFor: [String] = []
    private var chipFor: ModelChip?
    private var ages: [(label: UnsafeMutablePointer<GtkWidget>, since: Date)] = []
    private var stepAges: [(label: UnsafeMutablePointer<GtkWidget>, step: AgentStep)] = []
    private let select: @Sendable (String) -> Void
    private let closeButton = Gtk.button("✕", css: ["flat", "circular", "agents-close"]) {}
    var onClose: @Sendable () -> Void = {}

    var doingLabel: UnsafeMutablePointer<GtkWidget> { doing }
    var objectLabel: UnsafeMutablePointer<GtkWidget> { object }
    var changesRow: UnsafeMutablePointer<GtkWidget> { changes }
    var addedLabel: UnsafeMutablePointer<GtkWidget> { added }
    var removedLabel: UnsafeMutablePointer<GtkWidget> { removed }
    var titleLabel: UnsafeMutablePointer<GtkWidget> { title }
    var errorLabel: UnsafeMutablePointer<GtkWidget> { error }
    var stopControl: UnsafeMutablePointer<GtkWidget> { stopButton }
    var openControl: UnsafeMutablePointer<GtkWidget> { openButton }
    var nudgeControl: UnsafeMutablePointer<GtkWidget> { nudgeButton }
    var nudgeField: UnsafeMutablePointer<GtkWidget> { nudgeEntry }
    var watchControl: UnsafeMutablePointer<GtkWidget> { watchButton }
    var askCard: AgentsAskCard? { ask }
    var meterReading: AgentsMeters { meters }
    var stepCount: Int { stepsFor.count }
    var key: String? { subject?.key }
    var isListedOnly: Bool { gtk_widget_get_visible(listed) != 0 }
    var contentColumn: UnsafeMutablePointer<GtkWidget> { column }

    init(actions: AgentsActions, select: @escaping @Sendable (String) -> Void) {
        self.actions = actions
        self.select = select
        let scroller = gtk_scrolled_window_new()!
        widget = scroller
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_vexpand(scroller, 1)
        watchButton = Gtk.button(Localized.text("Watch this one"), css: ["agents-watch-button"]) {}
        openButton = Gtk.button(Localized.text("Open chat"), css: ["suggested-action", "agents-open"]) {}
        stopButton = Gtk.button(Localized.text("Stop"), css: ["agents-stop"]) {}
        nudgeButton = Gtk.button(Localized.text("Nudge"), css: ["agents-nudge"]) {}
        build()
    }

    private func build() {
        Gtk.margins(column, top: 18, bottom: 20, leading: 18, trailing: 18)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_valign(elapsed, GTK_ALIGN_START)
        let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_box_append(ptr(head), glyph)
        gtk_box_append(ptr(head), title)
        gtk_box_append(ptr(head), elapsed)
        gtk_widget_set_valign(closeButton, GTK_ALIGN_START)
        tailscode_set_accessible_label(closeButton, Localized.text("Close the peek"))
        gtk_box_append(ptr(head), closeButton)
        gtk_box_append(ptr(facts), machine)
        gtk_box_append(ptr(facts), modelHolder)
        gtk_box_append(ptr(column), head)
        gtk_box_append(ptr(column), facts)
        gtk_box_append(ptr(column), askHolder)

        gtk_box_append(ptr(doingBlock), Gtk.label(Localized.text("DOING NOW"), css: "agents-peek-section", selectable: false))
        gtk_box_append(ptr(doingBlock), doing)
        gtk_widget_set_focusable(object, 0)
        gtk_box_append(ptr(changes), added)
        gtk_box_append(ptr(changes), removed)
        gtk_widget_set_halign(changes, GTK_ALIGN_START)
        gtk_box_append(ptr(doingBlock), object)
        gtk_box_append(ptr(doingBlock), changes)
        gtk_box_append(ptr(doingBlock), listed)
        gtk_box_append(ptr(doingBlock), watchButton)
        gtk_widget_set_halign(watchButton, GTK_ALIGN_START)
        gtk_box_append(ptr(column), doingBlock)

        gtk_box_append(ptr(stepsBlock), Gtk.label(Localized.text("LAST STEPS"), css: "agents-peek-section", selectable: false))
        gtk_box_append(ptr(stepsBlock), stepsList)
        gtk_box_append(ptr(column), stepsBlock)
        gtk_box_append(ptr(agentsBlock), Gtk.label(Localized.text("AGENTS IN THIS CHAT"), css: "agents-peek-section", selectable: false))
        gtk_box_append(ptr(agentsBlock), agentsList)
        gtk_box_append(ptr(column), agentsBlock)
        gtk_box_append(ptr(touchedBlock), Gtk.label(Localized.text("FILES TOUCHED"), css: "agents-peek-section", selectable: false))
        gtk_box_append(ptr(touchedBlock), touchedList)
        gtk_box_append(ptr(column), touchedBlock)
        gtk_box_append(ptr(column), meters.widget)
        gtk_box_append(ptr(beatBlock), beat.widget)
        gtk_box_append(ptr(beatBlock), Gtk.label(Localized.text("last minute"), css: "agents-meta", selectable: false))
        gtk_box_append(ptr(column), beatBlock)
        gtk_box_append(ptr(column), note)
        gtk_box_append(ptr(column), error)

        gtk_entry_set_placeholder_text(ptr(nudgeEntry), Localized.text("Nudge this agent…"))
        gtk_widget_set_hexpand(nudgeEntry, 1)
        tailscode_set_accessible_label(nudgeEntry, Localized.text("Nudge this agent"))
        gtk_box_append(ptr(nudgeRow), nudgeEntry)
        gtk_box_append(ptr(nudgeRow), nudgeButton)
        gtk_widget_set_sensitive(nudgeButton, 0)
        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_hexpand(openButton, 1)
        gtk_box_append(ptr(buttons), openButton)
        gtk_box_append(ptr(buttons), stopButton)
        gtk_box_append(ptr(column), buttons)
        gtk_box_append(ptr(column), nudgeRow)
        gtk_scrolled_window_set_child(op(widget), column)

        gtk_label_set_xalign(op(error), 0)
        Gtk.connect(UnsafeMutableRawPointer(closeButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.onClose() }
        }
        Gtk.connect(UnsafeMutableRawPointer(watchButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, let subject = self.subject else { return }
                self.actions.perform(.watch, key: subject.key, title: subject.title)
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(openButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let key = self?.subject?.key else { return }
                self?.actions.openChat(key)
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(stopButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, let subject = self.subject else { return }
                self.actions.perform(.stop, key: subject.key, title: subject.title)
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(nudgeButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.sendNudge() }
        }
        Gtk.connect(UnsafeMutableRawPointer(nudgeEntry), "activate") { [weak self] in
            Gtk.onMain { [weak self] in self?.sendNudge() }
        }
        Gtk.connect(UnsafeMutableRawPointer(nudgeEntry), "changed") { [weak self] in
            Gtk.onMain { [weak self] in self?.refreshNudge() }
        }
    }

    var nudgeText: String { Dialogs.entryText(nudgeEntry) }

    private func sendNudge() {
        guard let subject, !nudgeText.isEmpty, gtk_widget_get_sensitive(nudgeButton) != 0 else { return }
        actions.perform(.nudge, key: subject.key, title: subject.title, text: nudgeText)
    }

    func clearNudgeIfSent() {
        guard let subject, case .sent(.nudge, _) = actions.state(subject.key) else { return }
        gtk_editable_set_text(op(nudgeEntry), "")
    }

    func show(_ subject: AgentPeekSubject, facts: AgentFacts?, now: Date) {
        let changed = self.subject?.key != subject.key
        self.subject = subject
        current = facts
        if changed {
            gtk_editable_set_text(op(nudgeEntry), "")
            stepsFor = []
            childrenFor = []
            touchedFor = []
        }
        AgentsParts.settleGlyph(glyph, tone: subject.tone, motion: subject.motion)
        AgentsParts.setText(title, subject.title)
        AgentsParts.setText(machine, subject.machine)
        applyChip(subject.chip)
        applyAsk(subject, now: now)
        applyDoing(subject, facts: facts)
        applyLists(facts, now: now)
        if let facts {
            meters.apply(facts)
            beat.show(beat: facts.beat, tone: subject.tone)
        } else {
            AgentsParts.setVisible(meters.widget, false)
            beat.show(beat: nil, tone: subject.tone)
        }
        AgentsParts.setVisible(beatBlock, facts != nil)
        refreshControls()
        tick(now: now)
    }

    private func applyChip(_ chip: ModelChip?) {
        guard chip != chipFor else { return }
        chipFor = chip
        AgentsParts.clearChildren(modelHolder)
        if let chip { gtk_box_append(ptr(modelHolder), SidebarRow.modelLabel(chip)) }
    }

    private func applyAsk(_ subject: AgentPeekSubject, now: Date) {
        guard let card = subject.card else {
            AgentsParts.setVisible(askHolder, false)
            return
        }
        AgentsParts.setVisible(askHolder, true)
        let view: AgentsAskCard
        if let existing = ask {
            view = existing
        } else {
            view = AgentsAskCard(actions: actions, select: select)
            ask = view
            gtk_box_append(ptr(askHolder), view.widget)
        }
        view.apply(card, state: actions.state(card.id), now: now)
    }

    private func applyDoing(_ subject: AgentPeekSubject, facts: AgentFacts?) {
        if let finish = subject.finish {
            AgentsParts.setText(doing, finish.line)
            showObject(nil)
            AgentsParts.setVisible(listed, false)
            AgentsParts.setVisible(watchButton, false)
            return
        }
        if let facts {
            AgentsParts.setText(doing, facts.doing ?? Localized.text("Idle"))
            showObject(facts.object)
            AgentsParts.setVisible(listed, false)
            AgentsParts.setVisible(watchButton, false)
            return
        }
        guard subject.row != nil || subject.card != nil else {
            AgentsParts.setText(doing, Localized.text("Not running now"))
            showObject(nil)
            AgentsParts.setText(listed, subject.laneNote ?? "")
            AgentsParts.setVisible(listed, subject.laneNote != nil)
            AgentsParts.setVisible(watchButton, false)
            return
        }
        let line = subject.row?.line ?? subject.card?.ask.lead ?? ""
        AgentsParts.setText(doing, line.isEmpty ? Localized.text("Working") : line)
        showObject(nil)
        AgentsParts.setText(listed, Localized.text("Listed only, not watched"))
        AgentsParts.setVisible(listed, true)
        let canWatch = subject.row.map { $0.tone == .live && !$0.isWatched && $0.motion.isAnimated } ?? false
        AgentsParts.setVisible(watchButton, canWatch)
    }

    /// The thing the call is about, under the words that say what is happening: the whole command
    /// wrapped, or the path wrapped with the lines an edit adds and removes in their colours.
    private func showObject(_ next: AgentObject?) {
        guard let next, !next.text.isEmpty else {
            AgentsParts.setText(object, "")
            AgentsParts.setVisible(object, false)
            AgentsParts.setVisible(changes, false)
            return
        }
        AgentsParts.setText(object, next.text)
        AgentsParts.setVisible(object, true)
        let hasChanges = next.kind == .path && (next.added != nil || next.removed != nil)
        AgentsParts.setVisible(changes, hasChanges)
        AgentsParts.setVisible(added, next.added != nil)
        AgentsParts.setVisible(removed, next.removed != nil)
        AgentsParts.setText(added, "+\(next.added ?? 0)")
        AgentsParts.setText(removed, "−\(next.removed ?? 0)")
        tailscode_set_accessible_label(
            changes,
            Localized.text("%d lines added, %d removed", next.added ?? 0, next.removed ?? 0))
    }

    private func applyLists(_ facts: AgentFacts?, now: Date) {
        let steps = facts?.steps ?? []
        AgentsParts.setVisible(stepsBlock, !steps.isEmpty)
        if steps != stepsFor {
            stepsFor = steps
            AgentsParts.clearChildren(stepsList)
            stepAges = []
            for step in steps {
                let made = stepLine(step, now: now)
                gtk_box_append(ptr(stepsList), made)
            }
        }
        let children = facts?.children ?? subject?.row?.children ?? []
        AgentsParts.setVisible(agentsBlock, !children.isEmpty)
        if children != childrenFor {
            childrenFor = children
            AgentsParts.clearChildren(agentsList)
            ages = []
            for child in children {
                let made = AgentsChildLine.make(child, now: now)
                if let age = made.age { ages.append(age) }
                gtk_box_append(ptr(agentsList), made.widget)
            }
        }
        let touched = facts?.touched ?? []
        AgentsParts.setVisible(touchedBlock, !touched.isEmpty)
        if touched != touchedFor {
            touchedFor = touched
            AgentsParts.clearChildren(touchedList)
            let chips = touched.map { name -> UnsafeMutablePointer<GtkWidget> in
                let chip = Gtk.label(name, css: "agents-chip", selectable: true)
                gtk_label_set_ellipsize(op(chip), PANGO_ELLIPSIZE_MIDDLE)
                gtk_label_set_max_width_chars(op(chip), 32)
                return chip
            }
            gtk_box_append(ptr(touchedList), Gtk.wrapRow(chips, spacing: 6))
        }
    }

    private func stepLine(_ step: AgentStep, now: Date) -> UnsafeMutablePointer<GtkWidget> {
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let face = AgentsParts.outcomeGlyph(step.outcome)
        let mark = Gtk.label(face.glyph, css: "agents-glyph", selectable: false)
        gtk_widget_set_valign(mark, GTK_ALIGN_START)
        Gtk.setTone(
            mark, face.tone.glyphCSS,
            from: ["glyph-running", "glyph-needs", "glyph-error", "glyph-pending"])
        tailscode_set_accessible_hidden(mark, 1)
        let words = Gtk.label(step.words, css: "agents-step", wrap: true, selectable: true)
        gtk_widget_set_hexpand(words, 1)
        let age = Gtk.label("", css: "agents-elapsed", selectable: false)
        gtk_widget_set_valign(age, GTK_ALIGN_START)
        stepAges.append((age, step))
        gtk_box_append(ptr(line), mark)
        gtk_box_append(ptr(line), words)
        gtk_box_append(ptr(line), age)
        let outcome: String
        switch step.outcome {
        case .running: outcome = Localized.text("running")
        case .done: outcome = Localized.text("done")
        case .failed: outcome = Localized.text("failed")
        case .stopped: outcome = Localized.text("stopped")
        }
        tailscode_set_accessible_label(line, step.words + ", " + outcome)
        return line
    }

    func tick(now: Date) {
        guard let subject else { return }
        let started = current?.startedAt ?? subject.row?.startedAt
        AgentsParts.setText(elapsed, started.map { AgentsParts.clock($0, now: now) } ?? subject.finish.map {
            Localized.text("%@ ago", AgentsParts.age($0.endedAt, now: now))
        } ?? "")
        for entry in stepAges {
            AgentsParts.setText(entry.label, Self.seen(entry.step, now: now))
        }
        for entry in ages { AgentsParts.setText(entry.label, AgentsParts.age(entry.since, now: now)) }
        ask?.tick(now: now)
    }

    /// When this device first saw a step: "now" while it is out, then how long ago. A call has no
    /// duration of its own, so this is never said as how long it took.
    static func seen(_ step: AgentStep, now: Date) -> String {
        guard let seen = step.seen else { return "" }
        let seconds = max(0, now.timeIntervalSince(seen))
        if step.outcome == .running, seconds < 3 { return Localized.text("now") }
        return AgentsParts.age(seen, now: now)
    }

    /// The verbs follow the state: dead while a press travels, Stop only where something is
    /// watched and running, a nudge only with words in it.
    func refreshControls() {
        guard let subject else { return }
        let state = actions.state(subject.key)
        let live = current != nil && subject.finish == nil
        let running = current?.isRunning == true
        AgentsParts.setVisible(stopButton, live && running)
        AgentsParts.setVisible(nudgeRow, live && running)
        AgentsParts.setVisible(openButton, true)
        var failure: String?
        if case .failed(_, let why) = state { failure = why }
        AgentsParts.setVisible(error, failure != nil)
        if let failure { AgentsParts.setText(error, Localized.text("Could not send: %@", failure)) }
        var noted = ""
        switch state {
        case .sent(.nudge, _): noted = Localized.text("Nudge sent. It is read when the turn yields.")
        case .sent(.stop, _): noted = Localized.text("Stop sent")
        default: break
        }
        AgentsParts.setText(note, noted)
        AgentsParts.setVisible(note, !noted.isEmpty)
        let stopTitle: String
        switch state {
        case .inFlight(.stop): stopTitle = Localized.text("Stopping…")
        case .sent(.stop, _): stopTitle = Localized.text("Stop sent")
        default: stopTitle = Localized.text("Stop")
        }
        gtk_button_set_label(ptr(stopButton), stopTitle)
        gtk_widget_set_sensitive(stopButton, state.blocks(.stop) || subject.isAway ? 0 : 1)
        gtk_widget_set_sensitive(watchButton, state.blocks(.watch) ? 0 : 1)
        gtk_widget_set_sensitive(nudgeEntry, state.blocks(.nudge) || subject.isAway ? 0 : 1)
        refreshNudge()
        clearNudgeIfSent()
        if let card = subject.card { ask?.apply(card, state: actions.state(card.id), now: Date()) }
    }

    private func refreshNudge() {
        let state = subject.map { actions.state($0.key) } ?? .idle
        let usable = !nudgeText.isEmpty && !state.blocks(.nudge) && subject?.isAway != true
        gtk_widget_set_sensitive(nudgeButton, usable ? 1 : 0)
    }
}
