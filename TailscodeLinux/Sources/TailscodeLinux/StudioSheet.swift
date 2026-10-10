import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Where a Tab goes while the sheet is up. The sheet traps focus: a Tab inside a popover the sheet
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

/// The Studio, risen inside the window: one sheet hosting both lanes behind a lane switch, in the
/// main window's overlay over a scrim.
///
/// There is no second toplevel. The image surface and the forge surface are the two pages of one
/// stack, every dialog they open is an ordinary transient of the one main window, and that is what
/// removed the reason the old windows were not modal — a modal over a modal hands X11 an input
/// focus the window manager will not grant. Closing never stops a render: the job lives in
/// ``ImageStudio`` and ``ForgeRunner``, and the panes here are only views that are built when the
/// sheet rises and let go of when it has left.
///
/// Every number is Core's (`StudioSheetGeometry`, `StudioSheetMotion`, `StudioSheetMetrics`) and
/// the state machine is `StudioSheetState`. The sheet is laid out at its final size before it
/// moves and is moved as one layer — a translation inside a `GtkFixed`, which is drawn and picked
/// at the new place and never measured again — so nothing inside re-wraps while it travels.
final class StudioSheet: @unchecked Sendable {
    nonisolated(unsafe) private static var installed: StudioSheet?

    /// The sheet while it is on screen, rising, at rest or leaving, for the headless driver and for
    /// anything that asks whether the Studio is up. Nil when it is closed.
    static var current: StudioSheet? {
        guard let sheet = installed, sheet.state != .closed else { return nil }
        return sheet
    }

    /// The one sheet this window owns, whether it is up or not.
    static var shared: StudioSheet? { installed }

    /// Lets go of the claim to be the window's sheet, for a harness that built its own.
    func retire() {
        if Self.installed === self { Self.installed = nil }
        stopClock()
        if let observer = imageObserver { NotificationCenter.default.removeObserver(observer) }
        imageObserver = nil
        tearDown()
    }

    private let overlay: UnsafeMutablePointer<GtkWidget>
    private let content: UnsafeMutablePointer<GtkWidget>
    private let window: UnsafeMutablePointer<GtkWidget>
    private let titlebar: @Sendable () -> Double
    private let scrim = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
    private let probe = gtk_drawing_area_new()!
    private let host = gtk_fixed_new()!
    private let sheet: UnsafeMutablePointer<GtkWidget>
    private let lanes = gtk_stack_new()!
    private let pills = gtk_stack_new()!
    private let note = Gtk.label("", css: "studio-note", selectable: false)
    private let queue = Gtk.label("", css: "studio-queue", selectable: false)
    private let done: UnsafeMutablePointer<GtkWidget>
    private var laneButtons: [StudioLaneKind: UnsafeMutablePointer<GtkWidget>] = [:]

    private(set) var state: StudioSheetState = .closed
    private(set) var lane: StudioLaneKind = .image
    private(set) var frame = StudioSheetGeometry.frame(windowWidth: 0, windowHeight: 0, titlebar: 0)
    private(set) var progress: Double = 0

    private var drawPane: DrawPane?
    private var forgePane: ForgePane?
    private var opener: UnsafeMutablePointer<GtkWidget>?
    private var tick: guint = 0
    private var motionReduced = false
    private var noticeEnds: Date?
    private var imageObserver: NSObjectProtocol?

    /// How many times the room inside the sheet was handed a new size, which a harness reads before
    /// and after a move to prove that nothing inside re-laid-out while the sheet travelled.
    private(set) var layoutPasses = 0

    /// Told the moment the sheet goes up, so the window drops the half-typed chord it was holding.
    var onRise: (@Sendable () -> Void)?

    /// - Parameters:
    ///   - overlay: the overlay that spans the whole window, sidebar, conversation and composer.
    ///   - content: what the overlay's child is — everything the sheet covers.
    ///   - window: the one main window every dialog the Studio opens is a transient of.
    ///   - titlebar: how far down the window's own bar clears, so the sheet stays below it.
    init(
        overlay: UnsafeMutablePointer<GtkWidget>, content: UnsafeMutablePointer<GtkWidget>,
        window: UnsafeMutablePointer<GtkWidget>, titlebar: @escaping @Sendable () -> Double
    ) {
        self.overlay = overlay
        self.content = content
        self.window = window
        self.titlebar = titlebar
        sheet = tailscode_box_new_with_role(
            GTK_ORIENTATION_VERTICAL, 0, GTK_ACCESSIBLE_ROLE_DIALOG)!
        done = Gtk.button(Localized.text("Done"), css: ["studio-done"], onClick: {})
        build()
        Self.installed = self
    }

