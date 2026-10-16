import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The Inspect lens: point at the running app's own picture and it says what is there. Hovering
/// outlines the view under the pointer, pressing pins it, and the panel beside the picture gives
/// that view in the app's own words with the views around it as a breadcrumb that walks up to a
/// parent. A line under it takes what a person wants changed and sends it to the agent with the
/// view named, so the agent is told which button is meant rather than asked to guess.
final class PreviewInspectView: PreviewLensView, @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)

    private let model: PreviewInspectModel
    private let message = Gtk.label("", css: "preview-row-detail", wrap: true, selectable: false)
    private let crumbs = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
    private let crumbScroller = gtk_scrolled_window_new()!
    private let rows = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
    private let headline = Gtk.label("", css: "preview-row-title", wrap: true, selectable: false)
    private let say = gtk_entry_new()!
    private let sendButton: UnsafeMutablePointer<GtkWidget>
    private let body = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
    private var drawnRows: [PreviewInspectReading.Row] = []
    private var drawnCrumbs: [String] = []

    init(model: PreviewInspectModel) {
        self.model = model
        sendButton = Gtk.button(Localized.text("Send"), css: ["preview-chip"]) {}
        build()
    }

    private func build() {
        Gtk.margins(root, top: 10, bottom: 12, leading: 8, trailing: 14)
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)

        PreviewPane.capWidth(message, 32)
        gtk_label_set_xalign(op(message), 0)
        gtk_box_append(ptr(root), message)

        PreviewPane.capWidth(headline, 32)
        gtk_box_append(ptr(body), headline)

        gtk_scrolled_window_set_policy(op(crumbScroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
        gtk_scrolled_window_set_child(op(crumbScroller), crumbs)
        gtk_scrolled_window_set_propagate_natural_height(op(crumbScroller), 1)
        gtk_box_append(ptr(body), crumbScroller)

        gtk_box_append(ptr(body), rows)

        gtk_entry_set_placeholder_text(ptr(say), Localized.text("Tell the agent what to change here"))
        Gtk.addClass(say, "preview-say")
        gtk_widget_set_hexpand(say, 1)
        gtk_editable_set_width_chars(op(say), 8)
        gtk_editable_set_max_width_chars(op(say), 40)
        tailscode_set_accessible_label(say, Localized.text("Tell the agent what to change here"))
        Gtk.connect(UnsafeMutableRawPointer(say), "activate") { [weak self] in
            Gtk.onMain { [weak self] in self?.send() }
        }
        Gtk.onKey(say) { [weak self] keyval, _ in
            guard keyval == Keymap.escape, let self else { return false }
            self.model.clearSelection()
            return true
        }
        Gtk.connect(UnsafeMutableRawPointer(sendButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.send() }
        }
        gtk_widget_set_halign(sendButton, GTK_ALIGN_END)
        gtk_box_append(ptr(body), say)
        gtk_box_append(ptr(body), sendButton)
        gtk_box_append(ptr(root), body)
        paint()
    }

    func open() {
        model.setActive(true)
        model.read(audit: false)
        paint()
    }

    func close() {
        model.setActive(false)
    }

    /// Redraws the panel from what the model holds.
    func paint() {
        let shown = model.shown
        if let failure = model.failure, model.tree == nil {
            show(message: failure)
            return
        }
        guard model.tree != nil else {
            show(message: Localized.text("Reading the screen…"))
            return
        }
        guard let shown else {
            show(message: Localized.text("Point at something on the screen. Press to keep it selected."))
            return
        }
        gtk_widget_set_visible(message, 0)
        gtk_widget_set_visible(body, 1)
        let pinned = model.selected != nil
        let title = "\(PreviewInspectReading.name(of: shown)) · \(PreviewInspectReading.kindWords(shown.className))"
        gtk_label_set_text(op(headline), title)
        paintCrumbs(pinned: pinned)
        paintRows(PreviewInspectReading.rows(for: shown))
        gtk_widget_set_sensitive(say, pinned ? 1 : 0)
        gtk_widget_set_sensitive(sendButton, pinned ? 1 : 0)
    }

    private func show(message text: String) {
        gtk_label_set_text(op(message), text)
        gtk_widget_set_visible(message, 1)
        gtk_widget_set_visible(body, 0)
    }

    private func paintCrumbs(pinned: Bool) {
        let trail = pinned ? model.trail : []
        let signature = trail.map { "\($0.id)|\(PreviewInspectReading.crumb($0))" }
        guard signature != drawnCrumbs else { return }
        drawnCrumbs = signature
        Gtk.removeChildren(of: crumbs)
        gtk_widget_set_visible(crumbScroller, trail.isEmpty ? 0 : 1)
        for (depth, node) in trail.enumerated() {
            if depth > 0 { gtk_box_append(ptr(crumbs), Gtk.label("›", css: "preview-row-detail", selectable: false)) }
            let title = depth == 0 ? Localized.text("Window") : PreviewInspectReading.crumb(node)
            let current = depth == trail.count - 1
            let button = Gtk.button(title, css: ["preview-lens"]) { [weak self] in
                Gtk.onMain { [weak self] in self?.model.select(depth: depth) }
            }
            if current { Gtk.addClass(button, "preview-lens-on") }
            gtk_box_append(ptr(crumbs), button)
        }
        Gtk.betweenFrames(of: crumbScroller) { [weak self] in self?.scrollCrumbsToEnd() }
    }

    /// The view pinned is the last crumb, so a trail longer than the panel shows its end and the
    /// rest is a scroll away.
    private func scrollCrumbsToEnd() {
        guard let adjustment = gtk_scrolled_window_get_hadjustment(op(crumbScroller)) else { return }
        gtk_adjustment_set_value(adjustment, gtk_adjustment_get_upper(adjustment))
    }

    private func paintRows(_ wanted: [PreviewInspectReading.Row]) {
        guard wanted != drawnRows else { return }
        drawnRows = wanted
        Gtk.removeChildren(of: rows)
        for row in wanted {
            let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
            let name = Gtk.label(row.label, css: "preview-row-detail", selectable: false)
            gtk_widget_set_valign(name, GTK_ALIGN_START)
            gtk_widget_set_size_request(name, 96, -1)
            let value = Gtk.label(row.value, css: "preview-row-title", wrap: true, selectable: true)
            PreviewPane.capWidth(value, 26)
            gtk_widget_set_hexpand(value, 1)
            gtk_box_append(ptr(line), name)
            gtk_box_append(ptr(line), value)
            gtk_box_append(ptr(rows), line)
        }
    }

    private func send() {
        let typed = (gtk_editable_get_text(op(say)).map(String.init(cString:)) ?? "")
        guard let words = model.sentence(saying: typed) else { return }
        gtk_editable_set_text(op(say), "")
        model.askAgent(words)
    }

    var typedWords: String { gtk_editable_get_text(op(say)).map(String.init(cString:)) ?? "" }

    func type(_ words: String) {
        gtk_editable_set_text(op(say), words)
    }

    func submit() {
        send()
    }

    var headlineText: String { gtk_label_get_text(op(headline)).map(String.init(cString:)) ?? "" }
    var messageText: String { gtk_label_get_text(op(message)).map(String.init(cString:)) ?? "" }
    var rowCount: Int { drawnRows.count }
    var crumbCount: Int { drawnCrumbs.count }
    var canSend: Bool { gtk_widget_get_sensitive(sendButton) != 0 }

    var summary: String {
        "inspect \(model.summary)"
    }

    func drive(_ command: String) -> Bool {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return false }
        let argument = parts.count > 1 ? parts[1] : ""
        let numbers = argument.split(separator: ",").compactMap { Double($0) }
        switch verb {
        case "hover" where numbers.count == 2:
            model.hover(fractionX: numbers[0], fractionY: numbers[1])
        case "press" where numbers.count == 2:
            model.press(fractionX: numbers[0], fractionY: numbers[1])
        case "up":
            model.select(depth: max(0, model.trail.count - 2))
        case "clear":
            model.clearSelection()
        case "say":
            type(argument)
            send()
        default:
            return false
        }
        return true
    }
}
