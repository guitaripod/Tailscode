import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The picture as it will leave, before it leaves. Sharing a picture nobody has seen is a guess,
/// so the clipboard and the file dialog are reached through this window: the format (a post X
/// shows whole, a square, a portrait, the full-length column), a chip for every module the
/// account can fill and the reason beside every one it cannot, the look, and the picture itself,
/// redrawn a moment after anything changes. The choice is remembered per device; nothing in the
/// panel behind changes, because the share dresses the picture only.
final class ShareCardDialog: @unchecked Sendable {
    private static let redrawDelay: UInt32 = 120

    private let analytics: UsageAnalytics
    private let package: AnalyticsShare
    private let slot: UnsafeMutablePointer<GtkWidget>
    private let note: UnsafeMutablePointer<GtkWidget>
    private var stylePicker: UnsafeMutablePointer<GtkWidget>?
    private var formatButtons: [ShareFormat: UnsafeMutablePointer<GtkWidget>] = [:]
    private var chips: [ShareModule: UnsafeMutablePointer<GtkWidget>] = [:]
    private var window: UnsafeMutablePointer<GtkWidget>?
    private var updating = false
    private var closed = false
    private var generation = 0

    private(set) var selection: ShareSelection
    private(set) var previewSize: (width: Int, height: Int)?
    private(set) var offers: [String] = []

    @discardableResult
    static func present(
        _ analytics: UsageAnalytics, parent: UnsafeMutablePointer<GtkWidget>?,
        selection: ShareSelection = ShareSelectionStore.load()
    ) -> ShareCardDialog {
        let dialog = ShareCardDialog(analytics, selection: selection)
        dialog.build(parent: parent)
        return dialog
    }

    var hasPreview: Bool { gtk_widget_get_first_child(slot) != nil }

    var fit: ShareFit { selection.fit(analytics) }

    var caption: String { package.caption(selection) }

    var altText: String { package.altText(selection) }

    func close() {
        guard let window, !closed else { return }
        gtk_window_destroy(ptr(window))
    }

    func isEnabled(_ module: ShareModule) -> Bool {
        guard let chip = chips[module] else { return false }
        return gtk_widget_get_sensitive(chip) != 0
    }

    func isOn(_ module: ShareModule) -> Bool {
        guard let chip = chips[module] else { return false }
        return gtk_toggle_button_get_active(ptr(chip)) != 0
    }

    private init(_ analytics: UsageAnalytics, selection: ShareSelection) {
        self.analytics = analytics
        self.package = AnalyticsShare(analytics)
        self.selection = selection
        slot = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        note = Gtk.label("", css: "dim-label", wrap: true, selectable: false)
    }

