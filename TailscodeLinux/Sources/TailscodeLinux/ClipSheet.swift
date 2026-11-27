import CAdw
import CGtkShim
import Foundation
import TailscodeCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A video an agent named, playing on the viewer's sheet: the file's name, Save to Downloads and
/// Done over libmpv drawing into the sheet's body, and under the picture a transport — play and
/// pause, where it is, a bar to seek on, its length, speed, sound and loop. It stands where the
/// picture viewer stands, so the two never stand together: either one opening closes the other.
///
/// A clip of a few seconds loops (`MediaLoop`), a longer one opens where it was left
/// (`MediaPlayhead`) and the place it is left at is kept. A seek in a short clip lands on the exact
/// frame and one in a long film on the nearest keyframe, which needs no decoding up to it.
///
/// Keys while it is up: space or k plays and pauses, the arrows seek five seconds and j and l ten,
/// comma and period step a frame, [ and ] change speed, m mutes, Home goes to the start, Escape
/// leaves.
final class ClipSheet: @unchecked Sendable {
    nonisolated(unsafe) private static var open: ClipSheet?

    static var current: ClipSheet? { open }

    /// Plays `source` (a ticket URL or a cached file). `playhead` is the key its place is kept
    /// under; `failed` is told when the player cannot open it, so the row can read the file again
    /// rather than offer a dead ticket twice.
    static func present(
        name: String, source: String, duration: Double?, playhead: String,
        failed: @escaping @Sendable () -> Void, notice: @escaping @Sendable (String) -> Void
    ) {
        guard let stack = SheetStack.shared, tailscode_mpv_available() != 0 else {
            notice(MediaTileReading.unplayable(name))
            return
        }
        if MediaViewer.current != nil { stack.closeViewer() }
        open?.layer.closeNow()
        let sheet = ClipSheet(
            layer: stack.viewerLayer, name: name, source: source, duration: duration,
            playhead: playhead, failed: failed, notice: notice)
        open = sheet
        sheet.layer.present()
    }

    /// Takes the sheet down at once, for the picture viewer about to stand where it stands.
    static func closeNow() {
        open?.layer.closeNow()
    }

    static let speeds: [Double] = [1, 1.25, 1.5, 2, 0.5, 0.75]

    private let layer: SheetLayer
    private let name: String
    private let source: String
    private let playhead: String
    private let failed: @Sendable () -> Void
    private let notice: @Sendable (String) -> Void
    private var player: OpaquePointer?
    private var box: UnsafeMutableRawPointer?
    private var duration: Double?
    private var paused = false
    private var muted = false
    private var looping: Bool
    private var speed = 1.0
    private var ticking = false
    private var closed = false
    private var settingBar = false
    private var startAt: Double?
    private var started = false

