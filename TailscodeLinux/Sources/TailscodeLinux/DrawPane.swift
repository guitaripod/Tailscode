import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A picture being painted inside the split tree. The pane is a pane like any other — it splits,
/// resizes, zooms and closes with the same verbs — and what it holds is one endpoint plus one
/// prompt, small enough to survive a restart exactly as a stream or a page does.
///
/// The surface is a fusion of the three image UIs worth stealing from: the prompt bar lives at
/// the bottom where the hands already are (OpenAI), the chips that shape the ask sit in one row
/// above it and never open a menu (Grok), and the picture that comes back is the pane — full
/// bleed, click to open it full size, with the words that made it one glance away (Gemini).
/// Everything the model is asked, the pane says in its own body: engine, aspect, mode, and what
/// each one costs.
final class DrawPane: @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private(set) var slot: ImageGenSlot
    private var onChange: (@Sendable () -> Void)?

    private let askBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
    private(set) var entry = gtk_entry_new()!
    private let chipRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let engineChip: UnsafeMutablePointer<GtkWidget>
    private let aspectChip: UnsafeMutablePointer<GtkWidget>
    private let modeChip: UnsafeMutablePointer<GtkWidget>
    private let statusLabel = Gtk.label("", css: "draw-status", wrap: true, selectable: false)
    private let progressLabel = Gtk.label("", css: "draw-progress", selectable: false)
    private let stageBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    private let stageScroller = gtk_scrolled_window_new()!
    private let stageHolder = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
    private let noticeLabel = Gtk.label("", css: "video-notice", wrap: true, selectable: false)
    private let reasonLabel = Gtk.label("", css: "dim", wrap: true, selectable: false)
    private let historyLabel = Gtk.label("", css: "draw-history", selectable: false)

    /// The textures this pane owns, keyed by file path — a finished picture paints from its own
    /// bytes, fetched once, held until the pane closes.
    private var textures: [String: UInt] = [:]
    private var workingTexture: UInt = 0
    private var ticking = false
    private var referencePath: String?
    private var runner: ImageGenRunner?
    /// Where the renders actually run. A slot is pointed at one machine; the address survives a
    /// restart and the pane re-checks the server when it wakes.
    static var defaultEndpoint: ImageGenEndpoint {
        ImageGenDoor.current().endpoint ?? ImageGenEndpoint(host: "127.0.0.1")
    }

    init(endpoint: ImageGenEndpoint?) {
        slot = ImageGenSlot(endpoint: endpoint ?? Self.defaultEndpoint)
        slot.setEngine(ImageGenStore.engine())
        slot.setAspect(ImageGenStore.aspect())
        slot.setMode(ImageGenStore.mode())
        engineChip = Gtk.button("", css: ["draw-chip"], onClick: {})
        aspectChip = Gtk.button("", css: ["draw-chip"], onClick: {})
        modeChip = Gtk.button("", css: ["draw-chip"], onClick: {})
        buildRoot()
        render()
        refreshNotice()
        checkMachine()
    }

    /// Asks the machine whether it is there and whether it holds the model files, and files the
    /// answer where every surface can read it. Nothing here waits on it: the pane draws first and
    /// the sighting arrives when it arrives — a socket-activated ComfyUI takes the better part of
    /// a minute to wake, and a pane that stared at a spinner for it would be a pane that lied
    /// about what it knows.
    private func checkMachine() {
        let endpoint = slot.endpoint
        Task.detached {
            let health = await ImageGenClient(endpoint: endpoint).health()
            ImageGenStore.record(ImageGenSighting(endpoint: endpoint, health: health))
        }
    }

    /// Wires the chips once the pane exists — a closure over `self` cannot be built until every
    /// stored property is initialized, so the actions attach here rather than in `init`.
    func wireChips() {
        Gtk.connect(UnsafeMutableRawPointer(engineChip), "clicked") { [weak self] in
            self?.cycleEngine()
        }
        Gtk.connect(UnsafeMutableRawPointer(aspectChip), "clicked") { [weak self] in
            self?.cycleAspect()
        }
        Gtk.connect(UnsafeMutableRawPointer(modeChip), "clicked") { [weak self] in
            self?.cycleMode()
        }
    }

    var target: ImageGenEndpoint { slot.endpoint }
    var isAsking: Bool { slot.isAsking }
    var isBusy: Bool { slot.isBusy }

    /// One line for the headless driver: the phase, the chips, and what the stage is holding.
    var summary: String {
        let phase: String
        switch slot.phase {
        case .asking: phase = "asking"
        case .composing: phase = "composing"
        case .painting: phase = "painting"
        case .failed: phase = "failed"
        }
        let prompt: String
        switch slot.phase {
        case .asking: prompt = "-"
        case .composing(let text): prompt = text
        case .painting(let text, _, _): prompt = text
        case .failed(let text, _): prompt = text
        }
        return
            "draw \(phase) engine=\(slot.engine.rawValue) aspect=\(slot.aspect.rawValue) mode=\(slot.mode.rawValue) prompt=\(prompt.isEmpty ? "-" : prompt) tiles=\(slot.pictures.count) reason=\(slot.failure ?? "-")"
    }

    /// Types into the prompt as a person would, so the driver exercises the same path a
    /// keystroke does rather than a private one that could drift from it.
    func driverType(_ text: String) {
        focusPrompt()
        gtk_editable_set_text(op(entry), text)
    }

    func driverSubmit() {
        submit()
    }

    func focusPrompt() {
        gtk_widget_grab_focus(entry)
    }

    func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        onChange = handler
    }

    private func changed() {
        Gtk.onMain { [weak self] in
            guard let self else { return }
            self.refreshChips()
            self.onChange?()
        }
    }

    func shutdown() {
        runner?.cancel()
        for bits in textures.values {
            if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
        }
        textures = [:]
        if workingTexture != 0, let raw = UnsafeMutableRawPointer(bitPattern: workingTexture) {
            g_object_unref(raw)
        }
        workingTexture = 0
    }

    // MARK: - Building

    private func buildRoot() {
        Gtk.addClass(root, "canvas")
        Gtk.addClass(root, "draw-pane")
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)

        Gtk.addClass(askBox, "draw-ask")
        Gtk.margins(askBox, top: 12, bottom: 12, leading: 18, trailing: 18)
        gtk_widget_set_valign(askBox, GTK_ALIGN_END)
        gtk_widget_set_hexpand(askBox, 1)

        gtk_entry_set_placeholder_text(ptr(entry), ImageGenNotice.emptyBody)
        gtk_widget_set_hexpand(entry, 1)
        Gtk.addClass(entry, "draw-entry")
        Gtk.connect(UnsafeMutableRawPointer(entry), "activate") { [weak self] in
            self?.submit()
        }
        Gtk.addClass(chipRow, "draw-chips")
        gtk_widget_set_halign(chipRow, GTK_ALIGN_START)
        gtk_widget_set_hexpand(chipRow, 1)
        for chip in [engineChip, aspectChip, modeChip] {
            gtk_widget_set_halign(chip, GTK_ALIGN_START)
            gtk_box_append(ptr(chipRow), chip)
        }

        gtk_label_set_xalign(op(statusLabel), 0)
        gtk_label_set_xalign(op(progressLabel), 0)
        gtk_label_set_xalign(op(noticeLabel), 0)
        gtk_label_set_max_width_chars(op(noticeLabel), 46)
        gtk_label_set_xalign(op(historyLabel), 0)

        gtk_scrolled_window_set_policy(op(stageScroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
        gtk_scrolled_window_set_child(op(stageScroller), stageHolder)
        gtk_widget_set_vexpand(stageScroller, 1)
        gtk_widget_set_hexpand(stageScroller, 1)
        gtk_widget_set_hexpand(stageHolder, 1)
        Gtk.addClass(stageHolder, "draw-stage")

        gtk_box_append(ptr(askBox), stageScroller)
        gtk_box_append(ptr(askBox), statusLabel)
        gtk_box_append(ptr(askBox), progressLabel)
        gtk_box_append(ptr(askBox), reasonLabel)
        gtk_box_append(ptr(askBox), chipRow)
        gtk_box_append(ptr(askBox), entry)
        gtk_box_append(ptr(askBox), noticeLabel)
        gtk_box_append(ptr(root), askBox)
        gtk_box_append(ptr(root), historyLabel)
    }

    // MARK: - Rendering

    private func render() {
        Gtk.onMain { [weak self] in
            guard let self else { return }
            self.refreshChips()
            self.refreshStatus()
            self.refreshStage()
            self.refreshNotice()
        }
    }

    private func refreshChips() {
        gtk_button_set_label(ptr(engineChip), slot.engine.label)
        gtk_button_set_label(ptr(aspectChip), slot.aspect.label)
        gtk_button_set_label(ptr(modeChip), slot.mode.label)
    }

    private func refreshNotice() {
        let text = slot.isAsking ? ImageGenNotice.splitCostLine : ""
        gtk_label_set_text(op(noticeLabel), text)
        gtk_widget_set_visible(noticeLabel, slot.isAsking ? 1 : 0)
    }

    private func refreshStatus() {
        switch slot.phase {
        case .asking:
            gtk_label_set_text(op(statusLabel), slot.hint)
            gtk_label_set_text(op(progressLabel), "")
            gtk_widget_set_visible(progressLabel, 0)
        case .composing(let prompt):
            gtk_label_set_text(
                op(statusLabel),
                Localized.text(
                    "Ready — %@ · %@", slot.engine.label, prompt.ellipsized(to: 64)))
            gtk_label_set_text(op(progressLabel), "")
            gtk_widget_set_visible(progressLabel, 0)
        case .painting(let prompt, let engine, let mode):
            let verb = mode == .edit ? "Editing with" : "Painting with"
            gtk_label_set_text(
                op(statusLabel),
                Localized.text("%@ %@ — %@", verb, engine.label, prompt.ellipsized(to: 72)))
            gtk_label_set_text(op(progressLabel), slot.busyLine)
            gtk_widget_set_visible(progressLabel, 1)
        case .failed(let prompt, let reason):
            gtk_label_set_text(op(statusLabel), reason)
            gtk_label_set_text(op(progressLabel), prompt.ellipsized(to: 72))
            gtk_widget_set_visible(progressLabel, 1)
        }
    }

    private func refreshStage() {
        Gtk.removeChildren(of: stageHolder)
        if slot.isAsking {
            gtk_widget_set_visible(stageScroller, 0)
            return
        }
        gtk_widget_set_visible(stageScroller, 1)
        for picture in slot.pictures {
            stageHolder.appendTile(
                textureBits: textures[picture.path] ?? 0, caption: picture.prompt,
                onClick: { [weak self] in self?.open(picture) })
        }
        if slot.isBusy {
            stageHolder.appendWorking()
        }
        if slot.pictures.count > 1,
            let adjustment = gtk_scrolled_window_get_hadjustment(op(stageScroller))
        {
            let bits = UInt(bitPattern: adjustment)
            Gtk.after(50) {
                gtk_adjustment_set_value(UnsafeMutablePointer(bitPattern: bits), 0)
            }
        }
    }

    private func refreshIdentity() {
        onChange?()
    }

    // MARK: - Actions

    private func cycleEngine() {
        slot.advance(.engine)
        rememberChips()
        render()
    }

    private func cycleAspect() {
        slot.advance(.aspect)
        rememberChips()
        render()
    }

    private func cycleMode() {
        slot.advance(.mode)
        rememberChips()
        render()
        if slot.mode == .edit { offerReference() }
    }

    /// What was last drawn with is what the next slot opens on, on this machine and after a
    /// restart — three chips are a preference, not a per-pane accident.
    private func rememberChips() {
        ImageGenStore.remember(engine: slot.engine, aspect: slot.aspect, mode: slot.mode)
    }

    func handle(_ command: ImageGenCommand) {
        switch command {
        case .submit: submit()
        case .engine: cycleEngine()
        case .aspect: cycleAspect()
        case .mode: cycleMode()
        case .open:
            if let newest = slot.pictures.first { open(newest) }
        case .next, .previous:
            break
        case .bigger, .smaller:
            break
        }
    }

    func submit() {
        guard let raw = gtk_editable_get_text(op(entry)) else { return }
        let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        slot.begin(prompt: text)
        let engine = slot.engine
        let mode = slot.mode
        let aspect = slot.aspect
        let reference = mode == .edit ? referencePath : nil
        let fresh = ImageGenRunner(
            endpoint: slot.endpoint, prompt: text, engine: engine, mode: mode, aspect: aspect)
        runner = fresh
        render()
        let producing = fresh
        producing.run(
            prompt: text, engine: engine, mode: mode, aspect: aspect, referencePath: reference
        ) { [weak self] outcome in
            Gtk.onMain { [weak self] in
                self?.finished(outcome, from: producing)
            }
        }
        render()
    }

    /// The outcome is owned by the runner that produced it, not by whatever the pane is running
    /// now — a second submit while one paints must not steal the first's picture or its words.
    private func finished(_ outcome: ImageGenRunner.Outcome, from runner: ImageGenRunner) {
        switch outcome {
        case .picture(let data, let seconds):
            let path = ImageGenFiles.write(data, engine: runner.engine)
            let picture = ImageGenPicture(
                path: path, prompt: runner.prompt, engine: runner.engine, mode: runner.mode,
                aspect: runner.aspect, seconds: seconds, seed: runner.seed)
            slot.finish(picture)
            decode(picture.path, data: data)
        case .failure(let reason):
            slot.fail(prompt: runner.prompt, reason: reason)
        }
        if runner === self.runner { self.runner = nil }
        render()
    }

    private func decode(_ path: String, data: Data) {
        let bits: UInt = data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            var width: Int32 = 0
            var height: Int32 = 0
            guard let texture = tailscode_texture_scaled(
                base, gsize(data.count), 1024, &width, &height)
            else { return 0 }
            return UInt(bitPattern: UnsafeMutableRawPointer(texture))
        }
        guard bits != 0 else { return }
        if let stale = textures[path], let raw = UnsafeMutableRawPointer(bitPattern: stale) {
            g_object_unref(raw)
        }
        textures[path] = bits
        render()
    }

    private func offerReference() {
        Gtk.openFiles(parent: hostWindow) { [weak self] paths in
            guard let self, let path = paths.first else { return }
            self.referencePath = path
            Gtk.onMain { [weak self] in
                guard let self else { return }
                gtk_entry_set_placeholder_text(
                    ptr(self.entry),
                    Localized.text("What to change in %@…", (path as NSString).lastPathComponent))
                self.focusPrompt()
            }
        }
    }

    private func open(_ picture: ImageGenPicture) {
        guard let bits = textures[picture.path], bits != 0 else { return }
        DrawViewer.present(picture: picture, textureBits: bits, parent: hostWindow)
    }

    var hostWindow: UnsafeMutablePointer<GtkWidget>? {
        guard let root = gtk_widget_get_root(ptr(root)) else { return nil }
        return UnsafeMutablePointer(root)
    }
}

