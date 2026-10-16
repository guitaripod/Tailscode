import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What the chip shows when the pointer rests on it: the date, the places the person watches with
/// the sun drawn along each of their days, the machines and how far each clock is from this one,
/// and the quota window about to reopen. Every word is `WorldClockReading`'s; this only arranges
/// them. It is redrawn in place on the minute, so the pointer never loses the surface it is on.
final class ClockGlanceView: @unchecked Sendable {
    static let width: Int32 = 380

    let widget: UnsafeMutablePointer<GtkWidget>
    private let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)

    init() {
        widget = Gtk.groupBox(GTK_ORIENTATION_VERTICAL, spacing: 0, spoken: Localized.text("World clock"))
        gtk_widget_set_size_request(widget, Self.width, -1)
        Gtk.margins(column, top: 14, bottom: 10, leading: 16, trailing: 16)
        gtk_box_append(ptr(widget), column)
    }

    var text: String { Gtk.spokenText(of: widget) }

    func render(_ reading: WorldClockReading) {
        Gtk.removeChildren(of: column)
        let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let date = ClockUI.label(reading.dateLine, "clock-date")
        gtk_widget_set_hexpand(date, 1)
        gtk_box_append(ptr(head), date)
        gtk_box_append(ptr(head), ClockUI.label(reading.weekLine, "clock-dim"))
        gtk_box_append(ptr(column), head)
        gtk_box_append(ptr(column), ClockUI.label(reading.zoneLine, "clock-dim"))

        gtk_box_append(ptr(column), section(Localized.text("AROUND THE WORLD"), top: 14))
        for zone in reading.zones { gtk_box_append(ptr(column), row(for: zone)) }
        if !reading.suggestions.isEmpty { gtk_box_append(ptr(column), suggestions(reading.suggestions)) }

        if !reading.machines.isEmpty {
            gtk_box_append(ptr(column), rule(top: 12))
            gtk_box_append(ptr(column), section(Localized.text("MACHINES"), top: 12))
            for machine in reading.machines { gtk_box_append(ptr(column), row(for: machine)) }
            if let warning = reading.skewWarning {
                let card = ClockUI.label(warning, "clock-card-warn", wrap: true)
                gtk_widget_set_margin_top(card, 4)
                gtk_box_append(ptr(column), card)
            }
        }

        if !reading.resets.isEmpty {
            gtk_box_append(ptr(column), rule(top: 12))
            for reset in reading.resets { gtk_box_append(ptr(column), row(for: reset)) }
        }

        gtk_box_append(ptr(column), rule(top: 12))
        let hint = ClockUI.label(reading.hint, "clock-dim")
        gtk_widget_set_margin_top(hint, 10)
        gtk_box_append(ptr(column), hint)
    }

    private func section(_ title: String, top: Int32) -> UnsafeMutablePointer<GtkWidget> {
        let label = ClockUI.label(title, "clock-section")
        gtk_widget_set_margin_top(label, top)
        gtk_widget_set_margin_bottom(label, 4)
        return label
    }

    private func rule(top: Int32) -> UnsafeMutablePointer<GtkWidget> {
        let rule = ClockUI.rule()
        gtk_widget_set_margin_top(rule, top)
        return rule
    }

    private func row(for zone: WorldClockReading.Zone) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_widget_set_size_request(row, -1, 38)
        let names = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(names, 112, -1)
        gtk_widget_set_valign(names, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(names), ClockUI.label(zone.name, "clock-name"))
        gtk_box_append(ptr(names), ClockUI.label(zone.detail, "clock-dim"))
        gtk_box_append(ptr(row), names)

        let strip = tailscode_strip_new(14, 8, 4)!
        gtk_widget_set_valign(strip, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(strip, 1)
        MeridianInk.paint(strip: strip, bar: zone.bar)
        let palette = MatrixTheme.palette
        let dot = MeridianInk.rgb(zone.isUp == true ? palette.warn : MeridianInk.pale)
        dot.withUnsafeBufferPointer { tailscode_strip_set_dot(strip, zone.marker, 7, $0.baseAddress) }
        tailscode_set_accessible_hidden(strip, 1)
        gtk_box_append(ptr(row), strip)

        let time = ClockUI.label(zone.time, "clock-time")
        gtk_widget_set_size_request(time, 56, -1)
        gtk_label_set_xalign(op(time), 1)
        gtk_box_append(ptr(row), time)
        return row
    }

    private func row(for machine: MachineClockReading) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_widget_set_size_request(row, -1, 30)
        gtk_box_append(ptr(row), ClockUI.dot(machine.tone))
        let name = ClockUI.label(machine.name, "clock-name")
        gtk_widget_set_hexpand(name, 1)
        gtk_box_append(ptr(row), name)
        gtk_box_append(ptr(row), ClockUI.label(machine.status, "clock-status \(ClockUI.tone(machine.tone))"))
        let time = ClockUI.label(machine.time ?? "\u{2014}", "clock-stamp")
        gtk_widget_set_size_request(time, 62, -1)
        gtk_label_set_xalign(op(time), 1)
        gtk_box_append(ptr(row), time)
        return row
    }

    private func row(for reset: ClockReset) -> UnsafeMutablePointer<GtkWidget> {
        let style = ClockWatch.shared.preferences.style
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_widget_set_margin_top(row, 2)
        let tile = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(tile, "clock-tile")
        gtk_widget_set_size_request(tile, 28, 28)
        gtk_widget_set_valign(tile, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(tile), ClockUI.glyph(TAILSCODE_GLYPH_CLOCK, size: 15, body: MatrixTheme.palette.info))
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(words, 1)
        gtk_widget_set_valign(words, GTK_ALIGN_CENTER)
        let title = ClockUI.label(reset.title(viewer: .current, style: style), "clock-name", wrap: true)
        gtk_box_append(ptr(words), title)
        gtk_box_append(
            ptr(words),
            ClockUI.label(reset.note, "clock-dim"))
        let countdown = ClockUI.label(reset.countdown(now: ClockWatch.shared.now), "clock-countdown")
        gtk_widget_set_valign(countdown, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(row), tile)
        gtk_box_append(ptr(row), words)
        gtk_box_append(ptr(row), countdown)
        return row
    }

    private func suggestions(_ cities: [WorldCity]) -> UnsafeMutablePointer<GtkWidget> {
        let line = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        gtk_widget_set_margin_top(line, 6)
        gtk_box_append(ptr(line), ClockUI.label(Localized.text("Add a city"), "clock-dim"))
        var chips: [UnsafeMutablePointer<GtkWidget>] = []
        for city in cities {
            let id = city.id
            let chip = Gtk.button(city.name, css: ["clock-suggest"]) {
                ClockWatch.shared.updatePreferences { $0.pin(id) }
            }
            chips.append(chip)
        }
        gtk_box_append(ptr(line), Gtk.wrapRow(chips, spacing: 6))
        return line
    }
}
