import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The servers this machine knows, editable in place, in the desktop's own furniture: a
/// preferences window whose configured group holds one expander per machine — what it is, whether
/// it is answering, which software it runs, which account its Claude is signed into, and the three
/// fields that define it, all editable without removing and re-adding the row.
///
/// A window presented from a local variable is a window whose buttons do nothing: GTK owns the
/// widgets, nothing owns the Swift object behind them, and every `[weak self]` handler wakes up
/// holding nil. This one holds itself for exactly as long as its window is open, and lets go on
/// `close-request`.
///
/// Adding a server probes it before saving — a typo fails here, named, rather than becoming a row
/// that never loads — and the failure is the shared `ConnectDiagnosis`, so the address that didn't
/// parse, the port that answered as something else and the password that was refused each read the
/// same on this desk as on the phone, and each offers the one action that fixes it.
final class ServerManager: @unchecked Sendable {
    let onChanged: @Sendable () -> Void
    var token: UInt = 0
    var window: UnsafeMutablePointer<GtkWidget>?
    var configuredGroup: UnsafeMutablePointer<GtkWidget>?
    var addGroup: UnsafeMutablePointer<GtkWidget>?
    var configuredRows: [UnsafeMutablePointer<GtkWidget>] = []
    var rows: [String: ServerRow] = [:]

    var addressRow: UnsafeMutablePointer<GtkWidget>?
    var nameRow: UnsafeMutablePointer<GtkWidget>?
    var passwordRow: UnsafeMutablePointer<GtkWidget>?
    var agentRow: UnsafeMutablePointer<GtkWidget>?
    var probeButton: UnsafeMutablePointer<GtkWidget>?
    var statusRow: UnsafeMutablePointer<GtkWidget>?
    var statusActions: UnsafeMutablePointer<GtkWidget>?
    var probing = false
    /// The row a save came from, re-opened when the list redraws — an edit applied inside an
    /// expander should leave the reader where they were, not collapsed back to the top.
    var expandAfterReload: String?
    var profiles: [ConnectionProfile] = []
    var observingUpdates = false
    var expandAll = false

    init(onChanged: @escaping @Sendable () -> Void) {
        self.onChanged = onChanged
    }

    func present(parent: UnsafeMutablePointer<GtkWidget>?) {
        if let window {
            gtk_window_present(ptr(window))
            return
        }
        let window = adw_preferences_window_new()!
        gtk_window_set_title(ptr(window), Localized.text("Servers"))
        gtk_window_set_default_size(ptr(window), 640, 780)
        gtk_window_set_modal(ptr(window), 0)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }
        self.window = window

        let page = adw_preferences_page_new()!
        adw_preferences_window_add(ptr(window), ptr(page))
        configuredGroup = makeConfiguredGroup(on: page)
        addGroup = makeAddGroup(on: page)

        token = Self.hold(self)
        let token = self.token
        Gtk.observe(UnsafeMutableRawPointer(window), "close-request") { Self.release(token) }
        observeUpdates()

