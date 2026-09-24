import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The Full Disk Access checklist a Mac server earns once — a title, one row per grant with its
/// purpose and state, the button that opens System Settings on that machine, and the numbered
/// steps that replace themselves with `done` the moment the switch is noticed. Shared by the
/// servers window, which embeds it inside a configured server's own expander, and first run,
/// which shows it inline as the checklist's own step — every word comes from
/// `MachinePermissionReading`, and this class only lays it out.
final class MachinePermissionsBox: @unchecked Sendable {
    var onRequest: ((MachinePermissions.Grant.Kind) -> Void)?

    let widget: UnsafeMutablePointer<GtkWidget>

    private let local: Bool
    private let titleLabel = Gtk.label("", css: "row-title", selectable: false)
    private let rowsBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let stepsBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
    private let messageLabel = Gtk.label("", wrap: true, selectable: false)
    private static let messageTones = ["dim", "glyph-running", "glyph-error"]

    init(local: Bool) {
        self.local = local
        let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        widget = root
        gtk_widget_set_hexpand(root, 1)

        gtk_box_append(ptr(root), titleLabel)
        gtk_box_append(ptr(root), rowsBox)
        Gtk.margins(stepsBox, leading: 12)
        gtk_widget_set_visible(stepsBox, 0)
        gtk_box_append(ptr(root), stepsBox)
        gtk_widget_set_visible(messageLabel, 0)
        gtk_box_append(ptr(root), messageLabel)
    }

    /// One answer painted into the checklist it belongs to.
    func apply(_ permissions: MachinePermissions) {
        gtk_label_set_text(op(titleLabel), MachinePermissionReading.sectionTitle(permissions))

        Gtk.removeChildren(of: rowsBox)
        for grant in permissions.known {
            guard let kind = grant.kind else { continue }
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)

            let titles = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
            gtk_widget_set_hexpand(titles, 1)
            gtk_box_append(
                ptr(titles), Gtk.label(MachinePermissionReading.title(kind), selectable: false))
            gtk_box_append(
                ptr(titles),
                Gtk.label(
                    MachinePermissionReading.purpose(kind), css: "dim", wrap: true,
                    selectable: false))
            gtk_box_append(ptr(row), titles)

            let stateLabel = Gtk.label(
                "\(MachinePermissionReading.glyph(grant)) \(MachinePermissionReading.state(grant))",
                selectable: false)
            gtk_widget_set_valign(stateLabel, GTK_ALIGN_CENTER)
            Gtk.addClass(stateLabel, grant.state == .granted ? "glyph-done" : "glyph-pending")
            gtk_box_append(ptr(row), stateLabel)

            if grant.state == .missing {
                let kindCopy = kind
                let button = Gtk.button(
                    MachinePermissionReading.action(permissions, local: local),
                    css: ["suggested-action"]
                ) { [weak self] in
                    self?.onRequest?(kindCopy)
                }
                gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
                gtk_box_append(ptr(row), button)
            }

            if let hint = MachinePermissionReading.accessibility(grant) {
                gtk_widget_set_tooltip_text(row, hint)
            }
            gtk_box_append(ptr(rowsBox), row)
        }

        Gtk.removeChildren(of: stepsBox)
        if MachinePermissionReading.isWaiting(permissions) {
            for (index, step) in MachinePermissionReading.steps(permissions, local: local).enumerated() {
                gtk_box_append(
                    ptr(stepsBox),
                    Gtk.label("\(index + 1). \(step)", css: "dim", wrap: true, selectable: false))
            }
            gtk_widget_set_visible(stepsBox, 1)
        } else {
            gtk_widget_set_visible(stepsBox, 0)
        }

        if MachinePermissionReading.showsDone(permissions) {
            gtk_label_set_text(op(messageLabel), MachinePermissionReading.done(permissions))
            Gtk.setTone(messageLabel, "glyph-running", from: Self.messageTones)
            gtk_widget_set_visible(messageLabel, 1)
        } else {
            gtk_widget_set_visible(messageLabel, 0)
        }
    }

    /// A request the server refused or could not reach — shown until the next successful read
    /// replaces it.
    func showRequestFailed() {
        gtk_label_set_text(op(messageLabel), MachinePermissionReading.requestFailed)
        Gtk.setTone(messageLabel, "glyph-error", from: Self.messageTones)
        gtk_widget_set_visible(messageLabel, 1)
    }
}
