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
        /// The ring beside a segment that carries a meter, so an update fills it in place.
        fileprivate var rings: [String: UInt] = [:]
        fileprivate var notice: UInt = 0
        fileprivate var spacer: UInt = 0
        fileprivate var slots = StatusBandSlots()
        fileprivate var written: [String: Written] = [:]
        fileprivate var dirty: Set<String> = []
        fileprivate var requested: [String: Int32] = [:]
        fileprivate var glyphs: GlyphSlot?

        /// Where each fact sits and how wide it is inside `box`, in pixels, for the selftest that
        /// holds the band still.
        func placements(in box: UnsafeMutablePointer<GtkWidget>) -> [String: (x: Double, width: Double)] {
            var found: [String: (x: Double, width: Double)] = [:]
            for (id, bits) in widgets {
                guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { continue }
                var bounds = graphene_rect_t()
                let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
                guard gtk_widget_compute_bounds(widget, box, &bounds) != 0 else { continue }
                found[id] = (Double(bounds.origin.x), Double(bounds.size.width))
            }
            return found
        }

        /// The facts belong to one conversation's band: showing another starts the widths over, so a
        /// long tool name from one chat does not leave room in the next.
        func resetSlots() {
            slots.reset()
            glyphs = nil
            dirty = Set(widgets.keys)
        }
    }

    /// What a segment last put on its widget. A render that would say the same again is skipped:
    /// every write asks GTK to measure the label, and every fact but the clock is the same words
    /// as a second ago.
    fileprivate struct Written: Equatable {
        let text: String
        let css: String
        let parts: [GitBadgePart]?
        let meter: Double?
        let spoken: String
        let icon: ActivityIcon?
    }

    /// The room the leading mark keeps, in Pango units: as wide as the widest glyph of the vocabulary
    /// in the band's own face. A glyph from a fallback font has its own advance, so each mark is padded
    /// up to the slot with letter spacing and a sweep repaints without moving what follows it.
    fileprivate final class GlyphSlot {
        let width: Int32
        private var advances: [String: Int32] = [:]

        init(measuredOn widget: UnsafeMutablePointer<GtkWidget>) {
            var widest: Int32 = 0
            for glyph in StatusBandSlots.leadingGlyphs {
                let advance = Self.advance(of: glyph, on: widget)
                advances[glyph] = advance
                widest = max(widest, advance)
            }
            width = widest
        }

        func padding(for glyph: String, on widget: UnsafeMutablePointer<GtkWidget>) -> Int32 {
            max(0, width - (advances[glyph] ?? Self.advance(of: glyph, on: widget)))
        }

        private static func advance(of glyph: String, on widget: UnsafeMutablePointer<GtkWidget>)
            -> Int32
        {
            guard let layout = gtk_widget_create_pango_layout(widget, glyph) else { return 0 }
            defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
            var measured: Int32 = 0
            pango_layout_get_size(layout, &measured, nil)
            return measured
        }
    }

    private static func wearsGlyphSlot(_ segment: StatusFacts.Segment) -> Bool {
        segment.icon != nil || segment.id == "agents"
    }

    private static func kindTag(_ segment: StatusFacts.Segment) -> String {
        let meter = segment.meter == nil && segment.id != "context" ? "" : "+meter"
        switch segment.kind {
        case .plain: return "plain" + meter
        case .act: return "act" + meter
        case .menu: return "menu" + meter
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
            state.rings[id] = nil
            state.written[id] = nil
            state.requested[id] = nil
            state.dirty.remove(id)
        }

        var previous: UnsafeMutablePointer<GtkWidget>?
        for segment in segments {
            let tag = kindTag(segment)
            if let bits = state.widgets[segment.id], state.kinds[segment.id] == tag,
                let raw = UnsafeMutableRawPointer(bitPattern: bits)
            {
                let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
                previous = widget
                let now = Written(
                    text: segment.text, css: segment.css, parts: segment.parts,
                    meter: segment.meter, spoken: spoken(segment, facts: facts), icon: segment.icon)
                guard state.written[segment.id] != now else { continue }
                state.written[segment.id] = now
                update(widget, segment: segment, state: state)
                fill(state.rings[segment.id], segment: segment)
                tailscode_set_accessible_label(widget, now.spoken)
                state.dirty.insert(segment.id)
                continue
            }
            if let bits = state.widgets[segment.id],
                let raw = UnsafeMutableRawPointer(bitPattern: bits)
            {
                gtk_box_remove(ptr(box), ptr(raw) as UnsafeMutablePointer<GtkWidget>)
            }
            state.requested[segment.id] = nil
            let widget = make(segment, state: state, perform: perform)
            let spokenWords = spoken(segment, facts: facts)
            tailscode_set_accessible_label(widget, spokenWords)
            gtk_box_insert_child_after(ptr(box), widget, previous)
            state.widgets[segment.id] = UInt(bitPattern: widget)
            state.kinds[segment.id] = tag
            state.written[segment.id] = Written(
                text: segment.text, css: segment.css, parts: segment.parts, meter: segment.meter,
                spoken: spokenWords, icon: segment.icon)
            state.dirty.insert(segment.id)
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
            gtk_widget_set_tooltip_text(label, notice)
        }
    }

    /// What a screen reader says for a segment: the state in words where Core has them, and the
    /// agents counted out loud rather than read as the glyph and digits the band draws.
    private static func spoken(_ segment: StatusFacts.Segment, facts: StatusFacts) -> String {
        switch segment.id {
        case "phase":
            return facts.activity?.spoken ?? segment.text
        case "queued":
            return ActivityKind.queued(facts.queued).spoken
        case "agents":
            let working = facts.activeAgents
            let finished = facts.finishedAgents
            guard working > 0 else { return Localized.text("%@ agents finished", "\(finished)") }
            let line = Localized.text("%@ agents working", "\(working)")
            return finished > 0 ? line + ", " + Localized.text("%@ finished", "\(finished)") : line
        default:
            return segment.text
        }
    }

    /// The segments in the order they are given up as the band narrows: the note first, then the
    /// quietest facts, and last the state of the turn itself. A segment that does not fit is hidden
    /// whole rather than shrunk to an ellipsis, so whatever remains reads in full.
    private static let keepOrder = [
        "phase", "queued", "agents", "context", "wall", "cost", "goal", "branch", "cache", "attach",
    ]

    static func fit(_ box: UnsafeMutablePointer<GtkWidget>, state: State, width: Int32) {
        guard width > 0 else { return }
        var shown: [UnsafeMutablePointer<GtkWidget>] = []
        for id in keepOrder {
            guard let bits = state.widgets[id], let raw = UnsafeMutableRawPointer(bitPattern: bits)
            else { continue }
            let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            gtk_widget_set_visible(widget, 1)
            shown.append(widget)
        }
        hold(state, band: width)
        var noticeWidget: UnsafeMutablePointer<GtkWidget>?
        if let raw = UnsafeMutableRawPointer(bitPattern: state.notice) {
            let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            if let text = gtk_label_get_text(op(widget)), text.pointee != 0 {
                noticeWidget = widget
                gtk_widget_set_visible(widget, 1)
            }
        }
        func natural() -> Int32 {
            var natural: Int32 = 0
            gtk_widget_measure(box, GTK_ORIENTATION_HORIZONTAL, -1, nil, &natural, nil, nil)
            return natural
        }
        if let noticeWidget, natural() > width { gtk_widget_set_visible(noticeWidget, 0) }
        while shown.count > 1, natural() > width, let last = shown.popLast() {
            gtk_widget_set_visible(last, 0)
        }
    }

    /// Gives each fact the room of the widest it has been. A fact whose words changed is measured
    /// bare, with no request on it, so the width is what the words ask for; every fact is then asked
    /// for its held width against the band as it is now, which is why a resize runs through here
    /// too. The request is a minimum, so the band still hides a fact that does not fit.
    private static func hold(_ state: State, band: Int32) {
        for (id, bits) in state.widgets {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { continue }
            let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            if state.dirty.contains(id) {
                gtk_widget_set_size_request(widget, -1, -1)
                var natural: Int32 = 0
                gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, nil, &natural, nil, nil)
                state.slots.widen(id, to: Double(natural), in: Double(band))
                state.requested[id] = -1
            }
            let held = Int32(state.slots.width(of: id, in: Double(band)).rounded(.up))
            guard state.requested[id] != held else { continue }
            state.requested[id] = held
            gtk_widget_set_size_request(widget, held, -1)
        }
        state.dirty.removeAll()
    }

    private static func update(
        _ widget: UnsafeMutablePointer<GtkWidget>, segment: StatusFacts.Segment, state: State
    ) {
        write(segment.text, to: widget, segment: segment, state: state)
        for css in StatusFacts.Segment.allCSS where css != segment.css {
            gtk_widget_remove_css_class(widget, css)
        }
        Gtk.addClass(widget, segment.css)
        animate(widget, segment: segment, state: state)
    }

    /// A fact that is about something happening moves the way that thing moves — the turn's own
    /// segment breathes, a compaction sweeps, an approval knocks twice — and a fact that is merely
    /// a number holds still. The band redraws every second regardless; the swell runs on the frame
    /// clock underneath that, so the words tick once a second while the light is continuous.
    private static func animate(
        _ widget: UnsafeMutablePointer<GtkWidget>, segment: StatusFacts.Segment, state: State
    ) {
        ActivityPulse.apply(segment.icon, to: widget, text: segment.text) { text in
            write(text, to: widget, segment: segment, state: state)
        }
    }

    /// A button built around a ring keeps its own label, which the plain setter would replace with
    /// a fresh one and drop the ring with it — so the words go to the label already inside.
    private static func write(
        _ text: String, to widget: UnsafeMutablePointer<GtkWidget>,
        segment: StatusFacts.Segment, state: State
    ) {
        if wearsGlyphSlot(segment), segment.parts == nil, let label = labelInside(widget) {
            gtk_label_set_markup(op(label), slotted(text, state: state, on: label))
            return
        }
        let parts = segment.parts
        switch segment.kind {
        case .plain: gtk_label_set_text(op(widget), text)
        case .act:
            if tailscode_is_label(widget) == 0, let label = labelInside(widget) {
                gtk_label_set_text(op(label), text)
            } else {
                gtk_button_set_label(ptr(widget), text)
            }
        case .menu: gtk_menu_button_set_label(op(widget), text)
        }
        guard let parts, !parts.isEmpty else { return }
        tint(widget, parts: parts)
    }

    /// The words with their leading mark padded to the slot, as Pango markup, so the word that
    /// follows starts in the same place whichever mark leads. Pango splits letter spacing into a
    /// half on each side of the glyph and takes the left half back at the start of a line, where
    /// this glyph always stands — so the spacing asked for is twice the room wanted.
    static func slotted(
        _ text: String, state: State, on label: UnsafeMutablePointer<GtkWidget>
    ) -> String {
        guard let glyph = text.first.map(String.init) else { return "" }
        let slot = state.glyphs ?? GlyphSlot(measuredOn: label)
        state.glyphs = slot
        let padding = slot.padding(for: glyph, on: label) * 2
        let rest = PangoMarkdown.escape(String(text.dropFirst()))
        guard padding > 0 else { return PangoMarkdown.escape(glyph) + rest }
        return "<span letter_spacing='\(padding)'>\(PangoMarkdown.escape(glyph))</span>" + rest
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

    /// The ring wears the segment's own register: the neutral dim ink while there is room, the
    /// warning and danger inks as the room goes, so the colour of the words and the colour of the
    /// arc always agree.
    private static func fill(_ bits: UInt?, segment: StatusFacts.Segment) {
        guard let bits, let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        guard let fraction = segment.meter else {
            gtk_widget_set_opacity(ptr(raw), 0)
            return
        }
        gtk_widget_set_opacity(ptr(raw), 1)
        let palette = MatrixTheme.palette
        let hex: String
        switch segment.css {
        case "seg-warn": hex = palette.warn
        case "seg-error": hex = palette.danger
        case "seg-live": hex = palette.accent
        default: hex = palette.textDim
        }
        let rgb = PresenceRGB(hex: hex) ?? PresenceRGB(red: 0.5, green: 0.5, blue: 0.5)
        let ink = [rgb.red, rgb.green, rgb.blue]
        ink.withUnsafeBufferPointer {
            tailscode_ring_set(ptr(raw), fraction, $0.baseAddress, 2.0, 0.22)
        }
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
            if segment.meter != nil || segment.id == "context" {
                let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 5)
                let ring = tailscode_ring_new()!
                gtk_widget_set_size_request(ring, 12, 12)
                gtk_widget_set_valign(ring, GTK_ALIGN_CENTER)
                gtk_box_append(ptr(row), ring)
                let label = Gtk.label(segment.text, css: nil, selectable: false)
                gtk_box_append(ptr(row), label)
                gtk_button_set_child(ptr(button), row)
                state.rings[segment.id] = UInt(bitPattern: ring)
                fill(state.rings[segment.id], segment: segment)
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
        if wearsGlyphSlot(segment) { write(segment.text, to: widget, segment: segment, state: state) }
        animate(widget, segment: segment, state: state)
        return widget
    }
}
