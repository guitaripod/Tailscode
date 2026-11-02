import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The furniture every machine-level window shares: a non-modal preferences window floated over
/// the app, one page whose groups are redrawn whole when what they say changes, a toast, and the
/// rule that a class-backed GTK window holds its own Swift object for as long as it is open — so a
/// second ask raises the open window rather than stacking a copy.
class MachineWindow: @unchecked Sendable {
    let key: String
    var window: UnsafeMutablePointer<GtkWidget>?
    var page: UnsafeMutablePointer<GtkWidget>?
    var groups: [UnsafeMutablePointer<GtkWidget>] = []
    var isOpen: Bool { window != nil }

    init(key: String) {
        self.key = key
    }

    /// Raises the window under `key` when one is open, or builds this one.
    func show(title: String, parent: UnsafeMutablePointer<GtkWidget>?, width: Int32 = 560, height: Int32 = 680) {
        if let window {
            gtk_window_present(ptr(window))
            return
        }
        let window = adw_preferences_window_new()!
        gtk_window_set_title(ptr(window), title)
        gtk_window_set_default_size(ptr(window), width, height)
        gtk_window_set_modal(ptr(window), 0)
        adw_preferences_window_set_search_enabled(ptr(window), 0)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }
        let page = adw_preferences_page_new()!
        adw_preferences_window_add(ptr(window), ptr(page))
        self.window = window
        self.page = page
        MachineWindowRegistry.hold(self)
        let key = self.key
        Gtk.observe(UnsafeMutableRawPointer(window), "close-request") {
            MachineWindowRegistry.release(key)
        }
        opened()
        gtk_window_present(ptr(window))
    }

    /// What a subclass does once its window exists: fill it and start asking.
    func opened() {}

    /// What a subclass stops when its window goes.
    func closed() {}

    func close() {
        guard let window else { return }
        gtk_window_close(ptr(window))
    }

    /// Replaces every group on the page with `fresh`, in order.
    func replaceGroups(_ fresh: [UnsafeMutablePointer<GtkWidget>]) {
        guard let page else { return }
        for group in groups { adw_preferences_page_remove(ptr(page), ptr(group)) }
        groups = fresh
        for group in fresh { adw_preferences_page_add(ptr(page), ptr(group)) }
    }

    func toast(_ text: String) {
        guard let window, let toast = adw_toast_new(text) else { return }
        adw_toast_set_timeout(toast, 3)
        adw_preferences_window_add_toast(ptr(window), toast)
    }

    func forgetWidgets() {
        closed()
        window = nil
        page = nil
        groups = []
    }

    /// A refusal in the words it came with: the server's own sentence where it gave one.
    static func words(_ error: Error) -> String {
        if case AgentError.http(_, let body) = error,
            let data = body.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sentence = object["error"] as? String
        {
            return sentence
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

enum MachineWindowRegistry {
    nonisolated(unsafe) private static var open: [String: MachineWindow] = [:]

    static func hold(_ window: MachineWindow) { open[window.key] = window }

    static func release(_ key: String) {
        open[key]?.forgetWidgets()
        open[key] = nil
    }

    static func existing(_ key: String) -> MachineWindow? { open[key] }

    /// Every open window of one kind, for a change that all of them should read again.
    static func all<Kind: MachineWindow>(_ kind: Kind.Type) -> [Kind] {
        open.values.compactMap { $0 as? Kind }
    }
}

/// The rows the machine windows are built from, drawn the Adwaita way.
enum MachineRows {
    static func group(_ title: String?, description: String? = nil) -> UnsafeMutablePointer<GtkWidget> {
        let group = adw_preferences_group_new()!
        if let title { adw_preferences_group_set_title(ptr(group), title) }
        if let description { adw_preferences_group_set_description(ptr(group), description) }
        return group
    }

    static func add(_ row: UnsafeMutablePointer<GtkWidget>, to group: UnsafeMutablePointer<GtkWidget>) {
        adw_preferences_group_add(ptr(group), ptr(row))
    }

    static func row(
        _ title: String, subtitle: String? = nil, subtitleCSS: String? = nil, wraps: Bool = true
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_action_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), title)
        if let subtitle, !subtitle.isEmpty {
            adw_action_row_set_subtitle(ptr(row), subtitle)
            if wraps { adw_action_row_set_subtitle_lines(ptr(row), 0) }
        }
        if let subtitleCSS { Gtk.addClass(row, subtitleCSS) }
        return row
    }

    /// A row that opens something: the whole row takes the press and wears a chevron.
    static func link(
        _ title: String, subtitle: String? = nil, onOpen: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = row(title, subtitle: subtitle)
        gtk_list_box_row_set_activatable(ptr(row), 1)
        let chevron = Gtk.label("›", css: "dim-label", selectable: false)
        gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(row), chevron)
        Gtk.connect(UnsafeMutableRawPointer(row), "activated") { Gtk.onMain { onOpen() } }
        return row
    }

    static func prefix(_ text: String, css: String?, on row: UnsafeMutablePointer<GtkWidget>) {
        let label = Gtk.label(text, css: css, selectable: false)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(label, 22, -1)
        adw_action_row_add_prefix(ptr(row), label)
    }

    static func suffixButton(
        _ title: String, css: [String] = ["flat"], sensitive: Bool = true, on row: UnsafeMutablePointer<GtkWidget>,
        onClick: @escaping @Sendable () -> Void
    ) {
        let button = Gtk.button(title, css: css) { Gtk.onMain { onClick() } }
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        gtk_widget_set_sensitive(button, sensitive ? 1 : 0)
        adw_action_row_add_suffix(ptr(row), button)
    }

    /// A widget that is not a row, seated in a group as a row of its own so it draws where it is
    /// added rather than below the group's rows.
    static func wrapped(_ child: UnsafeMutablePointer<GtkWidget>, margin: Int32 = 12) -> UnsafeMutablePointer<GtkWidget> {
        let holder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.margins(holder, top: margin, bottom: margin, leading: margin, trailing: margin)
        gtk_box_append(ptr(holder), child)
        let row = adw_preferences_row_new()!
        gtk_list_box_row_set_child(ptr(row), holder)
        gtk_list_box_row_set_activatable(ptr(row), 0)
        gtk_list_box_row_set_selectable(ptr(row), 0)
        return row
    }

    static func tone(_ tone: AgentTone) -> String? {
        switch tone {
        case .ready: return "fact-good"
        case .attention: return "fact-warn"
        case .failed: return "fact-bad"
        case .working, .neutral: return nil
        }
    }

    static func stepGlyph(_ state: AgentSetupStep.State) -> (String, String) {
        switch state {
        case .done: return ("✓", "glyph-done")
        case .next: return ("○", "glyph-needs")
        case .waiting: return ("·", "dim-label")
        case .failed: return ("!", "glyph-error")
        case .working: return ("…", "glyph-pending")
        }
    }

    static func markCSS(_ mark: ScheduleMark) -> String {
        switch mark {
        case .answered, .done: return "glyph-done"
        case .failed: return "glyph-error"
        case .running, .caughtUp: return "glyph-pending"
        case .missed: return "glyph-needs"
        case .quiet, .waiting, .paused: return "dim-label"
        }
    }

    static func openLink(_ address: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [address]
        try? process.run()
    }
}
