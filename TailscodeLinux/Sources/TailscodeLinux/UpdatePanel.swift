import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// One machine's software, drawn from Core's `UpdateCard` and nothing else.
///
/// It is rewritten in place rather than rebuilt: a job in flight lands a new reading every couple
/// of seconds for minutes on end, and a card that rebuilt itself on each one would throw away
/// whatever the reader had opened and move a button under the pointer. Lists — the steps, what is
/// new, the details — are laid out again only when their content actually changes; the clock
/// beside the step under way ticks on its own, once a second, while the card's window is mapped.
///
/// Two ways to sit: `standalone` draws its own boxed card and names the machine above the
/// headline, for the window listing every machine; `embedded` draws neither, for a screen that is
/// already about that one machine.
final class UpdateCardView: @unchecked Sendable {
    enum Style {
        case standalone
        case embedded
    }

    var onAction: ((UpdateCard.Action) -> Void)?
    var onAutomation: ((Bool) -> Void)?

    let widget: UnsafeMutablePointer<GtkWidget>

    private let style: Style
    private let machineLabel = Gtk.label("", css: "sidebar-detail", selectable: false)
    private let glyph = Gtk.label("·", selectable: false)
    private let headlineLabel = Gtk.label("", css: "card-title", wrap: true, selectable: false)
    private let versionLabel = Gtk.label("", css: "usage-plan", wrap: true, selectable: false)
    private let messageLabel = Gtk.label("", wrap: true)
    private let stepsBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
    private let notesTitleLabel = Gtk.label("", css: "update-heading", selectable: false)
    private let notesBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
    private let moreNotesButton = gtk_button_new()!
    private let actionsBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let automationBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
    private let automationTitleLabel = Gtk.label("", selectable: false)
    private let automationSwitch = gtk_switch_new()!
    private let automationStatusLabel = Gtk.label("", css: "seam-footnote", wrap: true, selectable: false)
    private let detailsButton = gtk_button_new()!
    private let factsBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let footnoteLabel = Gtk.label("", css: "seam-footnote", selectable: false)

    private var card: UpdateCard?
    private var notesExpanded = false
    private var detailsExpanded = false
    private var writingAutomation = false
    private var drawnSteps: [StepShape] = []
    private var stepRows: [(id: String, detail: UnsafeMutablePointer<GtkWidget>, clock: UnsafeMutablePointer<GtkWidget>)] = []
    private var drawnNotes: [ReleaseNote] = []
    private var drawnFacts: [UpdateCard.Fact] = []
    private var drawnActions: [ActionKey] = []

    private var clockLabel: UnsafeMutablePointer<GtkWidget>?
    private var clockSince: Date?
    private var clockMapped = false
    private var clockRunning = false

    /// How much of what is new a card says before it offers the rest.
    private static let noteLimit = 4
    private static let glyphTones = ActivityTone.allCases.map(\.glyphCSS)

