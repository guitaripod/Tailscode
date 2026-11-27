import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The rows a video or a song an agent named stands as (`MediaMentions`): a video is its first
/// frame at a picture's size with a play mark, opened onto the clip sheet; a song is one slim line
/// that plays where it is. Both draw from `MediaDeck`, never from state of their own, because a
/// row is rebuilt whenever its transcript changes.
enum MediaTile {
    static func make(
        _ reference: FileReference, kind: MediaKind, key: String, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let name = MediaTileReading.name(of: reference)
        switch MediaDeck.shared.state(key, url: reference.url) {
        case nil:
            context.requestMedia?(reference, key, false)
            return kind == .video ? videoPlaceholder(name) : audioLine(name, ready: nil, key: key, context: context, reference: reference)
        case .reading:
            return kind == .video ? videoPlaceholder(name) : audioLine(name, ready: nil, key: key, context: context, reference: reference)
        case .failed(let failure):
            return failed(failure, name: name, reference: reference, key: key, context: context)
        case .ready(let ready):
            return kind == .video
                ? video(ready, name: name, reference: reference, key: key, context: context)
                : audioLine(name, ready: ready, key: key, context: context, reference: reference)
        }
    }

    /// The box a first frame is fitted into: a picture's, so a video and a screenshot in one turn
    /// read as one family.
    private static var frameBox: (Int32, Int32) {
        (Int32(ImagePreview.deskWidth), Int32(ImagePreview.deskWidth * 9 / 16))
    }

    private static func videoPlaceholder(_ name: String) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        let frame = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(frame, "image-part")
        Gtk.addClass(frame, "media-frame")
        gtk_widget_set_size_request(frame, frameBox.0, frameBox.1)
        gtk_widget_set_halign(frame, GTK_ALIGN_START)
        let label = Gtk.label(Localized.text("Loading…"), css: "dim", selectable: false)
        gtk_widget_set_halign(label, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(label, 1)
        gtk_box_append(ptr(frame), label)
        gtk_box_append(ptr(column), frame)
        gtk_box_append(
            ptr(column),
            Gtk.label(
                MediaTileReading.caption(name: name, kind: .video, duration: nil), css: "row-detail",
                selectable: false))
        return column
    }

