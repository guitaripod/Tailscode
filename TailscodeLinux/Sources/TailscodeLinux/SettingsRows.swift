import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The rows every Settings page is made of. A page asks for a group and fills it; nothing here
/// knows what a setting means, only how one is drawn — and each is drawn the Adwaita way, so a
/// row reads, focuses and takes a keyboard the same wherever it sits.
enum SettingsRows {
    static func group(
        _ title: String?, on page: UnsafeMutablePointer<GtkWidget>, description: String? = nil
    ) -> UnsafeMutablePointer<GtkWidget> {
        let group = adw_preferences_group_new()!
        if let title { adw_preferences_group_set_title(ptr(group), title) }
        if let description { adw_preferences_group_set_description(ptr(group), description) }
        adw_preferences_page_add(ptr(page), ptr(group))
        return group
    }

    /// Holds `object` for exactly as long as `widget` lives. A page's controls call back into the
    /// object that built them through weak references, and nothing else owns it: left alone it is
    /// gone before the first press, and every slider answers into nothing.
    static func keep(_ object: AnyObject, alive widget: UnsafeMutablePointer<GtkWidget>) {
        g_object_set_data_full(
            UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GObject.self),
            "tailscode-kept-\(ObjectIdentifier(object).hashValue)",
            Unmanaged.passRetained(object).toOpaque()
        ) { raw in
            guard let raw else { return }
            Unmanaged<AnyObject>.fromOpaque(raw).release()
        }
    }

    static func add(_ row: UnsafeMutablePointer<GtkWidget>, to group: UnsafeMutablePointer<GtkWidget>) {
        adw_preferences_group_add(ptr(group), ptr(row))
    }

    static func comboRow(
        title: String, subtitle: String?, options: [String], selected: Int,
        onChange: @escaping @Sendable (Int) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_combo_row_new()!
        adw_preferences_row_set_title(ptr(row), title)
        if let subtitle { adw_action_row_set_subtitle(ptr(row), subtitle) }
        let model = gtk_string_list_new(nil)!
        for option in options { gtk_string_list_append(model, option) }
        adw_combo_row_set_model(
            ptr(UnsafeMutableRawPointer(row)), OpaquePointer(UnsafeMutableRawPointer(model)))
        adw_combo_row_set_selected(ptr(UnsafeMutableRawPointer(row)), guint(selected))
        let bits = UInt(bitPattern: row)
        Gtk.onNotify(UnsafeMutableRawPointer(row), property: "selected") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            onChange(Int(adw_combo_row_get_selected(ptr(raw))))
        }
        return row
    }

    static func switchRow(
        title: String, subtitle: String?, value: Bool,
        onChange: @escaping @Sendable (Bool) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_switch_row_new()!
        adw_preferences_row_set_title(ptr(row), title)
        if let subtitle { adw_action_row_set_subtitle(ptr(row), subtitle) }
        adw_switch_row_set_active(OpaquePointer(row), value ? 1 : 0)
        let bits = UInt(bitPattern: row)
        Gtk.onNotify(UnsafeMutableRawPointer(row), property: "active") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            onChange(adw_switch_row_get_active(op(raw)) != 0)
        }
        return row
    }

    static func spinRow(
        title: String, subtitle: String? = nil, value: Double, lower: Double, upper: Double,
        step: Double, onChange: @escaping @Sendable (Double) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_spin_row_new_with_range(lower, upper, step)!
        adw_preferences_row_set_title(ptr(row), title)
        if let subtitle { adw_action_row_set_subtitle(ptr(row), subtitle) }
        adw_spin_row_set_value(OpaquePointer(row), value)
        let bits = UInt(bitPattern: row)
        Gtk.onNotify(UnsafeMutableRawPointer(row), property: "value") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            onChange(adw_spin_row_get_value(op(raw)))
        }
        return row
    }

    static func buttonRow(
        _ title: String, subtitle: String? = nil, label: String? = nil,
        onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_action_row_new()!
        adw_preferences_row_set_title(ptr(row), title)
        if let subtitle { adw_action_row_set_subtitle(ptr(row), subtitle) }
        let button = Gtk.button(label ?? Localized.text("Reset"), css: ["flat"], onClick: onClick)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(row), button)
        return row
    }

    /// A fact and no control: the title on the left, the value on the right, and no pretence of
    /// being something to press.
    static func infoRow(
        _ title: String, value: String, subtitle: String? = nil
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_action_row_new()!
        adw_preferences_row_set_title(ptr(row), title)
        if let subtitle { adw_action_row_set_subtitle(ptr(row), subtitle) }
        let label = Gtk.label(value, css: "dim-label", wrap: false, selectable: false)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(row), label)
        gtk_list_box_row_set_activatable(ptr(UnsafeMutableRawPointer(row)), 0)
        return row
    }

    /// A choice among a few short words, drawn as one linked strip of buttons: the whole set is
    /// visible and one press picks, which a drop-down that hides its options and truncates the
    /// one it shows never manages.
    static func segmentedRow(
        title: String, subtitle: String?, options: [String], selected: Int,
        onChange: @escaping @Sendable (Int) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_action_row_new()!
        adw_preferences_row_set_title(ptr(row), title)
        if let subtitle { adw_action_row_set_subtitle(ptr(row), subtitle) }
        let strip = segmented(options: options, selected: selected, onChange: onChange)
        adw_action_row_add_suffix(ptr(row), strip)
        return row
    }

    static func segmented(
        options: [String], selected: Int, onChange: @escaping @Sendable (Int) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let strip = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_add_css_class(strip, "linked")
        gtk_widget_set_valign(strip, GTK_ALIGN_CENTER)
        var first: UnsafeMutablePointer<GtkWidget>?
        for (index, option) in options.enumerated() {
            let button = gtk_toggle_button_new_with_label(option)!
            if let first {
                gtk_toggle_button_set_group(ptr(button), ptr(first))
            } else {
                first = button
            }
            if index == selected { gtk_toggle_button_set_active(ptr(button), 1) }
            let bits = UInt(bitPattern: button)
            Gtk.onNotify(UnsafeMutableRawPointer(button), property: "active") {
                guard let raw = UnsafeMutableRawPointer(bitPattern: bits),
                    gtk_toggle_button_get_active(ptr(raw)) != 0
                else { return }
                onChange(index)
            }
            gtk_box_append(ptr(strip), button)
        }
        return strip
    }
}