    init(style: Style) {
        self.style = style
        let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        if style == .standalone { Gtk.addClass(root, "usage-card") }
        widget = root
        gtk_widget_set_hexpand(root, 1)

        gtk_widget_set_visible(machineLabel, style == .standalone ? 1 : 0)
        gtk_box_append(ptr(root), machineLabel)

        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        let titles = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(titles, 1)
        gtk_box_append(ptr(titles), headlineLabel)
        gtk_box_append(ptr(titles), versionLabel)
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_box_append(ptr(header), glyph)
        gtk_box_append(ptr(header), titles)
        gtk_box_append(ptr(root), header)

        gtk_box_append(ptr(root), messageLabel)
        gtk_box_append(ptr(root), stepsBox)

        gtk_box_append(ptr(root), notesTitleLabel)
        gtk_box_append(ptr(root), notesBox)
        Gtk.addClass(moreNotesButton, "flat")
        Gtk.addClass(moreNotesButton, "update-link")
        gtk_widget_set_halign(moreNotesButton, GTK_ALIGN_START)
        gtk_box_append(ptr(root), moreNotesButton)

        gtk_box_append(ptr(root), actionsBox)

        let switchLine = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_widget_set_hexpand(automationTitleLabel, 1)
        gtk_widget_set_valign(automationSwitch, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(switchLine), automationTitleLabel)
        gtk_box_append(ptr(switchLine), automationSwitch)
        gtk_box_append(ptr(automationBox), switchLine)
        gtk_box_append(ptr(automationBox), automationStatusLabel)
        gtk_box_append(ptr(root), automationBox)

        Gtk.addClass(detailsButton, "flat")
        Gtk.addClass(detailsButton, "update-link")
        gtk_widget_set_halign(detailsButton, GTK_ALIGN_START)
        gtk_box_append(ptr(root), detailsButton)
        gtk_widget_set_visible(factsBox, 0)
        gtk_box_append(ptr(root), factsBox)

        gtk_box_append(ptr(root), footnoteLabel)

        Gtk.connect(UnsafeMutableRawPointer(moreNotesButton), "clicked") { [weak self] in
            self?.toggleNotes()
        }
        Gtk.connect(UnsafeMutableRawPointer(detailsButton), "clicked") { [weak self] in
            self?.toggleDetails()
        }
        Gtk.onNotify(UnsafeMutableRawPointer(automationSwitch), property: "active") { [weak self] in
            guard let self, !self.writingAutomation else { return }
            let enabled = gtk_switch_get_active(op(self.automationSwitch)) != 0
            gtk_widget_set_sensitive(self.automationSwitch, 0)
            self.onAutomation?(enabled)
        }
        Gtk.connect(UnsafeMutableRawPointer(root), "map") { [weak self] in
            self?.clockMapped = true
            self?.runClock()
        }
        Gtk.connect(UnsafeMutableRawPointer(root), "unmap") { [weak self] in
            self?.clockMapped = false
            self?.runClock()
        }
    }

    /// One answer painted into the card it belongs to.
    func apply(_ card: UpdateCard) {
        self.card = card
        if style == .standalone {
            gtk_label_set_text(
                op(machineLabel),
                [card.machine, card.subtitle].compactMap { $0 }.joined(separator: " · ").uppercased())
        }

        gtk_label_set_text(op(glyph), card.icon.glyph)
        Gtk.setTone(glyph, card.icon.glyphCSS, from: Self.glyphTones)
        ActivityPulse.apply(card.icon, to: glyph)

        gtk_label_set_text(op(headlineLabel), card.headline)
        Gtk.setTone(
            headlineLabel, card.stage == .failed ? "pending-text-failed" : nil,
            from: ["pending-text-failed"])
        gtk_widget_set_tooltip_text(headlineLabel, card.accessibility)

        gtk_label_set_text(op(versionLabel), card.versionLine ?? "")
        gtk_widget_set_visible(versionLabel, card.versionLine == nil ? 0 : 1)

        gtk_label_set_text(op(messageLabel), card.message ?? "")
        gtk_widget_set_visible(messageLabel, card.message == nil ? 0 : 1)

        renderSteps(card.steps)
        renderNotes(card)
        renderActions(card)
        renderAutomation(card.automation)
        renderFacts(card.facts)

        gtk_label_set_text(op(footnoteLabel), card.footnote ?? "")
        gtk_widget_set_visible(footnoteLabel, card.footnote == nil ? 0 : 1)
    }

    /// The machine did not change its policy; the switch goes back to what the machine last said.
    func restoreAutomation() {
        renderAutomation(card?.automation)
    }

    private struct StepShape: Equatable {
        let id: String
        let title: String
        let state: UpdateCard.Step.State
    }

