import CAdw
import CGtkShim
import Foundation
import TailscodeCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A video an agent named, playing on the viewer's sheet: the file's name and where it is, play and
/// pause, Save to Downloads and Done over libmpv drawing into the sheet's body. It stands where the
/// picture viewer stands, so the two never stand together: either one opening closes the other.
///
/// Keys while it is up: space plays and pauses, the arrows seek five seconds, m mutes, Escape
/// leaves.
final class ClipSheet: @unchecked Sendable {
    nonisolated(unsafe) private static var open: ClipSheet?

    static var current: ClipSheet? { open }

    /// Plays `source` (a ticket URL or a cached file). `failed` is told when the player cannot open
    /// it, so the row can read the file again rather than offer a dead ticket twice.
    static func present(
        name: String, source: String, failed: @escaping @Sendable () -> Void,
        notice: @escaping @Sendable (String) -> Void
    ) {
        guard let stack = SheetStack.shared, tailscode_mpv_available() != 0 else {
            notice(MediaTileReading.unplayable(name))
            return
        }
        if MediaViewer.current != nil { stack.closeViewer() }
        open?.layer.closeNow()
        let sheet = ClipSheet(
            layer: stack.viewerLayer, name: name, source: source, failed: failed, notice: notice)
        open = sheet
        sheet.layer.present()
    }

    /// Takes the sheet down at once, for the picture viewer about to stand where it stands.
    static func closeNow() {
        open?.layer.closeNow()
    }

    private let layer: SheetLayer
    private let name: String
    private let source: String
    private let failed: @Sendable () -> Void
    private let notice: @Sendable (String) -> Void
    private var player: OpaquePointer?
    private var box: UnsafeMutableRawPointer?
    private var paused = false
    private var ticking = false
    private var closed = false

    private let titleLabel = Gtk.label("", css: "viewer-title", selectable: false)
    private let subLabel = Gtk.label("", css: "viewer-sub", selectable: false)
    private let playButton: UnsafeMutablePointer<GtkWidget>
    private let saveButton: UnsafeMutablePointer<GtkWidget>
    private let doneButton: UnsafeMutablePointer<GtkWidget>
    private let body = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)

    private init(
        layer: SheetLayer, name: String, source: String, failed: @escaping @Sendable () -> Void,
        notice: @escaping @Sendable (String) -> Void
    ) {
        self.layer = layer
        self.name = name
        self.source = source
        self.failed = failed
        self.notice = notice
        playButton = Gtk.button(Localized.text("Pause"), css: ["viewer-button"], onClick: {})
        saveButton = Gtk.button(Localized.text("Save to Downloads"), css: ["viewer-button"], onClick: {})
        doneButton = Gtk.button(Localized.text("Done"), css: ["studio-done", "viewer-done"], onClick: {})
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
        layer.install(toolbar: makeToolbar(), body: body)
    }

    private func makeToolbar() -> UnsafeMutablePointer<GtkWidget> {
        let bar = gtk_center_box_new()!
        Gtk.addClass(bar, "studio-sheet-bar")
        Gtk.addClass(bar, "viewer-bar")
        gtk_widget_set_size_request(bar, -1, Int32(StudioSheetMetrics.toolbarHeight))
        gtk_widget_set_valign(playButton, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(playButton, Localized.text("Play or pause (space)"))
        gtk_center_box_set_start_widget(op(bar), playButton)

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
        gtk_center_box_set_center_widget(op(bar), middle)

        let trailing = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_valign(trailing, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(trailing), saveButton)
        gtk_box_append(ptr(trailing), doneButton)
        gtk_center_box_set_end_widget(op(bar), trailing)
        for button in [playButton, saveButton, doneButton] {
            gtk_widget_set_focus_on_click(button, 0)
        }
        wire(playButton) { $0.togglePause() }
        wire(saveButton) { $0.save() }
        wire(doneButton) { $0.layer.dismiss() }
        return bar
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
        if let area = tailscode_mpv_area(created) {
            gtk_widget_set_hexpand(area, 1)
            gtk_widget_set_vexpand(area, 1)
            gtk_box_append(ptr(body), area)
        }
        MediaDeck.shared.stopAudio()
        MediaDeck.command(created, ["set", "keep-open", "yes"])
        tailscode_mpv_play(created, source)
        tick()
    }

    private func heard(_ event: String, _ payload: String) {
        switch event {
        case "pause":
            paused = payload == "1"
            gtk_button_set_label(ptr(playButton), paused ? Localized.text("Play") : Localized.text("Pause"))
        case "error":
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
        let duration = tailscode_mpv_number(player, "duration")
        if paused, duration > 0, position >= duration - 0.25 {
            MediaDeck.command(player, ["seek", "0", "absolute"])
            MediaDeck.command(player, ["set", "pause", "no"])
            return
        }
        MediaDeck.command(player, ["cycle", "pause"])
    }

    private func seek(_ seconds: Int) {
        guard let player else { return }
        MediaDeck.command(player, ["seek", String(seconds), "relative"])
    }

    private func handleKey(_ keyval: UInt32) -> Bool {
        switch keyval {
        case 0x0020:
            togglePause()
        case 0xFF51:
            seek(-5)
        case 0xFF53:
            seek(5)
        case UInt32(UnicodeScalar("m").value):
            if let player { MediaDeck.command(player, ["cycle", "mute"]) }
        case 0xFF1B:
            layer.dismiss()
        default:
            return false
        }
        return true
    }

    /// Four times a second the line under the name says where the video is.
    private func tick() {
        guard !ticking, !closed else { return }
        ticking = true
        Gtk.after(250) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.ticking = false
                guard !self.closed, let player = self.player else { return }
                let position = tailscode_mpv_number(player, "time-pos")
                let duration = tailscode_mpv_number(player, "duration")
                if let line = MediaTileReading.progress(
                    at: position >= 0 ? position : nil, of: duration > 0 ? duration : nil)
                {
                    gtk_label_set_text(op(self.subLabel), line)
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
            tailscode_mpv_free(player)
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
