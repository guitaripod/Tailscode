import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension MeridianSheet {
    func makeLane(_ lane: MeridianBoard.Lane, index: Int, last: Int) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium + 2)
        gtk_widget_set_size_request(row, -1, 44)

        let info = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.small + 2)
        let tile = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(tile, "clock-lane-tile")
        gtk_widget_set_size_request(tile, 30, 30)
        gtk_widget_set_valign(tile, GTK_ALIGN_CENTER)
        let glyph = tailscode_glyph_new(16)!
        tailscode_set_accessible_hidden(glyph, 1)
        gtk_box_append(ptr(tile), glyph)
        gtk_box_append(ptr(info), tile)

        let names = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(names, 1)
        gtk_widget_set_valign(names, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(names), ClockUI.label(lane.name, "clock-lane-name"))
        gtk_box_append(ptr(names), ClockUI.label(lane.subtitle, "clock-dim"))
        gtk_box_append(ptr(info), names)

        let when = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_valign(when, GTK_ALIGN_CENTER)
        let time = ClockUI.label(lane.time, "clock-lane-time")
        let day = ClockUI.label(lane.dayWord, "clock-dim")
        gtk_label_set_xalign(op(time), 1)
        gtk_label_set_xalign(op(day), 1)
        gtk_box_append(ptr(when), time)
        gtk_box_append(ptr(when), day)
        gtk_box_append(ptr(info), when)

        let controls = makeControls(for: lane, index: index, last: last)
        gtk_size_group_add_widget(controlsColumn, controls.cluster)
        gtk_box_append(ptr(info), controls.cluster)
        if let reveal = controls.reveal {
            laneReveals.append(reveal)
            watchLane(row, reveal: reveal)
        }
        if lane.isRemovable {
            let rowHold = Gtk.WeakWidget(row)
            Gtk.onRightClick(row) { [weak self] x, y in
                Gtk.onMain { [weak self] in
                    guard let row = rowHold.widget else { return }
                    self?.laneMenu(for: lane, row: row, x: x, y: y)
                }
            }
        }
        gtk_box_append(ptr(row), labelCell(info))
        gtk_box_append(ptr(row), makeBar(lane))
        laneRefs.append(LaneRefs(id: lane.id, time: time, day: day, glyph: glyph))
        return row
    }

    func watchLane(_ row: UnsafeMutablePointer<GtkWidget>, reveal: LaneReveal) {
        Gtk.onPointer(
            row,
            move: { _, _ in
                Gtk.onMain {
                    reveal.hover = true
                    reveal.apply()
                }
            },
            leave: {
                Gtk.onMain {
                    reveal.hover = false
                    reveal.apply()
                }
            })
        let focus = gtk_event_controller_focus_new()!
        gtk_widget_add_controller(row, focus)
        let address = Int(bitPattern: UnsafeMutableRawPointer(focus))
        Gtk.onNotify(UnsafeMutableRawPointer(focus), property: "contains-focus") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
            let inside = gtk_event_controller_focus_contains_focus(op(raw)) != 0
            Gtk.onMain {
                reveal.focus = inside
                reveal.apply()
            }
        }
    }

    func makeControls(
        for lane: MeridianBoard.Lane, index: Int, last: Int
    ) -> (cluster: UnsafeMutablePointer<GtkWidget>, reveal: LaneReveal?) {
        let cluster = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
        gtk_widget_set_valign(cluster, GTK_ALIGN_CENTER)
        guard lane.isRemovable else {
            gtk_widget_set_opacity(cluster, 0)
            gtk_widget_set_can_target(cluster, 0)
            return (cluster, nil)
        }
        let id = lane.id
        controlStates.append((id, index > 1, index < last))
        func button(
            _ glyph: String, _ label: String, enabled: Bool, _ act: @escaping @Sendable () -> Void
        ) -> UnsafeMutablePointer<GtkWidget> {
            let item = Gtk.button(glyph, css: ["flat", "clock-lane-control"]) { Gtk.onMain(act) }
            tailscode_set_accessible_label(item, label)
            gtk_widget_set_tooltip_text(item, label)
            gtk_widget_set_sensitive(item, enabled ? 1 : 0)
            return item
        }
        gtk_box_append(
            ptr(cluster),
            button("\u{2191}", Localized.text("Move up"), enabled: index > 1) {
                ClockWatch.shared.updatePreferences { $0.move(id, by: -1) }
            })
        gtk_box_append(
            ptr(cluster),
            button("\u{2193}", Localized.text("Move down"), enabled: index < last) {
                ClockWatch.shared.updatePreferences { $0.move(id, by: 1) }
            })
        gtk_box_append(
            ptr(cluster),
            button("\u{00D7}", String(format: Localized.text("Remove %@"), lane.name), enabled: true) {
                ClockWatch.shared.updatePreferences { $0.unpin(id) }
            })
        let reveal = LaneReveal(cluster: cluster)
        reveal.apply()
        return (cluster, reveal)
    }

    func makeBar(_ lane: MeridianBoard.Lane) -> UnsafeMutablePointer<GtkWidget> {
        let strip = tailscode_strip_new(40, 0, 13)!
        gtk_widget_set_valign(strip, GTK_ALIGN_FILL)
        gtk_widget_set_vexpand(strip, 1)
        let hours = max(1, Int((Double(board.minutes) / 60).rounded()))
        MeridianInk.paint(strip: strip, bar: lane.bar, hairline: 0.06, grid: hours, noon: true)
        Gtk.addClass(strip, "clock-strip")
        tailscode_set_accessible_label(strip, lane.name)
        gtk_widget_set_size_request(strip, trackFloor, -1)
        guard !lane.marks.isEmpty else { return strip }
        let kinds = lane.marks.map { $0.kind == .reset ? Int32(0) : Int32(1) }
        let positions = lane.marks.map(\.position)
        withCStrings(lane.marks.map(\.label)) { labels in
            kinds.withUnsafeBufferPointer { kindPointer in
                positions.withUnsafeBufferPointer { positionPointer in
                    tailscode_strip_set_marks(
                        strip, Int32(lane.marks.count), kindPointer.baseAddress,
                        positionPointer.baseAddress, labels)
                }
            }
        }
        let marks = lane.marks
        let callback = Unmanaged.passRetained(
            MeridianCallback { [weak self] _, value in
                Gtk.onMain { [weak self] in self?.markPressed(marks, index: Int(value)) }
            })
        markCallbacks.append(callback)
        tailscode_strip_set_handler(
            strip,
            { raw, kind, value in
                guard let raw else { return }
                Unmanaged<MeridianCallback>.fromOpaque(raw).takeUnretainedValue().work(kind, value)
            }, callback.toOpaque())
        return strip
    }

    func markPressed(_ marks: [MeridianBoard.Mark], index: Int) {
        guard marks.indices.contains(index), marks[index].kind == .reset else { return }
        let mark = marks[index]
        let reset = ClockResets.upcoming(
            holdings: ClockWatch.shared.currentHoldings, now: ClockWatch.shared.now, limit: 4
        ).first { $0.instant == mark.instant }
        let note = reset.map { String(format: Localized.text("%@ window reopens"), $0.provider) }
        addAlarm(at: mark.instant, note: note)
    }

    func laneMenu(
        for lane: MeridianBoard.Lane, row: UnsafeMutablePointer<GtkWidget>, x: Double, y: Double
    ) {
        var anchorX = 0.0
        var anchorY = 0.0
        guard gtk_widget_translate_coordinates(row, lanesBox, x, y, &anchorX, &anchorY) != 0 else { return }
        let id = lane.id
        Gtk.contextMenu(
            on: lanesBox, x: anchorX, y: anchorY,
            rows: [
                (Localized.text("Remove"), nil, { ClockWatch.shared.updatePreferences { $0.unpin(id) } }),
                (Localized.text("Move up"), nil, { ClockWatch.shared.updatePreferences { $0.move(id, by: -1) } }),
                (Localized.text("Move down"), nil, { ClockWatch.shared.updatePreferences { $0.move(id, by: 1) } }),
            ])
    }

    func renderInsight() {
        Gtk.removeChildren(of: insightBox)
        guard let insight = board.insight else {
            gtk_widget_set_visible(insightBox, 0)
            return
        }
        gtk_widget_set_visible(insightBox, 1)
        let glyph = ClockUI.glyph(TAILSCODE_GLYPH_INFO, size: 15, body: MatrixTheme.palette.info)
        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        gtk_widget_set_margin_top(glyph, 2)
        gtk_box_append(ptr(insightBox), glyph)
        let label = ClockUI.label(insight, "clock-insight-text", wrap: true, chars: Self.longLine)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(insightBox), label)
    }

    func renderMachines() {
        Gtk.removeChildren(of: machinesBody)
        guard !board.machines.isEmpty else {
            gtk_widget_set_visible(machinesRow, 0)
            return
        }
        gtk_widget_set_visible(machinesRow, 1)
        var items: [UnsafeMutablePointer<GtkWidget>] = []
        for machine in board.machines {
            let item = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.small - 2)
            Gtk.addClass(item, "clock-machine")
            gtk_box_append(ptr(item), ClockUI.dot(machine.tone))
            gtk_box_append(ptr(item), ClockUI.label(machine.name, "clock-name"))
            gtk_box_append(ptr(item), ClockUI.label(machine.status, "clock-status \(ClockUI.tone(machine.tone))"))
            if let time = machine.time {
                gtk_box_append(ptr(item), ClockUI.label(time, "clock-stamp clock-dim"))
            }
            items.append(item)
        }
        gtk_box_append(ptr(machinesBody), Gtk.wrapRow(items, spacing: Space.medium))
        if let warning = board.skewWarning {
            gtk_box_append(
                ptr(machinesBody), ClockUI.label(warning, "clock-status clock-warn", wrap: true, chars: Self.longLine))
        }
    }

    func renderAlarms() {
        Gtk.removeChildren(of: alarmsBody)
        guard !board.alarms.isEmpty else {
            gtk_widget_set_visible(alarmsRow, 0)
            return
        }
        gtk_widget_set_visible(alarmsRow, 1)
        var pills: [UnsafeMutablePointer<GtkWidget>] = []
        for alarm in board.alarms {
            let pill = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.small - 2)
            Gtk.addClass(pill, "clock-alarm")
            gtk_box_append(ptr(pill), ClockUI.label(alarm.title, "clock-stamp"))
            gtk_box_append(ptr(pill), ClockUI.label(alarm.detail, "clock-dim"))
            let id = alarm.id
            let remove = Gtk.button("\u{00D7}", css: ["flat", "clock-remove"]) {
                ClockAlarmStore.update { $0.remove(id) }
            }
            tailscode_set_accessible_label(remove, String(format: Localized.text("Remove %@"), alarm.title))
            gtk_box_append(ptr(pill), remove)
            pills.append(pill)
        }
        gtk_box_append(ptr(alarmsBody), Gtk.wrapRow(pills, spacing: Space.small))
    }

    func renderFormats() {
        let now = ClockWatch.shared.now
        let zone = TimeZone.current
        let current = ClockWatch.shared.preferences.style
        for segment in segments {
            let text =
                segment.style == .system
                ? ClockStyle.systemDescription() : segment.style.example(at: now, in: zone)
            gtk_label_set_text(op(segment.example), text)
            if segment.style == current {
                gtk_widget_add_css_class(segment.button, "clock-seg-on")
                tailscode_set_accessible_pressed(segment.button, 1)
            } else {
                gtk_widget_remove_css_class(segment.button, "clock-seg-on")
                tailscode_set_accessible_pressed(segment.button, 0)
            }
        }
    }

    func toggleAddPlace() {
        if !addOpen { setAddOpen(true) } else { setAddOpen(false) }
    }

    func setAddOpen(_ open: Bool) {
        addOpen = open
        if !open, ClockWatch.shared.preferences.pins.isEmpty { emptyDismissed = true }
        if !open { gtk_editable_set_text(op(searchEntry), "") }
        renderPlaces()
        if open {
            gtk_widget_grab_focus(searchEntry)
            revealPlaces()
        } else {
            gtk_widget_grab_focus(ghostHeader)
        }
    }

    func revealPlaces() {
        let scrollerHold = bodyScroller.map { Gtk.WeakWidget($0) }
        let ghostHold = Gtk.WeakWidget(ghost)
        let bodyHold = Gtk.WeakWidget(body)
        Gtk.betweenFrames(of: window) {
            guard let scroller = scrollerHold?.widget, let ghost = ghostHold.widget, let body = bodyHold.widget,
                let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
            else { return }
            var bounds = graphene_rect_t()
            guard gtk_widget_compute_bounds(ghost, body, &bounds) != 0 else { return }
            let bottom = Double(bounds.origin.y + bounds.size.height) + 16
            let page = gtk_adjustment_get_page_size(adjustment)
            let target = min(gtk_adjustment_get_upper(adjustment) - page, max(gtk_adjustment_get_value(adjustment), bottom - page))
            gtk_adjustment_set_value(adjustment, target)
        }
    }

    func escape() {
        guard addOpen else {
            MeridianSheet.close()
            return
        }
        if !Dialogs.entryText(searchEntry).isEmpty {
            gtk_editable_set_text(op(searchEntry), "")
        } else {
            setAddOpen(false)
        }
    }

    func moveHighlight(_ step: Int) {
        guard !shownResults.isEmpty else { return }
        highlighted = (highlighted + step + shownResults.count) % shownResults.count
        renderPlaces()
    }

    func pinHighlighted() {
        guard shownResults.indices.contains(highlighted) else { return }
        pin(shownResults[highlighted].id)
    }

    func pin(_ id: String) {
        gtk_editable_set_text(op(searchEntry), "")
        addOpen = false
        ClockWatch.shared.updatePreferences { $0.pin(id) }
        renderPlaces()
        gtk_widget_grab_focus(scrubber)
    }
}