    private static func video(
        _ ready: MediaDeck.Ready, name: String, reference: FileReference, key: String,
        context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        let stage = gtk_overlay_new()!
        Gtk.addClass(stage, "image-part")
        Gtk.addClass(stage, "media-frame")
        gtk_widget_set_halign(stage, GTK_ALIGN_START)
        let posterBits = context.texture(forKey: MediaDeck.posterKey(key))
        if posterBits != 0, let texture = OpaquePointer(bitPattern: Int(bitPattern: posterBits)) {
            let width = tailscode_texture_width(texture)
            let height = tailscode_texture_height(texture)
            let box = frameBox
            let scale = min(
                Double(box.0) / Double(max(1, width)),
                Double(ImagePreview.deskHeight) / Double(max(1, height)), 1)
            let fitted = (Int32(Double(width) * scale), Int32(Double(height) * scale))
            let picture = tailscode_picture_for_texture_sized(texture, fitted.0, fitted.1)!
            gtk_picture_set_content_fit(op(picture), GTK_CONTENT_FIT_CONTAIN)
            gtk_widget_set_size_request(picture, fitted.0, fitted.1)
            gtk_overlay_set_child(op(stage), picture)
        } else {
            let blank = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_widget_set_size_request(blank, frameBox.0, frameBox.1)
            gtk_overlay_set_child(op(stage), blank)
            if let poster = ready.poster { MediaDeck.shared.restorePoster(key, from: poster) }
        }
        let mark = Gtk.label("▶", css: "media-play", selectable: false)
        gtk_widget_set_halign(mark, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(mark, 0)
        gtk_overlay_add_overlay(op(stage), mark)
        if let length = MediaTileReading.progress(at: nil, of: ready.duration) {
            let chip = Gtk.label(length, css: "media-length", selectable: false)
            gtk_widget_set_halign(chip, GTK_ALIGN_END)
            gtk_widget_set_valign(chip, GTK_ALIGN_END)
            Gtk.margins(chip, 6)
            gtk_widget_set_can_target(chip, 0)
            gtk_overlay_add_overlay(op(stage), chip)
        }
        let opener = gtk_button_new()!
        Gtk.addClass(opener, "flat")
        Gtk.addClass(opener, "media-opener")
        gtk_widget_set_halign(opener, GTK_ALIGN_START)
        gtk_button_set_child(ptr(opener), stage)
        gtk_widget_set_tooltip_text(opener, Localized.text("Play %@", name))
        tailscode_set_accessible_label(opener, Localized.text("Play %@", name))
        let play = context.playMedia
        Gtk.connect(UnsafeMutableRawPointer(opener), "clicked") { play?(reference, key) }
        gtk_box_append(ptr(column), opener)
        gtk_box_append(
            ptr(column),
            Gtk.label(
                MediaTileReading.caption(name: name, kind: .video, duration: ready.duration),
                css: "row-detail", selectable: false))
        return column
    }

    /// A song as one line: a play button, its name, where it is against its length, and a bar that
    /// seeks. While it plays, the deck moves the button, the time and the bar where they stand.
    private static func audioLine(
        _ name: String, ready: MediaDeck.Ready?, key: String, context: TranscriptContext,
        reference: FileReference
    ) -> UnsafeMutablePointer<GtkWidget> {
        let deck = MediaDeck.shared
        let playing = deck.playingKey == key
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(line, "media-audio")
        gtk_widget_set_halign(line, GTK_ALIGN_START)
        gtk_widget_set_size_request(line, Int32(ImagePreview.deskWidth), -1)
        let running = playing && !deck.audioPaused
        let button = Gtk.button(running ? "⏸" : "▶", css: ["flat", "media-audio-button"], onClick: {})
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        let label = running ? Localized.text("Pause %@", name) : Localized.text("Play %@", name)
        gtk_widget_set_tooltip_text(button, label)
        tailscode_set_accessible_label(button, label)
        gtk_widget_set_sensitive(button, ready == nil ? 0 : 1)
        let play = context.playMedia
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { play?(reference, key) }
        gtk_box_append(ptr(line), button)
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(words, 1)
        gtk_widget_set_valign(words, GTK_ALIGN_CENTER)
        let title = Gtk.label(name, css: "media-audio-name", selectable: false)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_MIDDLE)
        gtk_box_append(ptr(words), title)
        let position = playing ? deck.audioPosition : nil
        let detail = Gtk.label(
            ready == nil
                ? Localized.text("Loading…")
                : MediaTileReading.progress(at: position, of: ready?.duration)
                    ?? MediaTileReading.kindWord(.audio),
            css: "row-detail", selectable: false)
        gtk_box_append(ptr(words), detail)
        let bar = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.001)!
        Gtk.addClass(bar, "media-audio-bar")
        gtk_scale_set_draw_value(ptr(bar), 0)
        gtk_range_set_value(ptr(bar), MediaTileReading.fraction(at: position, of: ready?.duration))
        gtk_widget_set_sensitive(bar, ready?.duration == nil ? 0 : 1)
        tailscode_set_accessible_label(bar, Localized.text("Position in %@", name))
        let seek = context.seekMedia
        let barBits = UInt(bitPattern: bar)
        Gtk.connect(UnsafeMutableRawPointer(bar), "value-changed") {
            guard !MediaDeck.shared.isSettingBar,
                let range = UnsafeMutablePointer<GtkWidget>(bitPattern: barBits)
            else { return }
            seek?(reference, key, gtk_range_get_value(ptr(range)))
        }
        gtk_box_append(ptr(words), bar)
        gtk_box_append(ptr(line), words)
        if ready != nil {
            deck.attach(
                key,
                line: MediaDeck.LiveLine(
                    button: UInt(bitPattern: button), detail: UInt(bitPattern: detail), bar: barBits))
        }
        return line
    }

    /// The quiet line a file stands as when it could not be had; one that may come back on a
    /// second try is a press that tries.
    private static func failed(
        _ failure: NamedMediaFailure, name: String, reference: FileReference, key: String,
        context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let words = Gtk.label(
            MediaTileReading.words(failure, name: name), css: "media-missing", selectable: false)
        guard failure.isRetryable else { return words }
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        gtk_widget_set_halign(button, GTK_ALIGN_START)
        gtk_button_set_child(ptr(button), words)
        let request = context.requestMedia
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { request?(reference, key, true) }
        return button
    }
}