    private func renderSteps(_ steps: [UpdateCard.Step]) {
        gtk_widget_set_visible(stepsBox, steps.isEmpty ? 0 : 1)
        let shape = steps.map { StepShape(id: $0.id, title: $0.title, state: $0.state) }
        if shape != drawnSteps {
            Gtk.removeChildren(of: stepsBox)
            stepRows = []
            for step in steps {
                let (row, detail, clock) = buildStepRow(step)
                stepRows.append((id: step.id, detail: detail, clock: clock))
                gtk_box_append(ptr(stepsBox), row)
            }
            drawnSteps = shape
        } else {
            for (built, step) in zip(stepRows, steps) {
                gtk_label_set_text(op(built.detail), step.detail ?? "")
                gtk_widget_set_visible(built.detail, step.detail == nil ? 0 : 1)
            }
        }
        if let active = steps.first(where: { $0.state == .active }), let since = active.since,
            let clock = stepRows.first(where: { $0.id == active.id })?.clock
        {
            clockLabel = clock
            clockSince = since
        } else {
            clockLabel = nil
            clockSince = nil
        }
        runClock()
    }

    private func buildStepRow(_ step: UpdateCard.Step)
        -> (row: UnsafeMutablePointer<GtkWidget>, detail: UnsafeMutablePointer<GtkWidget>,
            clock: UnsafeMutablePointer<GtkWidget>)
    {
        let mark: UnsafeMutablePointer<GtkWidget>
        switch step.state {
        case .active:
            let spinner = gtk_spinner_new()!
            gtk_spinner_set_spinning(op(spinner), 1)
            mark = spinner
        case .done:
            mark = Gtk.label("✓", css: "glyph-done", selectable: false)
        case .failed:
            mark = Gtk.label("✗", css: "glyph-error", selectable: false)
        case .pending:
            mark = Gtk.label("○", css: "glyph-pending", selectable: false)
        }
        gtk_widget_set_valign(mark, GTK_ALIGN_START)
        gtk_widget_set_size_request(mark, 18, -1)

        let title = Gtk.label(
            step.title, css: step.state == .failed ? "pending-text-failed" : nil, selectable: false)
        if step.state == .pending { Gtk.addClass(title, "dim") }
        gtk_widget_set_hexpand(title, 1)

        let clock = Gtk.label("", css: "draw-clock", selectable: false)

        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(line), title)
        gtk_box_append(ptr(line), clock)

        let detail = Gtk.label(step.detail ?? "", css: "tool-detail", wrap: true, selectable: false)
        gtk_widget_set_visible(detail, step.detail == nil ? 0 : 1)

