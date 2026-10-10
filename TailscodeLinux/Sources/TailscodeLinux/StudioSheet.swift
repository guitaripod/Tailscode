import CAdw
import CGtkShim
import Foundation
import TailscodeCore

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
        stack.retire()
        if let observer = imageObserver { NotificationCenter.default.removeObserver(observer) }
        imageObserver = nil
        tearDown()
    }

    /// The sheets of the window this one stands in, which a media viewer opened from the Studio
    /// stands on top of.
    let stack: SheetStack
    private let layer: SheetLayer
    private let window: UnsafeMutablePointer<GtkWidget>
    private let lanes = gtk_stack_new()!
    private let pills = gtk_stack_new()!
    private let note = Gtk.label("", css: "studio-note", selectable: false)
    private let queue = Gtk.label("", css: "studio-queue", selectable: false)
    private let done: UnsafeMutablePointer<GtkWidget>
    private var laneButtons: [StudioLaneKind: UnsafeMutablePointer<GtkWidget>] = [:]

    var state: StudioSheetState { layer.state }
    private(set) var lane: StudioLaneKind = .image
    var frame: StudioSheetFrame { layer.frame }
    var progress: Double { layer.progress }

    private var wantedLane: StudioLaneKind = .image
    private var drawPane: DrawPane?
    private var forgePane: ForgePane?
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
        self.window = window
        stack = SheetStack(overlay: overlay, content: content, window: window, titlebar: titlebar)
        layer = stack.layers[0]
        done = Gtk.button(Localized.text("Done"), css: ["studio-done"], onClick: {})
        build()
        Self.installed = self
    }

    private func build() {
        layer.name = "studio"
        layer.setDialogName(StudioSheetWords.dialogName)
        layer.detail = { [weak self] in self?.wantedLane.rawValue ?? "" }
        layer.onRise = { [weak self] in self?.onRise?() }
        layer.prepare = { [weak self] in
            guard let self else { return }
            if self.wantedLane == .image { ImageStudio.shared.adoptDoor() }
            self.select(self.wantedLane)
        }
        layer.retarget = { [weak self] in
            guard let self else { return }
            self.select(self.wantedLane)
            self.focusWords()
        }
        layer.focusInitial = { [weak self] in self?.focusWords() }
        layer.onClosed = { [weak self] in self?.tearDown() }
        layer.keys = { [weak self] keyval, state in
            self?.handleKey(keyval: keyval, state: state) ?? false
        }

        gtk_stack_set_transition_type(op(lanes), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_hhomogeneous(op(lanes), 0)
        gtk_stack_set_vhomogeneous(op(lanes), 0)
        gtk_widget_set_hexpand(lanes, 1)
        gtk_widget_set_vexpand(lanes, 1)
        layer.install(toolbar: makeToolbar(), body: lanes)

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
                Gtk.onMain { [weak self] in
                    AppLog.write(.ui, "studio sheet lane switch pressed lane=\(kind.rawValue)")
                    self?.show(kind)
                }
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

    /// Brings the Studio up on a lane. Opened while it is already up it only changes lane, with no
    /// motion, and the words box takes the keyboard. A viewer standing on it steps off first.
    @discardableResult
    func show(_ lane: StudioLaneKind) -> StudioSheet {
        wantedLane = lane
        stack.closeViewer()
        layer.present()
        return self
    }

    /// Takes the sheet away by the same motion it came by, from wherever it is. A viewer standing on
    /// it goes at once, so nothing is left hanging over a Studio that has left.
    func dismiss() {
        stack.closeViewer()
        layer.dismiss()
    }

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

    /// Puts the sheet where Core says it goes for the window it is in.
    func relayout() {
        layer.relayout()
    }

    /// The face of the app the scrim is drawn over, as the desktop resolves it.
    var appearance: StudioSheetAppearance { layer.appearance }

    /// The appearance changed while the sheet was up: the scrim re-resolves to the other face's alpha.
    func rethemed() {
        layer.rethemed()
    }

    /// Draws the sheet at a presence between 0 (away) and 1 (at rest) with no clock running, for
    /// the headless driver that photographs the middle of the motion.
    func hold(at presence: Double) {
        if state == .closed { show(lane) }
        layer.hold(at: presence)
    }

    /// Lets a held sheet carry on to rest.
    func release() {
        layer.release()
    }

    /// Whether the sheet owns the keyboard: from the first frame of its rise to the moment it
    /// starts to leave.
    var capturesKeys: Bool { state.capturesKeys }

    /// A key while the sheet owns the keyboard. Core's rules come first — Ctrl+W closes the sheet
    /// before the window, Esc stops a render that is out and only then closes — then the lane
    /// switch, the focus trap and the lane's own keys. Nothing is ever handed to the conversation
    /// chord table: an unclaimed key goes on to whatever inside the sheet has focus, and no further.
    func handleKey(keyval: UInt32, state mask: UInt32) -> Bool {
        layer.route(
            keyval: keyval, state: mask,
            before: { chord in
                guard let target = Self.lane(for: chord) else { return false }
                AppLog.write(.ui, "studio sheet lane chord lane=\(target.rawValue)")
                show(target)
                return true
            },
            after: { chord, keyval in
                switch lane {
                case .image: return drawKey(chord, keyval: keyval)
                case .video: return forgeKey(chord, keyval: keyval)
                }
            })
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

    var summary: String {
        let kind = lane == .image ? (drawPane?.summary ?? "-") : (forgePane?.summary ?? "-")
        return
            "state=\(state) lane=\(lane.rawValue) frame=\(Int(frame.x)),\(Int(frame.y)) \(Int(frame.width))x\(Int(frame.height)) progress=\(String(format: "%.2f", progress)) scrim=\(String(format: "%.2f", layer.scrimOpacity)) chords=\(state.conversationChordsEnabled) out=\(renderIsOut) \(kind)"
    }

    var imagePane: DrawPane? { drawPane }

    var forge: ForgePane? { forgePane }

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

    var sheetWidget: UnsafeMutablePointer<GtkWidget> { layer.sheetWidget }

    var scrimWidget: UnsafeMutablePointer<GtkWidget> { layer.scrimWidget }

    var hostWidget: UnsafeMutablePointer<GtkWidget> { layer.hostWidget }
}
