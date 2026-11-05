import CAdw
import CGtkShim
import Foundation
import TailscodeCore

#if HAS_LAYER_SHELL
    import CLayerShell
#endif

/// The quick ask's place on the desktop: where its card stands, how big it is, and what moving or
/// resizing it does.
///
/// A Wayland window cannot place itself, so on a desktop that offers the layer shell (KDE,
/// Hyprland, Sway and the rest of wlroots) the quick ask is an overlay the size of the screen it
/// opens on — the screen the desktop considers active — with the card drawn inside it under the
/// pointer, at the size it was last given. A Wayland client learns where the pointer is only once
/// it is over one of its own surfaces, so the card waits unseen for the overlay's first word of the
/// pointer, and opens where it was left on that screen when none comes (a pointer over a panel, or
/// on another screen). The card is then the app's to move and resize: its ground drags it, a band
/// either side of its border sizes it, a press beside it closes it, and every change is remembered
/// (`QuickAskPlacementStore`), per screen for the place and once for the size. On a desktop without
/// the layer shell, and on X11, it is an ordinary window over the app: the desktop places, moves
/// and resizes it, its ground still drags it, and its size is remembered.
final class QuickAskStage: @unchecked Sendable {
    let window: UnsafeMutablePointer<GtkWidget>
    let card: UnsafeMutablePointer<GtkWidget>
    let isLayered: Bool
    private let room: UnsafeMutablePointer<GtkWidget>?
    private(set) var frame = QuickAskRect(
        x: 0, y: 0, width: QuickAskGeometry.defaultWidth, height: QuickAskGeometry.defaultHeight)
    private var screen: (name: String, width: Double, height: Double)?
    /// When the overlay had its screen, so the log can say how long the pointer took to be heard.
    private var stoodAt: Date?
    private var isPlaced = false
    private var dragStart: QuickAskRect?
    /// The mark at the head of the question box: the point of the card the pointer lands on.
    var anchor: UnsafeMutablePointer<GtkWidget>?
    /// A press beside the card, which dismisses it the way a press outside a palette does.
    var onBackdrop: (@Sendable () -> Void)?
    /// The surface stands and takes the keyboard, so nothing typed straight after the chord is lost;
    /// an overlay's card is held invisible until it has its place, so it never shows at a place it
    /// is about to leave.
    var onReady: (@Sendable () -> Void)?

    /// How long the card waits, unseen, for the desktop to say where the pointer is before opening
    /// where it was left instead: long enough for a compositor to answer the overlay's first frame,
    /// short enough that a pointer on another screen never makes the card feel slow to arrive.
    private static let pointerWait: UInt32 = 150

    static var layerAvailable: Bool {
        #if HAS_LAYER_SHELL
            return gtk_layer_is_supported() != 0
        #else
            return false
        #endif
    }

