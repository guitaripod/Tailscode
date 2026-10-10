import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Where a Tab goes while a sheet is up. A sheet traps focus: a Tab inside a popover the sheet
/// opened belongs to that popover, a Tab that moves inside the sheet is the ordinary one, and a Tab
/// that would leave the sheet wraps to its other end rather than reaching a conversation nobody
/// can see the focus of.
enum StudioSheetTab: Equatable {
    case leaveToPopover
    case moveWithin
    case wrap

    /// The route for a Tab given where focus is and whether moving it inside the sheet succeeded.
    static func route(inPopover: Bool, moved: Bool) -> StudioSheetTab {
        if inPopover { return .leaveToPopover }
        return moved ? .moveWithin : .wrap
    }
}

/// One sheet's host, with nothing in it that is the Studio's or the viewer's: the scrim, the frame
/// from Core's geometry at this layer's depth, the edge, the translation motion, the state machine,
/// the focus it takes and gives back, the accessible dialog and the key rules every sheet shares.
/// What is *inside* — a toolbar and a body — is handed in by whoever owns the layer.
///
/// A layer stacked on another sits at depth 1 while the one beneath is up, so its frame is pushed
/// in by Core and the Studio's edge shows above it, and at depth 0 when it is alone.
///
/// A layer is laid out at its final size before it moves and is moved as one layer, a translation
/// inside a `GtkFixed` which is drawn and picked at the new place and never measured again, so
/// nothing inside re-wraps while it travels.
final class SheetLayer: @unchecked Sendable {
    private let stackedOn: SheetLayer?
    private let overlay: UnsafeMutablePointer<GtkWidget>
    private let content: UnsafeMutablePointer<GtkWidget>
    private var covered: UnsafeMutablePointer<GtkWidget>?
    private let window: UnsafeMutablePointer<GtkWidget>
    private let titlebar: @Sendable () -> Double
    private let scrim = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
    private let scrimFill: UnsafeMutablePointer<GtkWidget>?
    private let host = gtk_fixed_new()!
    private let sheet: UnsafeMutablePointer<GtkWidget>
    private let clip = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
    private var installedBar: UnsafeMutablePointer<GtkWidget>?
    private var installedBody: UnsafeMutablePointer<GtkWidget>?
    private var opener: UnsafeMutablePointer<GtkWidget>?
    private var tick: guint = 0
    private var motionReduced = false

    private(set) var state: StudioSheetState = .closed
    private(set) var frame = StudioSheetGeometry.frame(windowWidth: 0, windowHeight: 0, titlebar: 0)
    private(set) var progress: Double = 0

    /// What the log calls this sheet.
    var name = "sheet"
    /// Appended to the log line of a show, so a lane or a picture is named without a dump of an enum.
    var detail: () -> String = { "" }
    /// Before the layer starts to show anything: the window drops a half-typed chord here.
    var onRise: (@Sendable () -> Void)?
    /// The widgets are on screen and the layer is about to move: the content builds what it shows.
    var prepare: (() -> Void)?
    /// The sheet was asked for while it was already up: the content changes what it shows, no motion.
    var retarget: (() -> Void)?
    /// The first frame is under way: the content takes the keyboard.
    var focusInitial: (() -> Void)?
    /// The sheet starts to leave.
    var willLeave: (() -> Void)?
    /// The sheet has gone and nothing of it is on screen: the content lets go of what it built.
    var onClosed: (() -> Void)?
    /// A key while this layer owns the keyboard; the stack asks the topmost layer that does.
    var keys: ((UInt32, UInt32) -> Bool)?

    /// - Parameters:
    ///   - stackedOn: the layer this one stands on when that is up, nil for the bottom layer.
    ///   - content: what the bottom layer covers: everything in the window.
    init(
        stackedOn: SheetLayer?, overlay: UnsafeMutablePointer<GtkWidget>,
        content: UnsafeMutablePointer<GtkWidget>, window: UnsafeMutablePointer<GtkWidget>,
        titlebar: @escaping @Sendable () -> Double
    ) {
        self.stackedOn = stackedOn
        self.overlay = overlay
        self.content = content
        self.window = window
        self.titlebar = titlebar
        sheet = tailscode_box_new_with_role(
            GTK_ORIENTATION_VERTICAL, 0, GTK_ACCESSIBLE_ROLE_DIALOG)!
        scrimFill = stackedOn != nil ? gtk_box_new(GTK_ORIENTATION_VERTICAL, 0) : nil
        build()
    }