extension Gtk {
    fileprivate static func pictureWidget(bits: UInt)
        -> UnsafeMutablePointer<GtkWidget>?
    {
        guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return nil }
        guard let widget = tailscode_picture_for_texture(OpaquePointer(raw)) else { return nil }
        gtk_picture_set_content_fit(op(widget), GTK_CONTENT_FIT_CONTAIN)
        Gtk.addClass(widget, "draw-picture")
        return widget
    }
}

private extension UnsafeMutablePointer where Pointee == GtkWidget {
    func appendWorking() {
        let holder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        let pulse = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(pulse, "draw-working")
        gtk_widget_set_size_request(pulse, 240, 200)
        gtk_box_append(ptr(holder), pulse)
        let words = Gtk.label(Localized.text("Painting…"), css: "draw-status", selectable: false)
        gtk_box_append(ptr(holder), words)
        gtk_box_append(ptr(self), holder)
    }

    func appendTile(textureBits: UInt, caption: String, onClick: @escaping @Sendable () -> Void) {
        let holder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        let button = gtk_button_new()!
        Gtk.addClass(button, "draw-tile")
        let buttonPtr = UnsafeMutableRawPointer(button).assumingMemoryBound(to: GtkButton.self)
        if textureBits != 0, let picture = Gtk.pictureWidget(bits: textureBits) {
            gtk_button_set_child(buttonPtr, picture)
        } else {
            let placeholder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            Gtk.addClass(placeholder, "draw-tile-empty")
            gtk_widget_set_size_request(placeholder, 240, 200)
            gtk_button_set_child(buttonPtr, placeholder)
        }
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onClick)
        let words = Gtk.label(caption, css: "draw-caption", selectable: false)
        gtk_label_set_ellipsize(op(words), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(op(words), 44)
        gtk_box_append(ptr(holder), button)
        gtk_box_append(ptr(holder), words)
        gtk_box_append(ptr(self), holder)
    }
}

extension ImageGenSlot {
    var busyLine: String {
        if case .painting(_, let engine, let mode) = phase {
            let verb = mode == .edit ? Localized.text("editing") : Localized.text("painting")
            return Localized.text("%@ · %@", engine.label, verb)
        }
        return ""
    }
}