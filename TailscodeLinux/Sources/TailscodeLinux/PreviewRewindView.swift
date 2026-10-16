import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The Rewind lens: the last ten seconds of the screen, every picture the host held with the
/// moment it was taken, under a scrubber. Play runs them at the speed they happened. A frame that
/// arrived late is an amber tick on the scrubber, counted in a line beneath.
///
/// The clip is fetched when the lens is opened and dropped when it is left. Only the picture on
/// show is ever decoded, and the one timer that exists is the one Play starts.
final class PreviewRewindView: PreviewLensView, @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)

    struct Frame: Sendable {
        var microseconds: UInt64
        var jpeg: Data
    }

    private let context: PreviewLensContext
    private let pages = gtk_stack_new()!
    private let message = Gtk.label("", css: "preview-status", wrap: true, selectable: false)
    private let frame = gtk_aspect_frame_new(0.5, 0.5, 0.5, 0)!
    private let picture = gtk_picture_new()!
    private let scrubber = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 1)!
    private let ticks: UnsafeMutablePointer<GtkWidget>
    private let timeLabel = Gtk.label("", css: "preview-row-detail", selectable: false)
    private let slowLabel = Gtk.label("", css: "preview-row-detail", selectable: false)
    private let playButton: UnsafeMutablePointer<GtkWidget>

    private(set) var frames: [Frame] = []
    private(set) var markedSlowFrames: [Int] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var decodedFrames = 0
    private var shownIndex = -1
    private var pictureSize: (width: Int, height: Int)?
    private var settingScrubber = false

    init(context: PreviewLensContext) {
        self.context = context
        playButton = Gtk.button(Localized.text("Play"), css: ["preview-chip"]) {}
        ticks = tailscode_scrub_ticks_new(scrubber)!
        build()
    }

    private func build() {
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)

        gtk_picture_set_content_fit(op(picture), GTK_CONTENT_FIT_FILL)
        gtk_picture_set_can_shrink(op(picture), 1)
        gtk_widget_set_hexpand(picture, 1)
        gtk_widget_set_vexpand(picture, 1)
        let overlay = gtk_overlay_new()!
        Gtk.addClass(overlay, "preview-picture")
        gtk_widget_set_overflow(overlay, GTK_OVERFLOW_HIDDEN)
        gtk_overlay_set_child(op(overlay), picture)
        gtk_widget_set_hexpand(frame, 1)
        gtk_widget_set_vexpand(frame, 1)
        Gtk.margins(frame, top: 10, bottom: 6, leading: 14, trailing: 14)
        gtk_aspect_frame_set_child(op(frame), overlay)

        let previous = Gtk.button("◀", css: ["preview-chip"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.step(-1) }
        }
        let next = Gtk.button("▶", css: ["preview-chip"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.step(1) }
        }
        gtk_widget_set_tooltip_text(previous, Localized.text("Previous frame"))
        gtk_widget_set_tooltip_text(next, Localized.text("Next frame"))
        Gtk.connect(UnsafeMutableRawPointer(playButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.togglePlay() }
        }

        Gtk.addClass(scrubber, "preview-scrub")
        gtk_scale_set_draw_value(ptr(scrubber), 0)
        gtk_widget_set_hexpand(scrubber, 1)
        gtk_widget_set_valign(scrubber, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(scrubber, -1, 32)
        let track = gtk_overlay_new()!
        gtk_widget_set_hexpand(track, 1)
        gtk_widget_set_valign(track, GTK_ALIGN_CENTER)
        gtk_overlay_set_child(op(track), scrubber)
        gtk_overlay_add_overlay(op(track), ticks)
        Gtk.connect(UnsafeMutableRawPointer(scrubber), "value-changed") { [weak self] in
            Gtk.onMain { [weak self] in self?.scrubbed() }
        }

        let controls = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(controls, top: 4, bottom: 0, leading: 14, trailing: 14)
        gtk_box_append(ptr(controls), previous)
        gtk_box_append(ptr(controls), playButton)
        gtk_box_append(ptr(controls), next)
        gtk_box_append(ptr(controls), track)
        gtk_box_append(ptr(controls), timeLabel)

        Gtk.margins(slowLabel, top: 0, bottom: 12, leading: 16, trailing: 14)

        let clip = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(clip, 1)
        gtk_widget_set_vexpand(clip, 1)
        gtk_box_append(ptr(clip), frame)
        gtk_box_append(ptr(clip), controls)
        gtk_box_append(ptr(clip), slowLabel)

        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_valign(words, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(words, GTK_ALIGN_CENTER)
        Gtk.margins(words, 24)
        PreviewPane.capWidth(message, 36)
        gtk_label_set_justify(op(message), GTK_JUSTIFY_CENTER)
        gtk_label_set_xalign(op(message), 0.5)
        gtk_box_append(ptr(words), message)

        gtk_widget_set_hexpand(pages, 1)
        gtk_widget_set_vexpand(pages, 1)
        gtk_stack_set_transition_type(op(pages), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_add_named(op(pages), clip, "clip")
        gtk_stack_add_named(op(pages), words, "message")
        gtk_stack_set_visible_child_name(op(pages), "message")
        gtk_box_append(ptr(root), pages)
    }

    func open() {
        guard let runner = context.runner() else {
            show(message: PreviewLensFailure.unreachable)
            return
        }
        context.tasks.spawn(slot: "replay") { [weak self] in
            do {
                let records = try await runner.replay(seconds: 10)
                let taken: [Frame] = records.compactMap { record in
                    guard case .frame(let microseconds, let jpeg) = record else { return nil }
                    return Frame(microseconds: microseconds, jpeg: jpeg)
                }
                Gtk.onMain { [weak self] in self?.load(taken) }
            } catch {
                guard !Task.isCancelled else { return }
                Gtk.onMain { [weak self] in self?.show(message: PreviewLensFailure.words(for: error)) }
            }
        }
    }

    func close() {
        isPlaying = false
        paintPlay()
        frames = []
        markedSlowFrames = []
        index = 0
        shownIndex = -1
        decodedFrames = 0
        pictureSize = nil
        gtk_picture_set_paintable(op(picture), nil)
        tailscode_scrub_ticks_set(ticks, nil, 0, nil)
        gtk_label_set_text(op(slowLabel), "")
        gtk_label_set_text(op(timeLabel), "")
    }

    private func show(message text: String) {
        gtk_label_set_text(op(message), text)
        gtk_stack_set_visible_child_name(op(pages), "message")
    }

    func load(_ clip: [Frame]) {
        close()
        let ordered = clip.sorted { $0.microseconds < $1.microseconds }
        guard let first = ordered.first?.microseconds, ordered.count > 0 else {
            show(message: Localized.text("Nothing moved on the screen in the last ten seconds"))
            return
        }
        frames = ordered.map { Frame(microseconds: $0.microseconds - first, jpeg: $0.jpeg) }
        let times = frames.map(\.microseconds)
        markedSlowFrames = PreviewRewindReading.slowFrames(times)
        settingScrubber = true
        gtk_range_set_range(ptr(scrubber), 0, max(1, Double(times[times.count - 1]) / 1000))
        gtk_range_set_value(ptr(scrubber), 0)
        settingScrubber = false
        paintTicks()
        gtk_label_set_text(
            op(slowLabel),
            frames.count > 1
                ? PreviewRewindReading.line(markedSlowFrames.count)
                : Localized.text("The screen held still, so there is only one picture"))
        gtk_widget_set_sensitive(playButton, frames.count > 1 ? 1 : 0)
        gtk_widget_set_sensitive(scrubber, frames.count > 1 ? 1 : 0)
        gtk_stack_set_visible_child_name(op(pages), "clip")
        showFrame(0)
    }

    private func paintTicks() {
        let span = Double(max(1, frames.last?.microseconds ?? 1))
        let places = markedSlowFrames.map { Double(frames[$0].microseconds) / span }
        let ink = PresenceRGB(hex: MatrixTheme.palette.warn) ?? PresenceRGB(red: 0.9, green: 0.6, blue: 0.1)
        let rgb = [ink.red, ink.green, ink.blue]
        places.withUnsafeBufferPointer { places in
            rgb.withUnsafeBufferPointer { rgb in
                tailscode_scrub_ticks_set(ticks, places.baseAddress, Int32(places.count), rgb.baseAddress)
            }
        }
    }

    /// The desk changed its palette: the late-frame ticks again, in the new warning ink.
    func retheme() {
        paintTicks()
    }

    /// Where each tick stands on the scrubber, in its own pixels.
    var tickPositions: [Double] {
        var out = [Double](repeating: 0, count: max(1, markedSlowFrames.count))
        let written = tailscode_scrub_ticks_plan(ticks, &out, Int32(out.count))
        return written <= 0 ? [] : Array(out.prefix(Int(written)))
    }

    private var totalSeconds: Double { Double(frames.last?.microseconds ?? 0) / 1_000_000 }

    /// Shows the frame at an index. The scrubber follows it unless the hand is on the scrubber,
    /// where it stays under the pointer rather than jumping back to the frame it landed on.
    func showFrame(_ target: Int, movingScrubber: Bool = true) {
        guard frames.indices.contains(target) else { return }
        index = target
        paintTime()
        if movingScrubber {
            settingScrubber = true
            gtk_range_set_value(ptr(scrubber), Double(frames[target].microseconds) / 1000)
            settingScrubber = false
        }
        guard shownIndex != target else { return }
        let bits = LensDecode.bits(frames[target].jpeg)
        guard bits != 0, let size = Gtk.textureSize(bits: bits) else {
            LensDecode.release(bits)
            return
        }
        Gtk.replacePicture(of: picture, bits: bits)
        LensDecode.release(bits)
        shownIndex = target
        decodedFrames += 1
        if pictureSize?.width != size.width || pictureSize?.height != size.height {
            gtk_aspect_frame_set_ratio(op(frame), Float(size.width) / Float(size.height))
        }
        pictureSize = size
    }

    private func paintTime() {
        let now = Double(frames.indices.contains(index) ? frames[index].microseconds : 0) / 1_000_000
        gtk_label_set_text(
            op(timeLabel), Localized.text("%@ s", String(format: "%.2f / %.2f", now, totalSeconds)))
    }

    private func scrubbed() {
        guard !settingScrubber, !frames.isEmpty else { return }
        pause()
        let target = PreviewRewindReading.index(
            atMicroseconds: UInt64(max(0, gtk_range_get_value(ptr(scrubber))) * 1000), in: frames.map(\.microseconds))
        showFrame(target, movingScrubber: false)
    }

    func seek(fraction: Double) {
        guard !frames.isEmpty else { return }
        pause()
        let span = Double(frames[frames.count - 1].microseconds)
        showFrame(PreviewRewindReading.index(atMicroseconds: UInt64(max(0, min(1, fraction)) * span), in: frames.map(\.microseconds)))
    }

    func step(_ direction: Int) {
        guard !frames.isEmpty else { return }
        pause()
        showFrame(max(0, min(frames.count - 1, index + direction)))
    }

    func togglePlay() {
        if isPlaying {
            pause()
            return
        }
        guard frames.count > 1 else { return }
        if index >= frames.count - 1 { showFrame(0) }
        isPlaying = true
        paintPlay()
        let times = frames.map(\.microseconds)
        let start = index
        context.tasks.spawn(slot: "play") { [weak self] in
            let clock = ContinuousClock()
            let origin = clock.now
            let base = times[start]
            while !Task.isCancelled {
                let spent = clock.now - origin
                let micros = UInt64(max(0, spent.components.seconds)) * 1_000_000
                    + UInt64(max(0, spent.components.attoseconds / 1_000_000_000_000))
                let target = PreviewRewindReading.index(atMicroseconds: base + micros, in: times)
                let last = target >= times.count - 1
                Gtk.onMain { [weak self] in
                    guard let self, self.isPlaying else { return }
                    self.showFrame(target)
                    if last { self.pause() }
                }
                if last { return }
                let wait = times[target + 1] - min(times[target + 1], base + micros)
                try? await Task.sleep(for: .microseconds(Int(max(1, wait))))
            }
        }
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        context.tasks.cancel(slot: "play")
        paintPlay()
    }

    private func paintPlay() {
        gtk_button_set_label(ptr(playButton), isPlaying ? Localized.text("Pause") : Localized.text("Play"))
    }

    var noteText: String { gtk_label_get_text(op(slowLabel)).map(String.init(cString:)) ?? "" }

    var summary: String {
        "rewind frames=\(frames.count) slow=\(markedSlowFrames.count) index=\(index) playing=\(isPlaying)"
    }

    func drive(_ command: String) -> Bool {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "seek":
            guard parts.count > 1, let fraction = Double(parts[1]) else { return false }
            seek(fraction: fraction)
        case "step":
            guard parts.count > 1, let direction = Int(parts[1]) else { return false }
            step(direction)
        case "play": togglePlay()
        default: return false
        }
        return true
    }
}

extension PreviewRewindReading {
    /// The last frame taken at or before a moment, so a scrubber lands on the picture that was on
    /// screen then rather than the next one.
    static func index(atMicroseconds moment: UInt64, in times: [UInt64]) -> Int {
        guard !times.isEmpty else { return 0 }
        var low = 0
        var high = times.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if times[middle] <= moment { low = middle } else { high = middle - 1 }
        }
        return low
    }
}
