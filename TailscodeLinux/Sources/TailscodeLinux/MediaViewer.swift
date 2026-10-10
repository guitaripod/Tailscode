import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The picture viewer, risen as a sheet in the window rather than opened as one of its own. It is
/// the conversation's gallery — every picture of the chat, paged — and the Studio's own viewer —
/// one finished picture with its making named — in one body: a toolbar of previous and next, the
/// file's name with `n of m`, and the actions; a canvas the pictures are judged on; and Done.
///
/// It stands on the first free layer of the window's `SheetStack`: the bottom one over a
/// conversation, the one above the Studio over the Studio, with the same insets pushed in by Core's
/// depth so the Studio's edge shows above it. One viewer exists at a time; asking for another while
/// it is up changes what it shows, with no motion.
///
/// A page paints the preview texture the transcript already holds and sharpens when the original's
/// full-resolution decode lands, so a page turn is instant. What a save or a copy hands over is the
/// original bytes, never the preview, whose size is the transcript's rather than the picture's.
final class MediaViewer: @unchecked Sendable {
    /// One more thing the viewer can do with the picture in front of it.
    struct Action: Sendable {
        let title: String
        let run: @Sendable () -> Void
    }

    /// A picture the viewer can show, described by what it can be asked rather than by where it
    /// came from: the conversation's pictures live in a transcript cache and the Studio's on disk.
    struct Item: Sendable {
        let key: String
        let name: String
        /// A line about how the picture was made, for the line under its name.
        let facts: String?
        /// Everything that is worth reading in full and does not fit under the name.
        let tooltip: String?
        /// The texture on hand to paint, or 0 while there is none.
        let texture: @Sendable () -> UInt
        /// The picture's own pixel size when it is known without decoding it.
        let dimensions: @Sendable () -> (Int32, Int32)?
        /// The original bytes, or nil while they are not on this device.
        let original: @Sendable () -> Data?
        /// Asks for the pixels to be brought here, when there is nothing to paint.
        let fetch: @Sendable () -> Void
        /// Lets go of anything the viewer held for this picture.
        let release: @Sendable () -> Void
        let actions: [Action]
    }

    nonisolated(unsafe) private static var open: MediaViewer?

    /// The viewer while it stands on a layer, for the headless driver and for anything that asks.
    static var current: MediaViewer? { open }

    /// How a source says it has a new picture for a key: it is handed what to call, and returns how
    /// to stop being told.
    typealias Landing = (@escaping @Sendable (String) -> Void) -> (@Sendable () -> Void)

    /// Shows `items`, on the one with `startKey`. A viewer already up is re-targeted to them with no
    /// motion; otherwise one rises on the first free layer of the window's stack.
    static func present(
        items: [Item], startKey: String, landing: Landing? = nil,
        notice: @escaping @Sendable (String) -> Void
    ) {
        guard !items.isEmpty, let stack = SheetStack.shared else {
            items.forEach { $0.release() }
            return
        }
        let start = items.firstIndex { $0.key == startKey } ?? 0
        if let viewer = open {
            viewer.retarget(items: items, start: start, landing: landing, notice: notice)
            viewer.layer.present()
            return
        }
        let viewer = MediaViewer(
            stack: stack, items: items, start: start, landing: landing, notice: notice)
        open = viewer
        viewer.layer.present()
    }

    private var items: [Item]
    private var pager: ViewerPager
    private(set) var zoom = ViewerZoom.fit
    private let layer: SheetLayer
    private var notice: @Sendable (String) -> Void
    private var stopListening: (@Sendable () -> Void)?
    private var noticeText: String?
    private var noticeEnds: Date?
    private var lastRelease: Double = 0
    private let driving: Bool