    private func build(parent: UnsafeMutablePointer<GtkWidget>?) {
        let (made, content, actions) = Dialogs.windowWithActions(
            title: Localized.text("Share card"), parent: parent, width: 780)
        window = made
        gtk_window_set_default_size(ptr(made), 780, 860)

        gtk_box_append(ptr(content), formatRow())
        gtk_box_append(ptr(content), moduleRow())
        gtk_widget_set_visible(note, 0)
        gtk_box_append(ptr(content), note)
        gtk_box_append(ptr(content), styleRow())

        gtk_widget_set_hexpand(slot, 1)
        gtk_box_append(ptr(content), slot)

        let retained = Unmanaged.passRetained(self).toOpaque()
        g_object_set_data_full(
            ptr(made), "tailscode-share-card", retained,
            { raw in
                guard let raw else { return }
                let dialog = Unmanaged<ShareCardDialog>.fromOpaque(raw).takeRetainedValue()
                dialog.closed = true
            })

        let windowHold = Gtk.WeakWidget(made)
        let captionButton = Gtk.button(Localized.text("Copy caption")) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                Gtk.copyToClipboard(self.caption)
            }
        }
        let copy = Gtk.button(Localized.text("Copy card")) { [weak self] in
            Gtk.onMain { [weak self] in self?.copyCard() }
        }
        let save = Gtk.button(Localized.text("Save image…")) { [weak self] in
            Gtk.onMain { [weak self] in self?.saveCard(window: windowHold) }
        }
        let close = Gtk.button(Localized.text("Close"), css: ["suggested-action"]) {
            guard let raw = windowHold.widget else { return }
            gtk_window_destroy(ptr(raw))
        }
        for button in [captionButton, copy, save, close] { gtk_box_append(ptr(actions), button) }
        offers = [
            Localized.text("Copy caption"), Localized.text("Copy card"),
            Localized.text("Save image…"), Localized.text("Close"),
        ]
        Gtk.onKey(made) { keyval, _ in
            guard keyval == Keymap.escape else { return false }
            guard let raw = windowHold.widget else { return true }
            gtk_window_destroy(ptr(raw))
            return true
        }
        refreshControls()
        renderPreview()
        gtk_window_present(ptr(made))
    }

    private func formatRow() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_box_append(ptr(row), Gtk.label(Localized.text("Format"), css: "dim-label", selectable: false))
        let group = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(group, "linked")
        var lead: UnsafeMutablePointer<GtkWidget>?
        for format in ShareFormat.allCases {
            let button = gtk_toggle_button_new_with_label(format.title)!
            if let lead { gtk_toggle_button_set_group(ptr(button), ptr(lead)) } else { lead = button }
            gtk_widget_set_tooltip_text(button, format.tagline)
            tailscode_set_accessible_label(button, format.title)
            tailscode_set_accessible_description(button, format.tagline)
            let hold = Gtk.WeakWidget(button)
            Gtk.connect(UnsafeMutableRawPointer(button), "toggled") { [weak self] in
                guard let self, !self.updating, let raw = hold.widget,
                    gtk_toggle_button_get_active(ptr(raw)) != 0
                else { return }
                Gtk.onMain { [weak self] in self?.choose(format) }
            }
            formatButtons[format] = button
            gtk_box_append(ptr(group), button)
        }
        gtk_box_append(ptr(row), group)
        return row
    }

    private func moduleRow() -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_box_append(ptr(column), Gtk.label(Localized.text("Modules"), css: "dim-label", selectable: false))
        let flow = gtk_flow_box_new()!
        gtk_flow_box_set_selection_mode(op(flow), GTK_SELECTION_NONE)
        gtk_flow_box_set_max_children_per_line(op(flow), 6)
        gtk_flow_box_set_column_spacing(op(flow), 6)
        gtk_flow_box_set_row_spacing(op(flow), 6)
        gtk_flow_box_set_homogeneous(op(flow), 0)
        for module in ShareModule.selectable {
            let chip = gtk_toggle_button_new()!
            let content = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
            gtk_box_append(ptr(content), gtk_image_new_from_icon_name(Self.icon(module))!)
            gtk_box_append(ptr(content), gtk_label_new(module.title)!)
            gtk_button_set_child(ptr(chip), content)
            tailscode_set_accessible_label(chip, module.title)
            let hold = Gtk.WeakWidget(chip)
            Gtk.connect(UnsafeMutableRawPointer(chip), "toggled") { [weak self] in
                guard let self, !self.updating, hold.widget != nil else { return }
                Gtk.onMain { [weak self] in self?.press(module) }
            }
            chips[module] = chip
            gtk_flow_box_append(op(flow), chip)
        }
        gtk_box_append(ptr(column), flow)
        return column
    }

    private func styleRow() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(row), Gtk.label(Localized.text("Card style"), css: "dim-label", selectable: false))
        let model = gtk_string_list_new(nil)!
        for candidate in CardStyle.all { gtk_string_list_append(model, candidate.name) }
        let picker = gtk_drop_down_new(OpaquePointer(UnsafeMutableRawPointer(model)), nil)!
        gtk_widget_set_tooltip_text(picker, Localized.text("Card style"))
        tailscode_set_accessible_label(picker, Localized.text("Card style"))
        let hold = Gtk.WeakWidget(picker)
        Gtk.onNotify(UnsafeMutableRawPointer(picker), property: "selected") { [weak self] in
            guard let self, let raw = hold.widget, !self.updating else { return }
            let selected = Int(gtk_drop_down_get_selected(op(raw)))
            guard CardStyle.all.indices.contains(selected) else { return }
            let picked = CardStyle.all[selected]
            guard picked.id != self.selection.style.id else { return }
            self.selection.style = picked
            CardStyleSelection.set(picked)
            SettingsFile.capture()
            self.scheduleRedraw()
        }
        stylePicker = picker
        gtk_box_append(ptr(row), picker)
        return row
    }

    func choose(_ format: ShareFormat) {
        guard format != selection.format else { return }
        selection.format = format
        selection.style = CardStyleSelection.current(for: format)
        remember()
        refreshControls()
        scheduleRedraw()
    }

    func press(_ module: ShareModule) {
        let outcome = selection.toggle(module, in: analytics)
        remember()
        refreshControls()
        if case .refused(let reason) = outcome {
            show(note: reason)
            return
        }
        scheduleRedraw()
    }

    private func remember() {
        ShareSelectionStore.save(selection)
        SettingsFile.capture()
    }

    private func show(note text: String?) {
        guard let text, !text.isEmpty else {
            gtk_widget_set_visible(note, 0)
            return
        }
        gtk_label_set_text(op(note), text)
        gtk_widget_set_visible(note, 1)
    }

    private func refreshControls() {
        updating = true
        defer { updating = false }
        for (format, button) in formatButtons {
            gtk_toggle_button_set_active(ptr(button), format == selection.format ? 1 : 0)
        }
        let current = fit
        for module in ShareModule.selectable {
            guard let chip = chips[module] else { continue }
            let state = current.state(of: module)
            let on: Bool
            var reason: String?
            switch state {
            case .on:
                on = true
            case .off:
                on = false
            case .blocked(let why):
                on = false
                reason = why
            }
            gtk_toggle_button_set_active(ptr(chip), on ? 1 : 0)
            gtk_widget_set_sensitive(chip, reason == nil ? 1 : 0)
            gtk_widget_set_tooltip_text(chip, reason ?? module.title)
            tailscode_set_accessible_description(chip, reason ?? "")
        }
        if let picker = stylePicker {
            let index = CardStyle.all.firstIndex { $0.id == selection.style.id } ?? 0
            gtk_drop_down_set_selected(op(picker), guint(index))
        }
        show(note: current.note)
    }

    private func scheduleRedraw() {
        generation += 1
        let mine = generation
        Gtk.after(Self.redrawDelay) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.closed, mine == self.generation else { return }
                self.renderPreview()
            }
        }
    }

    /// The preview is drawn at the card's own logical size, a quarter of the pixels the copy will
    /// carry, and the picture widget scales it to the window: text laid out at a fraction of a
    /// point per pixel would be hinted to whole pixels and no longer sit where Core put it.
    private func renderPreview() {
        guard let poster = AnalyticsCardRenderer.render(package, selection: selection, scale: 1),
            let png = poster.png
        else { return }
        previewSize = (poster.width, poster.height)
        Gtk.removeChildren(of: slot)
        let picture: UnsafeMutablePointer<GtkWidget>? = png.withUnsafeBytes { raw in
            guard let base = raw.baseAddress,
                let texture = tailscode_texture_from_bytes(base, gsize(png.count))
            else { return nil }
            defer { g_object_unref(UnsafeMutableRawPointer(texture)) }
            return tailscode_picture_for_texture(texture)
        }
        guard let picture else { return }
        gtk_widget_set_hexpand(picture, 1)
        Gtk.addClass(picture, "share-card-preview")
        tailscode_set_accessible_label(picture, Localized.text("Card preview"))
        tailscode_set_accessible_description(picture, altText)
        gtk_box_append(ptr(slot), picture)
    }

    private func copyCard() {
        guard let png = AnalyticsCardRenderer.png(package, selection: selection) else {
            Gtk.copyToClipboard(package.plainText)
            return
        }
        png.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            tailscode_clipboard_set_text_and_image_png(package.plainText, base, gsize(png.count))
        }
    }

    private func saveCard(window hold: Gtk.WeakWidget) {
        guard let png = AnalyticsCardRenderer.png(package, selection: selection),
            let raw = hold.widget
        else { return }
        Gtk.saveFile(parent: ptr(raw), suggestedName: package.filename, data: png) { _ in }
    }

    private static func icon(_ module: ShareModule) -> String {
        switch module {
        case .hero: return "emblem-system-symbolic"
        case .activity: return "emblem-system-symbolic"
        case .daily: return "view-continuous-symbolic"
        case .week: return "x-office-calendar-symbolic"
        case .providers: return "network-server-symbolic"
        case .models: return "applications-engineering-symbolic"
        case .projects: return "folder-symbolic"
        case .tools: return "applications-utilities-symbolic"
        case .tokens: return "view-grid-symbolic"
        case .records: return "starred-symbolic"
        case .insights: return "dialog-information-symbolic"
        }
    }
}
