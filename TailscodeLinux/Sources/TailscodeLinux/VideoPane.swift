import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A stream living inside the split tree. libmpv draws into this pane's own GL area, so the video
/// is a widget the tiling owns: the dividers resize it, zoom hides its siblings, and closing it
/// hands the space back — none of which is true of a player that owns a window. An empty slot
/// asks what to watch in its own body rather than in a dialog, because the pane is already the
/// place the answer belongs.
final class VideoPane: @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private(set) var slot: VideoSlot
    private var player: OpaquePointer?
    private var surface: UnsafeMutablePointer<GtkWidget>?
    private let askBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
    private let entry = gtk_entry_new()!
    private let headingLabel: UnsafeMutablePointer<GtkWidget>
    private let hintLabel: UnsafeMutablePointer<GtkWidget>
    private let reasonLabel: UnsafeMutablePointer<GtkWidget>
    private let noticeLabel: UnsafeMutablePointer<GtkWidget>
    private var callbackBox: UnsafeMutableRawPointer?

    /// Told to the pane's owner whenever what this slot says about itself changes, so the identity
    /// strip and the persisted layout follow the stream rather than lag a state behind.
    var onChange: (@Sendable () -> Void)?

    init(target: VideoTarget?) {
        slot = VideoSlot(target: target)
        headingLabel = Gtk.label(Localized.text("Watch"), css: "video-heading", selectable: false)
        hintLabel = Gtk.label(slot.hint, css: "dim", wrap: true, selectable: false)
        reasonLabel = Gtk.label("", css: "dim", selectable: false)
        noticeLabel = Gtk.label(slot.notice, css: "video-notice", wrap: true, selectable: false)
        buildRoot()
        if let target { point(at: target) } else { render() }
    }

    private func buildRoot() {
        Gtk.addClass(root, "canvas")
        Gtk.addClass(root, "video-pane")
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)

        gtk_widget_set_valign(askBox, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(askBox, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(askBox, 1)
        Gtk.margins(askBox, 24)
        gtk_entry_set_placeholder_text(ptr(entry), slot.prompt)
        gtk_widget_set_size_request(entry, 320, -1)
        Gtk.connect(UnsafeMutableRawPointer(entry), "activate") { [weak self] in
            self?.submit()
        }
        gtk_label_set_xalign(op(hintLabel), 0.5)
        gtk_label_set_justify(op(hintLabel), GTK_JUSTIFY_CENTER)
        gtk_label_set_max_width_chars(op(hintLabel), 46)
        gtk_label_set_xalign(op(noticeLabel), 0.5)
        gtk_label_set_justify(op(noticeLabel), GTK_JUSTIFY_CENTER)
        gtk_label_set_max_width_chars(op(noticeLabel), 46)
        gtk_widget_set_size_request(noticeLabel, 320, -1)
        gtk_box_append(ptr(askBox), headingLabel)
        gtk_box_append(ptr(askBox), entry)
        gtk_box_append(ptr(askBox), reasonLabel)
        gtk_box_append(ptr(askBox), hintLabel)
        gtk_box_append(ptr(askBox), noticeLabel)
        gtk_box_append(ptr(root), askBox)
    }

    var target: VideoTarget? { slot.target }
    var isAsking: Bool { slot.isAsking }

    /// One line for the headless driver: the phase, then what the slot is showing.
    var summary: String {
        let phase: String
        switch slot.phase {
        case .asking: phase = "asking"
        case .loading: phase = "loading"
        case .playing: phase = "playing"
        case .failed: phase = "failed"
        }
        return "\(phase) \(slot.target?.address ?? "-") [\(slot.title)] \(slot.subtitle)"
    }

    func focusPrompt() {
        gtk_widget_grab_focus(entry)
    }

    func submit() {
        guard let raw = gtk_editable_get_text(op(entry)) else { return }
        let text = String(cString: raw)
        guard let target = VideoTarget.classify(text) else { return }
        point(at: target)
    }

    func point(at target: VideoTarget) {
        slot.point(at: target)
        guard tailscode_mpv_available() != 0 else {
            slot.failed(Localized.text("This build has no libmpv, so a slot cannot play"))
            render()
            return
        }
        guard ensurePlayer() else {
            slot.failed(String(cString: tailscode_mpv_last_error()))
            render()
            return
        }
        tailscode_mpv_play(player, target.playbackURL)
        render()
    }

    /// Back to the question with the old target in the box — a mistyped channel is a correction,
    /// not a retype.
    func ask() {
        slot.ask()
        gtk_editable_set_text(op(entry), slot.draft)
        render()
        focusPrompt()
    }

    func handle(_ command: VideoCommand) {
        guard command != .change else {
            ask()
            return
        }
        guard let player, !slot.isAsking else { return }
        let arguments = command.mpvCommand
        guard !arguments.isEmpty else { return }
        withCommand(arguments) { tailscode_mpv_command(player, $0) }
    }

    func shutdown() {
        if let player {
            tailscode_mpv_free(player)
            self.player = nil
            surface = nil
        }
        if let callbackBox {
            Unmanaged<Box>.fromOpaque(callbackBox).release()
            self.callbackBox = nil
        }
    }

    private func ensurePlayer() -> Bool {
        if player != nil { return true }
        guard tailscode_mpv_available() != 0 else { return false }
        let box = Box(pane: self)
        let raw = Unmanaged.passRetained(box).toOpaque()
        guard
            let created = tailscode_mpv_new(
                { user, kind, text in
                    guard let user, let kind else { return }
                    let event = String(cString: kind)
                    let payload = text.map { String(cString: $0) } ?? ""
                    let box = Unmanaged<Box>.fromOpaque(user).takeUnretainedValue()
                    box.pane?.received(event: event, payload: payload)
                }, raw)
        else {
            Unmanaged<Box>.fromOpaque(raw).release()
            return false
        }
        player = created
        callbackBox = raw
        guard let area = tailscode_mpv_area(created) else { return false }
        surface = area
        gtk_widget_set_hexpand(area, 1)
        gtk_widget_set_vexpand(area, 1)
        gtk_box_append(ptr(root), area)
        return true
    }

    /// mpv's own words about the stream, turned into the slot's. A failure keeps the pane and
    /// explains itself; it never empties the slot, because the pane still holds its share of the
    /// grid and has to account for it.
    private func received(event: String, payload: String) {
        switch event {
        case "loaded":
            slot.loaded(title: slot.mediaTitle)
        case "title":
            slot.loaded(title: payload)
        case "pause":
            slot.paused = payload == "1"
        case "mute":
            slot.muted = payload == "1"
        case "error":
            slot.failed(
                payload.isEmpty ? Localized.text("That would not play") : payload)
        case "end":
            if case .loading = slot.phase {
                slot.failed(Localized.text("That would not play"))
            }
        default:
            return
        }
        render()
    }

    private func render() {
        let asking = slot.isAsking
        gtk_widget_set_visible(askBox, asking ? 1 : 0)
        if let surface { gtk_widget_set_visible(surface, asking ? 0 : 1) }
        if case .failed(let reason) = slot.phase {
            gtk_widget_set_visible(askBox, 1)
            if let surface { gtk_widget_set_visible(surface, 0) }
            gtk_label_set_text(op(reasonLabel), reason)
            gtk_widget_set_visible(reasonLabel, 1)
        } else {
            gtk_widget_set_visible(reasonLabel, 0)
        }
        gtk_label_set_text(op(hintLabel), slot.hint)
        onChange?()
    }

    private func withCommand(_ arguments: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> Void) {
        var pointers: [UnsafePointer<CChar>?] = arguments.map { argument in
            UnsafePointer(strdup(argument))
        }
        pointers.append(nil)
        pointers.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { body(base) }
        }
        for pointer in pointers where pointer != nil {
            free(UnsafeMutableRawPointer(mutating: pointer))
        }
    }

    /// The C callback carries a raw pointer, so the pane reaches it through a box it owns and
    /// releases at shutdown — an event arriving after the pane is gone finds nothing rather than
    /// a dangling object.
    private final class Box {
        weak var pane: VideoPane?
        init(pane: VideoPane) { self.pane = pane }
    }
}