    private let titleLabel = Gtk.label("", css: "viewer-title", selectable: false)
    private let subLabel = Gtk.label("", css: "viewer-sub", selectable: false)
    private let previousButton: UnsafeMutablePointer<GtkWidget>
    private let nextButton: UnsafeMutablePointer<GtkWidget>
    private let zoomButton: UnsafeMutablePointer<GtkWidget>
    private let copyButton: UnsafeMutablePointer<GtkWidget>
    private let saveButton: UnsafeMutablePointer<GtkWidget>
    private let moreButton: UnsafeMutablePointer<GtkWidget>
    private let doneButton: UnsafeMutablePointer<GtkWidget>
    private let menu: ActionBox
    private let scroller = gtk_scrolled_window_new()!
    private let holder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)

    /// The one full-resolution texture the viewer may own: the page being looked at. The
    /// transcript keeps only downsampled previews, so a page sharpens from the original bytes, and
    /// a page turned away from hands its texture back.
    private var fullKey: String?
    private var fullBits: UInt = 0

    /// How many times a page has been drawn, which a harness reads to prove a move or a re-target
    /// drew what it claims to.
    private(set) var renders = 0

    private init(
        stack: SheetStack, items: [Item], start: Int, landing: Landing?,
        notice: @escaping @Sendable (String) -> Void
    ) {
        self.items = items
        self.pager = ViewerPager(count: items.count, index: start)
        self.notice = notice
        self.layer = stack.viewerLayer
        self.driving = ProcessInfo.processInfo.environment["TAILSCODE_DRIVE"] != nil
        previousButton = Gtk.button("‹", css: ["viewer-button"], onClick: {})
        nextButton = Gtk.button("›", css: ["viewer-button"], onClick: {})
        zoomButton = Gtk.button(ViewerZoom.fit.buttonWord, css: ["viewer-button"], onClick: {})
        copyButton = Gtk.button(Localized.text("Copy"), css: ["viewer-button"], onClick: {})
        saveButton = Gtk.button(Localized.text("Save to Downloads"), css: ["viewer-button"], onClick: {})
        let menu = ActionBox()
        self.menu = menu
        moreButton = Gtk.menuButton(
            "⋯", css: ["viewer-button"],
            rows: { menu.actions.map { (title: $0.title, detail: nil, action: $0.run) } })
        doneButton = Gtk.button(Localized.text("Done"), css: ["studio-done", "viewer-done"], onClick: {})
        build()
        listen(landing)
    }

    private func build() {
        layer.name = "viewer"
        layer.setDialogName(Localized.text("Picture viewer, dialog"))
        layer.addSheetClass("viewer-sheet")
        layer.detail = { [weak self] in self?.currentKey ?? "" }
        layer.prepare = { [weak self] in self?.render() }
        layer.retarget = { [weak self] in self?.render() }
        layer.focusInitial = { [weak self] in
            guard let self else { return }
            gtk_widget_grab_focus(self.scroller)
        }
        layer.onClosed = { [weak self] in self?.tearDown() }
        layer.keys = { [weak self] keyval, state in
            self?.handleKey(keyval: keyval, state: state) ?? false
        }

        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_NEVER)
        gtk_widget_set_hexpand(scroller, 1)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_widget_set_focusable(scroller, 1)
        Gtk.addClass(scroller, "viewer-canvas")
        gtk_scrolled_window_set_child(op(scroller), holder)

        layer.install(toolbar: makeToolbar(), body: scroller)
    }

    private func makeToolbar() -> UnsafeMutablePointer<GtkWidget> {
        let bar = gtk_center_box_new()!
        Gtk.addClass(bar, "studio-sheet-bar")
        Gtk.addClass(bar, "viewer-bar")
        gtk_widget_set_size_request(bar, -1, Int32(StudioSheetMetrics.toolbarHeight))

        let paging = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 4)
        gtk_widget_set_valign(paging, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(previousButton, Localized.text("Previous picture (←)"))
        gtk_widget_set_tooltip_text(nextButton, Localized.text("Next picture (→)"))
        gtk_box_append(ptr(paging), previousButton)
        gtk_box_append(ptr(paging), nextButton)
        gtk_center_box_set_start_widget(op(bar), paging)

        let middle = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_valign(middle, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(middle, GTK_ALIGN_CENTER)
        for label in [titleLabel, subLabel] {
            gtk_label_set_xalign(op(label), 0.5)
            gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(op(label), 64)
            gtk_widget_set_halign(label, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(middle), label)
        }
        gtk_center_box_set_center_widget(op(bar), middle)

        let trailing = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_valign(trailing, GTK_ALIGN_CENTER)
        for button in [zoomButton, copyButton, saveButton, moreButton, doneButton] {
            gtk_box_append(ptr(trailing), button)
        }
        gtk_center_box_set_end_widget(op(bar), trailing)

        for button in [previousButton, nextButton, zoomButton, copyButton, saveButton, doneButton] {
            gtk_widget_set_focus_on_click(button, 0)
        }
        wire(previousButton) { $0.perform(.previous) }
        wire(nextButton) { $0.perform(.next) }
        wire(zoomButton) { $0.perform(.toggleZoom) }
        wire(copyButton) { $0.perform(.copy) }
        wire(saveButton) { $0.perform(.save) }
        wire(doneButton) { $0.perform(.close) }
        gtk_widget_set_tooltip_text(zoomButton, Localized.text("Zoom"))
        return bar
    }

    private func wire(
        _ button: UnsafeMutablePointer<GtkWidget>, _ action: @escaping @Sendable (MediaViewer) -> Void
    ) {
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                action(self)
            }
        }
    }

    private func listen(_ landing: Landing?) {
        stopListening?()
        stopListening = landing?({ [weak self] key in
            Gtk.onMain { [weak self] in
                guard let self, key == self.currentKey else { return }
                self.render()
            }
        })
    }

    private func retarget(
        items next: [Item], start: Int, landing: Landing?, notice: @escaping @Sendable (String) -> Void
    ) {
        dropFull()
        items.forEach { $0.release() }
        items = next
        pager = ViewerPager(count: next.count, index: start)
        zoom = .fit
        self.notice = notice
        listen(landing)
    }

    private var currentKey: String { items[pager.index].key }

    private var currentItem: Item { items[pager.index] }

    private func tearDown() {
        stopListening?()
        stopListening = nil
        dropFull()
        items.forEach { $0.release() }
        layer.uninstall()
        if Self.open === self { Self.open = nil }
    }

    /// What a command does: the page moves, the zoom changes, the picture is copied or saved, or the
    /// sheet leaves. Every key and every button comes here, so the two cannot drift.
    func perform(_ command: ViewerCommand) {
        switch command {
        case .previous: page(.previous)
        case .next: page(.next)
        case .first: page(.first)
        case .last: page(.last)
        case .zoomIn:
            zoom = zoom.zoomedIn(fit: fitScale)
            render()
        case .zoomOut:
            zoom = zoom.zoomedOut(fit: fitScale)
            render()
        case .fit:
            zoom = .fit
            render()
        case .actualSize:
            zoom = .actual
            render()
        case .toggleZoom:
            zoom = zoom.toggled
            render()
        case .copy: copy()
        case .save: save()
        case .close: layer.dismiss()
        }
    }

    private func page(_ command: ViewerCommand) {
        guard pager.canPage else { return }
        switch command {
        case .previous: pager.advance(by: -1)
        case .next: pager.advance(by: 1)
        case .first: pager.first()
        default: pager.last()
        }
        zoom = .fit
        render()
    }

    /// The scale that fits the page being looked at into the room the canvas has.
    private var fitScale: Double {
        let room = (width: Double(gtk_widget_get_width(scroller)), height: Double(gtk_widget_get_height(scroller)))
        guard let size = pixelSize(of: currentItem), size.0 > 0, size.1 > 0, room.width > 0, room.height > 0
        else { return 1 }
        return min(room.width / Double(size.0), room.height / Double(size.1))
    }

    private func texture(for item: Item) -> (bits: UInt, isFull: Bool) {
        if fullKey == item.key, fullBits != 0 { return (fullBits, true) }
        return (item.texture(), false)
    }

    private func pixelSize(of item: Item) -> (Int32, Int32)? {
        let shown = texture(for: item)
        if shown.isFull, let texture = OpaquePointer(bitPattern: Int(bitPattern: shown.bits)) {
            return (tailscode_texture_width(texture), tailscode_texture_height(texture))
        }
        if let known = item.dimensions() { return known }
        guard shown.bits != 0, let texture = OpaquePointer(bitPattern: Int(bitPattern: shown.bits)) else {
            return nil
        }
        return (tailscode_texture_width(texture), tailscode_texture_height(texture))
    }

    private func render() {
        renders += 1
        let item = currentItem
        gtk_label_set_text(op(titleLabel), item.name)
        gtk_widget_set_tooltip_text(titleLabel, item.tooltip)
        let paging = pager.canPage
        gtk_widget_set_visible(previousButton, paging ? 1 : 0)
        gtk_widget_set_visible(nextButton, paging ? 1 : 0)
        refreshActions()
        Gtk.removeChildren(of: holder)

        let shown = texture(for: item)
        guard shown.bits != 0, let texture = OpaquePointer(bitPattern: Int(bitPattern: shown.bits)) else {
            refreshSubline(size: nil)
            gtk_widget_set_hexpand(holder, 1)
            let loading = Gtk.label(Localized.text("Loading…"), css: "viewer-loading", selectable: false)
            gtk_widget_set_hexpand(loading, 1)
            gtk_widget_set_vexpand(loading, 1)
            gtk_label_set_xalign(op(loading), Float(0.5))
            gtk_box_append(ptr(holder), loading)
            item.fetch()
            reportState(texture: nil, size: nil, full: false)
            return
        }

        let size = pixelSize(of: item) ?? (tailscode_texture_width(texture), tailscode_texture_height(texture))
        refreshSubline(size: size)
        gtk_button_set_label(ptr(zoomButton), zoom.buttonWord)

        let picture = tailscode_picture_for_texture(texture)!
        if zoom.isFit {
            gtk_picture_set_content_fit(op(picture), GTK_CONTENT_FIT_CONTAIN)
            gtk_widget_set_hexpand(picture, 1)
            gtk_widget_set_vexpand(picture, 1)
            gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_NEVER)
        } else {
            let scale = zoom.scale(fit: fitScale)
            gtk_picture_set_content_fit(op(picture), GTK_CONTENT_FIT_FILL)
            gtk_widget_set_size_request(
                picture, Int32((Double(size.0) * scale).rounded()), Int32((Double(size.1) * scale).rounded()))
            gtk_widget_set_halign(picture, GTK_ALIGN_CENTER)
            gtk_widget_set_valign(picture, GTK_ALIGN_CENTER)
            gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        }
        Gtk.onRelease(picture) { [weak self] in
            Gtk.onMain { [weak self] in self?.pictureClicked() }
        }
        gtk_box_append(ptr(holder), picture)
        if !shown.isFull { requestFull(item) }
        reportState(texture: (tailscode_texture_width(texture), tailscode_texture_height(texture)), size: size, full: shown.isFull)
    }

    /// Two releases close together are a double-click, which is the zoom; one is nothing, so a
    /// press that lands to focus the canvas never zooms by accident.
    private func pictureClicked() {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        defer { lastRelease = now }
        guard now - lastRelease < Self.doubleClick else { return }
        lastRelease = 0
        perform(.toggleZoom)
    }

    private static let doubleClick: Double = 0.4

    private func refreshSubline(size: (Int32, Int32)?) {
        var parts: [String] = []
        if let counter = pager.counter { parts.append(counter) }
        if let size { parts.append("\(size.0)×\(size.1)") }
        if let label = zoomLabel { parts.append(label) }
        if let facts = currentItem.facts, !facts.isEmpty { parts.append(facts) }
        let line = noticeText ?? parts.joined(separator: " · ")
        gtk_label_set_text(op(subLabel), line.isEmpty ? "\u{00A0}" : line)
    }

    private var zoomLabel: String? {
        switch zoom {
        case .fit: return nil
        case .scaled(let value): return zoom.isActual ? Localized.text("1:1") : "\(Int((value * 100).rounded()))%"
        }
    }

    private func refreshActions() {
        let actions = currentItem.actions
        gtk_widget_set_visible(moreButton, actions.isEmpty ? 0 : 1)
        let popover = gtk_menu_button_get_popover(op(moreButton))
        if let popover { gtk_popover_popdown(popover) }
        menu.actions = actions
    }

    /// What the "more" menu lists, read when it opens and set whenever the page changes.
    private final class ActionBox: @unchecked Sendable {
        var actions: [Action] = []
    }

    /// Decodes the page's original bytes off the main context and swaps them in when they land; the
    /// preview stays up until then.
    private func requestFull(_ item: Item) {
        guard fullKey != item.key, let data = item.original() else { return }
        let key = item.key
        Task { [weak self] in
            let bits: UInt = data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress,
                    let texture = tailscode_texture_from_bytes(base, gsize(buffer.count))
                else { return UInt(0) }
                return UInt(bitPattern: texture)
            }
            guard bits != 0 else { return }
            Gtk.onMain { [weak self] in
                guard let self, self.layer.isUp, let at = self.items.firstIndex(where: { $0.key == key })
                else {
                    if let texture = OpaquePointer(bitPattern: Int(bitPattern: bits)) {
                        g_object_unref(UnsafeMutableRawPointer(texture))
                    }
                    return
                }
                self.dropFull()
                self.fullKey = key
                self.fullBits = bits
                if at == self.pager.index { self.render() }
            }
        }
    }

    private func dropFull() {
        if fullBits != 0, let texture = OpaquePointer(bitPattern: Int(bitPattern: fullBits)) {
            g_object_unref(UnsafeMutableRawPointer(texture))
        }
        fullKey = nil
        fullBits = 0
    }

    /// Says one thing under the file's name for a few seconds. A confirmation is shown where the
    /// person is looking rather than in the conversation behind the scrim.
    private func say(_ text: String) {
        let ends = Date().addingTimeInterval(4)
        noticeEnds = ends
        noticeText = text
        refreshSubline(size: pixelSize(of: currentItem))
        notice(text)
        Gtk.after(4000) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.noticeEnds == ends else { return }
                self.noticeEnds = nil
                self.noticeText = nil
                self.refreshSubline(size: self.pixelSize(of: self.currentItem))
            }
        }
    }

    private func copy() {
        guard let data = currentItem.original() else {
            say(Localized.text("Still loading — try again in a moment."))
            return
        }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            tailscode_clipboard_set_image_png(base, gsize(data.count))
        }
        say(ImageGenWords.copiedNotice)
    }

    private func save() {
        let item = currentItem
        guard let data = item.original() else {
            say(Localized.text("Still loading — try again in a moment."))
            return
        }
        let filename = ImageBytes.exportFilename(item.name, data: data)
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(filename)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wrote = (try? data.write(to: target)) != nil
        say(
            wrote
                ? Localized.text("Saved %@", target.path)
                : Localized.text("Could not write %@", target.path))
    }

    /// A key while the viewer is the topmost sheet. Esc and Ctrl+W close it and Tab stays inside it
    /// (the layer's rules); the rest are the viewer's own. Anything it does not claim goes on to
    /// what inside the sheet has focus, and no further — never to the Studio under it.
    func handleKey(keyval: UInt32, state mask: UInt32) -> Bool {
        layer.route(keyval: keyval, state: mask) { chord, keyval in
            if keyval == Keymap.escape {
                perform(.close)
                return true
            }
            let command = ViewerCommand.command(
                for: chord, buttonHasFocus: Gtk.focusIsButton(in: layer.windowWidget))
            guard let command else { return false }
            perform(command)
            return true
        }
    }

    /// What a harness reads: where the viewer is and what it is showing.
    var summary: String {
        let item = items.isEmpty ? "-" : currentKey
        return
            "state=\(layer.state) depth=\(layer.depth) item=\(item) page=\(pager.index + 1)/\(pager.count) zoom=\(zoom) full=\(fullBits != 0 && fullKey == item) frame=\(Int(layer.frame.x)),\(Int(layer.frame.y)) \(Int(layer.frame.width))x\(Int(layer.frame.height)) progress=\(String(format: "%.2f", layer.progress)) scrim=\(String(format: "%.2f", layer.scrimOpacity)) renders=\(renders)"
    }

    private func reportState(texture: (Int32, Int32)?, size: (Int32, Int32)?, full: Bool) {
        guard driving else { return }
        let shown = texture.map { "\($0.0)x\($0.1)" } ?? "-"
        let original = size.map { "\($0.0)x\($0.1)" } ?? "-"
        FileHandle.standardOutput.write(
            Data(
                "GALLERY key=\(currentKey) tex=\(shown) orig=\(original) full=\(full ? 1 : 0) zoom=\(zoom.isFit ? 0 : 1) depth=\(layer.depth)\n"
                    .utf8))
    }

    var sheetLayer: SheetLayer { layer }

    var pagerState: ViewerPager { pager }

    var sheetWidget: UnsafeMutablePointer<GtkWidget> { layer.sheetWidget }

    func page(to key: String) {
        guard let index = items.firstIndex(where: { $0.key == key }) else { return }
        pager = ViewerPager(count: items.count, index: index)
        zoom = .fit
        render()
    }
}

