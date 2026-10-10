import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The Studio's room, shared by the image lane and the video lane: a bar for the machine pill (in
/// a pane; a window puts the pill in its header), the stage, the shelf beside it or above the
/// dock, and the dock. What goes in each is the lane's business; where each goes, and when, is
/// this — and the rule is Core's (`StudioArrangement`): the shelf is a rail from 900 points of
/// width and a strip above the dock below it, and the chips fold into one Settings control when
/// the room is short or narrow.
///
/// In the sheet the room is measured against the sheet rather than against what is left under its
/// toolbar: `surround` is the height of what sits above the frame, so the folds read the same room
/// the design names (960 points of sheet width, 760 points of sheet height).
///
/// Everything moves by reference. A rail becoming a strip is the same shelf turned and put
/// somewhere else, so the tile somebody is looking at is the same tile after the pane is resized.
final class StudioFrame: @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    let metrics: StudioMetrics
    /// Points of the host that sit above this frame and belong to the room it is measured in.
    var surround: Double = 0
    let machine = StudioMachineButton()
    let toolbar = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    let shell: StudioStageShell
    let shelf: StudioShelfView
    let dock: StudioDock
    private let probe = gtk_drawing_area_new()!
    private let body = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    private let mainColumn = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let railSlot = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let stripSlot = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let dockHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private(set) var arrangement = StudioArrangement(shelf: .rail, chips: .row)
    private var arranged = false
    private var zoomed = false
    /// Told whenever the room has been put somewhere, with the room it had.
    var onArranged: (@Sendable (Double, Double) -> Void)?

    /// What the dock spends on its own sides: its holder's margins, its padding and its border.
    static let dockInset: Double = 16 * 2 + 12 * 2 + 2

    /// - Parameter window: whether the Studio is the sheet, whose toolbar carries the machine pill,
    ///   rather than a pane with a bar for it.
    init(helper: UnsafeMutablePointer<GtkWidget>, window: Bool) {
        metrics = window ? .sheet : .pane
        shell = StudioStageShell(metrics: metrics)
        shelf = StudioShelfView(metrics: metrics)
        dock = StudioDock(helper: helper)
        build(window: window)
    }

    private func build(window: Bool) {
        Gtk.addClass(root, "canvas")
        Gtk.addClass(root, "draw-pane")
        Gtk.addClass(root, "studio")
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)

        Gtk.addClass(toolbar, "studio-toolbar")
        if !window {
            gtk_widget_set_hexpand(machine.widget, 1)
            gtk_box_append(ptr(toolbar), machine.widget)
        }
        gtk_widget_set_visible(toolbar, window ? 0 : 1)

        gtk_widget_set_hexpand(mainColumn, 1)
        gtk_widget_set_vexpand(mainColumn, 1)
        gtk_box_append(ptr(mainColumn), shell.root)
        gtk_box_append(ptr(mainColumn), stripSlot)
        Gtk.margins(dockHolder, top: 6, bottom: 14, leading: 16, trailing: 16)
        gtk_box_append(ptr(dockHolder), dock.root)
        gtk_box_append(ptr(mainColumn), dockHolder)

        gtk_box_append(ptr(body), mainColumn)
        gtk_box_append(ptr(body), railSlot)
        gtk_box_append(ptr(railSlot), shelf.root)
        gtk_widget_set_vexpand(body, 1)

        let layout = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_vexpand(layout, 1)
        gtk_box_append(ptr(layout), toolbar)
        gtk_box_append(ptr(layout), body)

        let overlay = gtk_overlay_new()!
        gtk_widget_set_hexpand(overlay, 1)
        gtk_widget_set_vexpand(overlay, 1)
        gtk_overlay_set_child(op(overlay), layout)
        gtk_widget_set_hexpand(probe, 1)
        gtk_widget_set_vexpand(probe, 1)
        gtk_widget_set_can_target(probe, 0)
        gtk_widget_set_can_focus(probe, 0)
        Gtk.setHidden(probe, true)
        gtk_overlay_add_overlay(op(overlay), probe)
        gtk_overlay_set_measure_overlay(op(overlay), probe, 0)
        gtk_box_append(ptr(root), overlay)

        Gtk.onResize(probe) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.arrange(
                    width: Double(gtk_widget_get_width(self.probe)),
                    height: Double(gtk_widget_get_height(self.probe)))
            }
        }
    }

    /// The room's own size, as the probe last measured it.
    var size: (width: Int, height: Int) {
        (Int(gtk_widget_get_width(probe)), Int(gtk_widget_get_height(probe)))
    }

    /// Takes the room the pane has and decides what to do with it. A change that moves nothing
    /// moves nothing: a chip's menu open across a resize stays open.
    func arrange(width: Double, height: Double) {
        guard width > 0, height > 0 else { return }
        let next = StudioArrangement.resolve(
            width: width, height: height + surround, metrics: metrics)
        let rail = next.shelf == .rail
        let beside = width - (rail ? metrics.railWidth : 0)
        shell.setCompact(width < 640)
        dock.setCompact(beside < 560)
        dock.tray.layout(available: beside - Self.dockInset)
        onArranged?(width, height)
        guard next != arrangement || !arranged else { return }
        arranged = true
        arrangement = next
        if rail {
            move(shelf.root, to: railSlot)
        } else {
            move(shelf.root, to: stripSlot)
        }
        shelf.place(rail: rail)
        dock.tray.fold(next.chips == .settings)
        showShelves()
    }

    private func move(_ widget: UnsafeMutablePointer<GtkWidget>, to slot: UnsafeMutablePointer<GtkWidget>) {
        if gtk_widget_get_parent(widget) == slot { return }
        g_object_ref(UnsafeMutableRawPointer(widget))
        if gtk_widget_get_parent(widget) != nil { Gtk.detachFromParent(widget) }
        gtk_box_append(ptr(slot), widget)
        g_object_unref(UnsafeMutableRawPointer(widget))
    }

    private func showShelves() {
        gtk_widget_set_visible(railSlot, zoomed || arrangement.shelf != .rail ? 0 : 1)
        gtk_widget_set_visible(stripSlot, zoomed || arrangement.shelf != .strip ? 0 : 1)
    }

    /// A window giving its picture the whole room hides the dock and the shelf and keeps the
    /// stage; a pane never does, because it opens a viewer beside itself instead.
    func setZoomed(_ on: Bool) {
        guard on != zoomed else { return }
        zoomed = on
        gtk_widget_set_visible(dockHolder, on ? 0 : 1)
        showShelves()
    }

    /// The narrowest each part of the studio can be, for a harness proving that nothing in it holds
    /// the pane wider than the room it was given.
    var minimums: String {
        func narrowest(_ widget: UnsafeMutablePointer<GtkWidget>) -> Int {
            var least: Int32 = 0
            var natural: Int32 = 0
            gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, &least, &natural, nil, nil)
            return Int(least)
        }
        return "root=\(narrowest(root)) stage=\(narrowest(shell.root)) dock=\(narrowest(dock.root)) words=\(narrowest(dock.promptView)) shelf=\(narrowest(shelf.root)) toolbar=\(narrowest(toolbar))"
    }

    /// For the headless driver: where the room has been put.
    var summary: String {
        let room = size
        let chips = dock.tray.isFolded ? "settings" : "row"
        return
            "room=\(room.width)x\(room.height) shelf=\(arrangement.shelf == .rail ? "rail" : "strip") chips=\(chips) stage=\(Int(gtk_widget_get_height(shell.root)))/\(room.height) \(shell.progressSummary) verbs=\(shell.verbSummary) shelfview=[\(shelf.summary)] pill=[\(machine.summary)] dock=\(Int(dock.height)) min=[\(minimums)]"
    }

    /// Where a widget sits inside this studio's window, for a harness that has to click it.
    func bounds(of widget: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let root = gtk_widget_get_root(ptr(root)),
            let box = Gtk.bounds(of: widget, in: UnsafeMutablePointer(root))
        else { return "-" }
        return String(format: "%.0f,%.0f %.0fx%.0f", box.x, box.y, box.width, box.height)
    }
}
