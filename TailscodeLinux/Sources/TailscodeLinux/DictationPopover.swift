import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What the mic says when it cannot listen yet, from the mic itself: the speech model this machine
/// needs, once, with its size, its license and where it runs, then a real bar while it downloads;
/// or why the microphone cannot be heard, with the one thing that can be tried. Never a toast and
/// never a command to paste.
final class DictationPopover: @unchecked Sendable {
    private let popover = gtk_popover_new()!
    private let anchor: UnsafeMutablePointer<GtkWidget>
    private let box = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
    private let chord: String?
    private let host: String
    private let retry: @Sendable () -> Void
    private var watch: UUID?
    private var face: DictationFace
    private var bar: UnsafeMutablePointer<GtkWidget>?
    private var meta: UnsafeMutablePointer<GtkWidget>?
    private var shownState: DictationModelStore.State?
    private var alive = true
    private var lines: [String] = []

    init(
        anchor: UnsafeMutablePointer<GtkWidget>, face: DictationFace, chord: String?, host: String,
        retry: @escaping @Sendable () -> Void
    ) {
        self.anchor = anchor
        self.face = face
        self.chord = chord
        self.host = host
        self.retry = retry
        gtk_widget_set_parent(popover, anchor)
        gtk_popover_set_position(ptr(popover), GTK_POS_TOP)
        Gtk.addClass(popover, "dictation-popover")
        Gtk.margins(box, top: 6, bottom: 6, leading: 6, trailing: 6)
        gtk_widget_set_size_request(box, 320, -1)
        gtk_popover_set_child(ptr(popover), box)
        Gtk.connect(UnsafeMutableRawPointer(popover), "closed") { [weak self] in
            Gtk.onMain { [weak self] in self?.dispose() }
        }
    }

    var isShown: Bool { alive && gtk_widget_get_visible(popover) != 0 }

    func present() {
        if case .blocked = face {
            fill(blocked: face)
        } else {
            watch = DictationModelStore.shared.watch { [weak self] state in
                Gtk.onMain { [weak self] in self?.show(state) }
            }
        }
        gtk_popover_popup(ptr(popover))
    }

    func close() {
        guard alive else { return }
        gtk_popover_popdown(ptr(popover))
    }

    private func dispose() {
        guard alive else { return }
        alive = false
        if let watch { DictationModelStore.shared.unwatch(watch) }
        watch = nil
        let address = UInt(bitPattern: popover)
        Gtk.after(50) {
            Gtk.onMain {
                guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
                gtk_widget_unparent(raw.assumingMemoryBound(to: GtkWidget.self))
            }
        }
    }

    private func clear() {
        while let child = gtk_widget_get_first_child(box) { gtk_box_remove(ptr(box), child) }
        bar = nil
        meta = nil
        lines = []
    }

    private func fill(blocked face: DictationFace) {
        clear()
        guard case .blocked(let problem) = face else { return }
        add(title: DictationReading.blockedTitle(problem))
        add(body: DictationReading.blockedBody(problem, device: Localized.text("computer")))
        actions([
            Gtk.button(DictationReading.tryAgain, css: ["suggested-action"]) { [weak self] in
                Gtk.onMain { [weak self] in
                    self?.retry()
                    self?.close()
                }
            }
        ])
    }

    private func show(_ state: DictationModelStore.State) {
        guard alive else { return }
        if case .installing(let download) = state, case .installing? = shownState, let bar, let meta {
            update(bar: bar, meta: meta, download: download)
            shownState = state
            return
        }
        shownState = state
        clear()
        add(title: DictationModelReading.title)
        add(body: DictationModelReading.body(host: host))
        facts()
        switch state {
        case .absent:
            actions([
                Gtk.button(DictationModelReading.download, css: ["suggested-action"]) {
                    DictationModelStore.shared.install()
                }
            ])
        case .installing(let download):
            let bar = tailscode_meter_new()!
            gtk_widget_set_hexpand(bar, 1)
            gtk_box_append(ptr(box), bar)
            let meta = Gtk.label("", css: "row-detail", selectable: false)
            gtk_widget_set_halign(meta, GTK_ALIGN_START)
            gtk_box_append(ptr(box), meta)
            self.bar = bar
            self.meta = meta
            update(bar: bar, meta: meta, download: download)
            actions([Gtk.button(DictationModelReading.cancel, css: []) { DictationModelStore.shared.cancel() }])
        case .installed:
            add(body: DictationModelReading.ready(chord: chord))
            retry()
            Gtk.after(2500) { [weak self] in Gtk.onMain { [weak self] in self?.close() } }
        case .failed:
            add(body: DictationModelReading.failed)
            actions([
                Gtk.button(DictationReading.tryAgain, css: ["suggested-action"]) {
                    DictationModelStore.shared.install()
                }
            ])
        }
    }

    private func update(bar: UnsafeMutablePointer<GtkWidget>, meta: UnsafeMutablePointer<GtkWidget>, download: DictationDownload) {
        let accent = PartyInk(hex: MatrixTheme.palette.accent)
        let ink = [accent.red, accent.green, accent.blue]
        ink.withUnsafeBufferPointer { tailscode_meter_set(bar, download.fraction, $0.baseAddress, 0.18, 6) }
        let words: String
        switch download.stage {
        case .unpacking, .ready: words = DictationModelReading.unpacking
        case .downloading:
            let left = DictationModelReading.remaining(seconds: download.secondsLeft)
            let done = DictationModelReading.progress(done: download.done, total: download.total)
            words = left.isEmpty ? done : "\(done) · \(left)"
        }
        gtk_label_set_text(op(meta), words)
    }

    private func facts() {
        let grid = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        Gtk.addClass(grid, "dictation-facts")
        let rows = [
            (DictationModelReading.modelLabel, DictationModelPack.modelName),
            (DictationModelReading.sizeLabel, DictationReading.bytes(DictationModelPack.totalBytes)),
            (DictationModelReading.licenseLabel, DictationModelPack.license),
        ]
        for (label, value) in rows {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
            let name = Gtk.label(label, css: "row-detail", selectable: false)
            gtk_widget_set_hexpand(name, 1)
            gtk_widget_set_halign(name, GTK_ALIGN_START)
            gtk_box_append(ptr(row), name)
            gtk_box_append(ptr(row), Gtk.label(value, selectable: false))
            gtk_box_append(ptr(grid), row)
        }
        gtk_box_append(ptr(box), grid)
    }

    private func add(title: String) {
        lines.append(title)
        let label = Gtk.label(title, css: "dictation-popover-title", selectable: false)
        gtk_widget_set_halign(label, GTK_ALIGN_START)
        gtk_box_append(ptr(box), label)
    }

    private func add(body: String) {
        lines.append(body)
        let label = Gtk.label(body, css: "row-detail", selectable: false)
        gtk_label_set_wrap(op(label), 1)
        gtk_label_set_xalign(op(label), 0)
        gtk_label_set_max_width_chars(op(label), 44)
        gtk_box_append(ptr(box), label)
    }

    private func actions(_ buttons: [UnsafeMutablePointer<GtkWidget>]) {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(row, GTK_ALIGN_END)
        for button in buttons { gtk_box_append(ptr(row), button) }
        gtk_box_append(ptr(box), row)
    }

    var harnessText: String {
        let progress = meta.flatMap { gtk_label_get_text(op($0)).map { String(cString: $0) } }
        return (lines + [progress].compactMap { $0 }).joined(separator: " | ")
    }
}
