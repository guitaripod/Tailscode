import CAdw
import CGtkShim
import TailscodeCore

/// The band itself: a strip of clickable facts above the prompt box. Everything on it is either
/// something happening now or something you would act on — and clicking a fact does the obvious
/// thing to it, so reading the status and steering the turn are the same gesture.
enum StatusBand {
    /// A segment must never widen the column it sits in: the band ellipsizes, the conversation
    /// keeps its width.
    private static func clamp(_ widget: UnsafeMutablePointer<GtkWidget>) {
        gtk_widget_set_hexpand(widget, 0)
    }

    /// What the band keeps between renders: the widget for each fact, and the latest facts the
    /// popovers read from. A rebuilt widget is a closed popover, and this band redraws every
    /// second while a turn runs — so a segment that is still on screen is updated in place, and
    /// its list reads the newest facts at the moment it is opened.
    final class State: @unchecked Sendable {
        var facts = StatusFacts()
        fileprivate var widgets: [String: UInt] = [:]

        /// Test-driver access: pops the popover of a menu segment, the way a click would.
        func openMenu(id: String) {
            guard let bits = widgets[id], let raw = UnsafeMutableRawPointer(bitPattern: bits)
            else { return }
            gtk_menu_button_popup(op(raw))
        }
        fileprivate var kinds: [String: String] = [:]
        fileprivate var notice: UInt = 0
        fileprivate var spacer: UInt = 0
    }

    private static func kindTag(_ segment: StatusFacts.Segment) -> String {
        switch segment.kind {
        case .plain: return "plain"
        case .act: return "act"
        case .menu: return "menu"
        }
    }

    static func render(
        into box: UnsafeMutablePointer<GtkWidget>, state: State, facts: StatusFacts,
        notice: String?, perform: @escaping @Sendable (StatusFacts.Action) -> Void
    ) {
        state.facts = facts
        let segments = facts.segments
        let wanted = Set(segments.map(\.id))

        for (id, bits) in state.widgets where !wanted.contains(id) {
            if let raw = UnsafeMutableRawPointer(bitPattern: bits) {
                gtk_box_remove(ptr(box), ptr(raw) as UnsafeMutablePointer<GtkWidget>)
            }
            state.widgets[id] = nil
            state.kinds[id] = nil
        }

        var previous: UnsafeMutablePointer<GtkWidget>?
        for segment in segments {
            let tag = kindTag(segment)
            if let bits = state.widgets[segment.id], state.kinds[segment.id] == tag,
                let raw = UnsafeMutableRawPointer(bitPattern: bits)
            {
                let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
                update(widget, segment: segment)
                previous = widget
                continue
            }
            if let bits = state.widgets[segment.id],
                let raw = UnsafeMutableRawPointer(bitPattern: bits)
            {
                gtk_box_remove(ptr(box), ptr(raw) as UnsafeMutablePointer<GtkWidget>)
            }
            let widget = make(segment, state: state, perform: perform)
            gtk_box_insert_child_after(ptr(box), widget, previous)
            state.widgets[segment.id] = UInt(bitPattern: widget)
            state.kinds[segment.id] = tag
            previous = widget
        }

        if state.spacer == 0 {
            let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            gtk_widget_set_hexpand(spacer, 1)
            gtk_box_append(ptr(box), spacer)
            state.spacer = UInt(bitPattern: spacer)
        }
        if state.notice == 0 {
            let label = Gtk.label("", css: "seg-notice", selectable: false)
            Gtk.addClass(label, "seg")
            gtk_box_append(ptr(box), label)
            state.notice = UInt(bitPattern: label)
        }
        if let raw = UnsafeMutableRawPointer(bitPattern: state.notice) {
            let label: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            gtk_label_set_text(op(label), notice ?? "")
            gtk_widget_set_visible(label, (notice?.isEmpty == false) ? 1 : 0)
        }
    }

    private static func update(
        _ widget: UnsafeMutablePointer<GtkWidget>, segment: StatusFacts.Segment
    ) {
        write(segment.text, to: widget, kind: segment.kind, parts: segment.parts)
        for css in StatusFacts.Segment.allCSS where css != segment.css {
            gtk_widget_remove_css_class(widget, css)
        }
        Gtk.addClass(widget, segment.css)
        animate(widget, segment: segment)
    }

    /// A fact that is about something happening moves the way that thing moves — the turn's own
    /// segment breathes, a compaction sweeps, an approval knocks twice — and a fact that is merely
    /// a number holds still. The band redraws every second regardless; the swell runs on the frame
    /// clock underneath that, so the words tick once a second while the light is continuous.
    private static func animate(
        _ widget: UnsafeMutablePointer<GtkWidget>, segment: StatusFacts.Segment
    ) {
        let kind = segment.kind
        ActivityPulse.apply(segment.icon, to: widget, text: segment.text) { text in
            write(text, to: widget, kind: kind)
        }
    }

    private static func write(
        _ text: String, to widget: UnsafeMutablePointer<GtkWidget>,
        kind: StatusFacts.Segment.Kind, parts: [GitBadgePart]? = nil
    ) {
        switch kind {
        case .plain: gtk_label_set_text(op(widget), text)
        case .act: gtk_button_set_label(ptr(widget), text)
        case .menu: gtk_menu_button_set_label(op(widget), text)
        }
        guard let parts, !parts.isEmpty else { return }
        tint(widget, parts: parts)
    }

    /// A segment that arrives as runs is repainted run by run, each in the colour of what it means.
    /// The plain text is written first and then replaced with markup on the same label, so a widget
    /// that has no label to reach — a menu button's nested box — simply keeps the words.
    private static func tint(
        _ widget: UnsafeMutablePointer<GtkWidget>, parts: [GitBadgePart]
    ) {
        let markup = parts.map {
            "<span foreground='\($0.tone.hex)'>\(PangoMarkdown.escape($0.text))</span>"
        }.joined(separator: " ")
        guard let label = labelInside(widget) else { return }
        gtk_label_set_markup(op(label), markup)
    }

    private static func labelInside(_ widget: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget>?
    {
        if tailscode_is_label(widget) != 0 { return widget }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let found = labelInside(current) { return found }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }

    /// A menu segment's rows are read at open time, so a list opened mid-turn is the list as it
    /// is now.
    private static func make(
        _ segment: StatusFacts.Segment, state: State,
        perform: @escaping @Sendable (StatusFacts.Action) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let widget: UnsafeMutablePointer<GtkWidget>
        switch segment.kind {
        case .plain:
            let label = Gtk.label(segment.text, css: segment.css, selectable: false)
            Gtk.addClass(label, "seg")
            gtk_label_set_max_width_chars(op(label), 48)
            widget = label
        case .act(let action):
            let button = Gtk.button(segment.text, css: ["flat", "seg", segment.css]) {
                perform(action)
            }
            clamp(button)
            widget = button
        case .menu:
            let id = segment.id
            let button = Gtk.menuButton(segment.text, css: ["flat", "seg", segment.css]) {
                let rows = state.facts.segments.first { $0.id == id }?.rows ?? []
                return rows.map { row in
                    (row.title, row.detail, { if let action = row.action { perform(action) } })
                }
            }
            clamp(button)
            widget = button
        }
        animate(widget, segment: segment)
        return widget
    }
}
