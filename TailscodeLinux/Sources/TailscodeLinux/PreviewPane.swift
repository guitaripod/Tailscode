import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A running iOS app living inside the split tree: a Mac's simulator, streamed picture by picture
/// by a preview host and drawn in the pane the way a page or a stream is. The pane is a skin over
/// ``PreviewSlot`` and ``PreviewRunner``; every word on it is Core's and every fact comes from the
/// runner's two latest-wins mailboxes, which one frame tick drains.
///
/// The tick exists only while there is something to drain. The runner wakes it when a picture or a
/// state lands, it decodes the newest picture and no more than one per tick, and it takes itself
/// off the frame clock the moment both mailboxes are clean — so a pane showing a still screen owns
/// no clock at all, and a parked or shut-down pane owns neither a clock nor a stream.
final class PreviewPane: @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private(set) var slot: PreviewSlot
    let fixedHost: String?

    var onChange: (@Sendable () -> Void)?
    var onAskAgent: (@Sendable (String) -> Void)?

    private enum Face: String {
        case ask, setup, status, live
    }

    private let secrets: any SecretStore = FileSecretStore()
    private let lifetime = PaneLifetime()
    private let clock = PreviewClock()
    private var runner: PreviewRunner?
    private var probeTask: Task<Void, Never>?
    private var tick: UInt = 0
    private var lastDecodedAt = 0
    private var isParked = false
    private var isShutDown = false
    private var announced = ""

    private var jpeg: Data?
    private var pictureSize: (width: Int, height: Int)?

    private let faces = gtk_stack_new()!
    private(set) var lenses: PreviewLenses!

    private let askBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
    private let hostEntry = gtk_entry_new()!
    private let folderEntry = gtk_entry_new()!
    private let passwordEntry = gtk_entry_new()!
    private let reasonLabel = Gtk.label("", css: "dim", wrap: true, selectable: false)
    private let hostLabel = Gtk.label("", css: "dim", selectable: false)

    private let setupHeading = Gtk.label("", css: "video-heading", wrap: true, selectable: false)
    private let checklist = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private var drawnChecklist: [PreviewChecklistRow] = []

    private let statusLabel = Gtk.label("", css: "preview-status", wrap: true, selectable: false)
    private let retryPassword = gtk_entry_new()!
    private let statusBanner = PreviewBanner()

    private let picture = gtk_picture_new()!
    private let frame = gtk_aspect_frame_new(0.5, 0.5, 0.5, 0)!
    private let reconnectChip = Gtk.label("", css: "preview-chip", selectable: false)
    private let banner = PreviewBanner()
    private let lightChip: UnsafeMutablePointer<GtkWidget>
    private let darkChip: UnsafeMutablePointer<GtkWidget>
    private let copyChip: UnsafeMutablePointer<GtkWidget>
    private let touchChip: UnsafeMutablePointer<GtkWidget>
    private let homeChip: UnsafeMutablePointer<GtkWidget>
    private let keysChip: UnsafeMutablePointer<GtkWidget>
    private let touchGroup = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 4)
    private let touchNote = Gtk.label("", css: "preview-chip", selectable: false)
    private let touchLayer = PreviewTouchLayer()
    private var touchOn = PreviewTouchPreference.isOn()
    private(set) var keysOn = false
    private var touchUnsupported = false
    private var noteTicket = 0
    private var shownSurface: PreviewTouchSurface?

    init(target: PreviewTarget?, fixedHost: String? = nil, runs: Bool = true) {
        slot = PreviewSlot(target: target)
        self.fixedHost = fixedHost
        lightChip = Gtk.button(Localized.text("Light"), css: ["preview-chip"]) {}
        darkChip = Gtk.button(Localized.text("Dark"), css: ["preview-chip"]) {}
        copyChip = Gtk.button(Localized.text("Copy picture"), css: ["preview-chip"]) {}
        touchChip = Gtk.button(Localized.text("Touch"), css: ["preview-chip"]) {}
        homeChip = Gtk.button(Localized.text("Home"), css: ["preview-chip"]) {}
        keysChip = Gtk.button(Localized.text("Keys"), css: ["preview-chip"]) {}
        clock.pane = self
        buildRoot()
        wireControls()
        if let target {
            runsRunner = runs
            if runs { startRunner(for: target) }
        }
        render()
    }

    deinit {
        liftTick()
    }

    private var runsRunner = true

    var target: PreviewTarget? { slot.target }
    var isAsking: Bool { slot.isAsking }

    private func buildRoot() {
        Gtk.addClass(root, "canvas")
        Gtk.addClass(root, "preview-pane")
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)
        gtk_widget_set_hexpand(faces, 1)
        gtk_widget_set_vexpand(faces, 1)
        gtk_stack_set_transition_type(op(faces), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_hhomogeneous(op(faces), 0)
        gtk_stack_set_vhomogeneous(op(faces), 0)
        gtk_stack_add_named(op(faces), buildAsk(), Face.ask.rawValue)
        gtk_stack_add_named(op(faces), buildSetup(), Face.setup.rawValue)
        gtk_stack_add_named(op(faces), buildStatus(), Face.status.rawValue)
        gtk_stack_add_named(op(faces), buildLive(), Face.live.rawValue)
        gtk_box_append(ptr(root), faces)
    }

    private func buildAsk() -> UnsafeMutablePointer<GtkWidget> {
        gtk_widget_set_valign(askBox, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(askBox, GTK_ALIGN_CENTER)
        Gtk.margins(askBox, 24)
        let heading = Gtk.label(Localized.text("Preview"), css: "video-heading", selectable: false)
        gtk_entry_set_placeholder_text(ptr(hostEntry), Localized.text("Address of the Mac"))
        gtk_entry_set_placeholder_text(ptr(folderEntry), slot.prompt)
        gtk_entry_set_visibility(ptr(passwordEntry), 0)
        gtk_entry_set_placeholder_text(ptr(passwordEntry), Localized.text("Password"))
        for field in [hostEntry, folderEntry, passwordEntry] {
            Gtk.addClass(field, "preview-entry")
            gtk_widget_set_size_request(field, 260, -1)
            Gtk.connect(UnsafeMutableRawPointer(field), "activate") { [weak self] in
                self?.submit()
            }
        }
        gtk_widget_set_visible(passwordEntry, 0)
        gtk_widget_set_visible(reasonLabel, 0)
        let hint = Gtk.label(slot.hint, css: "dim", wrap: true, selectable: false)
        Self.capWidth(hint, 40)
        Self.capWidth(reasonLabel, 40)
        if let fixedHost {
            gtk_label_set_text(op(hostLabel), PreviewAccessStore.access(host: fixedHost)?.label ?? fixedHost)
            gtk_widget_set_visible(hostEntry, 0)
        } else {
            gtk_widget_set_visible(hostLabel, 0)
            let known = PreviewAccessStore.all()
            if known.count == 1, let only = known.first { gtk_editable_set_text(op(hostEntry), only.host) }
        }
        for child in [heading, hostLabel, hostEntry, folderEntry, passwordEntry, reasonLabel, hint] {
            gtk_box_append(ptr(askBox), child)
        }
        return askBox
    }

    private func buildSetup() -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 14)
        gtk_widget_set_halign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(column, 1)
        Gtk.margins(column, 24)
        Self.capWidth(setupHeading, 30)
        gtk_box_append(ptr(column), setupHeading)
        gtk_box_append(ptr(column), checklist)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_EXTERNAL, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(scroller), column)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 0)
        return scroller
    }

    private func buildStatus() -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
        gtk_widget_set_halign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(column, 260, -1)
        Gtk.margins(column, 24)
        Self.capWidth(statusLabel, 40)
        gtk_label_set_justify(op(statusLabel), GTK_JUSTIFY_CENTER)
        gtk_label_set_xalign(op(statusLabel), 0.5)
        gtk_entry_set_visibility(ptr(retryPassword), 0)
        gtk_entry_set_placeholder_text(ptr(retryPassword), Localized.text("Password"))
        Gtk.addClass(retryPassword, "preview-entry")
        gtk_widget_set_visible(retryPassword, 0)
        Gtk.connect(UnsafeMutableRawPointer(retryPassword), "activate") { [weak self] in
            self?.retryWithPassword()
        }
        gtk_box_append(ptr(column), statusLabel)
        gtk_box_append(ptr(column), retryPassword)
        gtk_box_append(ptr(column), statusBanner.widget)
        statusBanner.onAsk = { [weak self] in self?.askAgent() }
        return column
    }

    private func buildLive() -> UnsafeMutablePointer<GtkWidget> {
        let look = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(look, 1)
        gtk_widget_set_vexpand(look, 1)
        let stage = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(stage, 1)
        gtk_widget_set_vexpand(stage, 1)
        gtk_box_append(ptr(look), stage)
        let context = PreviewLensContext(
            runner: { [weak self] in self?.runner }, livePicture: { [weak self] in self?.jpeg },
            ask: { [weak self] words in self?.onAskAgent?(words) }, tasks: LensTasks())
        let inspecting = PreviewInspectModel(context: context)

        gtk_picture_set_content_fit(op(picture), GTK_CONTENT_FIT_FILL)
        gtk_picture_set_can_shrink(op(picture), 1)
        gtk_widget_set_hexpand(picture, 1)
        gtk_widget_set_vexpand(picture, 1)

        let overlay = gtk_overlay_new()!
        Gtk.addClass(overlay, "preview-picture")
        gtk_widget_set_overflow(overlay, GTK_OVERFLOW_HIDDEN)
        gtk_overlay_set_child(op(overlay), picture)
        gtk_overlay_add_overlay(op(overlay), inspecting.outline)
        touchLayer.pictureSize = { [weak self] in self?.pictureSize }
        touchLayer.onNote = { [weak self] words in
            Gtk.onMain { [weak self] in self?.showTouchNote(words) }
        }
        touchLayer.onUnsupported = { [weak self] in
            Gtk.onMain { [weak self] in
                self?.touchUnsupported = true
                self?.refreshTouch()
            }
        }
        gtk_overlay_add_overlay(op(overlay), touchLayer.widget)

        gtk_widget_set_halign(touchNote, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(touchNote, GTK_ALIGN_START)
        gtk_widget_set_margin_top(touchNote, 48)
        gtk_widget_set_visible(touchNote, 0)
        gtk_overlay_add_overlay(op(overlay), touchNote)

        gtk_widget_set_halign(reconnectChip, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(reconnectChip, GTK_ALIGN_START)
        gtk_widget_set_margin_top(reconnectChip, 12)
        gtk_widget_set_visible(reconnectChip, 0)
        gtk_overlay_add_overlay(op(overlay), reconnectChip)

        gtk_widget_set_halign(banner.widget, GTK_ALIGN_FILL)
        gtk_widget_set_valign(banner.widget, GTK_ALIGN_END)
        gtk_widget_set_margin_start(banner.widget, 10)
        gtk_widget_set_margin_end(banner.widget, 10)
        gtk_widget_set_margin_bottom(banner.widget, 10)
        gtk_overlay_add_overlay(op(overlay), banner.widget)
        banner.onAsk = { [weak self] in self?.askAgent() }

        gtk_widget_set_hexpand(frame, 1)
        gtk_widget_set_vexpand(frame, 1)
        Gtk.margins(frame, top: 14, bottom: 6, leading: 14, trailing: 14)
        gtk_aspect_frame_set_child(op(frame), overlay)
        gtk_box_append(ptr(stage), frame)

        let chips = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(chips, GTK_ALIGN_CENTER)
        Gtk.margins(chips, top: 4, bottom: 12, leading: 12, trailing: 12)
        let appearance = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 4)
        gtk_box_append(ptr(appearance), lightChip)
        gtk_box_append(ptr(appearance), darkChip)
        gtk_box_append(ptr(chips), appearance)
        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 4)
        gtk_box_append(ptr(actions), Gtk.button(Localized.text("Rebuild"), css: ["preview-chip"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.rebuild() }
        })
        gtk_box_append(ptr(actions), copyChip)
        gtk_box_append(ptr(chips), actions)
        for chip in [touchChip, homeChip, keysChip] { gtk_box_append(ptr(touchGroup), chip) }
        gtk_widget_set_visible(touchGroup, 0)
        gtk_box_append(ptr(chips), touchGroup)
        for group in [appearance, actions, touchGroup] { gtk_widget_set_halign(group, GTK_ALIGN_CENTER) }
        gtk_box_append(ptr(stage), chips)
        let lenses = PreviewLenses(look: look, stageChips: chips, context: context, inspect: inspecting)
        self.lenses = lenses
        lenses.onLensChanged = { [weak self] in self?.refreshTouch() }
        return lenses.root
    }

    private func wireControls() {
        Gtk.connect(UnsafeMutableRawPointer(lightChip), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.choose(appearance: "light") }
        }
        Gtk.connect(UnsafeMutableRawPointer(darkChip), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.choose(appearance: "dark") }
        }
        Gtk.connect(UnsafeMutableRawPointer(copyChip), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.copyPicture() }
        }
        Gtk.connect(UnsafeMutableRawPointer(touchChip), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.toggleTouch() }
        }
        Gtk.connect(UnsafeMutableRawPointer(homeChip), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.pressHome() }
        }
        Gtk.connect(UnsafeMutableRawPointer(keysChip), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.setKeys(!(self?.keysOn ?? false)) }
        }
        for (chip, name) in [(touchChip, "Touch"), (homeChip, "Home"), (keysChip, "Keys")] {
            tailscode_set_accessible_label(chip, Localized.text(name))
        }
        paintTouchChips()
    }

    func focusPrompt() {
        guard slot.isAsking else { return }
        gtk_widget_grab_focus(fixedHost == nil ? hostEntry : folderEntry)
    }

    /// One line for the headless driver and the selftest: the phase, then what the pane shows.
    var summary: String {
        let size = pictureSize.map { " \($0.width)x\($0.height)" } ?? ""
        guard !slot.isAsking else { return "asking" }
        let state = slot.state
        switch face {
        case .ask: return "asking"
        case .setup: return "settingUp rows=\(slot.checklist.count)"
        case .status:
            if state.light == .broken { return "broken banner=\(statusBanner.problem)" }
            return "\(phaseWord(state.phase)) [\(state.line)]"
        case .live:
            if state.light == .broken { return "broken\(size) banner=\(banner.problem)" }
            return "\(phaseWord(state.phase))\(size)"
        }
    }

    private func phaseWord(_ phase: PreviewPhase) -> String {
        switch phase {
        case .connecting: return "connecting"
        case .settingUp: return "settingUp"
        case .starting: return "starting"
        case .live: return "live"
        case .reconnecting: return "reconnecting"
        case .failed: return "failed"
        }
    }

    var lastPictureJPEG: Data? { jpeg }
    var hasTick: Bool { tick != 0 }
    var isRunning: Bool { runner != nil && !isParked && !isShutDown }

    private var face: Face {
        if slot.isAsking { return .ask }
        let state = slot.state
        switch state.phase {
        case .settingUp: return .setup
        case .connecting: return .status
        case .starting, .live, .reconnecting: return pictureSize == nil ? .status : .live
        case .failed: return pictureSize != nil && state.session != nil ? .live : .status
        }
    }

    private func render() {
        let showing = face
        gtk_stack_set_visible_child_name(op(faces), showing.rawValue)
        switch showing {
        case .ask: break
        case .setup: renderSetup()
        case .status: renderStatus()
        case .live: renderLive()
        }
        announceIfChanged()
    }

    private func announceIfChanged() {
        let line = "\(slot.title)|\(slot.subtitle)|\(slot.light)|\(slot.target?.address ?? "")"
        guard line != announced else { return }
        announced = line
        onChange?()
    }

    private func renderSetup() {
        gtk_label_set_text(op(setupHeading), slot.state.line)
        let rows = slot.checklist
        guard rows != drawnChecklist else { return }
        drawnChecklist = rows
        Gtk.removeChildren(of: checklist)
        for row in rows { gtk_box_append(ptr(checklist), rowWidget(row)) }
    }

    private func rowWidget(_ row: PreviewChecklistRow) -> UnsafeMutablePointer<GtkWidget> {
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        Gtk.addClass(line, "preview-row")
        let glyph = Gtk.label(glyph(for: row.state), css: glyphClass(for: row.state), selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        gtk_widget_set_size_request(glyph, 18, -1)
        gtk_box_append(ptr(line), glyph)

        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(words, 1)
        let title = Gtk.label(row.title, css: "preview-row-title", wrap: true, selectable: false)
        Self.capWidth(title, 40)
        gtk_box_append(ptr(words), title)
        if let detail = row.detail {
            let detailLabel = Gtk.label(detail, css: "preview-row-detail", wrap: true, selectable: true)
            Self.capWidth(detailLabel, 44)
            gtk_box_append(ptr(words), detailLabel)
        }
        if row.working || row.state == .working, let progress = row.progress {
            let bar = gtk_progress_bar_new()!
            gtk_progress_bar_set_fraction(op(bar), min(1, max(0, progress)))
            Gtk.addClass(bar, "preview-progress")
            gtk_widget_set_margin_top(bar, 4)
            gtk_box_append(ptr(words), bar)
        }
        gtk_box_append(ptr(line), words)

        if row.state == .fixable, !row.working, let fix = row.fix {
            let button = Gtk.button(row.fixLabel ?? Localized.text("Fix it"), css: ["preview-chip"]) {
                [weak self] in
                Gtk.onMain { [weak self] in self?.runner?.runFix(fix) }
            }
            gtk_widget_set_valign(button, GTK_ALIGN_START)
            gtk_box_append(ptr(line), button)
        }
        return line
    }

    static func capWidth(_ label: UnsafeMutablePointer<GtkWidget>, _ characters: Int32) {
        gtk_label_set_max_width_chars(op(label), characters)
    }

    private func glyph(for state: DoctorCheck.State) -> String {
        switch state {
        case .ok: return "✓"
        case .working: return "…"
        case .needsYou: return "!"
        case .fixable: return "•"
        case .failed: return "✕"
        }
    }

    private func glyphClass(for state: DoctorCheck.State) -> String {
        switch state {
        case .ok: return "preview-ok"
        case .working, .fixable: return "dim"
        case .needsYou: return "preview-attention"
        case .failed: return "preview-bad"
        }
    }

    private func renderStatus() {
        let state = slot.state
        gtk_label_set_text(op(statusLabel), state.line)
        gtk_widget_set_visible(retryPassword, state.needsPassword ? 1 : 0)
        let broken = state.light == .broken
        gtk_widget_set_visible(statusBanner.widget, broken ? 1 : 0)
        if broken { statusBanner.show(headline: headline(of: state), problem: state.firstProblem) }
    }

    private func renderLive() {
        let state = slot.state
        let stale = state.phase == .reconnecting
        let changing = state.phase == .starting
        gtk_widget_set_opacity(picture, stale || changing ? 0.55 : 1)
        gtk_widget_set_visible(reconnectChip, stale || changing ? 1 : 0)
        gtk_label_set_text(op(reconnectChip), stale ? PreviewLight.stale.line : state.line)
        let broken = state.light == .broken
        gtk_widget_set_visible(banner.widget, broken ? 1 : 0)
        if broken { banner.show(headline: headline(of: state), problem: state.firstProblem) }
        renderAppearance()
        refreshTouch()
    }

    private func renderAppearance() {
        let dark = slot.appearance == "dark"
        Gtk.setTone(lightChip, dark ? nil : "preview-chip-on", from: ["preview-chip-on"])
        Gtk.setTone(darkChip, dark ? "preview-chip-on" : nil, from: ["preview-chip-on"])
    }

    private func headline(of state: PreviewState) -> String {
        state.lastBuild.map(PreviewReading.headline(of:)) ?? state.line
    }

    /// Picks a lens, when the pane is showing a picture to read another way. False otherwise, so
    /// a digit typed over the setup checklist is left for the window to use.
    @discardableResult
    func chooseLens(_ lens: PreviewLens) -> Bool {
        guard !slot.isAsking, face == .live else { return false }
        return lenses.select(lens)
    }

    func retheme() {
        lenses.retheme()
        touchLayer.retheme()
    }

    /// Lets go of what a lens has pinned on the picture. False when nothing was pinned.
    @discardableResult
    func escape() -> Bool {
        guard !slot.isAsking else { return false }
        return lenses.escape()
    }

    /// What the touch controls show and do right now, from the host's word on touch, the lens and
    /// the person's choice. Core decides; the pane draws it.
    var touchSurface: PreviewTouchSurface {
        PreviewTouchSurface.read(
            acceptsTouch: slot.state.acceptsTouch, unsupported: touchUnsupported, phase: slot.state.phase,
            lens: lenses?.current ?? .look, touchOn: touchOn)
    }

    private func refreshTouch() {
        guard !isParked, !isShutDown else { return }
        let surface = touchSurface
        if keysOn && !surface.keysSurvive { setKeys(false) }
        guard surface != shownSurface else { return }
        shownSurface = surface
        gtk_widget_set_visible(touchGroup, surface.showsChips ? 1 : 0)
        lenses?.setTouchChips(shown: surface.showsChips)
        gtk_widget_set_sensitive(homeChip, surface.homeEnabled ? 1 : 0)
        touchLayer.setOperating(surface.pointerOperates)
        paintTouchChips()
    }

    private func letGoOfTouch() {
        touchLayer.suspend()
        shownSurface = nil
        setKeys(false)
    }

    private func toggleTouch() {
        touchOn.toggle()
        PreviewTouchPreference.set(touchOn)
        refreshTouch()
        paintTouchChips()
    }

    private func pressHome() {
        guard touchSurface.homeEnabled else { return }
        touchLayer.pressHome()
    }

    func setKeys(_ on: Bool) {
        guard on != keysOn else { return }
        guard !on || touchSurface.keysSurvive else { return }
        keysOn = on
        if !on { touchLayer.flushTypingNow() }
        paintTouchChips()
    }

    /// Takes a key while Keys is on. False for a chord that belongs to the window.
    func forwardKey(_ chord: KeyChord) -> Bool {
        guard keysOn, let action = PreviewKeyReading.action(for: chord) else { return false }
        switch action {
        case .type(let character): touchLayer.type(character)
        case .key(let name): touchLayer.press(key: name)
        case .stopKeys: setKeys(false)
        case .cannotType: showTouchNote(PreviewKeyReading.cannotTypeWords)
        }
        return true
    }

    private func paintTouchChips() {
        Gtk.setTone(touchChip, touchOn ? "preview-chip-on" : nil, from: ["preview-chip-on"])
        Gtk.setTone(keysChip, keysOn ? "preview-chip-on" : nil, from: ["preview-chip-on"])
        tailscode_set_accessible_pressed(touchChip, touchOn ? 1 : 0)
        tailscode_set_accessible_pressed(keysChip, keysOn ? 1 : 0)
        gtk_widget_set_tooltip_text(
            touchChip,
            touchOn
                ? Localized.text("The pointer operates the app. Press to only watch.")
                : Localized.text("The pointer only watches. Press to operate the app."))
        gtk_widget_set_tooltip_text(homeChip, Localized.text("Send the Home button to the app"))
        gtk_widget_set_tooltip_text(
            keysChip,
            keysOn
                ? Localized.text("Keys are going to the app. Press Esc to stop.")
                : Localized.text("Type into the app with the keyboard. Esc stops."))
    }

    private func showTouchNote(_ words: String) {
        gtk_label_set_text(op(touchNote), words)
        gtk_widget_set_visible(touchNote, 1)
        noteTicket += 1
        let ticket = noteTicket
        Gtk.after(4000) { [weak self] in
            guard let self, ticket == self.noteTicket else { return }
            gtk_widget_set_visible(self.touchNote, 0)
        }
    }

    var touchNoteText: String? {
        gtk_widget_get_visible(touchNote) != 0 ? gtk_label_get_text(op(touchNote)).map(String.init(cString:)) : nil
    }

    var touchChipsShown: Bool { gtk_widget_get_visible(touchGroup) != 0 }
    var touchTasks: Int { touchLayer.activeTasks }
    var touchIsOn: Bool { touchOn }
    var touchLayerView: PreviewTouchLayer { touchLayer }
    var touchChipWidgets: (touch: UnsafeMutablePointer<GtkWidget>, home: UnsafeMutablePointer<GtkWidget>, keys: UnsafeMutablePointer<GtkWidget>) {
        (touchChip, homeChip, keysChip)
    }

    func useTouchSink(_ sink: PreviewTouchSink?) {
        touchLayer.setSink(sink)
    }

    func toggleTouchForTest() {
        toggleTouch()
    }

    func pressHomeForTest() {
        pressHome()
    }

    var lens: PreviewLens { lenses.current }
    var lensSummary: String { lenses.summary }
    var lensTasks: Int { lenses.activeTasks + touchLayer.activeTasks }

    func driveLens(_ command: String) -> Bool {
        lenses.drive(command)
    }

    func handle(_ command: PreviewCommand) {
        guard !slot.isAsking else { return }
        switch command {
        case .toggleAppearance: choose(appearance: slot.nextAppearance)
        case .rebuild: rebuild()
        case .copyPicture: copyPicture()
        }
    }

    private func choose(appearance: String) {
        guard appearance != slot.appearance else { return }
        slot.appearance = appearance
        runner?.setAppearance(appearance)
        renderAppearance()
    }

    private func rebuild() {
        runner?.rebuild()
    }

    private func copyPicture() {
        guard let jpeg else { return }
        jpeg.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            tailscode_clipboard_set_image_png(base, gsize(jpeg.count))
        }
    }

    private func askAgent() {
        let problem = slot.state.firstProblem ?? slot.state.line
        let words = Localized.text(
            "The preview of %@ would not build. The first problem is: %@. Please fix it.",
            slot.target?.appName ?? slot.title, problem)
        onAskAgent?(words)
    }

    func submit() {
        let typedHost = fixedHost ?? text(of: hostEntry)
        let folder = text(of: folderEntry)
        guard !typedHost.isEmpty else {
            gtk_widget_grab_focus(hostEntry)
            return
        }
        guard !folder.isEmpty else {
            gtk_widget_grab_focus(folderEntry)
            return
        }
        let (host, typedPort) = Self.split(typedHost)
        let remembered = PreviewAccessStore.access(host: host)
        let access = PreviewAccess(
            host: host, port: typedPort ?? remembered?.port ?? PreviewAccess(host: host).port,
            name: remembered?.name)
        let typedPassword = gtk_editable_get_text(op(passwordEntry)).map(String.init(cString:)) ?? ""
        let stored = (try? secrets.value(for: access.secretKey)) ?? nil
        let password = typedPassword.isEmpty ? stored : typedPassword
        show(reason: PreviewReach.checking.line)
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            let reach = await PreviewProbe.probe(access, password: password)
            Gtk.onMain { [weak self] in
                self?.probed(reach, access: access, folder: folder, typedPassword: typedPassword)
            }
        }
    }

    static func split(_ address: String) -> (host: String, port: Int?) {
        let parts = address.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let port = Int(parts[1]) else {
            return (address.trimmingCharacters(in: CharacterSet(charactersIn: ":")), nil)
        }
        return (parts[0], port)
    }

    private func probed(_ reach: PreviewReach, access: PreviewAccess, folder: String, typedPassword: String) {
        guard !isShutDown, slot.isAsking else { return }
        guard reach.isAnswering else {
            show(reason: reach.line)
            if reach.asksForPassword {
                gtk_widget_set_visible(passwordEntry, 1)
                gtk_widget_grab_focus(passwordEntry)
            }
            return
        }
        PreviewAccessStore.remember(access)
        if !typedPassword.isEmpty { try? secrets.setValue(typedPassword, for: access.secretKey) }
        show(reason: nil)
        point(at: PreviewTarget(host: access.host, port: access.port, project: folder))
    }

    private func show(reason: String?) {
        gtk_widget_set_visible(reasonLabel, reason == nil ? 0 : 1)
        gtk_label_set_text(op(reasonLabel), reason ?? "")
    }

    private func text(of entry: UnsafeMutablePointer<GtkWidget>) -> String {
        (gtk_editable_get_text(op(entry)).map(String.init(cString:)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func retryWithPassword() {
        guard let target = slot.target else { return }
        let typed = gtk_editable_get_text(op(retryPassword)).map(String.init(cString:)) ?? ""
        guard !typed.isEmpty else { return }
        try? secrets.setValue(typed, for: target.access.secretKey)
        gtk_editable_set_text(op(retryPassword), "")
        point(at: target)
    }

    func point(at target: PreviewTarget) {
        endRun()
        slot.point(at: target)
        resetPicture()
        startRunner(for: target)
        render()
    }

    func ask() {
        endRun()
        slot.ask()
        resetPicture()
        gtk_editable_set_text(op(folderEntry), slot.draft)
        render()
        focusPrompt()
    }

    private func startRunner(for target: PreviewTarget) {
        guard runsRunner else { return }
        let password = (try? secrets.value(for: target.access.secretKey)) ?? nil
        guard let config = target.access.config(password: password) else {
            var failed = PreviewState()
            failed.phase = .failed(PreviewReach.unreachable(target.access.address).line)
            slot.apply(failed)
            return
        }
        let runner = PreviewRunner(target: target, config: config, clock: clock)
        self.runner = runner
        touchLayer.setSink { try await runner.sendTouch($0) }
        guard !isParked, !isShutDown else { return }
        begin(runner)
    }

    private func begin(_ runner: PreviewRunner) {
        runner.start()
        lifetime.add { runner.stop() }
        lifetime.add { [weak self] in self?.liftTick() }
        arm()
    }

    private func endRun() {
        lifetime.cancelAll()
        letGoOfTouch()
        touchLayer.setSink(nil)
        touchUnsupported = false
        lenses.reset()
        runner = nil
    }

    func park() {
        guard !isParked else { return }
        isParked = true
        lifetime.cancelAll()
        letGoOfTouch()
        lenses.suspend()
        probeTask?.cancel()
    }

    func unpark() {
        guard isParked else { return }
        isParked = false
        refreshTouch()
        guard !isShutDown, let runner else { return }
        begin(runner)
        lenses.resume()
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        probeTask?.cancel()
        probeTask = nil
        lifetime.cancelAll()
        letGoOfTouch()
        touchLayer.setSink(nil)
        lenses.suspend()
        runner = nil
        clock.pane = nil
    }

    /// The window's keyboard went to another pane: this one stops forwarding keys.
    func focusLost() {
        setKeys(false)
    }

    fileprivate func wake() {
        guard runner != nil else { return }
        arm()
    }

    private func arm() {
        guard tick == 0, runner != nil, !isParked, !isShutDown else { return }
        g_object_ref(UnsafeMutableRawPointer(root))
        tick = UInt(
            tailscode_add_tick(
                root,
                { raw in
                    guard let raw else { return }
                    Unmanaged<PreviewPane>.fromOpaque(raw).takeUnretainedValue().step()
                }, Unmanaged.passUnretained(self).toOpaque()))
        if tick == 0 { g_object_unref(UnsafeMutableRawPointer(root)) }
    }

    private func liftTick() {
        guard tick != 0 else { return }
        tailscode_remove_tick(root, guint(tick))
        tick = 0
        g_object_unref(UnsafeMutableRawPointer(root))
    }

    private static let decodeInterval = 33_000

    /// One frame of the pane's whole work: the newest state, then the newest picture if the last
    /// decode is old enough, then the clock off the display again once nothing is waiting.
    private func step() {
        guard let runner else {
            liftTick()
            return
        }
        if let state = runner.states.take() { apply(state) }
        let now = g_get_monotonic_time()
        if runner.pictures.isDirty, now - lastDecodedAt >= Self.decodeInterval,
            let newest = runner.pictures.take()
        {
            lastDecodedAt = now
            adopt(newest.jpeg)
        }
        if !runner.states.isDirty, !runner.pictures.isDirty { liftTick() }
    }

    private func apply(_ state: PreviewState) {
        slot.apply(state)
        render()
        lenses.stateArrived(state)
    }

    /// Decodes a JPEG into the picture the pane shows. A bad frame keeps the last good one, which
    /// is the whole point of a preview that outlives a broken build.
    @discardableResult
    private func adopt(_ bytes: Data) -> Bool {
        let bits: UInt = bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress,
                let texture = tailscode_texture_from_bytes(base, gsize(bytes.count))
            else { return 0 }
            return UInt(bitPattern: UnsafeMutableRawPointer(texture))
        }
        guard bits != 0, let size = Gtk.textureSize(bits: bits) else { return false }
        Gtk.replacePicture(of: picture, bits: bits)
        if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
        jpeg = bytes
        if pictureSize?.width != size.width || pictureSize?.height != size.height {
            gtk_aspect_frame_set_ratio(op(frame), Float(size.width) / Float(size.height))
        }
        pictureSize = size
        render()
        return true
    }

    private func resetPicture() {
        gtk_picture_set_paintable(op(picture), nil)
        jpeg = nil
        pictureSize = nil
    }

    func freeze() {
        endRun()
    }

    func discardPicture() {
        resetPicture()
        render()
    }

    func applyForTest(_ state: PreviewState, jpeg bytes: Data? = nil) {
        if let bytes { adopt(bytes) }
        apply(state)
    }
}

/// The wake-up the runner is given: a drain request from any thread becomes one frame tick on the
/// main loop, and nothing else. It holds the pane weakly, so a runner outliving its pane for a
/// moment wakes nothing.
private final class PreviewClock: HostClock, @unchecked Sendable {
    nonisolated(unsafe) weak var pane: PreviewPane?

    func now() -> TimeInterval { Double(g_get_monotonic_time()) / 1_000_000 }

    func requestDrain() {
        Gtk.onMain { [weak self] in self?.pane?.wake() }
    }
}

/// What a failed build looks like over a picture: the headline, the first problem in mono ink, and
/// the one button that hands it to the agent.
final class PreviewBanner: @unchecked Sendable {
    let widget = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    var onAsk: (@Sendable () -> Void)?
    private let headline = Gtk.label("", css: "preview-banner-title", wrap: true, selectable: false)
    private let problemLabel = Gtk.label("", css: "preview-problem", wrap: true, selectable: true)
    private(set) var problem = ""

    init() {
        Gtk.addClass(widget, "preview-banner")
        gtk_widget_set_visible(widget, 0)
        let ask = Gtk.button(Localized.text("Ask the agent to fix it"), css: ["preview-chip"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.onAsk?() }
        }
        gtk_widget_set_halign(ask, GTK_ALIGN_START)
        if let child = gtk_button_get_child(ptr(ask)) {
            gtk_label_set_wrap(op(child), 1)
            gtk_label_set_wrap_mode(op(child), PANGO_WRAP_WORD_CHAR)
            gtk_label_set_max_width_chars(op(child), 14)
            gtk_label_set_justify(op(child), GTK_JUSTIFY_CENTER)
        }
        PreviewPane.capWidth(headline, 30)
        PreviewPane.capWidth(problemLabel, 36)
        gtk_box_append(ptr(widget), headline)
        gtk_box_append(ptr(widget), problemLabel)
        gtk_box_append(ptr(widget), ask)
    }

    func show(headline text: String, problem line: String?) {
        gtk_label_set_text(op(headline), text)
        problem = line ?? ""
        gtk_label_set_text(op(problemLabel), problem)
        gtk_widget_set_visible(problemLabel, problem.isEmpty ? 0 : 1)
    }
}
