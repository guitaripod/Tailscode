import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The call's face, drawn at call size: a round mark whose light is `VoiceCallFace.intensity`, read
/// from absolute time off the widget's own frame clock.
///
/// The activity badge cannot carry a face that leans in with a voice, and the presence orb has no
/// level to give, so the face is a disc of its tone with the face's own glyph in it. Connecting
/// sweeps its glyph, listening and the agent working breathe, speaking breathes with the voice's
/// level, and hearing, degraded and ended hold perfectly still and run no clock at all. Reduced
/// motion drops the movement and keeps the glyph and the tone, which are the meaning.
final class CallFaceMark: @unchecked Sendable {
    let widget = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    private let glyph = Gtk.label("", css: "call-face-glyph", selectable: false)
    private var face: VoiceCallFace = .ended
    private var level: @Sendable () -> Double = { 0 }
    private var shown = 0.0
    private var lastStep = 0.0
    private var lastOpacity = -1.0
    private var lastFrame = ""
    private lazy var lap = RepeatingMotion(holding: false) { [weak self] in self?.step() }

    private static let toneClasses = ["call-face-live", "call-face-attention", "call-face-danger", "call-face-quiet"]

    init() {
        Gtk.addClass(widget, "call-face")
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(widget, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(widget, Self.diameter, Self.diameter)
        gtk_label_set_ellipsize(op(glyph), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_halign(glyph, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(widget, 0)
        gtk_widget_set_valign(glyph, GTK_ALIGN_CENTER)
        gtk_label_set_xalign(op(glyph), 0.5)
        tailscode_set_accessible_hidden(widget, 1)
        gtk_box_append(ptr(widget), glyph)
        RepeatingMotion.watch(widget) { [weak self] in
            Gtk.onMain { [weak self] in self?.relay() }
        }
    }

    static let diameter: Int32 = 32

    private static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    /// Points the mark at a face. The same face again is left exactly as it is, so a snapshot that
    /// only moved a caption does not restart the swell.
    func show(_ next: VoiceCallFace, level source: @escaping @Sendable () -> Double) {
        level = source
        guard next != face || !hasShown else { return }
        hasShown = true
        face = next
        let name: String
        switch next.tone {
        case .live: name = "call-face-live"
        case .attention: name = "call-face-attention"
        case .danger: name = "call-face-danger"
        case .quiet: name = "call-face-quiet"
        }
        Gtk.setTone(widget, name, from: Self.toneClasses)
        relay()
    }

    private var hasShown = false

    /// Whether a clock is turning the face, for a harness that has to prove a settled face runs none.
    var isMoving: Bool { lap.isTurning }

    var reading: String {
        "face=\(face) moving=\(isMoving) glyph=\(glyphText) opacity=\(String(format: "%.2f", max(lastOpacity, 0)))"
    }

    var glyphText: String { gtk_label_get_text(op(glyph)).map { String(cString: $0) } ?? "" }

    /// Takes the moving-or-still decision again: the desk can change its mind about movement in the
    /// middle of a call, and a face that holds still has no clock to ask.
    private func relay() {
        lastOpacity = -1
        lastFrame = ""
        lastStep = 0
        shown = 0
        guard face.motion.isAnimated, lap.lay(on: widget, meaning: face.motion) else {
            lap.lift()
            gtk_widget_set_opacity(widget, 1)
            gtk_label_set_text(op(glyph), face.glyph)
            lastFrame = face.glyph
            return
        }
        step()
    }

    private func step() {
        let time = Self.now
        let elapsed = lastStep == 0 ? 0 : time - lastStep
        lastStep = time
        shown = VoiceCallLevels.smoothed(previous: shown, target: level(), dt: elapsed)
        let opacity = face.intensity(at: time, level: shown, reduceMotion: false)
        if abs(opacity - lastOpacity) > 0.004 {
            lastOpacity = opacity
            gtk_widget_set_opacity(widget, opacity)
        }
        let frame = face.motion.frame(at: time, of: face.icon.cycle) ?? face.glyph
        guard frame != lastFrame else { return }
        lastFrame = frame
        gtk_label_set_text(op(glyph), frame)
    }

    func stop() {
        lap.lift()
    }
}

/// How long a call has lasted, in the one shape a clock is read in.
enum CallClock {
    static func text(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let rest = whole % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
        return String(format: "%d:%02d", minutes, rest)
    }
}

/// The call, docked directly above the composer: the face, its word and a clock, what you said and
/// what the voice said, the agent's own account, mute and hang up, and the beta mark at the edge.
/// The transcript stays fully visible above it, because the person is watching the agent work
/// while they talk.
///
/// It draws a `VoiceCallSnapshot` and invents no word. When the call is over it keeps the ended
/// line for a moment and then leaves, and it is never a modal.
final class CallStripView: @unchecked Sendable {
    nonisolated(unsafe) static var lingers: UInt32 = 6000

    let widget = Gtk.groupBox(GTK_ORIENTATION_VERTICAL, spacing: 6, spoken: VoiceCallReading.name)
    private let face = CallFaceMark()
    private let wordLabel = Gtk.label("", css: "call-word", selectable: false)
    private let clockLabel = Gtk.label("", css: "call-clock", selectable: false)
    private let youRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let youText = Gtk.label("", css: "call-line-you", wrap: true, selectable: false)
    private let voiceRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let voiceText = Gtk.label("", css: "call-line-voice", wrap: true, selectable: false)
    private let endText = Gtk.label("", css: "call-line-end", wrap: true, selectable: false)
    private let agentRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let agentGlyph = Gtk.label("", css: "call-agent-glyph", selectable: false)
    private let agentText = Gtk.label("", css: "call-agent-text", selectable: false)
    private var mute: (button: UnsafeMutablePointer<GtkWidget>, parts: ChatChips.Parts)?
    private var hangUp: (button: UnsafeMutablePointer<GtkWidget>, parts: ChatChips.Parts)?
    private let beta: BetaBadge
    private var snapshot: VoiceCallSnapshot?
    private var topRow: UnsafeMutablePointer<GtkWidget>?
    private var topWidthFrame: UnsafeMutablePointer<GtkWidget>?
    private var clockTicket = 0
    private var leaveTicket = 0
    private var onMute: @Sendable (Bool) -> Void = { _ in }
    private var onHangUp: @Sendable () -> Void = {}
    private(set) var isShown = false

    init(
        reportLines: @escaping @Sendable () -> [String], mute onMute: @escaping @Sendable (Bool) -> Void,
        hangUp onHangUp: @escaping @Sendable () -> Void
    ) {
        self.onMute = onMute
        self.onHangUp = onHangUp
        beta = BetaBadge(feature: .voiceCall, reportLines: reportLines)
        Gtk.addClass(widget, "call-strip")
        gtk_widget_set_visible(widget, 0)

        let top = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_box_append(ptr(top), face.widget)
        let status = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_hexpand(status, 1)
        gtk_widget_set_valign(status, GTK_ALIGN_CENTER)
        gtk_label_set_ellipsize(op(wordLabel), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_valign(clockLabel, GTK_ALIGN_CENTER)
        gtk_label_set_ellipsize(op(clockLabel), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(status), wordLabel)
        gtk_box_append(ptr(status), clockLabel)
        gtk_box_append(ptr(top), status)
        gtk_box_append(ptr(top), beta.widget)

        let muteControl = ChatChips.control(
            glyph: "🎙", word: VoiceCallReading.mute, label: VoiceCallReading.muteTooltip
        ) { [weak self] in
            Gtk.onMain { [weak self] in self?.pressMute() }
        }
        mute = muteControl
        gtk_widget_set_tooltip_text(muteControl.button, VoiceCallReading.muteTooltip)
        tailscode_set_accessible_pressed(muteControl.button, 0)
        gtk_box_append(ptr(top), muteControl.button)

        let hangControl = ChatChips.control(
            glyph: "■", word: VoiceCallReading.hangUp, tone: .danger, label: VoiceCallReading.hangUp
        ) { [weak self] in
            Gtk.onMain { [weak self] in self?.onHangUp() }
        }
        hangUp = hangControl
        gtk_widget_set_tooltip_text(hangControl.button, VoiceCallReading.hangUp)
        gtk_box_append(ptr(top), hangControl.button)
        topRow = top
        let topFrame = gtk_overlay_new()!
        gtk_overlay_set_child(op(topFrame), Gtk.shrinkable(top))
        let gauge = gtk_drawing_area_new()!
        gtk_widget_set_can_target(gauge, 0)
        gtk_widget_set_can_focus(gauge, 0)
        gtk_overlay_add_overlay(op(topFrame), gauge)
        topWidthFrame = topFrame
        gtk_box_append(ptr(widget), topFrame)
        Gtk.onResize(gauge) { [weak self] in
            Gtk.onMain { [weak self] in self?.fit() }
        }

        Self.caption(youRow, role: VoiceCallReading.youLabel, text: youText)
        Self.caption(voiceRow, role: VoiceCallReading.voiceLabel, text: voiceText)
        gtk_box_append(ptr(widget), youRow)
        gtk_box_append(ptr(widget), voiceRow)
        gtk_label_set_lines(op(endText), 3)
        gtk_widget_set_visible(endText, 0)
        gtk_box_append(ptr(widget), endText)

        gtk_label_set_ellipsize(op(agentGlyph), PANGO_ELLIPSIZE_NONE)
        gtk_label_set_ellipsize(op(agentText), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(agentText, 1)
        tailscode_set_accessible_hidden(agentGlyph, 1)
        gtk_box_append(ptr(agentRow), agentGlyph)
        gtk_box_append(ptr(agentRow), agentText)
        gtk_widget_set_visible(agentRow, 0)
        gtk_box_append(ptr(widget), agentRow)

    }

    private static func caption(
        _ row: UnsafeMutablePointer<GtkWidget>, role: String, text: UnsafeMutablePointer<GtkWidget>
    ) {
        let name = Gtk.label(role, css: "call-role", selectable: false)
        gtk_label_set_ellipsize(op(name), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_valign(name, GTK_ALIGN_START)
        gtk_label_set_width_chars(op(name), 5)
        gtk_widget_set_hexpand(text, 1)
        gtk_label_set_lines(op(text), 2)
        gtk_label_set_ellipsize(op(text), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(row), name)
        gtk_box_append(ptr(row), text)
        gtk_widget_set_visible(row, 0)
    }

    var faceMark: CallFaceMark { face }

    var report: String {
        "shown=\(isShown) word=\"\(text(of: wordLabel))\" clock=\"\(text(of: clockLabel))\" "
            + "you=\"\(text(of: youText))\" voice=\"\(text(of: voiceText))\" end=\"\(text(of: endText))\" "
            + "agent=\"\(text(of: agentText))\" muted=\(snapshot?.muted ?? false) \(face.reading)"
    }

    private func text(of label: UnsafeMutablePointer<GtkWidget>) -> String {
        gtk_label_get_text(op(label)).map { String(cString: $0) } ?? ""
    }

    var muteWord: String { mute.flatMap { $0.parts.word.map(text(of:)) } ?? "" }

    var hasMute: Bool { mute.map { gtk_widget_get_visible($0.button) != 0 } ?? false }

    var hasHangUp: Bool { hangUp.map { gtk_widget_get_visible($0.button) != 0 } ?? false }

    func pressMute() {
        onMute(!(snapshot?.muted ?? false))
    }

    func pressHangUp() { onHangUp() }

    func apply(_ next: VoiceCallSnapshot, level: @escaping @Sendable () -> Double) {
        let previous = snapshot
        snapshot = next
        leaveTicket += 1
        isShown = true
        gtk_widget_set_visible(widget, 1)
        face.show(next.face, level: level)
        gtk_label_set_text(op(wordLabel), next.word)
        tailscode_set_accessible_label(widget, next.spoken)
        let open = next.isOpen
        let you = next.lines.last { $0.kind == .you }
        let voice = next.lines.last { $0.kind == .voice }
        Self.write(youRow, youText, you)
        Self.write(voiceRow, voiceText, voice)
        if let note = next.endLine, !open {
            gtk_label_set_text(op(endText), next.end == .hungUp ? "" : note)
            gtk_widget_set_visible(endText, next.end == .hungUp ? 0 : 1)
        } else {
            gtk_widget_set_visible(endText, 0)
        }
        if next.degraded != nil, open {
            gtk_label_set_text(op(endText), next.degraded?.line ?? "")
            gtk_widget_set_visible(endText, 1)
        }
        if let mute, let hangUp {
            gtk_widget_set_visible(mute.button, open ? 1 : 0)
            gtk_widget_set_visible(hangUp.button, open ? 1 : 0)
            let muted = next.muted
            wear(mute: mute, muted: muted)
            tailscode_set_accessible_pressed(mute.button, muted ? 1 : 0)
        }
        if open {
            startClock()
        } else {
            clockTicket += 1
            gtk_label_set_text(op(clockLabel), Self.clockText(next))
            scheduleLeave()
        }
        if previous?.startedAt != next.startedAt { updateClock() }
        fit()
    }

    private static func write(
        _ row: UnsafeMutablePointer<GtkWidget>, _ label: UnsafeMutablePointer<GtkWidget>, _ line: VoiceCallLine?
    ) {
        guard let line else {
            gtk_widget_set_visible(row, 0)
            return
        }
        gtk_widget_set_visible(row, 1)
        gtk_label_set_text(op(label), line.text)
        if line.final {
            gtk_widget_remove_css_class(label, "call-line-partial")
        } else {
            gtk_widget_add_css_class(label, "call-line-partial")
        }
    }

    private static func clockText(_ snapshot: VoiceCallSnapshot) -> String {
        guard let started = snapshot.startedAt else { return "" }
        return CallClock.text(Date().timeIntervalSince(started))
    }

    /// The agent's own account, wearing the face its state already has in the chat's status line.
    func setAgent(kind: ActivityKind?, text: String?) {
        guard let text, !text.isEmpty else {
            ActivityPulse.stop(agentGlyph)
            gtk_widget_set_visible(agentRow, 0)
            return
        }
        gtk_widget_set_visible(agentRow, 1)
        gtk_label_set_text(op(agentText), text)
        let icon = kind?.icon ?? ActivityKind.queued(0).icon
        gtk_label_set_text(op(agentGlyph), kind == nil ? "·" : icon.glyph)
        Gtk.setTone(agentGlyph, ChatChips.toneClass(kind == nil ? .quiet : icon.tone), from: ChatChips.toneClasses)
        if kind != nil { ActivityPulse.apply(icon, to: agentGlyph) } else { ActivityPulse.stop(agentGlyph) }
    }

    private func startClock() {
        clockTicket += 1
        let mine = clockTicket
        updateClock()
        tick(mine)
    }

    private func tick(_ mine: Int) {
        Gtk.after(1000) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.clockTicket == mine, self.snapshot?.isOpen == true else { return }
                self.updateClock()
                self.tick(mine)
            }
        }
    }

    private func updateClock() {
        guard let snapshot else { return }
        gtk_label_set_text(op(clockLabel), Self.clockText(snapshot))
    }

    private func scheduleLeave() {
        leaveTicket += 1
        let mine = leaveTicket
        Gtk.after(Self.lingers) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.leaveTicket == mine, self.snapshot?.isOpen == false else { return }
                self.dismiss()
            }
        }
    }

    func dismiss() {
        clockTicket += 1
        leaveTicket += 1
        snapshot = nil
        isShown = false
        face.stop()
        ActivityPulse.stop(agentGlyph)
        gtk_widget_set_visible(widget, 0)
    }

    /// What the first line gives up as the pane narrows, one step at a time: the chips' words (their
    /// glyphs and tooltips carry the meaning), then the clock, then the beta mark's seat. The face,
    /// its word, mute and hang up never go. The line asks for no width of its own, so the pane's
    /// width is what it is told rather than what it would like.
    private static let steps: [(words: Bool, clock: Bool, beta: Bool)] = [
        (true, true, true), (false, true, true), (false, false, true), (false, false, false),
    ]

    private func fit() {
        guard let topRow, let frame = topWidthFrame else { return }
        let width = gtk_widget_get_width(frame)
        guard width > 0 else { return }
        for step in Self.steps {
            for parts in [mute?.parts, hangUp?.parts] {
                if let word = parts?.word { gtk_widget_set_visible(word, step.words ? 1 : 0) }
            }
            gtk_widget_set_visible(clockLabel, step.clock ? 1 : 0)
            gtk_widget_set_visible(beta.widget, step.beta ? 1 : 0)
            var minimum: Int32 = 0
            var natural: Int32 = 0
            gtk_widget_measure(topRow, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, nil, nil)
            if natural <= width { return }
        }
    }

    private func wear(
        mute control: (button: UnsafeMutablePointer<GtkWidget>, parts: ChatChips.Parts), muted: Bool
    ) {
        if let word = control.parts.word {
            gtk_label_set_text(op(word), muted ? VoiceCallReading.unmute : VoiceCallReading.mute)
        }
        gtk_widget_set_tooltip_text(control.button, muted ? VoiceCallReading.unmuteTooltip : VoiceCallReading.muteTooltip)
        tailscode_set_accessible_label(control.button, muted ? VoiceCallReading.unmuteTooltip : VoiceCallReading.muteTooltip)
        if let glyph = control.parts.glyph { gtk_label_set_text(op(glyph), muted ? "🔇" : "🎙") }
        if muted {
            gtk_widget_add_css_class(control.button, "chip-on")
        } else {
            gtk_widget_remove_css_class(control.button, "chip-on")
        }
    }

    func tearDown() {
        clockTicket += 1
        leaveTicket += 1
        face.stop()
        beta.tearDown()
    }
}
