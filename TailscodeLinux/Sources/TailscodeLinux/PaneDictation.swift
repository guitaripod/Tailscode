import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// What a pane tells dictation about itself: its box, its window, the words its chat knows, and how
/// it sends.
protocol DictationPaneHost: AnyObject {
    var dictationEditor: PromptEditor { get }
    var dictationWindow: UnsafeMutablePointer<GtkWidget>? { get }
    var dictationSendTarget: UnsafeMutablePointer<GtkWidget>? { get }
    var dictationKey: String { get }
    var dictationCallLive: Bool { get }
    var dictationShortcuts: ShortcutSet { get }
    func dictationVocabulary() -> DictationVocabulary
    func dictationSend()
    func dictationAnnounce(_ words: String)
}

/// A pane's microphone: the chip beside attach that grows into five level bars while it listens,
/// the lit edge on the box, the hint line, and the take itself — from the press that opens it to
/// the words left in the box. The engine and the microphone are the process's; this pane only
/// holds a take while it is the one the person is talking into.
final class PaneDictation: @unchecked Sendable {
    let chip = gtk_button_new()!
    let hint = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)

    private let mic = gtk_image_new_from_icon_name("audio-input-microphone-symbolic")!
    private let bars = DictationBarsView()
    let word = Gtk.label("", selectable: false)
    private let badge = Gtk.label("↓", css: "chip-tone-live", selectable: false)
    private let hintDot = Gtk.label("●", css: "chip-tone-live", selectable: false)
    private let hintTimer = Gtk.label("", css: "row-detail", selectable: false)
    private let hintText = Gtk.label("", css: "row-detail", selectable: false)
    private let hintUndo = gtk_button_new_with_label(DictationReading.undo)!
    private weak var host: (any DictationPaneHost)?
    private let demo: Bool
    private let demoWordDelay: TimeInterval

    private var readiness: DictationReadiness?
    private var snapshot = DictationSnapshot.idle
    private var session: DictationSession?
    private var follower: Task<Void, Never>?
    private var press = DictationPress()
    private var anchor = DictationInsertion(before: "", after: "")
    private var original = ""
    private var originalCaret = 0
    private var discarded: String?
    private var detached = false
    private var level = 0.0
    private var lastFrame = 0.0
    private var tick: UInt = 0
    private var tickLink: TickLink?
    private var takes = 0
    private var pressOrigin: (x: Double, y: Double) = (0, 0)
    private var heldKeyval: UInt32?
    private var ending: DictationEnd?
    private var endingShownAt = 0.0
    private var popover: DictationPopover?
    private var storeWatch: UUID?
    private var gone = false
    private var chain: Task<Void, Never>?
    private var popoverOnRelease = false
    private var lastPointerAt = 0.0
    /// A narrow pane keeps the chip's glyph and bars and gives up its word, as Send and Stop do.
    var compact = false {
        didSet { if compact != oldValue { redraw() } }
    }

    private final class TickLink: @unchecked Sendable {
        weak var owner: PaneDictation?
        init(_ owner: PaneDictation) { self.owner = owner }
    }

    private final class Link: @unchecked Sendable {
        weak var owner: PaneDictation?
    }

    init(host: any DictationPaneHost, demo: Bool = DemoMode.isActive, demoWordDelay: TimeInterval = 0.22) {
        self.host = host
        self.demo = demo
        self.demoWordDelay = demoWordDelay
        build()
        let link = Link()
        link.owner = self
        Gtk.onPressDrag(
            chip,
            begin: { x, y in Gtk.onMain { link.owner?.pointerDown(x: x, y: y) } },
            update: { dx, dy in Gtk.onMain { link.owner?.pointerMoved(dx: dx, dy: dy) } },
            end: { dx, dy in Gtk.onMain { link.owner?.pointerUp(dx: dx, dy: dy) } },
            cancel: { Gtk.onMain { link.owner?.pointerAbandoned() } })
        Gtk.connect(UnsafeMutableRawPointer(chip), "clicked") { link.owner?.keyboardActivated() }
        Gtk.connect(UnsafeMutableRawPointer(hintUndo), "clicked") { link.owner?.undoDiscard() }
        host.dictationEditor.onEditDuringDictation = { Gtk.onMain { link.owner?.stopKeepingShown() } }
        storeWatch = DictationModelStore.shared.watch { _ in Gtk.onMain { link.owner?.refresh() } }
        refresh()
    }

    private func build() {
        Gtk.addClass(chip, "chip-ctl")
        gtk_widget_set_valign(chip, GTK_ALIGN_CENTER)
        let content = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_valign(content, GTK_ALIGN_CENTER)
        gtk_image_set_pixel_size(op(mic), 14)
        gtk_widget_set_valign(mic, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(bars.widget, 0)
        Gtk.addClass(word, "chip-gap")
        gtk_label_set_width_chars(op(word), 4)
        gtk_label_set_xalign(op(word), 0)
        Gtk.addClass(badge, "chip-gap")
        gtk_widget_set_visible(badge, 0)
        for part in [mic, bars.widget, word, badge] { gtk_box_append(ptr(content), part) }
        gtk_button_set_child(ptr(chip), content)

        Gtk.addClass(hint, "dictation-hint")
        gtk_widget_set_halign(hint, GTK_ALIGN_END)
        gtk_label_set_ellipsize(op(hintText), PANGO_ELLIPSIZE_END)
        Gtk.addClass(hintUndo, "flat")
        Gtk.addClass(hintUndo, "dictation-undo")
        for part in [hintDot, hintTimer, hintText, hintUndo] { gtk_box_append(ptr(hint), part) }
        gtk_widget_set_visible(hint, 0)
    }

    var isOpen: Bool { session != nil && !detached }

    private var face: DictationFace {
        let available = PulseVoiceIO.isAvailable || demo
        let hidden = !available || (host?.dictationCallLive ?? false)
        return DictationFace.read(readiness: demo ? .ready : readiness, snapshot: snapshot, available: !hidden)
    }

    private var chord: String? { host?.dictationShortcuts.effective["composer.dictate"]?.first }

    private static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    private static let modifierKeys: Set<UInt32> = [0xFFE1, 0xFFE2, 0xFFE3, 0xFFE4, 0xFFE7, 0xFFE8, 0xFFE9, 0xFFEA, 0xFFEB, 0xFFEC]

    /// Reads the engine again and redraws. Called when the model store moves, the call changes, or
    /// the chat changes.
    func refresh() {
        guard !gone else { return }
        let recognizer = SherpaDictationRecognizer.shared
        Task { [weak self] in
            let value = await recognizer.readiness(language: SherpaDictationRecognizer.language)
            Gtk.onMain { [weak self] in
                guard let self, !self.gone else { return }
                self.readiness = value
                self.redraw()
            }
        }
        redraw()
    }

    func chatChanged() {
        stopKeepingShown()
        ending = nil
        redraw()
    }

    func shutdown() {
        guard !gone else { return }
        stopKeepingShown()
        gone = true
        stopTicking()
        if let storeWatch { DictationModelStore.shared.unwatch(storeWatch) }
        popover?.close()
    }


    private func pointerDown(x: Double, y: Double) {
        lastPointerAt = Self.now
        pressOrigin = (x, y)
        if !isOpen, !face.isTakeable {
            popoverOnRelease = true
            return
        }
        act(press.down(at: Self.now, listening: isOpen), mode: .held)
    }

    private func pointerMoved(dx: Double, dy: Double) {
        guard isOpen, press.isDown, snapshot.mode == .held || press.isHeld(at: Self.now) else { return }
        let arm = DictationSlide.arm(
            travelled: dx, overSend: overSend(dx: dx, dy: dy), cancelDistance: DictationSlide.pointerCancelDistance)
        guard let session, arm != snapshot.arm else { return }
        enqueue { await session.setArm(arm) }
    }

    private func pointerUp(dx: Double, dy: Double) {
        if popoverOnRelease {
            popoverOnRelease = false
            showPopover()
            return
        }
        act(press.up(at: Self.now), mode: .held)
    }

    private func pointerAbandoned() {
        popoverOnRelease = false
        act(press.abandon(at: Self.now), mode: .held)
    }

    /// Space or Return on the focused chip. A pointer press also ends in the button's own click,
    /// which the press has already answered.
    private func keyboardActivated() {
        guard Self.now - lastPointerAt > 0.6 else { return }
        if isOpen {
            stop(sending: false)
        } else {
            open(mode: .handsFree)
        }
    }

    /// The chord went down. Auto-repeat arrives as more presses while it is held and changes
    /// nothing.
    func chordDown(keyval: UInt32) {
        if heldKeyval == nil { heldKeyval = UInt32(gdk_keyval_to_lower(guint(keyval))) }
        act(press.down(at: Self.now, listening: isOpen), mode: .held)
    }

    /// A key went up anywhere in the window. Letting go of any key of the chord ends a hold — its
    /// letter or one of its modifiers — because GTK does not always hand the window the letter's
    /// release once the press was spent on an action.
    func keyReleased(keyval: UInt32) {
        guard let held = heldKeyval else { return }
        let lowered = UInt32(gdk_keyval_to_lower(guint(keyval)))
        guard lowered == held || Self.modifierKeys.contains(keyval) else { return }
        heldKeyval = nil
        act(press.up(at: Self.now), mode: .held)
    }

    /// Esc throws an open take away and ⏎ settles it and sends; nothing else is taken from the box.
    func handleKey(keyval: UInt32, state: UInt32) -> Bool {
        guard isOpen else { return false }
        if keyval == Keymap.escape {
            cancel()
            return true
        }
        let isReturn = keyval == Keymap.enter || keyval == Keymap.keypadEnter
        if isReturn, state & Keymap.shift == 0, Preferences.sendOnReturn || state & Keymap.control != 0 {
            stop(sending: true)
            return true
        }
        return false
    }

    private func act(_ action: DictationPress.Action, mode: DictationMode) {
        switch action {
        case .open: open(mode: mode)
        case .becomeHandsFree:
            guard let session else { return }
            enqueue { await session.setMode(.handsFree) }
        case .stop:
            switch snapshot.arm {
            case .cancel: cancel()
            case .send: stop(sending: true)
            case .none: stop(sending: false)
            }
        case .none: break
        }
    }

    private func overSend(dx: Double, dy: Double) -> Bool {
        guard let target = host?.dictationSendTarget else { return false }
        var bounds = graphene_rect_t()
        guard gtk_widget_compute_bounds(target, chip, &bounds) != 0 else { return false }
        let x = pressOrigin.x + dx
        let y = pressOrigin.y + dy
        let slop = DictationSlide.sendSlop
        return x >= Double(bounds.origin.x) - slop && x <= Double(bounds.origin.x + bounds.size.width) + slop
            && y >= Double(bounds.origin.y) - slop && y <= Double(bounds.origin.y + bounds.size.height) + slop
    }


    private func open(mode: DictationMode) {
        guard let host, !gone, session == nil else { return }
        switch face {
        case .hidden:
            press = DictationPress()
            return
        case .needsModel, .preparing, .blocked:
            press = DictationPress()
            heldKeyval = nil
            showPopover()
            return
        default: break
        }
        let editor = host.dictationEditor
        anchor = editor.dictationAnchor()
        original = editor.text
        originalCaret = editor.cursor
        discarded = nil
        ending = nil
        detached = false
        takes += 1
        editor.setDictating(true)
        let vocabulary =
            demo ? DictationDemoRecognizer.vocabulary
            : (DictationPreferences.usesChatWords ? host.dictationVocabulary() : .empty)
        let recognizer: any DictationRecognizer =
            demo ? DictationDemoRecognizer(wordDelay: demoWordDelay) : SherpaDictationRecognizer.shared
        let capture: any VoiceAudioCapture = demo ? DictationDemoCapture() : PulseVoiceIO().capture
        let atStart = anchor.before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let session = DictationSession(
            capture: capture, recognizer: recognizer, language: SherpaDictationRecognizer.language,
            vocabulary: vocabulary, atStartOfBox: atStart, take: takes)
        self.session = session
        snapshot = DictationSnapshot(phase: .waking, mode: mode, startedAt: nil, take: takes)
        level = 0
        startTicking()
        redraw()
        follower = Task { [weak self] in
            for await next in session.snapshots {
                Gtk.onMain { [weak self] in self?.apply(next, from: session) }
            }
        }
        let key = host.dictationKey
        enqueue {
            await DictationDesk.shared.claim(key, session: session)
            await session.open(mode: mode)
        }
        host.dictationAnnounce(DictationReading.announceOpen)
        AppLog.write(.session, "dictation: take \(takes) opened \(mode.rawValue)\(demo ? " (demo)" : "")")
    }

    private func apply(_ next: DictationSnapshot, from source: DictationSession) {
        guard source === session, !detached, let editor = host?.dictationEditor else { return }
        snapshot = next
        if next.phase != .idle {
            editor.showDictation(anchor.compose(settled: next.settled, heard: next.heard), struck: next.arm == .cancel)
        } else if let end = next.ended {
            land(DictationTake(text: next.settled, end: end), from: source, sending: false)
        }
        redraw()
    }

    private func stop(sending: Bool) {
        guard let session, !detached else { return }
        enqueue { [weak self] in
            let take = await session.finish(sending: sending)
            Gtk.onMain { [weak self] in self?.land(take, from: session, sending: sending) }
        }
    }

    private func cancel() {
        guard let session, !detached, let editor = host?.dictationEditor else { return }
        let shown = editor.text
        enqueue { [weak self] in
            _ = await session.cancel()
            Gtk.onMain { [weak self] in
                guard let self, session === self.session else { return }
                editor.restoreDictation(self.original, caret: self.originalCaret)
                self.discarded = shown == self.original ? nil : shown
                self.finish(as: .discarded)
            }
        }
    }

    /// A take that ended, whichever way: its words go into the box as one undo step, or the box goes
    /// back to how it was when there were none.
    /// Runs `work` after everything already asked of the take, so a quick tap's switch to hands-free
    /// never reaches the take before the take has opened.
    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = chain
        chain = Task {
            await previous?.value
            await work()
        }
    }

    private func land(_ take: DictationTake, from source: DictationSession, sending: Bool) {
        guard source === session, let host else { return }
        let editor = host.dictationEditor
        if take.text.isEmpty {
            editor.restoreDictation(original, caret: originalCaret)
        } else {
            editor.commitDictation(anchor.compose(settled: take.text, heard: ""), from: original)
        }
        finish(as: take.end)
        if sending, !editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { host.dictationSend() }
    }

    private func finish(as end: DictationEnd) {
        if let session { Task { await DictationDesk.shared.release(session) } }
        follower?.cancel()
        follower = nil
        session = nil
        press = DictationPress()
        heldKeyval = nil
        snapshot = DictationSnapshot(ended: end, take: takes)
        ending = end
        endingShownAt = Self.now
        stopTicking()
        host?.dictationEditor.edge.set(lit: false, tone: .live, glow: 0)
        host?.dictationAnnounce(DictationReading.announce(end))
        AppLog.write(.session, "dictation: take \(takes) ended \(end)")
        redraw()
        if let hint = DictationReading.ending(end) {
            let shown = endingShownAt
            Gtk.after(UInt32(hint.lingers * 1000)) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, self.endingShownAt == shown, self.session == nil else { return }
                    self.ending = nil
                    self.discarded = nil
                    self.redraw()
                }
            }
        }
    }

    /// The person typed into the box mid-take, left the chat or closed the pane: the take stops
    /// where it stands and what is in the box stays exactly as shown.
    func stopKeepingShown() {
        guard let session, !detached else { return }
        detached = true
        enqueue { _ = await session.finish() }
        host?.dictationEditor.setDictating(false)
        finish(as: .kept(words: snapshot.wordCount))
    }

    private func undoDiscard() {
        guard let discarded, let editor = host?.dictationEditor else { return }
        editor.commitDictation(
            DictationInsertion(before: discarded, after: "").compose(settled: "", heard: ""), from: editor.text)
        self.discarded = nil
        ending = nil
        redraw()
    }


    private func redraw() {
        guard !gone else { return }
        let face = self.face
        gtk_widget_set_visible(chip, face == .hidden ? 0 : 1)
        let open = face.showsBars
        gtk_widget_set_visible(mic, open ? 0 : 1)
        gtk_widget_set_visible(bars.widget, open ? 1 : 0)
        gtk_widget_set_visible(badge, face.wearsDownloadBadge ? 1 : 0)
        let armedCancel = face.tone == .danger
        if open && !armedCancel { Gtk.addClass(chip, "chip-on") } else { gtk_widget_remove_css_class(chip, "chip-on") }
        if armedCancel { Gtk.addClass(chip, "chip-danger") } else { gtk_widget_remove_css_class(chip, "chip-danger") }
        if case .blocked = face { Gtk.addClass(mic, "chip-tone-attention") } else { gtk_widget_remove_css_class(mic, "chip-tone-attention") }
        gtk_label_set_text(op(word), chipWord(face))
        gtk_widget_set_visible(word, compact ? 0 : 1)
        if let send = host?.dictationSendTarget {
            if case .listening(.held, .send) = face { Gtk.addClass(send, "chip-on") } else { gtk_widget_remove_css_class(send, "chip-on") }
        }
        gtk_widget_set_tooltip_text(chip, DictationReading.tooltip(face, chord: chord))
        tailscode_set_accessible_label(chip, DictationReading.accessibilityLabel(face))
        drawHint(face)
        host?.dictationEditor.edge.set(
            lit: face.litEdge, tone: face.tone == .danger ? .danger : .live, glow: DictationBars.edgeOpacity(level: level))
    }

    private func chipWord(_ face: DictationFace) -> String {
        switch face {
        case .preparing(let progress): return progress.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? "…"
        case .waking, .listening: return DictationReading.elapsed(snapshot, sessionNow) ?? "0:00"
        case .settling: return "…"
        default: return Localized.text("talk")
        }
    }

    private var sessionNow: Double { ProcessInfo.processInfo.systemUptime }

    private func drawHint(_ face: DictationFace) {
        var shown = snapshot
        if !face.showsBars, let ending { shown.ended = ending }
        let hint = DictationReading.hint(
            face: face, snapshot: shown, now: sessionNow, surface: .pointer, chord: chord)
        guard let hint, face.showsBars || face.isPreparing || ending != nil else {
            gtk_widget_set_visible(self.hint, 0)
            return
        }
        gtk_widget_set_visible(self.hint, 1)
        gtk_widget_set_visible(hintDot, hint.style == .live ? 1 : 0)
        gtk_label_set_text(op(hintTimer), hint.timer ?? "")
        gtk_widget_set_visible(hintTimer, hint.timer == nil ? 0 : 1)
        gtk_label_set_text(op(hintText), hint.text)
        for tone in ["chip-tone-danger", "chip-tone-attention"] { gtk_widget_remove_css_class(hintText, tone) }
        switch hint.style {
        case .danger: Gtk.addClass(hintText, "chip-tone-danger")
        case .warning: Gtk.addClass(hintText, "chip-tone-attention")
        case .live, .plain: break
        }
        gtk_widget_set_visible(hintUndo, hint.offersUndo && discarded != nil ? 1 : 0)
    }

    private func startTicking() {
        guard tick == 0 else { return }
        _ = Gtk.releaseInstalled
        let link = TickLink(self)
        tickLink = link
        lastFrame = Self.now
        tick = UInt(
            tailscode_add_owned_tick(
                chip,
                { raw in
                    guard let raw, let owner = Unmanaged<TickLink>.fromOpaque(raw).takeUnretainedValue().owner else {
                        return 0
                    }
                    owner.frame()
                    return 1
                }, Unmanaged.passRetained(link).toOpaque()))
    }

    private func stopTicking() {
        if tick != 0, tickLink != nil { tailscode_remove_tick(chip, guint(tick)) }
        tick = 0
        tickLink = nil
    }

    private func frame() {
        let time = Self.now
        guard ActivityTuning.wantsFrame(at: time, lastDrawn: lastFrame) else { return }
        let dt = time - lastFrame
        lastFrame = time
        let target = session.map { $0.level } ?? 0
        level = VoiceCallLevels.smoothed(previous: level, target: target, dt: dt)
        let face = self.face
        let onAccent = PartyInk(hex: MatrixTheme.palette.onAccent)
        let heights =
            face == .settling
            ? [Double](repeating: DictationBars.floor, count: DictationBars.count)
            : DictationBars.heights(level: level, time: time, reduceMotion: !RepeatingMotion.allowed)
        bars.set(heights: heights, ink: onAccent)
        host?.dictationEditor.edge.set(
            lit: face.litEdge, tone: face.tone == .danger ? .danger : .live, glow: DictationBars.edgeOpacity(level: level))
        let label = chipWord(face)
        if let current = gtk_label_get_text(op(word)).map({ String(cString: $0) }), current != label {
            gtk_label_set_text(op(word), label)
            drawHint(face)
        }
    }


    private func showPopover() {
        if popover?.isShown == true { return }
        popover?.close()
        let popover = DictationPopover(
            anchor: chip, face: face, chord: chord, host: Self.machineName,
            retry: { [weak self] in Gtk.onMain { [weak self] in self?.refresh() } })
        self.popover = popover
        popover.present()
    }

    private static var machineName: String {
        ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "this computer"
    }


    var harnessFace: DictationFace { face }
    var harnessSnapshot: DictationSnapshot { snapshot }
    var harnessHint: String {
        gtk_widget_get_visible(hint) == 0 ? "" : gtk_label_get_text(op(hintText)).map { String(cString: $0) } ?? ""
    }
    func harnessPress() { pointerDown(x: 1, y: 1) }
    func harnessRelease() { pointerUp(dx: 0, dy: 0) }
    func harnessSlide(dx: Double) { pointerMoved(dx: dx, dy: 0) }
    var harnessPopover: String { popover?.isShown == true ? popover?.harnessText ?? "" : "" }
    func harnessReadiness(_ value: DictationReadiness) {
        readiness = value
        redraw()
    }
}
