import CAdw
import CGtkShim
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The tone every delegate surface reads a state in. `ActivityTone` already carries the meaning;
/// this only owns the two CSS vocabularies a GTK label can wear it as — plain text, and the pill
/// backgrounds `MatrixTheme` already ships for every other list in this app.
enum DelegateToneCSS {
    private static let textClasses = [
        "delegate-tone-live", "delegate-tone-attention", "delegate-tone-danger", "delegate-tone-quiet",
    ]
    private static let pillClasses = ["pill-live", "pill-needs", "pill-error", "pill-offline"]

    static func apply(_ widget: UnsafeMutablePointer<GtkWidget>, _ tone: ActivityTone) {
        Gtk.setTone(widget, textName(tone), from: textClasses)
    }

    static func applyPill(_ widget: UnsafeMutablePointer<GtkWidget>, _ tone: ActivityTone) {
        Gtk.setTone(widget, pillName(tone), from: pillClasses)
    }

    private static func textName(_ tone: ActivityTone) -> String {
        switch tone {
        case .live: return "delegate-tone-live"
        case .attention: return "delegate-tone-attention"
        case .danger: return "delegate-tone-danger"
        case .quiet: return "delegate-tone-quiet"
        }
    }

    private static func pillName(_ tone: ActivityTone) -> String {
        switch tone {
        case .live: return "pill-live"
        case .attention: return "pill-needs"
        case .danger: return "pill-error"
        case .quiet: return "pill-offline"
        }
    }
}

/// The dispatcher board, opened over the work rather than beside it — the same reasoning
/// `ForgeWindow` gives for its own modal: a board is a thing you check on, not a place you type,
/// so it costs the conversation behind it nothing and comes back whole the moment it closes.
///
/// It leads with the work rather than the connection: the machine is a picker in the header and its
/// version the title's second line, New packet is the first thing in the window, the ladder is one
/// row of rungs, and the runs are grouped by what they ask of the reader. Every board, stream and
/// password lives in ``DelegateRunner`` so that closing this window never stops a run already out.
final class DelegateWindow: @unchecked Sendable {
    nonisolated(unsafe) private static var open: DelegateWindow?
    /// Where the window reads this device's chats from — the main window's live listing — so the
    /// composer can offer their repositories and an apply can see a chat working under it.
    nonisolated(unsafe) static var chatSource: @Sendable () -> [SessionEntry] = { SessionListCache.load() }

    static var current: DelegateWindow? { open }