extension MediaViewer {
    /// The Studio's own viewer: one finished picture with the words that made it, its facts and the
    /// seed, which is the reroll. The viewer keeps its own reference to the stage's texture, so a
    /// new render landing under it cannot free the pixels it is showing.
    static func present(
        picture: ImageGenPicture, textureBits: UInt, notice: @escaping @Sendable (String) -> Void
    ) {
        let texture = OpaquePointer(bitPattern: Int(bitPattern: textureBits))
        if let texture { g_object_ref(UnsafeMutableRawPointer(texture)) }
        let path = picture.path
        let prompt = picture.prompt
        let seed = picture.seed
        let item = Item(
            key: path, name: picture.name, facts: ImageGenFacts.line(for: picture), tooltip: prompt,
            texture: { textureBits }, dimensions: { nil },
            original: { try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) },
            fetch: {},
            release: {
                guard let held = OpaquePointer(bitPattern: Int(bitPattern: textureBits)) else { return }
                g_object_unref(UnsafeMutableRawPointer(held))
            },
            actions: [
                Action(title: Localized.text("Open Folder")) { openFolder(of: path) },
                Action(title: Localized.text("Copy Prompt")) {
                    Gtk.onMain { Gtk.copyToClipboard(prompt) }
                },
                Action(title: Localized.text("Copy Seed")) {
                    Gtk.onMain { Gtk.copyToClipboard("\(seed)") }
                },
            ])
        present(items: [item], startKey: path, notice: notice)
    }

    private static func openFolder(of path: String) {
        let folder = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        let handle = Process()
        handle.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        handle.arguments = ["sh", "-c", "xdg-open '\(folder.path)'"]
        try? handle.run()
    }
}
