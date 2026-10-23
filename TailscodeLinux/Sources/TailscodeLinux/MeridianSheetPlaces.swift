import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension MeridianSheet {
    func renderPlaces() {
        let preferences = ClockWatch.shared.preferences
        let status = MeridianPlaces.status(preferences)
        gtk_label_set_text(op(ghostInvitation), status.invitation)
        gtk_label_set_text(op(ghostSummary), status.summary)
        gtk_widget_set_sensitive(ghostHeader, status.isFull ? 0 : 1)
        tailscode_set_accessible_label(ghostHeader, "\(status.invitation), \(status.summary)")
        gtk_entry_set_placeholder_text(ptr(searchEntry), status.placeholder)
        let open = addOpen && !status.isFull
        gtk_widget_set_visible(ghostPanel, open ? 1 : 0)
        if open { Gtk.addClass(ghost, "clock-ghost-open") } else { gtk_widget_remove_css_class(ghost, "clock-ghost-open") }
        Gtk.removeChildren(of: results)
        shownResults = []
        guard open else { return }
        let query = Dialogs.entryText(searchEntry)
        let now = ClockWatch.shared.now
        placesMinute = Int(now.timeIntervalSince1970 / 60)
        if query.isEmpty {
            shownResults = MeridianPlaces.suggestions(preferences: preferences, viewer: .current, now: now)
            if !shownResults.isEmpty {
                let heading = ClockUI.label(Localized.text("Popular"), "clock-section")
                gtk_widget_set_margin_top(heading, Space.hair)
                gtk_box_append(ptr(results), heading)
            }
        } else {
            shownResults = MeridianPlaces.results(
                for: query, preferences: preferences, viewer: .current, now: now)
            if shownResults.isEmpty {
                gtk_box_append(
                    ptr(results), ClockUI.label(MeridianPlaces.emptyResult(for: query), "clock-dim", wrap: true, chars: 60))
            }
        }
        highlighted = min(highlighted, max(0, shownResults.count - 1))
        for (index, place) in shownResults.enumerated() {
            gtk_box_append(ptr(results), makeResult(place, on: index == highlighted))
        }
    }

    func makeResult(_ place: PlaceRow, on: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let item = gtk_button_new()!
        Gtk.addClass(item, "flat")
        Gtk.addClass(item, "clock-result")
        if on { Gtk.addClass(item, "clock-result-on") }
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium)
        let names = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(names, 1)
        gtk_widget_set_valign(names, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(names), ClockUI.label(place.name, "clock-name"))
        gtk_box_append(ptr(names), ClockUI.label(place.detail, "clock-dim"))
        let when = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_valign(when, GTK_ALIGN_CENTER)
        let time = ClockUI.label(place.time, "clock-lane-time")
        let away = ClockUI.label("\(place.offset) \u{00B7} \(place.dayWord)", "clock-dim")
        gtk_label_set_xalign(op(time), 1)
        gtk_label_set_xalign(op(away), 1)
        gtk_box_append(ptr(when), time)
        gtk_box_append(ptr(when), away)
        gtk_box_append(ptr(line), names)
        gtk_box_append(ptr(line), when)
        gtk_button_set_child(ptr(item), line)
        tailscode_set_accessible_label(item, place.spoken)
        let id = place.id
        Gtk.connect(UnsafeMutableRawPointer(item), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.pin(id) }
        }
        return item
    }

    func paintMoment() {
        gtk_label_set_text(op(headTime), board.head)
        gtk_label_set_text(op(dateLine), board.dateLine)
        gtk_label_set_text(op(delta), board.delta)
        let atNow = board.scrubMinute == board.nowMinute
        Gtk.setTone(delta, atNow ? "clock-ok" : "clock-warn", from: ["clock-ok", "clock-warn"])
        for (ref, lane) in zip(laneRefs, board.lanes) {
            gtk_label_set_text(op(ref.time), lane.time)
            gtk_label_set_text(op(ref.day), lane.dayWord)
            switch lane.isUp {
            case true?:
                gtk_widget_set_visible(ref.glyph, 1)
                MeridianInk.glyph(ref.glyph, kind: TAILSCODE_GLYPH_SUN, body: MeridianInk.rgb(MatrixTheme.palette.warn))
            case false?:
                gtk_widget_set_visible(ref.glyph, 1)
                MeridianInk.glyph(ref.glyph, kind: TAILSCODE_GLYPH_MOON, body: MeridianInk.rgb(MeridianInk.pale))
            case nil:
                gtk_widget_set_visible(ref.glyph, 0)
            }
        }
        let golden = board.golden
        tailscode_lines_set(
            lines, golden?.start ?? -1, golden?.end ?? -1, golden?.label, board.nowPosition,
            board.linePosition)
        let thumb = board.minutes > 1 ? Double(board.scrubMinute) / Double(board.minutes - 1) : 0
        tailscode_scrubber_set(scrubber, thumb)
        for entry in copyButtons {
            let text: String
            switch entry.kind {
            case .iso: text = board.copy.iso
            case .utc: text = board.copy.utc
            case .epoch: text = board.copy.epoch
            }
            gtk_label_set_text(op(entry.value), text)
        }
        gtk_button_set_label(ptr(notify), board.notifyLabel)
        gtk_widget_set_sensitive(notify, board.canNotify ? 1 : 0)
        renderFormats()
        if addOpen, placesMinute != Int(ClockWatch.shared.now.timeIntervalSince1970 / 60) { renderPlaces() }
    }

    func copy(_ kind: CopyKind) {
        let text: String
        switch kind {
        case .iso: text = board.copy.iso
        case .utc: text = board.copy.utc
        case .epoch: text = board.copy.epoch
        }
        Gtk.copyToClipboard(text)
        guard let entry = copyButtons.first(where: { $0.kind == kind }) else { return }
        gtk_label_set_text(op(entry.title), Localized.text("Copied"))
        Gtk.addClass(entry.title, "clock-copied")
        let ticket = (copyTickets[kind] ?? 0) + 1
        copyTickets[kind] = ticket
        let titleHold = Gtk.WeakWidget(entry.title)
        Gtk.after(1200) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.copyTickets[kind] == ticket, let raw = titleHold.widget else { return }
                gtk_label_set_text(op(raw), Localized.text(kind.title))
                gtk_widget_remove_css_class(raw, "clock-copied")
            }
        }
    }

    func addAlarm(at instant: Date?, note: String?) {
        let when = instant ?? board.scrubInstant
        let added = ClockAlarmStore.add(
            at: when, zoneID: TimeZone.current.identifier, note: note, now: ClockWatch.shared.now)
        guard added == nil else { return }
        notifyTicket += 1
        let ticket = notifyTicket
        gtk_button_set_label(ptr(notify), Localized.text("Already set"))
        let notifyHold = Gtk.WeakWidget(notify)
        Gtk.after(1200) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.notifyTicket == ticket, let raw = notifyHold.widget else { return }
                gtk_button_set_label(ptr(raw), self.board.notifyLabel)
            }
        }
    }

    func withCStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> T) -> T {
        let duplicated = strings.map { strdup($0) }
        defer { duplicated.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = duplicated.map { $0.map { UnsafePointer($0) } }
        return pointers.withUnsafeMutableBufferPointer { body(UnsafePointer($0.baseAddress!)) }
    }
}