    @discardableResult
    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?, host: String? = nil, handoff: DelegateHandoff? = nil
    ) -> DelegateWindow {
        let window: DelegateWindow
        if let open {
            gtk_window_present(ptr(open.window))
            if let host = host ?? handoff?.host { open.selectHost(host) }
            window = open
        } else {
            window = DelegateWindow(parent: parent, host: host ?? handoff?.host)
            open = window
        }
        if let handoff { window.compose(handoff: handoff) }
        return window
    }

    private enum Mode: Equatable {
        case board
        case run(String)
    }

    private let runner = DelegateRunner.shared
    private var mode: Mode = .board
    private var currentHost = ""
    private var knownHosts: [String] = []
    private var serverNames: [String: String] = [:]
    private var pendingHandoff: DelegateHandoff?
    private var askedPatch: Set<String> = []
    private var pendingScroll: Double?
    private var scrollGeneration = 0
    private var renderedMode: Mode?

    private let window: UnsafeMutablePointer<GtkWidget>
    private let titleWidget = adw_window_title_new(DelegateEntryPoint.title, "")!
    private let beta = DelegateBetaBadge()
    private let backButton = gtk_button_new_from_icon_name("go-previous-symbolic")!
    private let refreshButton = gtk_button_new_from_icon_name("view-refresh-symbolic")!
    private var machineButton: UnsafeMutablePointer<GtkWidget>!
    private let scroller = gtk_scrolled_window_new()!
    private let toastOverlay = adw_toast_overlay_new()!
    private let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 18)
    private let passwordEntry = gtk_password_entry_new()!

    private init(parent: UnsafeMutablePointer<GtkWidget>?, host: String?) {
        window = gtk_window_new()!
        gtk_window_set_modal(ptr(window), 1)
        FeatureWindow.fill(window, near: parent, minimumWidth: 640, minimumHeight: 480)
        gtk_widget_set_size_request(window, 560, 480)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }

        let header = adw_header_bar_new()!
        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(titleRow, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(titleRow), titleWidget)
        gtk_box_append(ptr(titleRow), beta.widget)
        adw_header_bar_set_title_widget(op(UnsafeMutableRawPointer(header)), titleRow)
        adw_header_bar_pack_start(op(UnsafeMutableRawPointer(header)), backButton)
        gtk_widget_set_tooltip_text(refreshButton, Localized.text("Refresh"))
        Gtk.addClass(refreshButton, "flat")
        adw_header_bar_pack_end(op(UnsafeMutableRawPointer(header)), refreshButton)
        machineButton = Gtk.menuButton("", css: ["flat"]) { [weak self] in self?.machineMenu() ?? [] }
        gtk_widget_set_tooltip_text(machineButton, Localized.text("Machine"))
        adw_header_bar_pack_end(op(UnsafeMutableRawPointer(header)), machineButton)
        gtk_window_set_titlebar(ptr(window), header)

        g_object_ref_sink(UnsafeMutableRawPointer(passwordEntry))
        gtk_password_entry_set_show_peek_icon(op(passwordEntry), 1)
        gtk_widget_set_hexpand(passwordEntry, 1)

        Gtk.margins(root, top: 16, bottom: 24, leading: 22, trailing: 22)
        let clamp = adw_clamp_new()!
        adw_clamp_set_maximum_size(op(UnsafeMutableRawPointer(clamp)), 980)
        adw_clamp_set_child(op(UnsafeMutableRawPointer(clamp)), root)
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(scroller), clamp)
        gtk_widget_set_vexpand(scroller, 1)
        adw_toast_overlay_set_child(op(UnsafeMutableRawPointer(toastOverlay)), scroller)
        gtk_window_set_child(ptr(window), toastOverlay)

        if let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)) {
            Gtk.onNotify(UnsafeMutableRawPointer(adjustment), property: "upper") { [weak self] in
                Gtk.onMain { [weak self] in self?.applyPendingScroll() }
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(passwordEntry), "activate") { [weak self] in
            Gtk.onMain { [weak self] in self?.pressCheck() }
        }
        Gtk.connect(UnsafeMutableRawPointer(backButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.showBoard() }
        }
        Gtk.connect(UnsafeMutableRawPointer(refreshButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.pressRefresh() }
        }
        Gtk.onKey(window) { [weak self] keyval, _ in
            guard let self, keyval == Keymap.escape else { return false }
            if case .run = self.mode {
                self.showBoard()
                return true
            }
            self.close()
            return true
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [weak self] in
            guard let self else { return }
            Self.destroyed(self)
        }

        runner.watch(self) { [weak self] in
            Gtk.onMain { [weak self] in self?.render() }
        }

        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            Gtk.onMain { [weak self] in self?.adopt(profiles: profiles) }
        }

        if let host {
            selectHost(host)
        } else {
            render()
        }
        gtk_window_present(ptr(window))
    }

    private func adopt(profiles: [ConnectionProfile]) {
        var hosts = Set(profiles.compactMap { $0.baseURL.host })
        for profile in profiles {
            if let host = profile.baseURL.host { serverNames[host] = profile.name }
        }
        for access in DelegateAccessStore.all() { hosts.insert(access.host) }
        knownHosts = hosts.sorted()
        if currentHost.isEmpty, let first = knownHosts.first {
            selectHost(first)
        } else {
            render()
        }
    }

    private func name(of host: String) -> String {
        serverNames[host] ?? host.split(separator: ".").first.map(String.init) ?? host
    }

    private func machineMenu() -> [Gtk.MenuSection] {
        let machines = knownHosts.map { host in
            Gtk.MenuRow(
                title: name(of: host), detail: runner.reach[host]?.line ?? host, on: host == currentHost,
                action: { [weak self] in Gtk.onMain { [weak self] in self?.selectHost(host) } })
        }
        let other = Gtk.MenuRow(
            title: Localized.text("Another machine…"), detail: Localized.text("A host on your tailnet running delegate"),
            action: { [weak self] in Gtk.onMain { [weak self] in self?.askForHost() } })
        return [Gtk.MenuSection(heading: nil, rows: machines), Gtk.MenuSection(heading: nil, rows: [other])]
    }

    private func askForHost() {
        Dialogs.prompt(
            title: Localized.text("Another machine"),
            body: Localized.text("The host name or address of a machine running delegate."),
            placeholder: "studio.tailnet.ts.net", confirmLabel: Localized.text("Open"), parent: window
        ) { [weak self] host in
            Gtk.onMain { [weak self] in
                guard let self, !host.isEmpty else { return }
                if !self.knownHosts.contains(host) { self.knownHosts.append(host) }
                self.selectHost(host)
            }
        }
    }

    private func pressCheck() {
        guard !currentHost.isEmpty else { return }
        let password = Dialogs.entryText(passwordEntry)
        runner.check(host: currentHost, password: password.isEmpty ? nil : password, serverName: name(of: currentHost))
        render()
    }

    private func pressRefresh() {
        guard !currentHost.isEmpty else { return }
        if (runner.reach[currentHost] ?? .unknown).isAnswering {
            runner.refresh(host: currentHost, serverName: name(of: currentHost))
        } else {
            runner.check(host: currentHost, password: runner.password(host: currentHost), serverName: name(of: currentHost))
        }
    }

    /// A host taken up by the picker: chosen, typed, or handed in by whoever opened the window. A
    /// host this device has already confirmed once is re-checked with its remembered password rather
    /// than left to say "not checked" over a daemon that answers fine.
    func selectHost(_ host: String) {
        guard !host.isEmpty else { return }
        let changed = host != currentHost
        currentHost = host
        if changed { mode = .board }
        if runner.isDemo(host: host) {
            if runner.reach[host] == nil { runner.probe(host: host, serverName: name(of: host)) }
        } else if runner.reach[host] == nil {
            runner.check(host: host, password: runner.password(host: host), serverName: name(of: host))
        }
        render()
    }

    private func showBoard() {
        mode = .board
        render()
    }

    private func openRun(_ runID: String) {
        runner.load(runID: runID, host: currentHost, serverName: name(of: currentHost))
        mode = .run(runID)
        render()
    }

    private func close() {
        gtk_window_destroy(ptr(window))
    }

    private static func destroyed(_ window: DelegateWindow) {
        if open === window { open = nil }
        window.runner.unwatch(window)
        window.beta.tearDown()
    }

    private var board: DelegateBoard { runner.board(host: currentHost, serverName: name(of: currentHost)) }

    private var reach: DelegateReach { runner.reach[currentHost] ?? .unknown }

    private func render() {
        let kept = mode == renderedMode ? currentScroll() : 0
        renderedMode = mode
        releaseFocusInside()
        Gtk.removeChildren(of: root)
        gtk_widget_set_visible(backButton, mode == .board ? 0 : 1)
        gtk_widget_set_visible(machineButton, mode == .board ? 1 : 0)
        gtk_menu_button_set_label(op(machineButton), currentHost.isEmpty ? Localized.text("Machine") : name(of: currentHost))
        switch mode {
        case .board:
            adw_window_title_set_subtitle(op(UnsafeMutableRawPointer(titleWidget)), board.subtitle)
            renderBoard()
        case .run(let runID):
            adw_window_title_set_subtitle(op(UnsafeMutableRawPointer(titleWidget)), board.subtitle)
            renderRun(runID)
        }
        holdScroll(at: kept)
        if case .run = mode { gtk_widget_grab_focus(backButton) }
        if reach.isAnswering, let handoff = pendingHandoff, handoff.host == currentHost {
            pendingHandoff = nil
            presentComposer(draft: handoff.draft(capabilities: board.capabilities))
        }
    }

    private func renderBoard() {
        if currentHost.isEmpty {
            gtk_box_append(ptr(root), Gtk.label(Localized.text("Pick a machine to see its dispatcher."), css: "dg-note", wrap: true, selectable: false))
            return
        }
        guard reach.isAnswering else {
            renderUnanswered()
            return
        }
        let board = self.board
        let top = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        let compose = Gtk.button(DelegateEntryPoint.newPacketTitle, css: ["suggested-action", "dg-primary"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.presentComposer() }
        }
        gtk_widget_set_valign(compose, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(top), compose)
        let pitch = Gtk.label(board.note ?? DelegateEntryPoint.subtitle, css: "dg-note", wrap: true, selectable: false)
        gtk_widget_set_hexpand(pitch, 1)
        gtk_widget_set_valign(pitch, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(top), pitch)
        gtk_box_append(ptr(root), top)

        if !board.ladderRungs.isEmpty {
            let ladder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
            gtk_box_append(ptr(ladder), DelegateRunView.sectionLabel(DelegateComposerWords.ladderLabel))
            gtk_box_append(ptr(ladder), DelegateLadderView.board(board.ladderRungs))
            for hint in board.promotions {
                gtk_box_append(ptr(ladder), Gtk.label(hint, css: "dg-note", wrap: true, selectable: false))
            }
            gtk_box_append(ptr(root), ladder)
        }

        let sections = board.sections()
        if sections.isEmpty {
            gtk_box_append(ptr(root), Gtk.label(board.emptyLine, css: "dg-note", wrap: true, selectable: false))
        }
        for section in sections {
            let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
            gtk_box_append(ptr(column), DelegateRunView.sectionLabel(section.title))
            for row in section.rows { gtk_box_append(ptr(column), runRow(row)) }
            gtk_box_append(ptr(root), column)
        }
    }

    /// A machine that is not answering yet: asking, wanting its password, or not there — and, for a
    /// machine that has never answered, the road to installing the dispatcher.
    private func renderUnanswered() {
        let reach = self.reach
        let isDemo = runner.isDemo(host: currentHost)
        if reach.asksForPassword, !isDemo {
            let card = DelegateRunView.leadCard(
                DelegateRunReading.Lead(
                    title: Localized.text("This dispatcher wants its password"), caption: name(of: currentHost),
                    body: reach.line, tone: .attention))
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            gtk_box_append(ptr(row), passwordEntry)
            gtk_box_append(
                ptr(row),
                Gtk.button(Localized.text("Check"), css: ["suggested-action", "pill"]) { [weak self] in
                    Gtk.onMain { [weak self] in self?.pressCheck() }
                })
            Gtk.detachFromParent(passwordEntry)
            gtk_box_append(ptr(card), row)
            gtk_box_append(ptr(root), card)
            return
        }
        let title: String
        switch reach {
        case .checking, .unknown: title = Localized.text("Asking %@…", name(of: currentHost))
        default: title = Localized.text("Not answering")
        }
        gtk_box_append(
            ptr(root),
            DelegateRunView.leadCard(
                DelegateRunReading.Lead(title: title, caption: currentHost, body: reach == .checking ? nil : reach.line, tone: reach.tone)))
        if DelegateSetup.isWanted(board: board, known: runner.isKnown(host: currentHost)) {
            gtk_box_append(ptr(root), setupBlock())
        }
    }

    /// The road from a machine with no dispatcher to one that answers: the commands, each with a
    /// copy button and a line saying what it does.
    private func setupBlock() -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        gtk_box_append(ptr(column), DelegateRunView.sectionLabel(DelegateSetup.title))
        gtk_box_append(ptr(column), Gtk.label(DelegateSetup.lead(serverName: name(of: currentHost)), css: "row-detail", wrap: true, selectable: false))
        for step in DelegateSetup.steps {
            let block = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
            let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let title = Gtk.label(step.title, css: "row-title", selectable: false)
            gtk_widget_set_hexpand(title, 1)
            gtk_box_append(ptr(head), title)
            gtk_box_append(
                ptr(head),
                Gtk.button(Localized.text("Copy"), css: ["flat", "pill"]) { [weak self] in
                    Gtk.onMain { [weak self] in self?.copySetupCommand(step) }
                })
            gtk_box_append(ptr(block), head)
            gtk_box_append(ptr(block), Gtk.label(step.command, css: "dg-lead-output", wrap: true, selectable: true))
            gtk_box_append(ptr(block), Gtk.label(step.detail, css: "dg-note", wrap: true, selectable: false))
            gtk_box_append(ptr(column), block)
        }
        return column
    }

    private func copySetupCommand(_ step: DelegateSetup.Step) {
        Gtk.copyToClipboard(step.command)
        toast(DelegateSetup.copied + " · " + step.command)
    }

    private func runRow(_ row: DelegateRunRow) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "session-row")
        gtk_widget_set_tooltip_text(button, row.spoken)

        let glyph = Gtk.label("●", selectable: false)
        DelegateToneCSS.apply(glyph, row.tone)
        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        Gtk.margins(glyph, top: 3)
        ActivityPulse.apply(row.activity?.icon, to: glyph)

        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let title = Gtk.label(row.headline, css: "row-title", selectable: false)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(titleRow), title)
        if let badge = row.badge {
            let pill = Gtk.label(badge, css: "pill", selectable: false)
            DelegateToneCSS.applyPill(pill, row.tone)
            gtk_widget_set_valign(pill, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(titleRow), pill)
        }

        let detail = Gtk.label(row.detail, css: "row-detail", selectable: false)
        gtk_label_set_ellipsize(op(detail), PANGO_ELLIPSIZE_END)

        let meta = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(meta), DelegateLadderView.pips(row.rungs))
        let facts = [row.repo, row.age].filter { !$0.isEmpty }.joined(separator: " · ")
        if !facts.isEmpty { gtk_box_append(ptr(meta), Gtk.label(facts, css: "dg-row-meta", selectable: false)) }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
        gtk_box_append(ptr(column), titleRow)
        gtk_box_append(ptr(column), detail)
        gtk_box_append(ptr(column), meta)
        gtk_widget_set_hexpand(column, 1)

        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.margins(line, top: 6, bottom: 6, leading: 4, trailing: 4)
        gtk_box_append(ptr(line), glyph)
        gtk_box_append(ptr(line), column)
        gtk_button_set_child(ptr(button), line)

        let runID = row.runID
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.openRun(runID) }
        }
        return button
    }

    private func renderRun(_ runID: String) {
        let board = self.board
        guard let reading = board.reading(for: runID), let story = board.story(for: runID) else {
            gtk_box_append(ptr(root), Gtk.label(Localized.text("This run is gone."), css: "dg-note", selectable: false))
            return
        }
        if story.status == .passed, board.patches[runID] == nil, !askedPatch.contains(runID) {
            askedPatch.insert(runID)
            runner.patch(runID: runID, host: currentHost) { _ in }
        }
        gtk_box_append(
            ptr(root),
            DelegateRunView.make(
                reading: reading, board: board,
                onAction: { [weak self] kind in self?.perform(kind, runID: runID) },
                onFile: { [weak self] path in self?.openFile(path, runID: runID) }))
    }

    /// The first run the board lists, opened as a click would open it — the road the `drun` drive
    /// verb takes so the run view can be photographed without a pointer. A run waiting for a person
    /// is the one worth looking at, then a settled one.
    func openFirstRun() {
        let sections = board.sections()
        let rows = sections.first { $0.kind == .needsYou }?.rows ?? sections.first { $0.kind == .earlier }?.rows ?? sections.first?.rows ?? []
        guard let first = rows.first else { return }
        openRun(first.runID)
    }

    /// Opens a run by id, for the drive verbs that photograph one state at a time.
    func openRun(id: String) { openRun(id) }

    private var footprints: [DelegateChatFootprint] {
        DelegateChatFootprint.from(Self.chatSource(), host: currentHost)
    }

    func presentComposer(draft: DelegateDraft? = nil) {
        let board = self.board
        let choices = DelegateRepoChoices.make(runs: board.runs, chats: footprints)
        let seed = draft ?? DelegateDraft(capabilities: board.capabilities, repo: choices.first?.path ?? "")
        DelegateComposerDialog.present(parent: window, board: board, draft: seed, repoChoices: choices) { [weak self] draft in
            self?.send(draft)
        }
    }

    /// A chat handed its task over: the composer opens on that chat's machine with its goal and
    /// repository, once the machine has answered.
    func compose(handoff: DelegateHandoff) {
        if !knownHosts.contains(handoff.host) { knownHosts.append(handoff.host) }
        serverNames[handoff.host] = handoff.serverName
        pendingHandoff = handoff
        if currentHost != handoff.host {
            selectHost(handoff.host)
        } else {
            render()
        }
    }

    private func send(_ draft: DelegateDraft) {
        let host = currentHost
        runner.start(host: host, serverName: name(of: host), draft: draft) { [weak self] result in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let runID):
                    self.mode = .run(runID)
                    self.render()
                case .failure(let error):
                    self.toast(Self.describe(error))
                }
            }
        }
    }

    private func perform(_ kind: DelegateRunAction.Kind, runID: String) {
        switch kind {
        case .approve: respondToApproval(runID: runID, approved: true)
        case .hold: respondToApproval(runID: runID, approved: false)
        case .cancel:
            Dialogs.confirm(
                title: Localized.text("Cancel this run?"),
                body: Localized.text("The worker stops where it is and nothing it changed reaches the tree."),
                confirmLabel: Localized.text("Cancel run"), parent: window
            ) { [weak self] in Gtk.onMain { [weak self] in self?.cancelRun(runID) } }
        case .apply: apply(runID)
        case .discard:
            Dialogs.confirm(
                title: Localized.text("Discard this patch?"),
                body: Localized.text("The tree never sees it. The patch stays readable on this run."),
                confirmLabel: Localized.text("Discard"), parent: window
            ) { [weak self] in Gtk.onMain { [weak self] in self?.deliver(runID, apply: false) } }
        case .replay(let tier): replayRun(runID, tier: tier)
        case .duplicate:
            guard let packet = board.story(for: runID)?.packet else { return }
            presentComposer(draft: DelegateDraft(packet: packet))
        }
    }

    /// Applying lands files in a tree a chat may be writing to right now; that chat is named before
    /// the press rather than discovered after it.
    private func apply(_ runID: String) {
        let repo = board.reading(for: runID)?.repo ?? ""
        let cautions = DelegateApplyCheck.cautions(repo: repo, chats: footprints)
        guard cautions.isEmpty else {
            Dialogs.confirm(
                title: DelegateApplyCheck.confirmTitle, body: cautions.joined(separator: "\n\n"),
                confirmLabel: DelegateApplyCheck.confirmAction, destructive: false, parent: window
            ) { [weak self] in Gtk.onMain { [weak self] in self?.deliver(runID, apply: true) } }
            return
        }
        deliver(runID, apply: true)
    }

    private func deliver(_ runID: String, apply: Bool) {
        runner.deliver(runID: runID, host: currentHost, apply: apply) { [weak self] result in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    self.toast(apply ? Localized.text("Applied to the tree, unstaged") : Localized.text("Discarded"))
                case .failure(let error):
                    let refusal = DelegateRefusal(error)
                    Dialogs.reader(title: refusal.title, body: refusal.body, mono: refusal.bodyIsOutput, parent: self.window)
                }
            }
        }
    }

    private func openFile(_ path: String, runID: String) {
        let host = currentHost
        let runner = self.runner
        let name = path.split(separator: "/").last.map(String.init) ?? path
        GitDiffWindow.present(parent: window, title: name, subtitle: path) {
            let patch: String? = await withCheckedContinuation { continuation in
                Gtk.onMain {
                    runner.patch(runID: runID, host: host) { result in
                        continuation.resume(returning: try? result.get())
                    }
                }
            }
            return patch.flatMap { DelegatePatch.files($0).first { $0.path == path }?.patch }
        }
    }

    private func respondToApproval(runID: String, approved: Bool) {
        runner.approve(runID: runID, host: currentHost, approved: approved) { [weak self] result in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                if case .failure(let error) = result { self.toast(Self.describe(error)) }
                self.render()
            }
        }
    }

    private func cancelRun(_ runID: String) {
        runner.cancel(runID: runID, host: currentHost) { [weak self] result in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                if case .failure(let error) = result { self.toast(Self.describe(error)) }
                self.render()
            }
        }
    }

    private func replayRun(_ runID: String, tier: String) {
        runner.replay(runID: runID, host: currentHost, tier: tier, ceiling: nil) { [weak self] result in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let started):
                    self.mode = .run(started)
                    self.render()
                case .failure(let error):
                    self.toast(Self.describe(error))
                }
            }
        }
    }

    private func toast(_ text: String) {
        guard let toast = adw_toast_new(text) else { return }
        adw_toast_overlay_add_toast(op(UnsafeMutableRawPointer(toastOverlay)), toast)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// A rebuild that removes the focused widget leaves the window pointing at a widget that is
    /// gone; focus is let go of first, and a run's screen then hands it to the back button so no
    /// selectable label opens with its whole text highlighted.
    private func releaseFocusInside() {
        guard let focused = gtk_window_get_focus(ptr(window)), focused == root || gtk_widget_is_ancestor(focused, root) != 0
        else { return }
        gtk_window_set_focus(ptr(window), nil)
    }

    private func currentScroll() -> Double? {
        guard let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)) else { return nil }
        return gtk_adjustment_get_value(adjustment)
    }

    /// A rebuild empties and refills the column, which clamps the scroller to the top on the way;
    /// the position is held and re-applied on every height the scroller reports until the rebuild
    /// settles, the way `ModelChooserWindow` holds its list.
    private func applyPendingScroll() {
        guard let wanted = pendingScroll, let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)) else { return }
        let ceiling = max(0, gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment))
        gtk_adjustment_set_value(adjustment, min(max(0, wanted), ceiling))
    }

    private func holdScroll(at value: Double?) {
        pendingScroll = value
        applyPendingScroll()
        guard value != nil else { return }
        let token = scrollGeneration + 1
        scrollGeneration = token
        Gtk.after(250) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.scrollGeneration == token else { return }
                self.pendingScroll = nil
            }
        }
    }
}
