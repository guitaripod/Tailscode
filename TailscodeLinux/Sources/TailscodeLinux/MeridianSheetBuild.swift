import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension MeridianSheet {
    func fitWindow(near parent: UnsafeMutablePointer<GtkWidget>?) {
        let limit = FeatureWindow.size(near: parent, minimumWidth: Self.floorWidth, minimumHeight: Self.floorHeight)
        guard let content = gtk_window_get_child(ptr(window)) else { return }
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(content, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, nil, nil)
        let width = min(limit.width, max(Self.floorWidth, natural))
        var minimumHeight: Int32 = 0
        var naturalHeight: Int32 = 0
        gtk_widget_measure(content, GTK_ORIENTATION_VERTICAL, width, &minimumHeight, &naturalHeight, nil, nil)
        let height = min(limit.height, max(Self.floorHeight, naturalHeight))
        gtk_window_set_default_size(ptr(window), width, height)
    }

    func makeContent() -> UnsafeMutablePointer<GtkWidget> {
        let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.margins(
            body, top: 0, bottom: Space.medium, leading: Space.margin, trailing: Space.margin)
        let header = makeHeader()
        Gtk.margins(
            header, top: Space.large, bottom: Space.small, leading: Space.margin, trailing: Space.margin)
        gtk_box_append(ptr(root), header)
        gtk_box_append(ptr(body), makeLanes())
        gtk_box_append(ptr(body), makeScrubberRow())
        gtk_box_append(ptr(body), makeAddPlace())
        gtk_widget_set_margin_top(insightBox, Space.medium)
        Gtk.addClass(insightBox, "clock-insight")
        gtk_box_append(ptr(body), insightBox)
        sectionRow(machinesRow, title: Localized.text("MACHINES"), body: machinesBody)
        gtk_widget_set_margin_top(machinesRow, Space.medium)
        gtk_box_append(ptr(body), machinesRow)
        sectionRow(alarmsRow, title: Localized.text("ALARMS"), body: alarmsBody)
        gtk_widget_set_margin_top(alarmsRow, Space.medium)
        gtk_box_append(ptr(body), alarmsRow)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_propagate_natural_width(op(scroller), 1)
        gtk_scrolled_window_set_min_content_height(op(scroller), 240)
        bodyScroller = scroller
        gtk_scrolled_window_set_child(op(scroller), body)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_box_append(ptr(root), scroller)
        gtk_box_append(ptr(root), makeFooter())
        return root
    }

    func labelCell(_ widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget> {
        gtk_size_group_add_widget(labelColumn, widget)
        gtk_widget_set_hexpand(widget, 0)
        return widget
    }

    func sectionRow(
        _ row: UnsafeMutablePointer<GtkWidget>, title: String, body content: UnsafeMutablePointer<GtkWidget>
    ) {
        let label = ClockUI.label(title, "clock-section")
        gtk_widget_set_valign(label, GTK_ALIGN_START)
        gtk_widget_set_margin_top(label, 3)
        gtk_box_append(ptr(row), labelCell(label))
        gtk_widget_set_hexpand(content, 1)
        gtk_box_append(ptr(row), content)
    }

    func makeHeader() -> UnsafeMutablePointer<GtkWidget> {
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.large)
        let left = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.small)
        gtk_widget_set_hexpand(left, 1)
        gtk_widget_set_valign(left, GTK_ALIGN_START)
        let title = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.small + 4)
        gtk_box_append(ptr(title), ClockUI.glyph(TAILSCODE_GLYPH_GLOBE, size: 26, body: MatrixTheme.palette.accent))
        gtk_box_append(ptr(title), ClockUI.label(Localized.text("Meridian"), "clock-title"))
        gtk_box_append(ptr(left), title)
        gtk_label_set_wrap(op(dateLine), 1)
        gtk_box_append(ptr(left), dateLine)
        gtk_box_append(ptr(header), left)

        let right = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.hair)
        gtk_widget_set_halign(right, GTK_ALIGN_END)
        gtk_label_set_xalign(op(headTime), 1)
        gtk_label_set_xalign(op(delta), 1)
        gtk_widget_set_halign(headTime, GTK_ALIGN_END)
        gtk_widget_set_halign(delta, GTK_ALIGN_END)
        gtk_box_append(ptr(right), headTime)
        gtk_box_append(ptr(right), delta)
        gtk_box_append(ptr(header), right)

        let now = Gtk.button(Localized.text("Now"), css: ["clock-now"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.followClock() }
        }
        gtk_widget_set_valign(now, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(header), now)
        return header
    }

    func makeLanes() -> UnsafeMutablePointer<GtkWidget> {
        let section = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.small)
        gtk_widget_set_margin_top(section, Space.small)
        let tickRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium + 2)
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_box_append(ptr(tickRow), labelCell(spacer))
        gtk_widget_set_hexpand(ticks, 1)
        gtk_box_append(ptr(tickRow), ticks)
        gtk_box_append(ptr(section), tickRow)

        MeridianInk.apply(to: lines)
        MeridianInk.apply(to: ticks)
        MeridianInk.apply(to: scrubber)
        Gtk.addClass(ticks, "clock-ticks")
        Gtk.addClass(lines, "clock-lines")
        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(op(overlay), lanesBox)
        let lineHost = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium + 2)
        let lineSpacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_size_group_add_widget(labelColumn, lineSpacer)
        gtk_box_append(ptr(lineHost), lineSpacer)
        gtk_widget_set_hexpand(lines, 1)
        gtk_box_append(ptr(lineHost), lines)
        gtk_widget_set_can_target(lineHost, 0)
        gtk_overlay_add_overlay(op(overlay), lineHost)
        gtk_box_append(ptr(section), overlay)
        return section
    }

    func makeScrubberRow() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium + 2)
        gtk_widget_set_margin_top(row, Space.small + 2)
        let hint = ClockUI.label(Localized.text("Drag to read every desk at that moment"), "clock-dim", wrap: true, chars: 26)
        gtk_widget_set_valign(hint, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(row), labelCell(hint))
        Gtk.addClass(scrubber, "clock-scrubber")
        gtk_widget_set_valign(scrubber, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(scrubber, 1)
        tailscode_set_accessible_label(scrubber, Localized.text("Scrub time"))
        gtk_box_append(ptr(row), scrubber)
        return row
    }

    func makeAddPlace() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.addClass(ghost, "clock-ghost")
        gtk_widget_set_margin_top(ghost, Space.medium)

        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.small + 2)
        let tile = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(tile, "clock-lane-tile")
        gtk_widget_set_size_request(tile, 30, 30)
        gtk_widget_set_valign(tile, GTK_ALIGN_CENTER)
        let plus = ClockUI.label("+", "clock-plus")
        gtk_widget_set_halign(plus, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(plus, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(tile), plus)
        gtk_widget_set_hexpand(tile, 0)
        gtk_widget_set_halign(tile, GTK_ALIGN_START)
        tailscode_set_accessible_hidden(tile, 1)
        gtk_box_append(ptr(header), tile)
        gtk_widget_set_hexpand(ghostInvitation, 1)
        gtk_widget_set_valign(ghostInvitation, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(header), ghostInvitation)
        gtk_widget_set_valign(ghostSummary, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(header), ghostSummary)
        Gtk.addClass(ghostHeader, "flat")
        Gtk.addClass(ghostHeader, "clock-ghost-header")
        gtk_button_set_child(ptr(ghostHeader), header)
        gtk_widget_set_hexpand(ghostHeader, 1)
        Gtk.connect(UnsafeMutableRawPointer(ghostHeader), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.toggleAddPlace() }
        }
        gtk_box_append(ptr(ghost), ghostHeader)

        gtk_widget_set_hexpand(searchEntry, 1)
        Gtk.addClass(searchEntry, "clock-search")
        Gtk.margins(searchEntry, top: 0, bottom: 0, leading: Space.small, trailing: Space.small)
        gtk_box_append(ptr(ghostPanel), searchEntry)
        gtk_widget_set_margin_bottom(results, Space.small)
        Gtk.margins(results, top: 0, bottom: Space.small, leading: Space.small, trailing: Space.small)
        gtk_box_append(ptr(ghostPanel), results)
        gtk_box_append(ptr(ghost), ghostPanel)

        Gtk.onNotify(UnsafeMutableRawPointer(searchEntry), property: "text") { [weak self] in
            Gtk.onMain { [weak self] in
                self?.highlighted = 0
                self?.renderPlaces()
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(searchEntry), "activate") { [weak self] in
            Gtk.onMain { [weak self] in self?.pinHighlighted() }
        }
        Gtk.onKey(searchEntry) { [weak self] keyval, _ in
            guard keyval == 0xFF52 || keyval == 0xFF54 else { return false }
            Gtk.onMain { [weak self] in self?.moveHighlight(keyval == 0xFF54 ? 1 : -1) }
            return true
        }
        return ghost
    }

    func makeFooter() -> UnsafeMutablePointer<GtkWidget> {
        let footer = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_box_append(ptr(footer), Gtk.hairline())
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium)
        Gtk.margins(
            row, top: Space.small + 2, bottom: Space.medium + 2, leading: Space.margin, trailing: Space.margin)

        var items: [UnsafeMutablePointer<GtkWidget>] = []
        for kind in CopyKind.allCases { items.append(makeCopyButton(kind)) }
        items.append(makeSegmented())
        let end = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium)
        gtk_widget_set_valign(end, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(end, GTK_ALIGN_END)
        gtk_widget_set_hexpand(end, 1)
        let esc = ClockUI.label(Localized.text("Esc closes"), "clock-dim")
        gtk_widget_set_valign(esc, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(end), esc)
        gtk_box_append(ptr(end), notify)
        items.append(end)
        let flow = Gtk.wrapRow(items, spacing: Space.small)
        gtk_widget_set_halign(flow, GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(flow, 1)
        gtk_box_append(ptr(row), flow)
        Gtk.connect(UnsafeMutableRawPointer(notify), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.addAlarm(at: nil, note: nil) }
        }
        gtk_box_append(ptr(footer), row)
        return footer
    }

    func makeCopyButton(_ kind: CopyKind) -> UnsafeMutablePointer<GtkWidget> {
        let title = ClockUI.label(Localized.text(kind.title), "clock-copy-title")
        let value = ClockUI.label("", "clock-copy-value")
        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_box_append(ptr(lines), title)
        gtk_box_append(ptr(lines), value)
        let button = gtk_button_new()!
        Gtk.addClass(button, "clock-copy")
        gtk_button_set_child(ptr(button), lines)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.copy(kind) }
        }
        copyButtons.append((title, value, kind))
        return button
    }

    func makeSegmented() -> UnsafeMutablePointer<GtkWidget> {
        let accessible = tailscode_box_new_with_role(GTK_ORIENTATION_HORIZONTAL, 0, GTK_ACCESSIBLE_ROLE_GROUP)!
        tailscode_set_accessible_label(accessible, Localized.text("Time format"))
        Gtk.addClass(accessible, "clock-seg")
        gtk_widget_set_valign(accessible, GTK_ALIGN_CENTER)
        for style in ClockStyle.allCases {
            let title = ClockUI.label(style.title, "clock-seg-title")
            let example = ClockUI.label("", "clock-seg-example")
            let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
            gtk_box_append(ptr(lines), title)
            gtk_box_append(ptr(lines), example)
            let button = gtk_button_new()!
            Gtk.addClass(button, "flat")
            Gtk.addClass(button, "clock-seg-item")
            gtk_button_set_child(ptr(button), lines)
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked") {
                Gtk.onMain { ClockWatch.shared.updatePreferences { $0.style = style } }
            }
            gtk_box_append(ptr(accessible), button)
            segments.append(Segment(style: style, button: button, example: example))
        }
        return accessible
    }

    func installBehaviour() {
        let retained = Unmanaged.passRetained(
            MeridianCallback { [weak self] kind, value in
                Gtk.onMain { [weak self] in self?.scrubbed(kind: kind, fraction: value) }
            })
        scrubberCallback = retained
        tailscode_scrubber_set_handler(
            scrubber,
            { raw, kind, value in
                guard let raw else { return }
                Unmanaged<MeridianCallback>.fromOpaque(raw).takeUnretainedValue().work(kind, value)
            }, retained.toOpaque())
        Gtk.onKey(scrubber) { [weak self] keyval, state in
            guard let self else { return false }
            let step = state & Keymap.shift != 0 ? 15 : 1
            switch keyval {
            case 0xFF51: Gtk.onMain { [weak self] in self?.nudge(-step) }
            case 0xFF53: Gtk.onMain { [weak self] in self?.nudge(step) }
            case 0xFF50: Gtk.onMain { [weak self] in self?.land(on: 0) }
            case 0xFF57: Gtk.onMain { [weak self] in self?.land(on: (self?.board.minutes ?? 1) - 1) }
            default: return false
            }
            return true
        }
        Gtk.onKey(window) { [weak self] keyval, _ in
            guard keyval == Keymap.escape else { return false }
            Gtk.onMain { [weak self] in self?.escape() }
            return true
        }
        RepeatingMotion.watch(scrubber) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !RepeatingMotion.allowed, self.glide.isTurning else { return }
                self.finishGlide()
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [weak self] in
            self?.windowGone()
        }
    }

    func windowGone() {
        glide.lift()
        ClockWatch.shared.stopObserving(token)
        scrubberCallback?.release()
        scrubberCallback = nil
        releaseMarkCallbacks()
        MeridianSheet.current = nil
    }

    func releaseMarkCallbacks() {
        for callback in markCallbacks { callback.release() }
        markCallbacks = []
    }
}