        let text = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(text, 1)
        gtk_box_append(ptr(text), line)
        gtk_box_append(ptr(text), detail)

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(row), mark)
        gtk_box_append(ptr(row), text)
        return (row, detail, clock)
    }

    /// A clock that ticks only while there is a step under way and this card's window is mapped —
    /// closed or minimised, it stops rather than redrawing text nobody can see.
    private func runClock() {
        guard clockMapped, clockLabel != nil, clockSince != nil else {
            clockRunning = false
            return
        }
        tickClock()
        guard !clockRunning else { return }
        clockRunning = true
        scheduleClockTick()
    }

    private func scheduleClockTick() {
        Gtk.after(1000) { [weak self] in
            guard let self, self.clockRunning else { return }
            self.tickClock()
            self.scheduleClockTick()
        }
    }

    private func tickClock() {
        guard let since = clockSince, let clockLabel else { return }
        gtk_label_set_text(op(clockLabel), RelativeWhen.clock(Date().timeIntervalSince(since)))
    }

    private func renderNotes(_ card: UpdateCard) {
        let lines = card.notes.flatMap(\.items)
        gtk_label_set_text(op(notesTitleLabel), (card.notesTitle ?? "").uppercased())
        gtk_widget_set_visible(notesTitleLabel, lines.isEmpty ? 0 : 1)
        gtk_widget_set_visible(notesBox, lines.isEmpty ? 0 : 1)
        if card.notes != drawnNotes {
            drawnNotes = card.notes
            notesExpanded = false
            rebuildNotes()
        }
        let hidden = lines.count - Self.noteLimit
        gtk_widget_set_visible(moreNotesButton, hidden > 0 ? 1 : 0)
        gtk_button_set_label(
            ptr(moreNotesButton),
            notesExpanded
                ? Localized.text("Show less") : Localized.text("Show all %@", String(lines.count)))
    }

    private func rebuildNotes() {
        Gtk.removeChildren(of: notesBox)
        let lines = drawnNotes.flatMap(\.items)
        let shown = notesExpanded ? lines : Array(lines.prefix(Self.noteLimit))
        for line in shown { gtk_box_append(ptr(notesBox), buildBullet(line)) }
    }

    private func buildBullet(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let dot = Gtk.label("•", selectable: false)
        gtk_widget_set_valign(dot, GTK_ALIGN_START)
        let label = Gtk.label(text, wrap: true)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(row), dot)
        gtk_box_append(ptr(row), label)
        return row
    }

    private func toggleNotes() {
        notesExpanded.toggle()
        rebuildNotes()
        if let card { renderNotes(card) }
    }

    private struct ActionKey: Equatable {
        let title: String
        let enabled: Bool
        let prominent: Bool

        init(_ action: UpdateCard.Action) {
            title = action.title
            enabled = action.enabled
            prominent = action.prominent
        }
    }

    private func renderActions(_ card: UpdateCard) {
        let actions = [card.primary].compactMap { $0 } + card.secondary
        gtk_widget_set_visible(actionsBox, actions.isEmpty ? 0 : 1)
        let keys = actions.map(ActionKey.init)
        guard keys != drawnActions else { return }
        drawnActions = keys
        Gtk.removeChildren(of: actionsBox)
        for action in actions { gtk_box_append(ptr(actionsBox), buildActionButton(action)) }
    }

    private func buildActionButton(_ action: UpdateCard.Action) -> UnsafeMutablePointer<GtkWidget> {
        let css = action.prominent ? ["suggested-action"] : ["flat"]
        let button = Gtk.button(action.title, css: css) { [weak self] in
            self?.onAction?(action)
        }
        gtk_widget_set_sensitive(button, action.enabled ? 1 : 0)
        return button
    }

    private func renderAutomation(_ automation: UpdateCard.Automation?) {
        gtk_widget_set_visible(automationBox, automation == nil ? 0 : 1)
        guard let automation else { return }
        gtk_label_set_text(op(automationTitleLabel), automation.title)
        writingAutomation = true
        gtk_switch_set_active(op(automationSwitch), automation.isOn ? 1 : 0)
        writingAutomation = false
        gtk_widget_set_sensitive(automationSwitch, 1)
        gtk_label_set_text(op(automationStatusLabel), automation.status)
    }

    private func renderFacts(_ facts: [UpdateCard.Fact]) {
        gtk_widget_set_visible(detailsButton, facts.isEmpty ? 0 : 1)
        gtk_button_set_label(
            ptr(detailsButton),
            (detailsExpanded ? "▾ " : "▸ ") + Localized.text("Details"))
        gtk_widget_set_visible(factsBox, facts.isEmpty || !detailsExpanded ? 0 : 1)
        guard facts != drawnFacts else { return }
        drawnFacts = facts
        Gtk.removeChildren(of: factsBox)
        for fact in facts { gtk_box_append(ptr(factsBox), buildFactRow(fact)) }
    }

    private func buildFactRow(_ fact: UpdateCard.Fact) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        let label = Gtk.label(fact.label, css: "seam-footnote", selectable: false)
        let value = Gtk.label(fact.value, css: "tool-detail", wrap: true)
        gtk_box_append(ptr(row), label)
        gtk_box_append(ptr(row), value)
        return row
    }

    private func toggleDetails() {
        detailsExpanded.toggle()
        renderFacts(drawnFacts)
    }
}

/// A card's press, carried out. Shared by the Software Updates window and a server's own embedded
/// card, so a press drawn in two places is kept one way — and the question asked before a restart
/// is the one Core wrote, word for word, on every desk.
enum UpdatePress {
    static func perform(
        _ action: UpdateCard.Action, for reading: UpdateReading,
        parent: UnsafeMutablePointer<GtkWidget>?, toast: @escaping @Sendable (String) -> Void
    ) {
        switch action.kind {
        case .invitation(let invitation):
            take(invitation, action: action, reading: reading, parent: parent, toast: toast)
        case .setAside:
            UpdateLedger.acknowledge(reading)
        case .showLog:
            Dialogs.reader(
                title: Localized.text("%@ — update log", reading.title), body: reading.log ?? "",
                mono: true, parent: parent)
        case .checkNow:
            UpdateWatch.recheck(reading.component)
            toast(Localized.text("Asking %@…", reading.title))
        }
    }

