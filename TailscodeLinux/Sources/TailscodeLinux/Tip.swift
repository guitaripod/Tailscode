import CAdw
import CGtkShim
import Foundation

/// Hover help: what a control does, said under the pointer after a short rest. Every tooltip in
/// the app goes through here rather than through GTK's own, whose delay and look are not
/// settable, so help is quick to arrive, fades in and out, and is drawn in the theme.
enum Tip {
    /// Gives `widget` its help. A nil or empty `text` takes it away.
    static func set(_ widget: UnsafeMutablePointer<GtkWidget>, _ text: String?) {
        tailscode_tip_set(widget, text)
    }

    /// The words a widget's help says, nil when it has none: the ones it was given, or for an
    /// icon-only control the name it carries for a screen reader.
    static func text(of widget: UnsafeMutablePointer<GtkWidget>) -> String? {
        guard let raw = tailscode_tip_words(widget) else { return nil }
        defer { g_free(raw) }
        let words = String(cString: raw)
        return words.isEmpty ? nil : words
    }
}

extension Tip {
    /// One control that shows on screen and says nothing under the pointer.
    struct Gap: Sendable, CustomStringConvertible {
        let kind: String
        let words: String
        let classes: String
        let place: String
        let size: String
        var description: String { "\(kind) “\(words)” [\(classes)] \(size) in \(place)" }
    }

    /// Every button, menu button, switch and check mapped under `root` that has no help and does
    /// not name itself. A button wearing a sentence is its own help; a glyph, a bare icon or a
    /// button holding only a picture is not, and neither is a switch, whose row names it but whose
    /// effect is the thing worth saying.
    static func gaps(under root: UnsafeMutablePointer<GtkWidget>) -> [Gap] {
        var found: [Gap] = []
        walk(root, trail: []) { widget, trail in
            guard let kind = controlKind(widget), !trail.contains(where: Self.isToolkitPart) else { return }
            if text(of: widget) != nil || tailscode_tip_names_itself(widget) != 0 { return }
            let words = visibleWords(in: widget)
            if gtk_widget_get_mapped(widget) == 0 && words.trimmingCharacters(in: .whitespaces).isEmpty {
                return
            }
            found.append(
                Gap(
                    kind: kind, words: words, classes: classes(of: widget),
                    place: trail.suffix(7).joined(separator: " > "),
                    size: "\(gtk_widget_get_width(widget))x\(gtk_widget_get_height(widget)) holds \(inside(widget))"))
        }
        return found
    }

    /// Makes the control whose help reads `words` insensitive or sensitive again, for proving that
    /// help is still said over a control that cannot be pressed. Whether one was found.
    static func setSensitivity(of words: String, to sensitive: Bool) -> Bool {
        var found = false
        let list = gtk_window_list_toplevels()
        var node = list
        while let current = node {
            if let data = current.pointee.data {
                let window: UnsafeMutablePointer<GtkWidget> = ptr(data)
                walk(window, trail: []) { widget, _ in
                    if controlKind(widget) != nil, text(of: widget) == words {
                        gtk_widget_set_sensitive(widget, sensitive ? 1 : 0)
                        found = true
                    }
                }
            }
            node = current.pointee.next
        }
        g_list_free(list)
        return found
    }

    /// Every top-level window the application has, gaps and all.
    static func allGaps() -> [Gap] {
        var found: [Gap] = []
        let list = gtk_window_list_toplevels()
        var node = list
        while let current = node {
            if let data = current.pointee.data {
                let window: UnsafeMutablePointer<GtkWidget> = ptr(data)
                found += gaps(under: window)
            }
            node = current.pointee.next
        }
        g_list_free(list)
        return found
    }

    /// The buttons libadwaita draws inside its own widgets — the arrows of a spin row, a header's
    /// back button — which have a name for a screen reader and no use for a second one.
    private static func isToolkitPart(_ name: String) -> Bool {
        ["AdwSpinRow", "GtkSpinButton", "AdwBackButton", "AdwSplitButton"].contains { name.hasPrefix($0) }
    }

    private static func controlKind(_ widget: UnsafeMutablePointer<GtkWidget>) -> String? {
        let instance = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self)
        if let parent = gtk_widget_get_parent(widget),
            g_type_check_instance_is_a(
                UnsafeMutableRawPointer(parent).assumingMemoryBound(to: GTypeInstance.self),
                gtk_menu_button_get_type()) != 0
        {
            return nil
        }
        if g_type_check_instance_is_a(instance, gtk_menu_button_get_type()) != 0 { return "menu" }
        if g_type_check_instance_is_a(instance, gtk_switch_get_type()) != 0 { return "switch" }
        if g_type_check_instance_is_a(instance, gtk_check_button_get_type()) != 0 { return "check" }
        if g_type_check_instance_is_a(instance, gtk_toggle_button_get_type()) != 0 { return "toggle" }
        if g_type_check_instance_is_a(instance, gtk_button_get_type()) != 0 { return "button" }
        return nil
    }

    private static func walk(
        _ widget: UnsafeMutablePointer<GtkWidget>, trail: [String],
        visit: (UnsafeMutablePointer<GtkWidget>, [String]) -> Void
    ) {
        visit(widget, trail)
        let here = trail + [typeName(widget) + "." + (classes(of: widget).split(separator: " ").first.map(String.init) ?? "")]
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            walk(current, trail: here, visit: visit)
            child = gtk_widget_get_next_sibling(current)
        }
    }

    private static func inside(_ widget: UnsafeMutablePointer<GtkWidget>) -> String {
        var names: [String] = []
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            names.append(typeName(current) + "." + (classes(of: current).split(separator: " ").first.map(String.init) ?? ""))
            child = gtk_widget_get_next_sibling(current)
        }
        return names.joined(separator: ",")
    }

    private static func typeName(_ widget: UnsafeMutablePointer<GtkWidget>) -> String {
        String(cString: g_type_name_from_instance(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self)))
    }

    private static func classes(of widget: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let names = gtk_widget_get_css_classes(widget) else { return "" }
        defer { g_strfreev(names) }
        var out: [String] = []
        var index = 0
        while let name = names[index] {
            out.append(String(cString: name))
            index += 1
        }
        return out.joined(separator: " ")
    }

    private static func visibleWords(in widget: UnsafeMutablePointer<GtkWidget>) -> String {
        var words: [String] = []
        collectWords(widget, into: &words)
        return words.joined(separator: " ")
    }

    private static func collectWords(_ widget: UnsafeMutablePointer<GtkWidget>, into words: inout [String]) {
        let instance = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self)
        if g_type_check_instance_is_a(instance, gtk_label_get_type()) != 0,
            let raw = gtk_label_get_text(op(widget))
        {
            words.append(String(cString: raw))
        }
        if g_type_check_instance_is_a(instance, gtk_button_get_type()) != 0,
            let raw = gtk_button_get_label(ptr(UnsafeMutableRawPointer(widget)))
        {
            words.append(String(cString: raw))
        }
        if g_type_check_instance_is_a(instance, gtk_menu_button_get_type()) != 0,
            let raw = gtk_menu_button_get_label(op(widget))
        {
            words.append(String(cString: raw))
        }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            let kid = UnsafeMutableRawPointer(current).assumingMemoryBound(to: GTypeInstance.self)
            if g_type_check_instance_is_a(kid, gtk_popover_get_type()) == 0 {
                collectWords(current, into: &words)
            }
            child = gtk_widget_get_next_sibling(current)
        }
    }
}