    init(
        window: UnsafeMutablePointer<GtkWidget>, card: UnsafeMutablePointer<GtkWidget>,
        parent: UnsafeMutablePointer<GtkWidget>?
    ) {
        self.window = window
        self.card = card
        isLayered = Self.layerAvailable
        room = isLayered ? tailscode_stage_room() : nil
        if isLayered {
            mountOverlay()
        } else {
            mountWindow(parent: parent)
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        tailscode_stage_track(card, room, Self.hit, Self.drag, me)
    }

    private func mountOverlay() {
        guard let room else { return }
        #if HAS_LAYER_SHELL
            let layered: UnsafeMutablePointer<GtkWindow> = ptr(window)
            gtk_layer_init_for_window(layered)
            gtk_layer_set_namespace(layered, "tailscode-quick-ask")
            gtk_layer_set_layer(layered, GTK_LAYER_SHELL_LAYER_OVERLAY)
            gtk_layer_set_keyboard_mode(layered, GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE)
            for edge in [
                GTK_LAYER_SHELL_EDGE_LEFT, GTK_LAYER_SHELL_EDGE_RIGHT, GTK_LAYER_SHELL_EDGE_TOP,
                GTK_LAYER_SHELL_EDGE_BOTTOM,
            ] {
                gtk_layer_set_anchor(layered, edge, 1)
            }
        #endif
        standApart()
        holdOpen()
        Gtk.addClass(window, "qa-layer")
        Gtk.addClass(card, "qa-floating")
        gtk_widget_set_opacity(card, 0)
        gtk_box_append(ptr(room), card)
        gtk_window_set_child(ptr(window), room)
        let me = Unmanaged.passUnretained(self).toOpaque()
        tailscode_stage_backdrop(room, card, Self.backdrop, me)
        tailscode_when_sized(room, Self.sized, me)
    }

    /// The overlay keeps a window group of its own. A dialog open over the app — the welcome, the
    /// settings — holds the grab of the group it belongs to, and an overlay sharing that group
    /// would take the whole keyboard while every press and key on it was thrown away.
    private func standApart() {
        guard let group = gtk_window_group_new() else { return }
        gtk_window_group_add_window(group, ptr(window))
        g_object_unref(UnsafeMutableRawPointer(group))
    }

    /// A surface with nothing drawn on it is never shown, and one that is not shown is never told
    /// where the pointer is: so while the card waits, the overlay wears a tint too faint to see,
    /// which is enough for the desktop to show it and say where the pointer stands.
    private func holdOpen() {
        Gtk.addClass(window, "qa-arriving")
    }

    /// An ordinary window opens at the size it was last given, clamped to the screen of the app
    /// it is asked over, centred on that app by the desktop.
    private func mountWindow(parent: UnsafeMutablePointer<GtkWidget>?) {
        gtk_window_set_modal(ptr(window), 1)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }
        let area = Self.screenSize(near: parent)
        let size = QuickAskGeometry.size(
            QuickAskPlacementStore.load(), screenWidth: area.width, screenHeight: area.height)
        frame = QuickAskRect(x: 0, y: 0, width: size.width, height: size.height)
        gtk_window_set_default_size(ptr(window), Int32(size.width), Int32(size.height))
        gtk_window_set_titlebar(ptr(window), Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0))
        gtk_window_set_child(ptr(window), card)
        Gtk.onMain { [weak self] in self?.onReady?() }
    }

    private static func screenSize(near widget: UnsafeMutablePointer<GtkWidget>?)
        -> (width: Double, height: Double)
    {
        guard let widget, let native = gtk_widget_get_native(widget),
            let surface = gtk_native_get_surface(native),
            let monitor = gdk_display_get_monitor_at_surface(gdk_display_get_default(), surface)
        else { return (1920, 1080) }
        var geometry = GdkRectangle()
        gdk_monitor_get_geometry(monitor, &geometry)
        return (Double(geometry.width), Double(geometry.height))
    }

    /// The overlay has its screen: it takes the keyboard at once, and the card waits for the
    /// pointer.
    private func stand(width: Int32, height: Int32) {
        var name = "screen"
        if let native = gtk_widget_get_native(window), let surface = gtk_native_get_surface(native),
            let monitor = gdk_display_get_monitor_at_surface(gdk_display_get_default(), surface),
            let connector = gdk_monitor_get_connector(monitor)
        {
            name = String(cString: connector)
        }
        screen = (name: name, width: Double(width), height: Double(height))
        stoodAt = Date()
        onReady?()
        guard let room else { return }
        tailscode_when_pointed(
            room, Self.pointerWait, Self.pointed, Unmanaged.passUnretained(self).toOpaque())
    }

    /// The card goes under the pointer, the head of its question box where the pointer is. When the
    /// desktop never said where the pointer is, it goes where it was left on this screen, or where
    /// it was last left anywhere at the same share of this screen, or where a palette is expected.
    private func place(pointer: (x: Double, y: Double)?) {
        guard let screen else { return }
        let placement = QuickAskPlacementStore.load()
        let size = QuickAskGeometry.size(
            placement, screenWidth: screen.width, screenHeight: screen.height)
        let origin =
            if let pointer {
                QuickAskGeometry.origin(
                    pointer: pointer, anchor: anchorPoint(), screenWidth: screen.width,
                    screenHeight: screen.height, width: size.width, height: size.height)
            } else {
                QuickAskGeometry.origin(
                    placement, screen: screen.name, screenWidth: screen.width,
                    screenHeight: screen.height, width: size.width, height: size.height)
            }
        apply(QuickAskRect(x: origin.x, y: origin.y, width: size.width, height: size.height))
        isPlaced = true
        gtk_widget_remove_css_class(window, "qa-arriving")
        gtk_widget_set_opacity(card, 1)
        let waited = stoodAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        let by = pointer.map { "pointer=\(Int($0.x)),\(Int($0.y))" } ?? "memory"
        AppLog.write(.ui, "ASK placed screen=\(screen.name) by=\(by) after=\(waited)ms at=\(Int(origin.x)),\(Int(origin.y)) size=\(Int(size.width))x\(Int(size.height))")
    }

    /// Where the mark at the head of the question box stands on the card, from its top-left corner.
    private func anchorPoint() -> (x: Double, y: Double) {
        guard let anchor else { return (0, 0) }
        var centre = graphene_point_t(
            x: Float(gtk_widget_get_width(anchor)) / 2, y: Float(gtk_widget_get_height(anchor)) / 2)
        var mapped = graphene_point_t()
        guard gtk_widget_compute_point(anchor, card, &centre, &mapped) != 0 else { return (0, 0) }
        return (Double(mapped.x), Double(mapped.y))
    }

    private func apply(_ rect: QuickAskRect) {
        frame = rect
        guard let room else { return }
        tailscode_stage_room_place(room, rect.x, rect.y, rect.width, rect.height)
    }

    private func dragged(phase: Int32, edges: Int32, dx: Double, dy: Double) {
        switch phase {
        case 0:
            dragStart = frame
        case 1:
            guard let start = dragStart, let screen else { return }
            if edges == 16 {
                let origin = QuickAskGeometry.clampOrigin(
                    x: start.x + dx, y: start.y + dy, width: start.width, height: start.height,
                    screenWidth: screen.width, screenHeight: screen.height)
                apply(QuickAskRect(x: origin.x, y: origin.y, width: start.width, height: start.height))
            } else {
                apply(
                    QuickAskGeometry.resized(
                        start, edges: QuickAskEdges(rawValue: Int(edges)), dx: dx, dy: dy,
                        screenWidth: screen.width, screenHeight: screen.height))
            }
        default:
            dragStart = nil
            remember()
        }
    }

    /// What the person did to the card is kept: the place on this screen and the size, for an
    /// overlay; the size a window was left at, for a window — read as the window's own default
    /// size, which GTK keeps in step with every resize and which is the very number it is opened
    /// with, so a card closed and opened again comes back the size it was and not a border smaller.
    func remember() {
        if isLayered {
            guard isPlaced, let screen else { return }
            QuickAskPlacementStore.recordSize(width: frame.width, height: frame.height)
            QuickAskPlacementStore.recordSpot(
                x: frame.x, y: frame.y, screen: screen.name, screenWidth: screen.width,
                screenHeight: screen.height)
            return
        }
        var width: Int32 = 0
        var height: Int32 = 0
        gtk_window_get_default_size(ptr(window), &width, &height)
        guard width > 0, height > 0 else { return }
        QuickAskPlacementStore.recordSize(width: Double(width), height: Double(height))
    }

    /// Another window of the app takes the keyboard for a moment — the action editor, the model
    /// chooser, a file chooser, the screen's own drag. An overlay holds the keyboard and stands
    /// above every window, so it steps out of the way until that window is done.
    func stepAside() {
        guard isLayered else { return }
        gtk_widget_set_visible(window, 0)
    }

    /// Steps aside for as long as `child` stands.
    func stepAside(until child: UnsafeMutablePointer<GtkWidget>?) {
        guard isLayered, let child else { return }
        stepAside()
        Gtk.connect(UnsafeMutableRawPointer(child), "destroy") {
            Gtk.onMain { QuickAskWindow.open?.stage.stepBack() }
        }
    }

    /// The window a child of the card is put over: none for an overlay, which is not a window a
    /// dialog can belong to.
    var dialogParent: UnsafeMutablePointer<GtkWidget>? { isLayered ? nil : window }

    func stepBack() {
        guard isLayered else { return }
        gtk_window_present(ptr(window))
    }

    private static let hit: TailscodeStageHit = { x, y, width, height, _ in
        Int32(QuickAskGeometry.edges(atX: x, y: y, width: width, height: height).rawValue)
    }

    private static let drag: TailscodeStageDrag = { phase, edges, dx, dy, raw in
        guard let raw else { return }
        Unmanaged<QuickAskStage>.fromOpaque(raw).takeUnretainedValue()
            .dragged(phase: phase, edges: edges, dx: dx, dy: dy)
    }

    private static let backdrop: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
        guard let raw else { return }
        Unmanaged<QuickAskStage>.fromOpaque(raw).takeUnretainedValue().onBackdrop?()
    }

    private static let sized: @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Void = {
        width, height, raw in
        guard let raw else { return }
        Unmanaged<QuickAskStage>.fromOpaque(raw).takeUnretainedValue()
            .stand(width: width, height: height)
    }

    private static let pointed:
        @convention(c) (gboolean, Double, Double, UnsafeMutableRawPointer?) -> Void = {
            known, x, y, raw in
            guard let raw else { return }
            Unmanaged<QuickAskStage>.fromOpaque(raw).takeUnretainedValue()
                .place(pointer: known != 0 ? (x, y) : nil)
        }
}