    private func build() {
        Gtk.addClass(scrim, "studio-scrim")
        gtk_widget_set_hexpand(scrim, 1)
        gtk_widget_set_vexpand(scrim, 1)
        gtk_widget_set_visible(scrim, 0)
        gtk_widget_set_opacity(scrim, 0)
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
        tailscode_set_accessible_label(sheet, StudioSheetWords.dialogName)
        gtk_fixed_put(ptr(host), sheet, 0, 0)
        let clip = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(clip, "studio-sheet-clip")
        gtk_widget_set_overflow(clip, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_hexpand(clip, 1)
        gtk_widget_set_vexpand(clip, 1)
        gtk_box_append(ptr(sheet), clip)
        gtk_box_append(ptr(clip), makeToolbar())

        gtk_stack_set_transition_type(op(lanes), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_hhomogeneous(op(lanes), 0)
        gtk_stack_set_vhomogeneous(op(lanes), 0)
        gtk_widget_set_hexpand(lanes, 1)
        gtk_widget_set_vexpand(lanes, 1)
        gtk_box_append(ptr(clip), lanes)

        gtk_widget_set_hexpand(probe, 1)
        gtk_widget_set_vexpand(probe, 1)
        gtk_widget_set_can_target(probe, 0)
        gtk_widget_set_can_focus(probe, 0)
        Gtk.setHidden(probe, true)
        gtk_overlay_add_overlay(op(overlay), probe)
        gtk_overlay_set_measure_overlay(op(overlay), probe, 0)
        Gtk.onResize(probe) { [weak self] in
            Gtk.onMain { [weak self] in self?.relayout() }
        }

        imageObserver = NotificationCenter.default.addObserver(
            forName: ImageStudio.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            Gtk.onMain { [weak self] in self?.refreshChrome() }
        }
    }

    /// The bar the sheet carries inside itself, there being no window title bar to borrow: the lane
    /// switch leading, the machine pill and the line under it in the middle, the queue and Done at
    /// the end.
    private func makeToolbar() -> UnsafeMutablePointer<GtkWidget> {
        let bar = gtk_center_box_new()!
        Gtk.addClass(bar, "studio-sheet-bar")
        gtk_widget_set_size_request(bar, -1, Int32(StudioSheetMetrics.toolbarHeight))

        let switcher = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(switcher, "studio-lanes")
        gtk_widget_set_valign(switcher, GTK_ALIGN_CENTER)
        for kind in StudioLaneKind.allCases {
            let button = Gtk.button(Self.title(of: kind), css: ["studio-lane"]) { [weak self] in
                Gtk.onMain { [weak self] in self?.show(kind) }
            }
            laneButtons[kind] = button
            gtk_box_append(ptr(switcher), button)
        }
        gtk_center_box_set_start_widget(op(bar), switcher)

        let middle = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_valign(middle, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(middle, GTK_ALIGN_CENTER)
        gtk_stack_set_transition_type(op(pills), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_widget_set_halign(pills, GTK_ALIGN_CENTER)
        gtk_label_set_xalign(op(note), 0.5)
        gtk_label_set_ellipsize(op(note), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(op(note), 72)
        gtk_widget_set_halign(note, GTK_ALIGN_CENTER)
        gtk_label_set_text(op(note), Self.reserved)
        gtk_box_append(ptr(middle), pills)
        gtk_box_append(ptr(middle), note)
        gtk_center_box_set_center_widget(op(bar), middle)

        let trailing = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_widget_set_valign(trailing, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(trailing), queue)
        Gtk.connect(UnsafeMutableRawPointer(done), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.dismiss() }
        }
        gtk_box_append(ptr(trailing), done)
        gtk_center_box_set_end_widget(op(bar), trailing)
        return bar
    }

    private static func title(of lane: StudioLaneKind) -> String {
        switch lane {
        case .image: return Localized.text("Image")
        case .video: return Localized.text("Video")
        }
    }

    /// What the line under the pill says when it has nothing to say: a no-break space, so the bar
    /// keeps its height and a render starting or landing never moves the pill.
    private static let reserved = "\u{00A0}"

    // MARK: opening and closing

    /// Brings the Studio up on a lane. Opened while it is already up it only changes lane, with no
    /// motion, and the words box takes the keyboard.
    @discardableResult
    func show(_ lane: StudioLaneKind) -> StudioSheet {
        apply(.show(lane: lane))
        return self
    }

    /// Takes the sheet away by the same motion it came by, from wherever it is.
    func dismiss() {
        apply(.dismiss)
    }

    private func apply(_ event: StudioSheetEvent) {
        let before = state
        let result = state.reduced(by: event)
        state = result.state
        switch result.effect {
        case .none:
            if before != state, state == .closed { finishedClosing() }
        case .animateIn(let target):
            rise(on: target)
        case .changeLane(let target):
            select(target)
            focusWords()
        case .animateOut:
            returnKeyboard()
            run(to: 0, opening: false)
        }
    }

    /// A rise out of a closed sheet or out of one that is leaving: the second keeps its panes and
    /// starts from wherever the motion had got to.
    private func rise(on target: StudioLaneKind) {
        if let stale = opener { g_object_unref(UnsafeMutableRawPointer(stale)) }
        opener = Self.remember(window)
        onRise?()
        gtk_widget_set_visible(scrim, 1)
        gtk_widget_set_visible(host, 1)
        gtk_widget_set_can_target(content, 0)
        Gtk.setHidden(content, true)
        if target == .image { ImageStudio.shared.adoptDoor() }
        select(target)
        relayout()
        run(to: 1, opening: true)
        Gtk.onMain { [weak self] in self?.focusWords() }
    }

    private func finishedClosing() {
        stopClock()
        gtk_widget_set_visible(scrim, 0)
        gtk_widget_set_visible(host, 0)
        gtk_widget_set_can_target(content, 1)
        Gtk.setHidden(content, false)
        progress = 0
        tearDown()
    }

    /// The conversation's keyboard comes back as the sheet starts to leave, not when it has gone,
    /// so a stray key during the motion reaches a conversation that is in front again.
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

    // MARK: the lanes

    private func select(_ target: StudioLaneKind) {
        lane = target
        switch target {
        case .image: ensureImage()
        case .video: ensureForge()
        }
        let name = target.rawValue
        gtk_stack_set_visible_child_name(op(lanes), name)
        gtk_stack_set_visible_child_name(op(pills), name)
        for (kind, button) in laneButtons {
            if kind == target {
                Gtk.addClass(button, "studio-lane-on")
            } else {
                gtk_widget_remove_css_class(button, "studio-lane-on")
            }
        }
        refreshChrome()
    }

    private func ensureImage() {
        guard drawPane == nil else { return }
        let pane = DrawPane(studio: .shared, fills: true)
        pane.wireChips()
        pane.chrome.surround = StudioSheetMetrics.toolbarHeight
        pane.chrome.onArranged = { [weak self] _, _ in
            Gtk.onMain { [weak self] in self?.layoutPasses += 1 }
        }
        pane.onNotice = { [weak self] text in
            Gtk.onMain { [weak self] in self?.say(text) }
        }
        gtk_stack_add_named(op(lanes), pane.root, StudioLaneKind.image.rawValue)
        gtk_stack_add_named(op(pills), pane.machine.widget, StudioLaneKind.image.rawValue)
        drawPane = pane
    }

    private func ensureForge() {
        guard forgePane == nil else { return }
        let pane = ForgePane()
        pane.chrome.surround = StudioSheetMetrics.toolbarHeight
        pane.chrome.onArranged = { [weak self] _, _ in
            Gtk.onMain { [weak self] in self?.layoutPasses += 1 }
        }
        pane.onChange = { [weak self] in
            Gtk.onMain { [weak self] in self?.refreshChrome() }
        }
        gtk_stack_add_named(op(lanes), pane.root, StudioLaneKind.video.rawValue)
        gtk_stack_add_named(op(pills), pane.machine.widget, StudioLaneKind.video.rawValue)
        forgePane = pane
    }

    /// The panes are views, made when the sheet rises and let go of once it has left. A render is
    /// left exactly where it is, in the studio and the runner, still arriving.
    private func tearDown() {
        if let pane = drawPane {
            drawPane = nil
            gtk_stack_remove(op(lanes), pane.root)
            gtk_stack_remove(op(pills), pane.machine.widget)
            Gtk.onMain { pane.shutdown() }
        }
        if let pane = forgePane {
            forgePane = nil
            pane.stopDrawing()
            gtk_stack_remove(op(lanes), pane.root)
            gtk_stack_remove(op(pills), pane.machine.widget)
            Gtk.onMain { pane.shutdown() }
        }
        noticeEnds = nil
        gtk_label_set_text(op(note), Self.reserved)
    }

    private func focusWords() {
        switch lane {
        case .image: drawPane?.focusPrompt()
        case .video: forgePane?.focusPrompt()
        }
    }

    // MARK: the bar

    /// A file written or a picture copied is worth one line, said under the pill rather than as a
    /// dialog somebody has to dismiss. It clears itself, because a notice that outstays its news
    /// becomes chrome.
    private func say(_ text: String) {
        let ends = Date().addingTimeInterval(4)
        noticeEnds = ends
        gtk_label_set_text(op(note), text)
        Gtk.after(4000) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.noticeEnds == ends else { return }
                self.noticeEnds = nil
                self.refreshChrome()
            }
        }
    }

    /// Whether the lane in front has a render out, which decides what Esc does and what Done says.
    var renderIsOut: Bool {
        switch lane {
        case .image: return ImageStudio.shared.isPainting
        case .video: return ForgeRunner.shared.isRendering
        }
    }

    private func refreshChrome() {
        guard state != .closed else { return }
        if noticeEnds == nil {
            let line: String?
            switch lane {
            case .image: line = ImageGenSurface.dismissNote(painting: ImageStudio.shared.isPainting)
            case .video: line = ForgeSurface.dismissNote(rendering: ForgeRunner.shared.isRendering)
            }
            gtk_label_set_text(op(note), line ?? Self.reserved)
        }
        let count: Int
        switch lane {
        case .image: count = ImageStudio.shared.queueCount
        case .video: count = forgePane?.queueCount ?? 0
        }
        gtk_label_set_text(op(queue), "\(ImageGenMachineWords.queueLabel) \(count)")
        let out = renderIsOut
        gtk_widget_set_tooltip_text(done, out ? StudioSheetWords.escapeHint : StudioSheetWords.closeLabel)
        tailscode_set_accessible_description(done, out ? StudioSheetWords.escapeHint : nil)
    }

    // MARK: the frame

    /// Puts the sheet where Core says it goes for the window it is in. The sheet is allocated at its
    /// final size here, before any motion, and a resize or a maximise lands here again.
    func relayout() {
        let width = Double(gtk_widget_get_width(overlay))
        let height = Double(gtk_widget_get_height(overlay))
        guard width > 0, height > 0 else { return }
        let next = StudioSheetGeometry.frame(
            windowWidth: width, windowHeight: height, titlebar: titlebar())
        guard next != frame || gtk_widget_get_width(sheet) == 0 else { return }
        frame = next
        gtk_widget_set_margin_start(host, Int32(next.x.rounded()))
        gtk_widget_set_margin_top(host, Int32(next.y.rounded()))
        gtk_widget_set_size_request(host, Int32(next.width.rounded()), Int32(next.height.rounded()))
        gtk_widget_set_size_request(sheet, Int32(next.width.rounded()), Int32(next.height.rounded()))
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

    // MARK: the motion

    /// Draws the sheet at a presence between 0 (away) and 1 (at rest) with no clock running, for
    /// the headless driver that photographs the middle of the motion.
    func hold(at presence: Double) {
        if state == .closed { show(lane) }
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
        let link = Link(self, from: from, target: target, opening: opening, span: span, started: Self.now())
        _ = Gtk.releaseInstalled
        tick = tailscode_add_owned_tick(
            host,
            { raw in
                guard let raw else { return 0 }
                let link = Unmanaged<Link>.fromOpaque(raw).takeUnretainedValue()
                guard let sheet = link.sheet else { return 0 }
                return sheet.step(link) ? 1 : 0
            }, Unmanaged.passRetained(link).toOpaque())
    }

    /// What one running motion needs between frames: where it started from and is going, how long
    /// it takes and when it began. The clock holds it, and it holds the sheet only weakly, so a
    /// sheet let go of while its clock runs is a clock that ends on its next frame.
    private final class Link {
        weak var sheet: StudioSheet?
        let from: Double
        let target: Double
        let opening: Bool
        let span: Double
        let started: Double

        init(
            _ sheet: StudioSheet, from: Double, target: Double, opening: Bool, span: Double,
            started: Double
        ) {
            self.sheet = sheet
            self.from = from
            self.target = target
            self.opening = opening
            self.span = span
            self.started = started
        }
    }

    /// One frame of the motion on the display's own clock: the share done follows Core's ease, the
    /// sheet's translation and the scrim's alpha follow the same share, and the frame that reaches
    /// the end settles the state. Returns whether the clock keeps running.
    private func step(_ link: Link) -> Bool {
        let elapsed = Self.now() - link.started
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

    private func stopClock() {
        guard tick != 0 else { return }
        tailscode_remove_tick(host, tick)
        tick = 0
    }

    private static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: the keys

    /// Whether the sheet owns the keyboard: from the first frame of its rise to the moment it
    /// starts to leave.
    var capturesKeys: Bool { state.capturesKeys }

    /// A key while the sheet owns the keyboard. Core's rules come first — Ctrl+W closes the sheet
    /// before the window, Esc stops a render that is out and only then closes — then the lane
    /// switch, the focus trap and the lane's own keys. Nothing is ever handed to the conversation
    /// chord table: an unclaimed key goes on to whatever inside the sheet has focus, and no further.
    func handleKey(keyval: UInt32, state mask: UInt32) -> Bool {
        let inPopover = focusIsInPopover
        if keyval == Keymap.escape, inPopover { return false }
        guard let chord = KeyChord.canonical(keyval: keyval, state: mask) else {
            return handleTab(keyval: keyval, state: mask, inPopover: inPopover)
        }
        if StudioSheetKeys.closes(chord) {
            dismiss()
            return true
        }
        if let target = Self.lane(for: chord) {
            show(target)
            return true
        }
        if keyval == Keymap.tab || keyval == Self.isoLeftTab {
            return handleTab(keyval: keyval, state: mask, inPopover: inPopover)
        }
        switch lane {
        case .image: return drawKey(chord, keyval: keyval)
        case .video: return forgeKey(chord, keyval: keyval)
        }
    }

    /// Ctrl+1 and Ctrl+2: the two lanes, in the order the switch draws them.
    static func lane(for chord: KeyChord) -> StudioLaneKind? {
        guard chord.control, !chord.alt, !chord.shift else { return nil }
        switch chord.keyval {
        case UInt32(UnicodeScalar("1").value): return .image
        case UInt32(UnicodeScalar("2").value): return .video
        default: return nil
        }
    }

    private static let isoLeftTab: UInt32 = 0xFE20

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

    private func drawKey(_ chord: KeyChord, keyval: UInt32) -> Bool {
        guard let pane = drawPane else { return false }
        if Gtk.focusTakesText(window) {
            if let command = ImageGenCommand.command(for: chord), command == .submit, !chord.shift {
                pane.handle(command)
                return true
            }
        } else if let command = ImageGenCommand.command(for: chord) {
            if command == .submit, Gtk.focusIsButton(in: window) { return false }
            pane.handle(command)
            return true
        }
        guard keyval == Keymap.escape else { return false }
        if pane.isZoomed {
            pane.unzoom()
            return true
        }
        return escape()
    }

    private func forgeKey(_ chord: KeyChord, keyval: UInt32) -> Bool {
        guard let pane = forgePane else { return false }
        if pane.handleChord(chord) { return true }
        guard keyval == Keymap.escape else { return false }
        return escape()
    }

    /// Esc: stop the render that is out, or close. Closing never stops a render, so the first press
    /// is not spent on leaving while a picture is still being painted.
    private func escape() -> Bool {
        switch StudioSheetKeys.escape(renderIsOut: renderIsOut) {
        case .stopRender:
            switch lane {
            case .image: drawPane?.handle(.stop)
            case .video: forgePane?.stopRender()
            }
        case .closeSheet:
            dismiss()
        }
        return true
    }

    private var focusIsInPopover: Bool {
        guard let focused = tailscode_focused_widget(window) else { return false }
        return gtk_widget_get_ancestor(focused, gtk_popover_get_type()) != nil
    }

    // MARK: the driver

    var summary: String {
        let kind = lane == .image ? (drawPane?.summary ?? "-") : (forgePane?.summary ?? "-")
        return
            "state=\(state) lane=\(lane.rawValue) frame=\(Int(frame.x)),\(Int(frame.y)) \(Int(frame.width))x\(Int(frame.height)) progress=\(String(format: "%.2f", progress)) scrim=\(String(format: "%.2f", gtk_widget_get_opacity(scrim))) chords=\(state.conversationChordsEnabled) out=\(renderIsOut) \(kind)"
    }

    var imagePane: DrawPane? { drawPane }

    var forge: ForgePane? { forgePane }

    var imageSummary: String { drawPane?.summary ?? "-" }

    var studioSummary: String {
        switch lane {
        case .image: return drawPane?.studioSummary ?? "-"
        case .video: return forgePane?.chrome.summary ?? "-"
        }
    }

    var rewriteSummary: String {
        guard let draft = drawPane?.studio.draft else { return "none" }
        let phase: String
        switch draft.phase {
        case .writing: phase = "writing"
        case .landed: phase = "landed"
        case .failed(let reason): phase = "failed(\(reason))"
        }
        return "\(phase) helper=\(draft.helper.model)@\(draft.helper.displayHost) words=\(draft.words) aspect=\(draft.aspect?.rawValue ?? "-")"
    }

    var arrivalSummary: String { drawPane?.arrivalSummary ?? "-" }

    func driverType(_ text: String) { drawPane?.driverType(text) }

    func driverSubmit() { drawPane?.driverSubmit() }

    func driverAttach(_ path: String) { drawPane?.attachFiles([path]) }

    func driverEnhance() { drawPane?.driverEnhance() }

    func driverUseRewrite() { drawPane?.driverUseRewrite() }

    func demonstrate(_ name: String) { forgePane?.demonstrate(name) }

    func describe(_ text: String) { forgePane?.describe(text) }

    func handleChord(_ chord: KeyChord) -> Bool { forgePane?.handleChord(chord) ?? false }

    func drive(_ verb: String, _ argument: String) {
        guard let pane = forgePane else { return }
        switch verb {
        case "fenhance": pane.driveEnhance()
        case "fuse": pane.driveUseRewrite()
        case "fframe": pane.driveFrame(argument)
        case "fextend": pane.driveExtendNewest()
        case "fsound": pane.driveSound(argument)
        default: break
        }
    }

    var forgeSummary: String { forgePane?.summary ?? "-" }

    /// The parent every dialog the Studio opens names: the one main window.
    var dialogParent: UnsafeMutablePointer<GtkWidget> { window }

    /// What the dock's panes name as their host window, for a harness proving no second toplevel
    /// is involved.
    var paneHosts: [UnsafeMutablePointer<GtkWidget>?] {
        [drawPane?.hostWindow, forgePane?.hostWindow]
    }

    /// Where the sheet's own widgets sit in the window, for a harness that has to click them.
    func bounds(of widget: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let box = Gtk.bounds(of: widget, in: window) else { return "-" }
        return String(format: "%.0f,%.0f %.0fx%.0f", box.x, box.y, box.width, box.height)
    }

    var sheetWidget: UnsafeMutablePointer<GtkWidget> { sheet }

    var doneWidget: UnsafeMutablePointer<GtkWidget> { done }

    var scrimWidget: UnsafeMutablePointer<GtkWidget> { scrim }

    var hostWidget: UnsafeMutablePointer<GtkWidget> { host }
}