    private let titleLabel = Gtk.label("", css: "viewer-title", selectable: false)
    private let subLabel = Gtk.label("", css: "viewer-sub", selectable: false)
    private let saveButton: UnsafeMutablePointer<GtkWidget>
    private let doneButton: UnsafeMutablePointer<GtkWidget>
    private let playButton: UnsafeMutablePointer<GtkWidget>
    private let speedButton: UnsafeMutablePointer<GtkWidget>
    private let muteButton: UnsafeMutablePointer<GtkWidget>
    private let loopButton: UnsafeMutablePointer<GtkWidget>
    private let positionLabel = Gtk.label("0:00", css: "clip-time", selectable: false)
    private let lengthLabel = Gtk.label("", css: "clip-time", selectable: false)
    private let bar = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.0005)!
    private let body = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let stage = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)

    private init(
        layer: SheetLayer, name: String, source: String, duration: Double?, playhead: String,
        failed: @escaping @Sendable () -> Void, notice: @escaping @Sendable (String) -> Void
    ) {
        self.layer = layer
        self.name = name
        self.source = source
        self.duration = duration
        self.playhead = playhead
        self.failed = failed
        self.notice = notice
        looping = MediaLoop.loops(duration: duration)
        startAt = looping ? nil : MediaPlayhead.start(for: playhead)
        saveButton = Gtk.button(Localized.text("Save to Downloads"), css: ["viewer-button"], onClick: {})
        doneButton = Gtk.button(Localized.text("Done"), css: ["studio-done", "viewer-done"], onClick: {})
        playButton = Gtk.button("⏸", css: ["flat", "clip-button"], onClick: {})
        speedButton = Gtk.button("1×", css: ["flat", "clip-button"], onClick: {})
        muteButton = Gtk.button("🔊", css: ["flat", "clip-button"], onClick: {})
        loopButton = Gtk.button("⟲", css: ["flat", "clip-button"], onClick: {})
        build()
        start()
    }

    private func build() {
        layer.arrival = .rise
        layer.name = "clip"
        layer.setDialogName(Localized.text("Video player, dialog"))
        layer.addSheetClass("viewer-sheet")
        layer.detail = { [weak self] in self?.name ?? "" }
        layer.onClosed = { [weak self] in self?.tearDown() }
        layer.keys = { [weak self] keyval, _ in self?.handleKey(keyval) ?? false }
        layer.focusInitial = { [weak self] in
            guard let self else { return }
            gtk_widget_grab_focus(self.body)
        }
        gtk_widget_set_hexpand(body, 1)
        gtk_widget_set_vexpand(body, 1)
        gtk_widget_set_focusable(body, 1)
        Gtk.addClass(body, "viewer-canvas")
        gtk_widget_set_hexpand(stage, 1)
        gtk_widget_set_vexpand(stage, 1)
        gtk_box_append(ptr(body), stage)
        gtk_box_append(ptr(body), makeTransport())
        layer.install(toolbar: makeToolbar(), body: body)
    }

    private func makeToolbar() -> UnsafeMutablePointer<GtkWidget> {
        let toolbar = gtk_center_box_new()!
        Gtk.addClass(toolbar, "studio-sheet-bar")
        Gtk.addClass(toolbar, "viewer-bar")
        gtk_widget_set_size_request(toolbar, -1, Int32(StudioSheetMetrics.toolbarHeight))
        let middle = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_valign(middle, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(middle, GTK_ALIGN_CENTER)
        for label in [titleLabel, subLabel] {
            gtk_label_set_xalign(op(label), 0.5)
            gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_MIDDLE)
            gtk_label_set_max_width_chars(op(label), 64)
            gtk_widget_set_halign(label, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(middle), label)
        }
        gtk_label_set_text(op(titleLabel), name)
        gtk_label_set_text(
            op(subLabel), MediaTileReading.caption(name: "", kind: .video, duration: duration)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ·")))
        gtk_center_box_set_center_widget(op(toolbar), middle)
        let trailing = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_valign(trailing, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(trailing), saveButton)
        gtk_box_append(ptr(trailing), doneButton)
        gtk_center_box_set_end_widget(op(toolbar), trailing)
        for button in [saveButton, doneButton] { gtk_widget_set_focus_on_click(button, 0) }
        wire(saveButton) { $0.save() }
        wire(doneButton) { $0.layer.dismiss() }
        return toolbar
    }

    private func makeTransport() -> UnsafeMutablePointer<GtkWidget> {
        let transport = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.addClass(transport, "clip-transport")
        gtk_scale_set_draw_value(ptr(bar), 0)
        gtk_widget_set_hexpand(bar, 1)
        gtk_widget_set_valign(bar, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(bar, Localized.text("Position in %@", name))
        for (button, tip) in [
            (playButton, Localized.text("Play or pause (space)")),
            (speedButton, Localized.text("Speed ([ and ])")),
            (muteButton, Localized.text("Sound (m)")),
            (loopButton, Localized.text("Loop")),
        ] {
            gtk_widget_set_tooltip_text(button, tip)
            tailscode_set_accessible_label(button, tip)
            gtk_widget_set_focus_on_click(button, 0)
            gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        }
        for widget in [playButton, positionLabel, bar, lengthLabel, speedButton, loopButton, muteButton] {
            gtk_box_append(ptr(transport), widget)
        }
        wire(playButton) { $0.togglePause() }
        wire(speedButton) { $0.stepSpeed(by: 1) }
        wire(muteButton) { $0.toggleMute() }
        wire(loopButton) { $0.toggleLoop() }
        Gtk.connect(UnsafeMutableRawPointer(bar), "value-changed") { [weak self] in
            self?.barMoved()
        }
        showLoop()
        return transport
    }

    private func wire(
        _ button: UnsafeMutablePointer<GtkWidget>, _ action: @escaping @Sendable (ClipSheet) -> Void
    ) {
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                action(self)
            }
        }
    }

    private func start() {
        let box = Unmanaged.passRetained(Box(sheet: self)).toOpaque()
        guard
            let created = tailscode_mpv_new(
                { user, kind, text in
                    guard let user, let kind else { return }
                    let event = String(cString: kind)
                    let payload = text.map { String(cString: $0) } ?? ""
                    Unmanaged<Box>.fromOpaque(user).takeUnretainedValue().sheet?.heard(event, payload)
                }, box)
        else {
            Unmanaged<Box>.fromOpaque(box).release()
            gtk_label_set_text(op(subLabel), String(cString: tailscode_mpv_last_error()))
            return
        }
        player = created
        self.box = box
        MediaDeck.shared.stopAudio()
        MediaDeck.command(created, ["set", "keep-open", "yes"])
        MediaDeck.command(created, ["set", "loop-file", looping ? "inf" : "no"])
        MediaDeck.dress(created, title: name)
        guard let area = tailscode_mpv_area(created) else { return }
        gtk_widget_set_hexpand(area, 1)
        gtk_widget_set_vexpand(area, 1)
        gtk_box_append(ptr(stage), area)
        if gtk_widget_get_realized(area) != 0 {
            play()
        } else {
            Gtk.connect(UnsafeMutableRawPointer(area), "realize") { [weak self] in
                Gtk.onMain { [weak self] in self?.play() }
            }
        }
    }

    /// The file is opened only once the sheet's GL area exists: the area makes mpv's render
    /// context when it is realized, and a video mpv opens before that has nothing to draw into, so
    /// a clip with no sound fails outright ("no audio or video data played").
    private func play() {
        guard !started, !closed, let player else { return }
        started = true
        tailscode_mpv_play(player, source)
        tick()
        if ProcessInfo.processInfo.environment["TAILSCODE_CLIP_STATS"] == "1" { ClipStats(sheet: self).run() }
    }

    /// One line a second under `TAILSCODE_CLIP_STATS=1`: how often GTK painted, how long mpv held
    /// the main thread to draw, how late the main loop answered a 10 ms timer, and what mpv says
    /// of its own decoding and timing.
    func statsLine(lagMax: Double, lagAverage: Double) -> String? {
        guard !closed, let player else { return nil }
        var renders: guint64 = 0
        var total: gint64 = 0
        var worst: gint64 = 0
        tailscode_mpv_take_render_stats(player, &renders, &total, &worst)
        let area = tailscode_mpv_area(player)
        let fps = area.flatMap { gtk_widget_get_frame_clock($0) }.map { gdk_frame_clock_get_fps($0) } ?? -1
        func number(_ name: String) -> Double { tailscode_mpv_number(player, name) }
        let average = renders > 0 ? Double(total) / Double(renders) / 1000 : 0
        return String(
            format: "CLIPSTATS clock=%.1f renders=%llu render=%.2fms max=%.2fms lag=%.2fms lagmax=%.2fms vfps=%.1f dfps=%.1f drop=%.0f vodrop=%.0f delayed=%.0f mistimed=%.0f",
            fps, renders, average, Double(worst) / 1000, lagAverage, lagMax,
            number("estimated-vf-fps"), number("display-fps"), number("frame-drop-count"),
            number("decoder-frame-drop-count"), number("vo-delayed-frame-count"), number("mistimed-frame-count"))
            + " hwdec=" + String(cString: tailscode_mpv_text(player, "hwdec-current"))
            + " cpu=" + Self.processCPU() + " main=" + Self.mainCPU()
    }

    var isClosed: Bool { closed }

    var frameClock: OpaquePointer? {
        guard let player, let area = tailscode_mpv_area(player) else { return nil }
        return gtk_widget_get_frame_clock(area)
    }

    nonisolated(unsafe) private static var lastCPU: (ticks: Double, at: Double)?
    nonisolated(unsafe) private static var lastMain: (ticks: Double, at: Double)?

    /// The main thread's share of one core since the last line: the thread whose id is the
    /// process's, which is the one GTK and every callback here run on.
    private static func mainCPU() -> String {
        let pid = getpid()
        guard let stat = try? String(contentsOfFile: "/proc/self/task/\(pid)/stat", encoding: .utf8),
            let close = stat.lastIndex(of: ")")
        else { return "?" }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 13, let user = Double(fields[11]), let system = Double(fields[12]) else { return "?" }
        let ticks = user + system
        let now = Double(g_get_monotonic_time()) / 1_000_000
        defer { lastMain = (ticks, now) }
        guard let last = lastMain, now > last.at else { return "?" }
        return String(format: "%.2f", (ticks - last.ticks) / 100 / (now - last.at))
    }

    /// This process's CPU since the last line, in cores, read from /proc so it needs no tool.
    private static func processCPU() -> String {
        guard let stat = try? String(contentsOfFile: "/proc/self/stat", encoding: .utf8),
            let close = stat.lastIndex(of: ")")
        else { return "?" }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 13, let user = Double(fields[11]), let system = Double(fields[12]) else { return "?" }
        let ticks = user + system
        let now = Double(g_get_monotonic_time()) / 1_000_000
        defer { lastCPU = (ticks, now) }
        guard let last = lastCPU, now > last.at else { return "?" }
        return String(format: "%.2f", (ticks - last.ticks) / 100 / (now - last.at))
    }

    private func heard(_ event: String, _ payload: String) {
        switch event {
        case "loaded":
            if let player, let start = startAt, start > 0 {
                MediaDeck.command(player, ["seek", String(format: "%.2f", start), "absolute"])
            }
            startAt = nil
        case "pause":
            paused = payload == "1"
            gtk_button_set_label(ptr(playButton), paused ? "▶" : "⏸")
        case "mute":
            muted = payload == "1"
            gtk_button_set_label(ptr(muteButton), muted ? "🔇" : "🔊")
        case "error":
            AppLog.write(.ui, "clip sheet could not play \(name): \(payload)")
            gtk_label_set_text(op(subLabel), MediaTileReading.unreachable(name))
            failed()
        default:
            break
        }
    }

    /// Play at the end of the clip starts it over: the sheet keeps the last frame up rather than
    /// going black, so the clip is paused there, and unpausing a clip at its end plays nothing.
    private func togglePause() {
        guard let player else { return }
        let position = tailscode_mpv_number(player, "time-pos")
        let length = tailscode_mpv_number(player, "duration")
        if paused, length > 0, position >= length - 0.25 {
            MediaDeck.command(player, ["seek", "0", "absolute"])
            MediaDeck.command(player, ["set", "pause", "no"])
            return
        }
        MediaDeck.command(player, ["cycle", "pause"])
    }

    /// A short clip seeks to the exact frame; a long one to the keyframe nearest, at once.
    private var seekFlag: String {
        (duration ?? 0) <= 120 ? "absolute+exact" : "absolute+keyframes"
    }

    private func seek(by seconds: Double) {
        guard let player else { return }
        MediaDeck.command(
            player, ["seek", String(format: "%.2f", seconds), (duration ?? 0) <= 120 ? "relative+exact" : "relative"])
    }

    /// Read inside the signal, never after a hop to the main loop: the transport moves the bar
    /// four times a second, and a change read later than the guard around that move is a seek to
    /// where the clip already is, decoded from its last key frame each time.
    private func barMoved() {
        guard !settingBar, let player else { return }
        let length = tailscode_mpv_number(player, "duration")
        guard length > 0 else { return }
        let target = gtk_range_get_value(ptr(bar)) * length
        MediaDeck.command(player, ["seek", String(format: "%.3f", target), seekFlag])
        gtk_label_set_text(op(positionLabel), MediaTileReading.clock(target))
    }

    private func stepSpeed(by step: Int) {
        guard let player else { return }
        let index = Self.speeds.firstIndex(of: speed) ?? 0
        speed = Self.speeds[(index + step + Self.speeds.count) % Self.speeds.count]
        MediaDeck.command(player, ["set", "speed", String(speed)])
        gtk_button_set_label(ptr(speedButton), Self.speedWord(speed))
    }

    static func speedWord(_ speed: Double) -> String {
        let plain = speed == speed.rounded() ? String(Int(speed)) : String(speed)
        return plain + "×"
    }

    private func toggleMute() {
        guard let player else { return }
        MediaDeck.command(player, ["cycle", "mute"])
    }

    private func toggleLoop() {
        looping.toggle()
        if let player { MediaDeck.command(player, ["set", "loop-file", looping ? "inf" : "no"]) }
        showLoop()
    }

    private func showLoop() {
        gtk_widget_set_opacity(loopButton, looping ? 1 : 0.45)
        if looping { Gtk.addClass(loopButton, "clip-on") } else { gtk_widget_remove_css_class(loopButton, "clip-on") }
    }

    private func handleKey(_ keyval: UInt32) -> Bool {
        guard let player else { return false }
        switch keyval {
        case 0x0020, UInt32(UnicodeScalar("k").value):
            togglePause()
        case 0xFF51:
            seek(by: -5)
        case 0xFF53:
            seek(by: 5)
        case UInt32(UnicodeScalar("j").value):
            seek(by: -10)
        case UInt32(UnicodeScalar("l").value):
            seek(by: 10)
        case UInt32(UnicodeScalar(",").value):
            MediaDeck.command(player, ["frame-back-step"])
        case UInt32(UnicodeScalar(".").value):
            MediaDeck.command(player, ["frame-step"])
        case UInt32(UnicodeScalar("[").value):
            stepSpeed(by: -1)
        case UInt32(UnicodeScalar("]").value):
            stepSpeed(by: 1)
        case UInt32(UnicodeScalar("m").value):
            toggleMute()
        case 0xFF50:
            MediaDeck.command(player, ["seek", "0", "absolute"])
        case 0xFF1B:
            layer.dismiss()
        default:
            return false
        }
        return true
    }

    /// Four times a second the transport says where the video is.
    private func tick() {
        guard !ticking, !closed else { return }
        ticking = true
        Gtk.after(250) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.ticking = false
                guard !self.closed, let player = self.player else { return }
                let position = tailscode_mpv_number(player, "time-pos")
                let length = tailscode_mpv_number(player, "duration")
                if length > 0 {
                    if self.duration == nil { self.duration = length }
                    gtk_label_set_text(op(self.lengthLabel), MediaTileReading.clock(length.rounded()))
                }
                if position >= 0 {
                    gtk_label_set_text(op(self.positionLabel), MediaTileReading.clock(position))
                    self.settingBar = true
                    gtk_range_set_value(
                        ptr(self.bar), MediaTileReading.fraction(at: position, of: length > 0 ? length : nil))
                    self.settingBar = false
                }
                self.tick()
            }
        }
    }

    /// The file itself into Downloads: copied when it is already on this desk, fetched over its
    /// ticket when it is not, never a re-encode of what played.
    private func save() {
        let name = self.name
        let source = self.source
        let notice = self.notice
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(Self.freeName(name))
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if source.hasPrefix("/") {
            let wrote = (try? FileManager.default.copyItem(atPath: source, toPath: target.path)) != nil
            notice(wrote ? Localized.text("Saved %@", target.path) : Localized.text("Could not write %@", target.path))
            return
        }
        guard let url = URL(string: source) else { return }
        notice(Localized.text("Saving %@…", name))
        let task = URLSession.shared.downloadTask(with: url) { temporary, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var wrote = false
            if let temporary, (200..<300).contains(status) {
                wrote = (try? FileManager.default.moveItem(at: temporary, to: target)) != nil
            }
            notice(wrote ? Localized.text("Saved %@", target.path) : Localized.text("Could not write %@", target.path))
        }
        task.resume()
    }

    /// The file's own name in Downloads, numbered when one of that name is already there.
    private static func freeName(_ name: String) -> String {
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        guard FileManager.default.fileExists(atPath: downloads.appendingPathComponent(name).path) else {
            return name
        }
        let dot = name.lastIndex(of: ".")
        let stem = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        for number in 2..<1000 {
            let candidate = "\(stem) \(number)\(ext)"
            if !FileManager.default.fileExists(atPath: downloads.appendingPathComponent(candidate).path) {
                return candidate
            }
        }
        return "\(stem) \(UUID().uuidString.prefix(8))\(ext)"
    }

    private func tearDown() {
        closed = true
        if let player {
            if !looping {
                MediaPlayhead.keep(tailscode_mpv_number(player, "time-pos"), of: duration, for: playhead)
            }
            tailscode_mpv_free(player)
            HeapReturn.soon()
            self.player = nil
        }
        if let box {
            Unmanaged<Box>.fromOpaque(box).release()
            self.box = nil
        }
        layer.uninstall()
        if Self.open === self { Self.open = nil }
    }

    private final class Box {
        weak var sheet: ClipSheet?
        init(sheet: ClipSheet) { self.sheet = sheet }
    }
}