    private static func take(
        _ invitation: UpdateInvitation, action: UpdateCard.Action, reading: UpdateReading,
        parent: UnsafeMutablePointer<GtkWidget>?, toast: @escaping @Sendable (String) -> Void
    ) {
        switch invitation {
        case .installHere, .restartHere:
            guard let confirmation = action.confirmation else {
                Task { await UpdateWatch.perform(reading.component) }
                return
            }
            Dialogs.confirm(
                title: confirmation.title, body: confirmation.message,
                confirmLabel: confirmation.confirm, destructive: false, parent: parent
            ) {
                Task { await UpdateWatch.perform(reading.component) }
            }
        case .copyCommand(let command):
            Gtk.copyToClipboard(command)
            toast(
                [Localized.text("Command copied"), invitation.promise].compactMap { $0 }
                    .joined(separator: " "))
        case .openStore(let url), .openPage(let url):
            SignInDialog.openInBrowser(url)
            toast(Localized.text("Opened in your browser"))
        case .recheck:
            UpdateWatch.recheck(reading.component)
            toast(Localized.text("Asking %@…", reading.title))
        }
    }

    /// Turning a machine's own policy on or off. The card draws the switch from what the machine
    /// said; a refusal puts it back there and says why.
    static func setAutomation(
        _ enabled: Bool, for reading: UpdateReading, restore: @escaping @Sendable () -> Void,
        toast: @escaping @Sendable (String) -> Void
    ) {
        Task {
            guard let failure = await UpdateWatch.setAutoUpdate(reading.component, enabled) else {
                return
            }
            Gtk.onMain {
                restore()
                toast(Localized.text("%@ didn't change its update setting: %@", reading.title, failure))
            }
        }
    }
}

/// Every machine in the picture and what it is running: this app, and each server it talks to.
///
/// A hero states the whole picture in a sentence, offers "Update all" when more than one server can
/// take its own update, and says when this device last asked. Below it, one card per machine —
/// Core's `UpdateCard`, drawn by `UpdateCardView` and nothing else, so this window and a server's
/// own screen can never disagree about what a reading means.
///
/// Not modal, deliberately: an update takes minutes on somebody else's machine and the person is
/// not meant to sit and watch it. A single instance lives for the life of the process — opened
/// from the sidebar mark or from any server's own screen, a second ask always raises the one
/// window rather than stacking a copy of a screen already following a live update.
final class UpdatePanel: @unchecked Sendable {
    private static let shared = UpdatePanel()

    static func present(parent: UnsafeMutablePointer<GtkWidget>?) {
        shared.show(parent: parent)
    }

    private init() {}

    private var window: UnsafeMutablePointer<GtkWidget>?
    private var toastOverlay: UnsafeMutablePointer<GtkWidget>?
    private var cardsBox: UnsafeMutablePointer<GtkWidget>?
    private var emptyLabel: UnsafeMutablePointer<GtkWidget>?
    private var heroTitle: UnsafeMutablePointer<GtkWidget>?
    private var heroDetail: UnsafeMutablePointer<GtkWidget>?
    private var heroChecked: UnsafeMutablePointer<GtkWidget>?
    private var everythingButton: UnsafeMutablePointer<GtkWidget>?
    private var cards: [String: UpdateCardView] = [:]
    private var order: [String] = []
    private var watching = false