    private func build() {
        gtk_widget_set_hexpand(scrim, 1)
        gtk_widget_set_vexpand(scrim, 1)
        gtk_widget_set_visible(scrim, 0)
        gtk_widget_set_opacity(scrim, 0)
        if let scrimFill {
            Gtk.addClass(scrimFill, "studio-scrim")
            gtk_widget_set_hexpand(scrimFill, 1)
            gtk_widget_set_vexpand(scrimFill, 1)
            gtk_box_append(ptr(scrim), scrimFill)
        } else {
            Gtk.addClass(scrim, "studio-scrim")
        }
        Gtk.onPrimaryRelease(scrim) { [weak self] in
            Gtk.onMain { [weak self] in self?.dismiss() }
        }
        Gtk.setHidden(scrim, true)
        gtk_overlay_add_overlay(op(overlay), scrim)

        gtk_widget_set_halign(host, GTK_ALIGN_START)
        gtk_widget_set_valign(host, GTK_ALIGN_START)
        gtk_widget_set_visible(host, 0)
        gtk_overlay_add_overlay(op(overlay), host)

        Gtk.addClass(sheet, "studio-sheet")
        gtk_fixed_put(ptr(host), sheet, 0, 0)
        Gtk.addClass(clip, "studio-sheet-clip")
        gtk_widget_set_overflow(clip, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_hexpand(clip, 1)
        gtk_widget_set_vexpand(clip, 1)
        gtk_box_append(ptr(sheet), clip)
    }

    /// Names the sheet for assistive technology, which announces it as a dialog.
    func setDialogName(_ text: String) {
        tailscode_set_accessible_label(sheet, text)
    }

    /// Adds a class to the sheet, for a content that paints its own canvas.
    func addSheetClass(_ name: String) {
        Gtk.addClass(sheet, name)
    }

    /// Puts a toolbar and a body into the sheet. They stay until `uninstall`.
    func install(
        toolbar: UnsafeMutablePointer<GtkWidget>, body: UnsafeMutablePointer<GtkWidget>
    ) {
        uninstall()
        installedBar = toolbar
        installedBody = body
        gtk_box_append(ptr(clip), toolbar)
        gtk_box_append(ptr(clip), body)
    }

    func uninstall() {
        if let bar = installedBar { gtk_box_remove(ptr(clip), bar) }
        if let body = installedBody { gtk_box_remove(ptr(clip), body) }
        installedBar = nil
        installedBody = nil
    }

    var isUp: Bool { state != .closed }

    /// How far in the sheet sits: 1 while the layer beneath it is up, otherwise 0.
    var depth: Int { stackedOn?.isUp == true ? 1 : 0 }

    /// What this sheet hides from the pointer and from assistive technology while it is up: the
    /// sheet beneath it when there is one, the window's content otherwise.
    private var beneath: UnsafeMutablePointer<GtkWidget> {
        if let stackedOn, stackedOn.isUp { return stackedOn.host }
        return content
    }

    var capturesKeys: Bool { state.capturesKeys }

    func present() {
        apply(.show(lane: .image))
    }

    func dismiss() {
        apply(.dismiss)
    }

    /// Takes the sheet away with no motion at all, for a sheet another one needs the layer of.
    func closeNow() {
        guard state != .closed else { return }
        stopClock()
        AppLog.write(.ui, "\(name) sheet closed at once: \(state) -> closed")
        state = .closed
        returnKeyboard()
        finishedClosing()
    }

    /// What the log says about an event, never a dump of the enum.
    private static func words(for event: StudioSheetEvent) -> String {
        switch event {
        case .show: return "show"
        case .dismiss: return "dismiss"
        case .finished: return "finished"
        }
    }

    /// Every transition goes through the state machine in Core. Its `show` carries a Studio lane
    /// that a layer has no use for; what a show means is the content's, so the content reads it
    /// from the effect and this host only ever asks for "rise" or "stay".
    private func apply(_ event: StudioSheetEvent) {
        let before = state
        let result = state.reduced(by: event)
        state = result.state
        if event != .finished {
            let extra = event == .dismiss ? "" : detail()
            AppLog.write(
                .ui,
                "\(name) sheet \(Self.words(for: event))\(extra.isEmpty ? "" : " " + extra): \(before) -> \(state)"
            )
        }
        switch result.effect {
        case .none:
            if before != state, state == .closed { finishedClosing() }
        case .animateIn:
            rise()
        case .changeLane:
            retarget?()
        case .animateOut:
            returnKeyboard()
            willLeave?()
            run(to: 0, opening: false)
        }
    }

    /// A rise out of a closed sheet or out of one that is leaving: the second keeps what it built
    /// and starts from wherever the motion had got to.
    private func rise() {
        if let stale = opener { g_object_unref(UnsafeMutableRawPointer(stale)) }
        opener = Self.remember(window)
        onRise?()
        gtk_widget_set_visible(scrim, 1)
        gtk_widget_set_visible(host, 1)
        let hidden = beneath
        covered = hidden
        gtk_widget_set_can_target(hidden, 0)
        Gtk.setHidden(hidden, true)
        prepare?()
        relayout()
        run(to: 1, opening: true)
        Gtk.onMain { [weak self] in self?.focusInitial?() }
    }

    private func finishedClosing() {
        stopClock()
        gtk_widget_set_visible(scrim, 0)
        gtk_widget_set_visible(host, 0)
        if let covered {
            gtk_widget_set_can_target(covered, 1)
            Gtk.setHidden(covered, false)
        }
        covered = nil
        progress = 0
        onClosed?()
    }

    /// The keyboard of what was behind comes back as the sheet starts to leave, not when it has
    /// gone, so a stray key during the motion reaches whatever is in front again.
    private func returnKeyboard() {
        guard let opener else { return }
        self.opener = nil
        defer { g_object_unref(UnsafeMutableRawPointer(opener)) }
        guard gtk_widget_get_root(opener) != nil, gtk_widget_get_mapped(opener) != 0 else { return }
        gtk_window_set_focus(ptr(window), nil)
        gtk_widget_grab_focus(opener)
    }

    private static func remember(_ window: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget>?
    {
        guard let focused = tailscode_focused_widget(window) else { return nil }
        g_object_ref(UnsafeMutableRawPointer(focused))
        return focused
    }

    /// Puts the sheet where Core says it goes for the window it is in. The sheet is allocated at its
    /// final size here, before any motion, and a resize or a maximise lands here again.
    func relayout() {
        let width = Double(gtk_widget_get_width(overlay))
        let height = Double(gtk_widget_get_height(overlay))
        guard width > 0, height > 0 else { return }
        let bar = titlebar()
        let level = depth
        let next = StudioSheetGeometry.frame(
            windowWidth: width, windowHeight: height, titlebar: bar, depth: level)
        let below = level > 0
            ? StudioSheetGeometry.frame(windowWidth: width, windowHeight: height, titlebar: bar)
            : nil
        guard next != frame || gtk_widget_get_width(sheet) == 0 else { return }
        frame = next
        gtk_widget_set_margin_start(host, Int32(next.x.rounded()))
        gtk_widget_set_margin_top(host, Int32(next.y.rounded()))
        gtk_widget_set_size_request(host, Int32(next.width.rounded()), Int32(next.height.rounded()))
        gtk_widget_set_size_request(sheet, Int32(next.width.rounded()), Int32(next.height.rounded()))
        if let scrimFill {
            Gtk.margins(
                scrimFill, top: Int32((below?.y ?? 0).rounded()), bottom: 0,
                leading: Int32((below?.x ?? 0).rounded()), trailing: Int32((below?.x ?? 0).rounded()))
        }
        place()
    }

    private func place() {
        let rise = StudioSheetMotion.translation(
            progress: progress, sheetHeight: frame.height, reduced: motionReduced)
        tailscode_fixed_place(host, sheet, 0, rise.rounded())
        gtk_widget_set_opacity(
            sheet, StudioSheetMotion.sheetOpacity(progress: progress, reduced: motionReduced))
        gtk_widget_set_opacity(
            scrim, StudioSheetMotion.scrimOpacity(progress: progress, appearance: appearance))
    }

    /// The face of the app the scrim is drawn over, as the desktop resolves it.
    var appearance: StudioSheetAppearance {
        guard let manager = adw_style_manager_get_default() else { return .dark }
        return adw_style_manager_get_dark(manager) != 0 ? .dark : .light
    }

    /// The appearance changed while the sheet was up: the scrim re-resolves to the other face's alpha.
    func rethemed() {
        guard state != .closed else { return }
        place()
    }

    /// Draws the sheet at a presence between 0 (away) and 1 (at rest) with no clock running, for
    /// the headless driver that photographs the middle of the motion.
    func hold(at presence: Double) {
        stopClock()
        motionReduced = !RepeatingMotion.allowed
        progress = min(1, max(0, presence))
        place()
    }

    /// Lets a held sheet carry on to rest.
    func release() {
        guard state == .opening, tick == 0 else { return }
        run(to: 1, opening: true)
    }

    private func run(to target: Double, opening: Bool) {
        stopClock()
        motionReduced = !RepeatingMotion.allowed
        let from = progress
        let distance = abs(target - from)
        guard distance > 0 else {
            settle(target)
            return
        }
        let span = StudioSheetMotion.duration(opening: opening, reduced: motionReduced) * distance
        let link = Link(self, from: from, target: target, opening: opening, span: span)
        _ = Gtk.releaseInstalled
        tick = tailscode_add_owned_tick(
            host,
            { raw in
                guard let raw else { return 0 }
                let link = Unmanaged<Link>.fromOpaque(raw).takeUnretainedValue()
                guard let layer = link.layer else { return 0 }
                return layer.step(link) ? 1 : 0
            }, Unmanaged.passRetained(link).toOpaque())
    }

    /// What one running motion needs between frames: where it started from and is going, how long
    /// it takes and when its first frame was drawn. The motion begins at that frame rather than at
    /// the request, so whatever the main loop was busy with between the two — a content's first
    /// layout, a decode — is not taken out of the motion, which would otherwise arrive already
    /// finished. The clock holds it, and it holds the layer only weakly, so a layer let go of while
    /// its clock runs is a clock that ends on its next frame.
    private final class Link {
        weak var layer: SheetLayer?
        let from: Double
        let target: Double
        let opening: Bool
        let span: Double
        var started: Double?

        init(_ layer: SheetLayer, from: Double, target: Double, opening: Bool, span: Double) {
            self.layer = layer
            self.from = from
            self.target = target
            self.opening = opening
            self.span = span
        }
    }

    /// One frame of the motion on the display's own clock: the share done follows Core's ease, the
    /// sheet's translation and the scrim's alpha follow the same share, and the frame that reaches
    /// the end settles the state. Returns whether the clock keeps running.
    private func step(_ link: Link) -> Bool {
        let now = Self.now()
        let started = link.started ?? now
        link.started = started
        let elapsed = now - started
        guard elapsed < link.span else {
            tick = 0
            settle(link.target)
            return false
        }
        let share = StudioSheetMotion.eased(elapsed / link.span, opening: link.opening)
        progress = link.from + (link.target - link.from) * share
        place()
        return true
    }

    private func settle(_ target: Double) {
        progress = target
        place()
        apply(.finished)
    }

    func stopClock() {
        guard tick != 0 else { return }
        tailscode_remove_tick(host, tick)
        tick = 0
    }

    private static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private var focusIsInPopover: Bool {
        guard let focused = tailscode_focused_widget(window) else { return false }
        return gtk_widget_get_ancestor(focused, gtk_popover_get_type()) != nil
    }

    private static let isoLeftTab: UInt32 = 0xFE20

    /// A key while the layer owns the keyboard. Core's rules come first — Ctrl+W closes the sheet
    /// before the window — then the content's chords that outrank Tab, then the focus trap, then the
    /// content's other keys. Nothing is ever handed to the conversation chord table: an unclaimed
    /// key goes on to whatever inside the sheet has focus, and no further.
    ///
    /// - Parameters:
    ///   - before: chords the content claims ahead of the focus trap.
    ///   - after: every other key the content claims, with the key value for the ones with no chord.
    func route(
        keyval: UInt32, state mask: UInt32, before: (KeyChord) -> Bool = { _ in false },
        after: (KeyChord, UInt32) -> Bool
    ) -> Bool {
        let inPopover = focusIsInPopover
        if keyval == Keymap.escape, inPopover { return false }
        guard let chord = KeyChord.canonical(keyval: keyval, state: mask) else {
            return handleTab(keyval: keyval, state: mask, inPopover: inPopover)
        }
        if StudioSheetKeys.closes(chord) {
            AppLog.write(.ui, "\(name) sheet close chord")
            dismiss()
            return true
        }
        if before(chord) { return true }
        if keyval == Keymap.tab || keyval == Self.isoLeftTab {
            return handleTab(keyval: keyval, state: mask, inPopover: inPopover)
        }
        return after(chord, keyval)
    }

    /// Tab cycles inside the sheet: it moves focus the way the toolkit would, and a Tab that would
    /// leave wraps to the other end instead.
    private func handleTab(keyval: UInt32, state mask: UInt32, inPopover: Bool) -> Bool {
        guard keyval == Keymap.tab || keyval == Self.isoLeftTab else { return false }
        let backward = keyval == Self.isoLeftTab || mask & KeyChord.shiftMask != 0
        let direction = backward ? GTK_DIR_TAB_BACKWARD : GTK_DIR_TAB_FORWARD
        if inPopover { return false }
        let moved = gtk_widget_child_focus(sheet, direction) != 0
        if StudioSheetTab.route(inPopover: inPopover, moved: moved) == .wrap {
            gtk_window_set_focus(ptr(window), nil)
            _ = gtk_widget_child_focus(sheet, direction)
        }
        return true
    }

    var sheetWidget: UnsafeMutablePointer<GtkWidget> { sheet }

    var windowWidget: UnsafeMutablePointer<GtkWidget> { window }

    var scrimWidget: UnsafeMutablePointer<GtkWidget> { scrim }

    var hostWidget: UnsafeMutablePointer<GtkWidget> { host }

    var scrimOpacity: Double { gtk_widget_get_opacity(scrim) }

    var isMoving: Bool { tick != 0 }
}
