import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The one plate every rail on a transcript opens, and the one pointer watch that decides when. It
/// is not a popover — a menu button's popover takes the press and the keyboard with it — but an
/// ordinary widget in the transcript's overlay, positioned from the rail's bounds, so the rows under
/// it never move and the words under it are still a press on the words. It is fed by the same
/// motion controller that watches the transcript for a message, rather than one per row.
final class LinkRailController: @unchecked Sendable {
    let plate = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private(set) var overlay: UnsafeMutablePointer<GtkWidget>?
    private(set) var openID: Int?
    private(set) var rows: [UnsafeMutablePointer<GtkWidget>] = []
    private(set) var machine: RailHoverMachine!
    private var visibilityToken: UInt = 0
    private var onKeyboard = false
    private static let fadeOutRoom: UInt32 = 160

    init() {
        machine = RailHoverMachine(schedule: { delay, work in
            Gtk.after(delay) { Gtk.onMain { work() } }
        })
        machine.onOpen = { [weak self] id in self?.present(id) }
        machine.onClose = { [weak self] id in self?.retire(id) }
        Gtk.addClass(plate, "link-plate")
        gtk_widget_set_halign(plate, GTK_ALIGN_START)
        gtk_widget_set_valign(plate, GTK_ALIGN_START)
        gtk_widget_set_visible(plate, 0)
        gtk_widget_set_overflow(plate, GTK_OVERFLOW_HIDDEN)
    }

    func install(on overlay: UnsafeMutablePointer<GtkWidget>) {
        self.overlay = overlay
        gtk_overlay_add_overlay(op(overlay), plate)
        Gtk.onKey(plate) { [weak self] keyval, _ in
            guard let self, self.openID != nil else { return false }
            switch keyval {
            case Keymap.escape:
                self.escape()
                return true
            case Keymap.down:
                self.walk(by: 1)
                return true
            case Keymap.up:
                self.walk(by: -1)
                return true
            default:
                return false
            }
        }
    }

    /// What the pointer is over: a rail, the plate, or neither. One hit test per move, and only the
    /// widget the pointer is over is asked what it is.
    func target(atX x: Double, y: Double) -> RailHoverMachine.Target? {
        guard let overlay else { return nil }
        var current = gtk_widget_pick(overlay, x, y, GTK_PICK_DEFAULT)
        while let widget = current, widget != overlay {
            if widget == plate { return openID.map { .plate($0) } }
            if let id = LinkRailView.railID(of: widget) { return .rail(id) }
            current = gtk_widget_get_parent(widget)
        }
        return nil
    }

    /// Whether the pointer is on a rail or the plate, which keeps the message hover from also
    /// claiming it.
    func pointerMoved(x: Double, y: Double) -> Bool {
        let hit = target(atX: x, y: y)
        machine.move(over: hit)
        return hit != nil
    }

    func pointerLeft() {
        machine.move(over: nil)
    }

    func act(_ id: Int, _ act: RailAct) {
        switch act {
        case .click:
            onKeyboard = false
            machine.toggle(id)
        case .key:
            onKeyboard = true
            machine.toggle(id)
            if openID == id { focusRow(0) }
        case .down:
            onKeyboard = true
            if openID != id { machine.toggle(id) }
            focusRow(0)
        }
    }

    /// Escape takes an open plate down and says it did, so the key goes no further.
    @discardableResult
    func escape() -> Bool {
        guard openID != nil else { return false }
        let id = openID
        let keyboard = onKeyboard
        machine.escape()
        if keyboard, let id, let model = LinkRailRegistry.shared.model(id), let line = model.line {
            gtk_widget_grab_focus(line.widget)
        }
        return true
    }

    /// A scroll, a chat switch, a press on the words: the plate goes now, and comes back by the
    /// ordinary road if the pointer is still on a rail when the page is still.
    func dismiss() {
        guard let id = openID else { return }
        machine.forget(id)
    }

    func gone(_ id: Int) {
        machine.forget(id)
    }

    private func present(_ id: Int) {
        guard let overlay, let model = LinkRailRegistry.shared.model(id), let line = model.line,
            let railBox = Gtk.bounds(of: line.widget, in: overlay)
        else { return }
        let metrics = TranscriptGaps.metrics
        openID = id
        model.setOpen(true)
        model.fetch(opened: true)
        let machine = machine!
        let plateRef = WidgetRef(plate)
        let built = LinkRailPlateView.build(
            model: model, metrics: metrics,
            menuAnchor: { var found: UnsafeMutablePointer<GtkWidget>?; plateRef.with { found = $0 }; return found },
            menuOpen: { machine.suspend($0) })
        Gtk.removeChildren(of: plate)
        gtk_box_append(ptr(plate), built.content)
        rows = built.rows
        let width = min(metrics.railPlateWidth, Double(gtk_widget_get_width(overlay)) - 16)
        gtk_widget_set_size_request(plate, Int32(width), -1)
        let height = built.height + 2
        let spot = LinkRailPlacement.place(
            railX: railBox.x, railY: railBox.y, railHeight: railBox.height,
            overlayWidth: Double(gtk_widget_get_width(overlay)),
            overlayHeight: Double(gtk_widget_get_height(overlay)), plateWidth: width,
            plateHeight: height)
        gtk_widget_set_margin_start(plate, Int32(spot.x.rounded()))
        gtk_widget_set_margin_top(plate, Int32(spot.y.rounded()))
        if spot.upward {
            gtk_widget_add_css_class(plate, "link-plate-up")
        } else {
            gtk_widget_remove_css_class(plate, "link-plate-up")
        }
        gtk_widget_set_visible(plate, 1)
        visibilityToken &+= 1
        let token = visibilityToken
        Gtk.after(20) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.visibilityToken == token, self.openID != nil else { return }
                gtk_widget_add_css_class(self.plate, "link-plate-on")
            }
        }
    }

    private func retire(_ id: Int) {
        if openID == id { openID = nil }
        LinkRailRegistry.shared.model(id)?.setOpen(false)
        rows = []
        gtk_widget_remove_css_class(plate, "link-plate-on")
        visibilityToken &+= 1
        let token = visibilityToken
        Gtk.after(Self.fadeOutRoom) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.visibilityToken == token, self.openID == nil else { return }
                gtk_widget_set_visible(self.plate, 0)
                Gtk.removeChildren(of: self.plate)
            }
        }
    }

    private func focusRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        gtk_widget_grab_focus(rows[index])
    }

    private func walk(by step: Int) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { gtk_widget_has_focus($0) != 0 }
        let next = current.map { min(rows.count - 1, max(0, $0 + step)) } ?? (step > 0 ? 0 : rows.count - 1)
        focusRow(next)
    }
}