    private func show(parent: UnsafeMutablePointer<GtkWidget>?) {
        if let window {
            gtk_window_present(ptr(window))
            return
        }
        let window = gtk_window_new()!
        gtk_window_set_title(ptr(window), Localized.text("Software Updates"))
        gtk_window_set_default_size(ptr(window), 640, 760)
        gtk_window_set_modal(ptr(window), 0)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }
        self.window = window

        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(
            op(header), Gtk.label(Localized.text("Software Updates"), selectable: false))
        gtk_window_set_titlebar(ptr(window), header)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 20)
        Gtk.margins(column, top: 18, bottom: 24, leading: 18, trailing: 18)
        buildHero(in: column)

        let cardsBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 14)
        self.cardsBox = cardsBox
        gtk_box_append(ptr(column), cardsBox)

        let empty = Gtk.label(
            Localized.text("Nothing has answered yet. It asks on its own — or press Check now."),
            css: "dim", wrap: true, selectable: false)
        gtk_widget_set_halign(empty, GTK_ALIGN_START)
        emptyLabel = empty
        gtk_box_append(ptr(column), empty)

        let viewport = gtk_viewport_new(nil, nil)!
        gtk_viewport_set_scroll_to_focus(op(viewport), 0)
        gtk_viewport_set_child(op(viewport), column)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(scroller), viewport)
        gtk_widget_set_vexpand(scroller, 1)

        let toastOverlay = adw_toast_overlay_new()!
        adw_toast_overlay_set_child(op(toastOverlay), scroller)
        gtk_window_set_child(ptr(window), toastOverlay)
        self.toastOverlay = toastOverlay

        Gtk.observe(UnsafeMutableRawPointer(window), "close-request") { [weak self] in
            self?.forgetWidgets()
        }
        observeLedger()

        render()
        gtk_window_present(ptr(window))
    }

    private func buildHero(in column: UnsafeMutablePointer<GtkWidget>) {
        let hero = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)

        let title = Gtk.label("", css: "preflight-headline", wrap: true, selectable: false)
        heroTitle = title
        gtk_box_append(ptr(hero), title)

        let detail = Gtk.label("", css: "dim", wrap: true, selectable: false)
        heroDetail = detail
        gtk_box_append(ptr(hero), detail)

        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let everything = Gtk.button("", css: ["suggested-action", "pill"]) { [weak self] in
            self?.confirmUpdateEverything()
        }
        everythingButton = everything
        gtk_box_append(ptr(buttons), everything)
        gtk_box_append(
            ptr(buttons),
            Gtk.button(Localized.text("Check now")) { [weak self] in self?.checkNow() })
        gtk_box_append(ptr(hero), buttons)

        let checked = Gtk.label("", css: "seam-footnote", selectable: false)
        heroChecked = checked
        gtk_box_append(ptr(hero), checked)

        gtk_box_append(ptr(column), hero)
    }

    private func observeLedger() {
        guard !watching else { return }
        watching = true
        for name in [UpdateLedger.didChange, UpdateDriver.didChange] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) {
                [weak self] _ in
                Gtk.onMain { [weak self] in self?.render() }
            }
        }
    }

    /// Every answer that lands rewrites this window in place: cards are rebuilt only when the
    /// *set* or *order* of machines changes, because a rebuild under somebody's hand would close
    /// the notes they had open and move the button they were reaching for.
    private func render() {
        guard window != nil else { return }
        let rollup = UpdateLedger.rollup()
        let snapshot = UpdateWatch.driver.snapshot
        let ids = rollup.readings.map(\.id)
        if ids != order { relayout(ids) }
        renderHero(rollup, snapshot: snapshot)
        for reading in rollup.readings {
            cards[reading.id]?.apply(
                UpdateCard(
                    reading, acknowledged: rollup.isAcknowledged(reading),
                    busy: snapshot.isBusy(reading.component)))
        }
        emptyLabel.map { gtk_widget_set_visible($0, rollup.readings.isEmpty ? 1 : 0) }
    }

    private func relayout(_ ids: [String]) {
        guard let cardsBox else { return }
        for stale in Set(cards.keys).subtracting(ids) { cards.removeValue(forKey: stale) }
        Gtk.removeChildren(of: cardsBox)
        for id in ids {
            let card = cards[id] ?? makeCard(id)
            cards[id] = card
            gtk_box_append(ptr(cardsBox), card.widget)
        }
        order = ids
    }

    private func makeCard(_ id: String) -> UpdateCardView {
        let card = UpdateCardView(style: .standalone)
        card.onAction = { [weak self] action in
            guard let self, let reading = self.reading(id) else { return }
            UpdatePress.perform(action, for: reading, parent: self.window) { [weak self] text in
                Gtk.onMain { [weak self] in self?.toast(text) }
            }
        }
        card.onAutomation = { [weak self, weak card] enabled in
            guard let self, let card, let reading = self.reading(id) else { return }
            UpdatePress.setAutomation(
                enabled, for: reading, restore: { [weak card] in card?.restoreAutomation() },
                toast: { [weak self] text in Gtk.onMain { [weak self] in self?.toast(text) } })
        }
        return card
    }

    private func reading(_ id: String) -> UpdateReading? {
        UpdateLedger.rollup().readings.first { $0.id == id }
    }

    private func renderHero(_ rollup: UpdateRollup, snapshot: UpdateDriver.Snapshot) {
        guard let heroTitle, let heroDetail, let heroChecked, let everythingButton else { return }
        gtk_label_set_text(op(heroTitle), rollup.headline)
        let detail = rollup.readings.isEmpty ? "" : rollup.detail()
        gtk_label_set_text(op(heroDetail), detail)
        gtk_widget_set_visible(heroDetail, detail.isEmpty ? 0 : 1)

        if let walk = snapshot.walk {
            gtk_widget_set_visible(everythingButton, 1)
            gtk_widget_set_sensitive(everythingButton, 0)
            gtk_button_set_label(
                ptr(everythingButton),
                Localized.text(
                    "Updating %@ of %@…", String(min(walk.done + 1, walk.total)),
                    String(walk.total)))
        } else {
            gtk_widget_set_visible(everythingButton, rollup.canUpdateEverything ? 1 : 0)
            gtk_widget_set_sensitive(everythingButton, 1)
            gtk_button_set_label(
                ptr(everythingButton),
                Localized.text("Update all %@ servers", String(rollup.installableServers.count)))
        }

        let checkedText: String
        if snapshot.checking {
            checkedText = Localized.text("Checking every machine…")
        } else if let last = UpdateLedger.lastCheck() {
            checkedText = Localized.text("Last checked %@", RelativeWhen.ago(last))
        } else {
            checkedText = ""
        }
        gtk_label_set_text(op(heroChecked), checkedText)
        gtk_widget_set_visible(heroChecked, checkedText.isEmpty ? 0 : 1)
    }

    private func checkNow() {
        UpdateWatch.refresh()
        toast(Localized.text("Asking every machine…"))
    }

    private func confirmUpdateEverything() {
        let count = UpdateLedger.rollup().installableServers.count
        Dialogs.confirm(
            title: Localized.text("Update all %@ servers?", String(count)),
            body: Localized.text(
                "One at a time: each downloads and builds, then restarts once nothing is running "
                    + "on it."),
            confirmLabel: Localized.text("Update all"), destructive: false, parent: window
        ) {
            Task { await UpdateWatch.updateEverything() }
        }
    }

    private func toast(_ text: String) {
        guard let toastOverlay, let toast = adw_toast_new(text) else { return }
        adw_toast_overlay_add_toast(op(toastOverlay), toast)
    }

    /// Every pointer here belongs to a window GTK has destroyed. The panel itself outlives it —
    /// it is a permanent singleton, so a second ask can always find the same window — and an
    /// update still in flight will come back to write into a card. Nothing may be touched again,
    /// and a reopened window builds a fresh set rather than taking back widgets already gone.
    private func forgetWidgets() {
        window = nil
        toastOverlay = nil
        cardsBox = nil
        emptyLabel = nil
        heroTitle = nil
        heroDetail = nil
        heroChecked = nil
        everythingButton = nil
        cards = [:]
        order = []
    }
}