        reload()
        readTailnetAddress()
        gtk_window_present(ptr(window))
    }

    /// Every answer any machine gives redraws that machine's own embedded card in place — the
    /// same ledger the Software window renders from, so the two can never disagree about what a
    /// reading means while both happen to be open at once.
    /// Opens every server's expander, for a harness that has to look inside them all.
    func expandEverything() {
        expandAll = true
        for row in configuredRows where !profiles.isEmpty { adw_expander_row_set_expanded(ptr(row), 1) }
    }

    func observeUpdates() {
        guard !observingUpdates else { return }
        observingUpdates = true
        for name in [UpdateLedger.didChange, UpdateDriver.didChange] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) {
                [weak self] _ in
                Gtk.onMain { [weak self] in self?.refreshSoftwareCards() }
            }
        }
    }

    func refreshSoftwareCards() {
        guard window != nil else { return }
        let rollup = UpdateLedger.rollup()
        let snapshot = UpdateWatch.driver.snapshot
        for profile in profiles {
            guard let cardView = rows[profile.id]?.softwareCard else { continue }
            let component = UpdateComponent.server(profileID: profile.id)
            let existing = rollup.readings.first { $0.component == component }
            let reading =
                existing
                ?? UpdateReading(
                    component: component, title: profile.name, installed: .unknown,
                    verdict: .unverified(.neverChecked),
                    product: UpdateProduct.name(for: profile.backend))
            cardView.apply(
                UpdateCard(
                    reading, acknowledged: rollup.isAcknowledged(reading),
                    busy: snapshot.isBusy(component) || existing == nil))
        }
    }

    enum Tone {
        case good, warn, bad, quiet

        var css: String? {
            switch self {
            case .good: return "fact-good"
            case .warn: return "fact-warn"
            case .bad: return "fact-bad"
            case .quiet: return nil
            }
        }
    }

    static let glyphTones = [
        "glyph-done", "glyph-error", "glyph-pending", "glyph-needs",
    ]
    static let factTones = ["fact-good", "fact-warn", "fact-bad", "row-detail", "glyph-error"]

    func setGlyph(_ slots: ServerRow, _ text: String, css: String) {
        guard let glyph = slots.glyph else { return }
        gtk_label_set_text(op(glyph), text)
        Gtk.setTone(glyph, css, from: Self.glyphTones)
    }

    func setFact(
        _ row: UnsafeMutablePointer<GtkWidget>?, _ actionBox: UnsafeMutablePointer<GtkWidget>?,
        _ text: String, tone: Tone, actions: [UnsafeMutablePointer<GtkWidget>],
        title: String? = nil
    ) {
        guard let row else { return }
        if let title { adw_preferences_row_set_title(ptr(row), title) }
        adw_action_row_set_subtitle(ptr(row), text)
        Gtk.setTone(row, tone.css, from: Self.factTones)
        guard let actionBox else { return }
        Gtk.removeChildren(of: actionBox)
        for action in actions { gtk_box_append(ptr(actionBox), action) }
        gtk_widget_set_visible(actionBox, actions.isEmpty ? 0 : 1)
    }

    /// A row that states one fact about a server and carries whatever buttons that fact earns.
    /// The subtitle is where the sentence goes — it wraps to as many lines as it needs, because a
    /// named diagnosis is a paragraph and truncating it would put the app back to "unreachable".
    static func factRow(title: String)
        -> (UnsafeMutablePointer<GtkWidget>, UnsafeMutablePointer<GtkWidget>)
    {
        let row = adw_action_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), title)
        adw_action_row_set_subtitle_lines(ptr(row), 0)
        adw_action_row_set_subtitle_selectable(ptr(row), 1)
        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_valign(actions, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(actions, 0)
        adw_action_row_add_suffix(ptr(row), actions)
        return (row, actions)
    }

    /// What an address field puts in front of someone who wants to change it: `host:port` when the
    /// scheme is the ordinary one, and the whole URL when it isn't — a field that hid an `https`
    /// would silently downgrade the server the moment it was applied.
    static func editableAddress(_ profile: ConnectionProfile) -> String {
        guard profile.baseURL.scheme == "http" else {
            var text = profile.baseURL.absoluteString
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return ServerLabel.address(profile)
    }

    static func entryRow(title: String, tooltip: String?)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let row = adw_entry_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), title)
        if let tooltip { gtk_widget_set_tooltip_text(row, tooltip) }
        return row
    }

    /// A password is taken exactly as typed. Every other field here is trimmed, because a stray
    /// space in an address is a typo — in a secret it is a character the server is expecting.
    static func secretText(_ row: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let raw = gtk_editable_get_text(op(row)) else { return "" }
        return String(cString: raw)
    }

    static func passwordRow(title: String) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_password_entry_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), title)
        return row
    }

    static func inlineButton(
        _ title: String, css: [String] = ["flat"], onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = Gtk.button(title, css: css, onClick: onClick)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        return button
    }

    func toast(_ text: String) {
        guard let window, let toast = adw_toast_new(text) else { return }
        adw_preferences_window_add_toast(ptr(window), toast)
    }

    final class Registry: @unchecked Sendable {
        var managers: [UInt: ServerManager] = [:]
        var next: UInt = 1
    }

    static let registry = Registry()

    static func hold(_ manager: ServerManager) -> UInt {
        let token = registry.next
        registry.next += 1
        registry.managers[token] = manager
        return token
    }

    static func release(_ token: UInt) {
        registry.managers[token]?.forgetWidgets()
        registry.managers[token] = nil
    }

    /// Every pointer here belongs to a window GTK has destroyed. The manager itself may outlive it
    /// — the app holds one so a second ask raises rather than rebuilds — and a probe still in
    /// flight will come back to write into a row. Nothing may be touched again, and a reopened
    /// window must build a fresh set rather than take back the group it used to remove rows from.
    func forgetWidgets() {
        for slots in rows.values { slots.capabilities?.stop() }
        window = nil
        configuredGroup = nil
        addGroup = nil
        configuredRows = []
        rows = [:]
        addressRow = nil
        nameRow = nil
        passwordRow = nil
        agentRow = nil
        probeButton = nil
        statusRow = nil
        statusActions = nil
        probing = false
        expandAfterReload = nil
    }
}

/// The widgets one configured server's expander owns, so a probe that finishes a second later can
/// write into exactly its own row rather than rebuilding the list under whoever is reading it.
final class ServerRow {
    var glyph: UnsafeMutablePointer<GtkWidget>?
    var health: UnsafeMutablePointer<GtkWidget>?
    var healthActions: UnsafeMutablePointer<GtkWidget>?
    /// The embedded software card, Core's `UpdateCard` drawn the same way the Software window
    /// draws it — kept here so a ledger change can rewrite exactly this row's card in place.
    var softwareCard: UpdateCardView?
    var previewHost: PreviewHostRow?
    var capabilities: SetupCapabilitiesRows?
    var account: UnsafeMutablePointer<GtkWidget>?
    var accountActions: UnsafeMutablePointer<GtkWidget>?
    /// The Full Disk Access checklist, embedded the same way the software card is — kept here so
    /// a poll that lands a second later writes into exactly this row's box.
    var permissionsBox: MachinePermissionsBox?
    var permissionsWrapper: UnsafeMutablePointer<GtkWidget>?
    var permissionPollPending = false
    var address: UnsafeMutablePointer<GtkWidget>?
    var name: UnsafeMutablePointer<GtkWidget>?
    var password: UnsafeMutablePointer<GtkWidget>?
}
