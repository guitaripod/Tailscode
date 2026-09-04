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
/// Every board, stream and password lives in ``DelegateRunner`` so that closing this window can
/// never stop a run already out; this is only the view over it, and a host still answering when
/// the window closes keeps right on answering.
final class DelegateWindow: @unchecked Sendable {
    nonisolated(unsafe) private static var open: DelegateWindow?

    static var current: DelegateWindow? { open }

    @discardableResult
    static func present(parent: UnsafeMutablePointer<GtkWidget>?, host: String? = nil) -> DelegateWindow {
        if let open {
            gtk_window_present(ptr(open.window))
            if let host { open.selectHost(host) }
            return open
        }
        let made = DelegateWindow(parent: parent, host: host)
        open = made
        return made
    }

    private enum Mode {
        case board
        case run(String)
    }

    private let runner = DelegateRunner.shared
    private var mode: Mode = .board
    private var currentHost = ""
    private var knownHosts: [String] = []

    private let window: UnsafeMutablePointer<GtkWidget>
    private let titleWidget = adw_window_title_new(DelegateEntryPoint.title, "")!
    private let backButton = gtk_button_new_from_icon_name("go-previous-symbolic")!
    private let scroller = gtk_scrolled_window_new()!
    private let toastOverlay = adw_toast_overlay_new()!
    private let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 16)
    private let pickerRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let hostEntry = gtk_entry_new()!
    private let passwordEntry = gtk_password_entry_new()!
    private let checkButton = gtk_button_new_with_label(Localized.text("Check"))!
    private let reachLabel = Gtk.label("", css: "row-detail", selectable: false)
    private let below = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 16)

    private var isBoard: Bool {
        if case .board = mode { return true }
        return false
    }

    private init(parent: UnsafeMutablePointer<GtkWidget>?, host: String?) {
        window = gtk_window_new()!
        gtk_window_set_modal(ptr(window), 1)
        gtk_window_set_default_size(ptr(window), 920, Self.height(near: parent))
        gtk_widget_set_size_request(window, 640, 480)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }

        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(op(UnsafeMutableRawPointer(header)), titleWidget)
        adw_header_bar_pack_start(op(UnsafeMutableRawPointer(header)), backButton)
        gtk_window_set_titlebar(ptr(window), header)

        gtk_entry_set_placeholder_text(ptr(hostEntry), "127.0.0.1")
        gtk_widget_set_hexpand(hostEntry, 1)
        gtk_widget_set_hexpand(passwordEntry, 1)
        gtk_password_entry_set_show_peek_icon(op(passwordEntry), 1)
        gtk_widget_set_tooltip_text(
            passwordEntry, Localized.text("Only if the daemon asks for one"))

        let known = Gtk.menuButton(Localized.text("Known ▾"), css: ["flat"]) { [weak self] in
            guard let self else { return [] }
            return self.knownHosts.map { host in
                (
                    host, self.runner.reach[host]?.line,
                    { Gtk.onMain { self.selectHost(host) } } as @Sendable () -> Void
                )
            }
        }
        gtk_box_append(ptr(pickerRow), hostEntry)
        gtk_box_append(ptr(pickerRow), known)
        gtk_box_append(ptr(pickerRow), passwordEntry)
        gtk_box_append(ptr(pickerRow), checkButton)

        gtk_box_append(ptr(root), pickerRow)
        gtk_box_append(ptr(root), reachLabel)
        gtk_box_append(ptr(root), below)
        Gtk.margins(root, top: 12, bottom: 20, leading: 16, trailing: 16)

        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(scroller), root)
        gtk_widget_set_vexpand(scroller, 1)
        adw_toast_overlay_set_child(op(UnsafeMutableRawPointer(toastOverlay)), scroller)
        gtk_window_set_child(ptr(window), toastOverlay)

        Gtk.connect(UnsafeMutableRawPointer(hostEntry), "activate") { [weak self] in
            Gtk.onMain { [weak self] in self?.typedHost() }
        }
        Gtk.connect(UnsafeMutableRawPointer(passwordEntry), "activate") { [weak self] in
            Gtk.onMain { [weak self] in self?.pressCheck() }
        }
        Gtk.connect(UnsafeMutableRawPointer(checkButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.pressCheck() }
        }
        Gtk.connect(UnsafeMutableRawPointer(backButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.showBoard() }
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
        for access in DelegateAccessStore.all() { hosts.insert(access.host) }
        knownHosts = hosts.sorted()
        if currentHost.isEmpty, let first = knownHosts.first {
            selectHost(first)
        } else {
            render()
        }
    }

    private func typedHost() {
        let host = Dialogs.entryText(hostEntry)
        guard !host.isEmpty else { return }
        selectHost(host)
    }

    private func pressCheck() {
        let host = Dialogs.entryText(hostEntry)
        guard !host.isEmpty else { return }
        currentHost = host
        let password = Dialogs.entryText(passwordEntry)
        runner.check(host: host, password: password.isEmpty ? nil : password, serverName: host)
        render()
    }

    /// A host taken up by the picker: typed, chosen from the known list, or handed in by whoever
    /// opened the window. A host this device has already confirmed once is re-checked with its
    /// remembered password rather than left to say "not checked" over a daemon that answers fine.
    private func selectHost(_ host: String) {
        guard !host.isEmpty else { return }
        currentHost = host
        mode = .board
        gtk_editable_set_text(op(hostEntry), host)
        if runner.isDemo(host: host) {
            if runner.reach[host] == nil { runner.probe(host: host, serverName: host) }
        } else if runner.reach[host] == nil, DelegateAccessStore.access(host: host) != nil {
            runner.check(host: host, password: runner.password(host: host), serverName: host)
        }
        render()
    }

    private func showBoard() {
        mode = .board
        render()
    }

    private func openRun(_ runID: String) {
        runner.load(runID: runID, host: currentHost, serverName: currentHost)
        mode = .run(runID)
        render()
    }

    private func close() {
        gtk_window_destroy(ptr(window))
    }

    private static func destroyed(_ window: DelegateWindow) {
        if open === window { open = nil }
        window.runner.unwatch(window)
    }

    private func render() {
        let board = isBoard
        gtk_widget_set_visible(backButton, board ? 0 : 1)
        gtk_widget_set_visible(pickerRow, board ? 1 : 0)
        gtk_widget_set_visible(reachLabel, board ? 1 : 0)
        updateHeader()
        if board { updateConnectRow() }
        Gtk.removeChildren(of: below)
        switch mode {
        case .board:
            if (runner.reach[currentHost] ?? .unknown).isAnswering {
                gtk_box_append(ptr(below), boardContent())
            }
        case .run(let runID):
            gtk_box_append(ptr(below), runContent(runID))
        }
    }

    private func updateHeader() {
        switch mode {
        case .board:
            adw_window_title_set_subtitle(
                op(UnsafeMutableRawPointer(titleWidget)), currentHost)
        case .run(let runID):
            let story = runner.boards[currentHost]?.story(for: runID)
            adw_window_title_set_subtitle(
                op(UnsafeMutableRawPointer(titleWidget)), story?.headline ?? runID)
        }
    }

    private func updateConnectRow() {
        let reach = runner.reach[currentHost] ?? .unknown
        gtk_label_set_text(op(reachLabel), reach.line)
        DelegateToneCSS.apply(reachLabel, reach.tone)
        let checking = reach == .checking
        let isDemo = runner.isDemo(host: currentHost)
        gtk_widget_set_sensitive(checkButton, checking ? 0 : 1)
        gtk_button_set_label(ptr(checkButton), checking ? Localized.text("Checking…") : Localized.text("Check"))
        gtk_widget_set_visible(passwordEntry, (reach.isAnswering || isDemo) ? 0 : 1)
        gtk_widget_set_visible(checkButton, isDemo ? 0 : 1)
    }

    private func boardContent() -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 16)
        let board = runner.board(host: currentHost, serverName: currentHost)
        gtk_box_append(ptr(column), statusRow(board))
        if let note = board.note {
            gtk_box_append(ptr(column), Gtk.label(note, css: "watch-meta", wrap: true, selectable: false))
        }
        if !board.tierLines.isEmpty {
            gtk_box_append(ptr(column), DelegateRunView.sectionLabel(Localized.text("Tiers")))
            gtk_box_append(ptr(column), tiersBlock(board))
        }
        gtk_box_append(ptr(column), newPacketButton())
        gtk_box_append(ptr(column), DelegateRunView.sectionLabel(Localized.text("Runs")))
        gtk_box_append(ptr(column), runsBlock(board))
        if !board.statRows.isEmpty || !board.promotions.isEmpty {
            gtk_box_append(ptr(column), DelegateRunView.sectionLabel(Localized.text("Stats")))
            gtk_box_append(ptr(column), statsBlock(board))
        }
        return column
    }

    private func statusRow(_ board: DelegateBoard) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let label = Gtk.label(board.statusLine, css: "row-title", wrap: true, selectable: false)
        gtk_widget_set_hexpand(label, 1)
        DelegateToneCSS.apply(label, board.statusTone)
        gtk_box_append(ptr(row), label)
        gtk_box_append(
            ptr(row),
            Gtk.button(Localized.text("Refresh"), css: ["flat"]) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.runner.refresh(host: self.currentHost, serverName: self.currentHost)
                }
            })
        return row
    }

    private func tiersBlock(_ board: DelegateBoard) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        for tier in board.tierLines {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let name = Gtk.label(
                tier.label.isEmpty ? tier.tier : tier.label, css: "row-title", selectable: false)
            gtk_widget_set_hexpand(name, 1)
            gtk_box_append(ptr(row), name)
            let model = Gtk.label(tier.model, css: "watch-meta", selectable: false)
            gtk_label_set_ellipsize(op(model), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(op(model), 28)
            gtk_box_append(ptr(row), model)
            let pill = Gtk.label(tier.detail, css: "pill", selectable: false)
            DelegateToneCSS.applyPill(pill, tier.tone)
            gtk_box_append(ptr(row), pill)
            gtk_box_append(ptr(column), row)
        }
        return column
    }

    private func newPacketButton() -> UnsafeMutablePointer<GtkWidget> {
        let button = Gtk.button(
            DelegateEntryPoint.newPacketTitle, css: ["suggested-action", "pill"]
        ) { [weak self] in
            Gtk.onMain { [weak self] in self?.presentComposer() }
        }
        gtk_widget_set_halign(button, GTK_ALIGN_START)
        return button
    }

    private func presentComposer() {
        let board = runner.board(host: currentHost, serverName: currentHost)
        DelegateComposerDialog.present(parent: window, board: board) { [weak self] draft in
            self?.send(draft)
        }
    }

    private func send(_ draft: DelegateDraft) {
        let host = currentHost
        runner.start(host: host, serverName: host, draft: draft) { [weak self] result in
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

    private func runsBlock(_ board: DelegateBoard) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        let stories = board.runStories
        guard !stories.isEmpty else {
            gtk_box_append(
                ptr(column), Gtk.label(board.emptyLine, css: "dim", wrap: true, selectable: false))
            return column
        }
        for story in stories { gtk_box_append(ptr(column), runRow(story)) }
        return column
    }

    private func runRow(_ story: DelegateRunStory) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "session-row")

        let glyph = Gtk.label("●", selectable: false)
        DelegateToneCSS.apply(glyph, story.tone)
        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        Gtk.margins(glyph, top: 3)
        ActivityPulse.apply(story.activity?.icon, to: glyph)

        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.label(story.headline, css: "row-title", selectable: false)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(titleRow), title)
        if let badge = story.badge {
            let pill = Gtk.label(badge, css: "pill", selectable: false)
            DelegateToneCSS.applyPill(pill, story.tone)
            gtk_box_append(ptr(titleRow), pill)
        }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_box_append(ptr(column), titleRow)
        let subtitle = Gtk.label(story.subtitle, css: "row-detail", selectable: false)
        gtk_label_set_ellipsize(op(subtitle), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(column), subtitle)
        gtk_widget_set_hexpand(column, 1)

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 4, bottom: 4, leading: 4, trailing: 4)
        gtk_box_append(ptr(row), glyph)
        gtk_box_append(ptr(row), column)
        gtk_button_set_child(ptr(button), row)

        let runID = story.runID
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.openRun(runID) }
        }
        return button
    }

    private func statsBlock(_ board: DelegateBoard) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        for row in board.statRows {
            let block = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_box_append(
                ptr(block),
                Gtk.label(
                    "\(row.taskClass) / \(row.tier) · \(row.rateText)", css: "row-title",
                    selectable: false))
            gtk_box_append(ptr(block), Gtk.label(row.line, css: "row-detail", selectable: false))
            gtk_box_append(ptr(column), block)
        }
        for hint in board.promotions {
            gtk_box_append(
                ptr(column), Gtk.label(hint, css: "watch-meta", wrap: true, selectable: false))
        }
        return column
    }

    private func runContent(_ runID: String) -> UnsafeMutablePointer<GtkWidget> {
        let board = runner.board(host: currentHost, serverName: currentHost)
        guard let story = board.story(for: runID) else {
            return Gtk.label(Localized.text("This run is gone."), css: "dim", selectable: false)
        }
        return DelegateRunView.make(
            story: story, board: board,
            onApprove: { [weak self] in self?.respondToApproval(runID: runID, approved: true) },
            onHold: { [weak self] in self?.respondToApproval(runID: runID, approved: false) },
            onCancel: { [weak self] in self?.cancelRun(runID) },
            onReplay: { [weak self] tier in self?.replayRun(runID, tier: tier) })
    }

    /// The run screen's only gated decision: approve climbs, hold ends the run as held. Both cross
    /// the network through `DelegateClient.approve`, never a local guess about what the daemon will
    /// do with it.
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

    /// As tall as the surface asks for, and never taller than the display it opens on — the board
    /// carries a picker, a status line, every tier and every run, which is a tall window by design.
    private static func height(near widget: UnsafeMutablePointer<GtkWidget>?) -> Int32 {
        let asked: Int32 = 780
        let available = Int32(tailscode_monitor_workarea_height(widget))
        guard available > 0 else { return asked }
        return max(520, min(asked, Int32(Double(available) * 0.9)))
    }
}
