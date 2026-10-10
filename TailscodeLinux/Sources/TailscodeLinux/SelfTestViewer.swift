import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension SelfTest {
    /// What the sheet stack and the viewer on it promise that does not need a person looking: the
    /// pager and the zoom are plain arithmetic, a key means one thing, a viewer over the Studio sits
    /// where Core's depth-1 frame says for six window sizes, Esc and Ctrl+W and Done and the scrim
    /// close the top sheet only, the Studio's chords stay out of reach under a viewer, a second
    /// picture asked for while one is up re-targets it with no motion, focus goes back where it came
    /// from, nothing inside moves or re-lays-out while a viewer travels, and no second toplevel is
    /// ever made.
    static func checkMediaViewer() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("media viewer: \(label)") }
            checks += 1
        }
        func pump(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while g_main_context_iteration(nil, 0) != 0 {}
                if done() { return true }
                usleep(4000)
            }
            return done()
        }
        func toplevels() -> Int {
            Int(g_list_model_get_n_items(gtk_window_get_toplevels()))
        }

        try expect(
            ViewerCommand.command(for: chord("c", control: true), buttonHasFocus: false) == .copy
                && ViewerCommand.command(for: chord("s", control: true), buttonHasFocus: false) == .save,
            "Ctrl+C copies and Ctrl+S saves")
        try expect(
            ViewerCommand.command(for: chord(" "), buttonHasFocus: false) == .next
                && ViewerCommand.command(for: chord(" "), buttonHasFocus: true) == nil,
            "Space pages forward unless a button holds the keyboard")
        let keyed: [(UInt32, ViewerCommand)] = [
            (0xFF51, .previous), (0xFF53, .next), (0xFF50, .first), (0xFF57, .last),
            (UInt32(UnicodeScalar("+").value), .zoomIn), (UInt32(UnicodeScalar("=").value), .zoomIn),
            (UInt32(UnicodeScalar("-").value), .zoomOut), (UInt32(UnicodeScalar("0").value), .fit),
            (UInt32(UnicodeScalar("1").value), .actualSize),
        ]
        for (keyval, command) in keyed {
            let found = ViewerCommand.command(
                for: KeyChord.canonical(keyval: keyval, state: 0)!, buttonHasFocus: false)
            try expect(found == command, "key \(keyval) is \(command)")
        }
        try expect(
            ViewerCommand.command(for: chord("w", control: true), buttonHasFocus: false) == nil
                && ViewerCommand.command(for: chord("x"), buttonHasFocus: false) == nil,
            "the close chord and unclaimed letters are not the viewer's commands")

        var pager = ViewerPager(count: 3, index: 0)
        pager.advance(by: -1)
        try expect(pager.index == 2, "paging back from the first wraps to the last")
        pager.advance(by: 1)
        try expect(pager.index == 0, "paging on from the last wraps to the first")
        pager.last()
        try expect(pager.index == 2 && pager.counter != nil, "End is the last page and there is a counter")
        pager.first()
        try expect(pager.index == 0, "Home is the first page")
        var single = ViewerPager(count: 1)
        single.advance(by: 1)
        try expect(single.index == 0 && single.counter == nil && !single.canPage, "one picture has nowhere to go and no counter")
        try expect(ViewerPager(count: 0).index == 0 && ViewerPager(count: 4, index: 99).index == 3, "an index is clamped")

        let fitted = ViewerZoom.fit
        try expect(fitted.toggled == .actual && ViewerZoom.actual.toggled == .fit, "double-click is fit and 1:1 and back")
        let larger = fitted.zoomedIn(fit: 0.5)
        try expect(larger == .scaled(0.625), "a step in from the fit is a quarter more of it")
        try expect(larger.zoomedOut(fit: 0.5) == .fit, "a step back to the fit is the fit")
        try expect(
            ViewerZoom.scaled(ViewerZoom.maximum).zoomedIn(fit: 0.5) == .scaled(ViewerZoom.maximum),
            "zoom stops at its maximum")
        try expect(fitted.zoomedOut(fit: 0.5) == .fit, "the fit does not go smaller")
        try expect(ViewerZoom.actual.scale(fit: 0.3) == 1 && fitted.scale(fit: 0.3) == 0.3, "1:1 is a scale of one")

        let png = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        let released = ReleaseCount()
        func page(_ key: String) -> MediaViewer.Item {
            let bits: UInt = png.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress,
                    let texture = tailscode_texture_from_bytes(base, gsize(buffer.count))
                else { return 0 }
                return UInt(bitPattern: texture)
            }
            return MediaViewer.Item(
                key: key, name: "\(key).png", facts: nil, tooltip: nil,
                texture: { bits }, dimensions: { (1600, 1000) }, original: { png }, fetch: {},
                release: {
                    released.add()
                    if let texture = OpaquePointer(bitPattern: Int(bitPattern: bits)) {
                        g_object_unref(UnsafeMutableRawPointer(texture))
                    }
                }, actions: [])
        }
        func pages(_ keys: [String]) -> [MediaViewer.Item] { keys.map(page) }

        struct Rig {
            let window: UnsafeMutablePointer<GtkWidget>
            let overlay: UnsafeMutablePointer<GtkWidget>
            let entry: UnsafeMutablePointer<GtkWidget>
            let studio: StudioSheet
        }
        func rig(width: Int32, height: Int32) -> Rig {
            let window = gtk_window_new()!
            gtk_window_set_default_size(ptr(window), width, height)
            let overlay = gtk_overlay_new()!
            let content = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_widget_set_hexpand(content, 1)
            gtk_widget_set_vexpand(content, 1)
            let entry = gtk_entry_new()!
            gtk_box_append(ptr(content), entry)
            gtk_overlay_set_child(op(overlay), content)
            gtk_window_set_child(ptr(window), overlay)
            let studio = StudioSheet(
                overlay: overlay, content: content, window: window, titlebar: { 46 })
            gtk_window_present(ptr(window))
            _ = pump(1.5) { gtk_widget_get_width(overlay) == width && gtk_widget_get_height(overlay) == height }
            return Rig(window: window, overlay: overlay, entry: entry, studio: studio)
        }
        func finish(_ rig: Rig) {
            MediaViewer.current?.sheetLayer.closeNow()
            rig.studio.retire()
            gtk_window_destroy(ptr(rig.window))
            _ = pump(0.2)
        }
        func open(_ viewerKeys: [String], start: String? = nil) throws -> MediaViewer {
            MediaViewer.present(
                items: pages(viewerKeys), startKey: start ?? viewerKeys[0], notice: { _ in })
            guard let viewer = MediaViewer.current else {
                throw SelfTestFailure("media viewer: a viewer was asked for and none is up")
            }
            return viewer
        }

        for size in [(1440, 900), (1180, 820), (960, 640), (2560, 1400), (1008, 700), (640, 600)] {
            let rig = rig(width: Int32(size.0), height: Int32(size.1))
            defer { finish(rig) }
            rig.studio.show(.image)
            _ = pump(2.0) { rig.studio.state == .open }
            let viewer = try open(["a", "b"])
            _ = pump(2.0) { viewer.sheetLayer.state == .open }
            let width = Double(gtk_widget_get_width(rig.overlay))
            let height = Double(gtk_widget_get_height(rig.overlay))
            viewer.sheetLayer.relayout()
            let expected = StudioSheetGeometry.frame(
                windowWidth: width, windowHeight: height, titlebar: 46, depth: 1)
            try expect(
                viewer.sheetLayer.frame == expected && viewer.sheetLayer.depth == 1,
                "the viewer over the Studio at \(size.0)x\(size.1) is Core's depth-1 frame \(expected)")
            let below = StudioSheetGeometry.frame(windowWidth: width, windowHeight: height, titlebar: 46)
            try expect(
                rig.studio.frame == below
                    && (size.0 < 700
                        || (viewer.sheetLayer.frame.y == below.y + StudioSheetMetrics.stackInset
                            && viewer.sheetLayer.frame.x == below.x + StudioSheetMetrics.stackInset)),
                "the Studio keeps its own frame under it and the viewer is one inset further in at \(size.0)x\(size.1)")
        }

        let main = rig(width: 1440, height: 900)
        defer { finish(main) }
        /// Whether the keyboard is on `widget` or on something it is made of: a text field hands
        /// the keyboard to the text inside it.
        func holds(_ widget: UnsafeMutablePointer<GtkWidget>) -> Bool {
            guard let focused = tailscode_focused_widget(main.window) else { return false }
            return focused == widget || gtk_widget_is_ancestor(focused, widget) != 0
        }
        let studio = main.studio
        let stack = studio.stack
        let baseline = toplevels()

        try expect(stack.depth == 0 && stack.conversationChordsEnabled && stack.top == nil, "nothing up, nothing stands")
        try expect(stack.handleKey(keyval: 0x6E, state: KeyChord.controlMask) == nil, "with no sheet a key is the conversation's")

        gtk_window_set_focus(ptr(main.window), main.entry)
        let alone = try open(["a", "b", "c"], start: "b")
        try expect(
            alone.sheetLayer === stack.viewerLayer && alone.sheetLayer.depth == 0 && stack.depth == 1,
            "a viewer over a conversation is alone, at depth 0, on the viewer's layer")
        try expect(alone.pagerState.index == 1, "it lands on the picture asked for")
        try expect(
            tailscode_accessible_role(alone.sheetWidget) == Int32(GTK_ACCESSIBLE_ROLE_DIALOG.rawValue),
            "the viewer announces itself as a dialog")
        try expect(!stack.conversationChordsEnabled, "the conversation's chords are locked while a viewer is up")
        try expect(
            stack.handleKey(keyval: 0x6E, state: KeyChord.controlMask) != nil,
            "so even a chord nobody claims is answered by the sheet, never handed to the conversation")
        try expect(toplevels() == baseline, "a viewer is not a second toplevel (\(toplevels()) vs \(baseline))")
        try expect(pump(2.0) { alone.sheetLayer.state == .open }, "the viewer finishes rising")
        try expect(
            abs(gtk_widget_get_opacity(alone.sheetLayer.scrimWidget)
                - StudioSheetMotion.scrimAlpha(for: alone.sheetLayer.appearance)) < 0.005,
            "its scrim rests at the face's alpha")
        if let focused = tailscode_focused_widget(main.window) {
            try expect(
                gtk_widget_is_ancestor(focused, alone.sheetWidget) != 0 || focused == alone.sheetWidget,
                "the keyboard is inside the viewer once it is up")
        } else {
            throw SelfTestFailure("media viewer: nothing has the keyboard with a viewer up")
        }

        _ = alone.handleKey(keyval: 0xFF53, state: 0)
        try expect(alone.pagerState.index == 2, "→ pages on")
        _ = alone.handleKey(keyval: 0xFF53, state: 0)
        try expect(alone.pagerState.index == 0, "→ from the last wraps to the first")
        _ = alone.handleKey(keyval: 0xFF57, state: 0)
        try expect(alone.pagerState.index == 2, "End is the last page")
        _ = alone.handleKey(keyval: 0xFF50, state: 0)
        try expect(alone.pagerState.index == 0, "Home is the first page")
        _ = alone.handleKey(keyval: UInt32(UnicodeScalar("1").value), state: 0)
        try expect(alone.zoom == .actual, "1 is 1:1")
        _ = alone.handleKey(keyval: UInt32(UnicodeScalar("0").value), state: 0)
        try expect(alone.zoom == .fit, "0 is the fit")
        _ = alone.handleKey(keyval: UInt32(UnicodeScalar("+").value), state: 0)
        try expect(!alone.zoom.isFit, "+ zooms in")
        _ = alone.handleKey(keyval: UInt32(UnicodeScalar("-").value), state: 0)
        try expect(alone.zoom.isFit, "− zooms back out to the fit")
        alone.perform(.next)
        try expect(alone.zoom.isFit, "a page turn goes back to the fit")

        _ = pump(0.6)
        let rendersBefore = alone.renders
        let sizeBefore = (gtk_widget_get_width(alone.sheetWidget), gtk_widget_get_height(alone.sheetWidget))
        for presence in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0] {
            alone.sheetLayer.hold(at: presence)
            _ = pump(0.05)
            try expect(
                alone.renders == rendersBefore,
                "no page is drawn again at presence \(presence) (\(alone.renders) vs \(rendersBefore))")
            try expect(
                (gtk_widget_get_width(alone.sheetWidget), gtk_widget_get_height(alone.sheetWidget)) == sizeBefore,
                "the viewer keeps its allocation while it moves")
        }
        alone.sheetLayer.hold(at: 0.5)
        _ = pump(0.1)
        if let box = Gtk.bounds(of: alone.sheetWidget, in: main.window) {
            let travel = StudioSheetMotion.translation(
                progress: 0.5, sheetHeight: alone.sheetLayer.frame.height, reduced: false)
            try expect(
                abs(box.y - (alone.sheetLayer.frame.y + travel)) < 1.5,
                "half-way the viewer is the travel below its rest (\(box.y) vs \(alone.sheetLayer.frame.y + travel))")
        }
        alone.sheetLayer.hold(at: 1)
        alone.sheetLayer.release()
        _ = pump(1.0) { alone.sheetLayer.state == .open }

        let releasedBefore = released.value
        MediaViewer.present(items: pages(["x", "y"]), startKey: "y", notice: { _ in })
        try expect(MediaViewer.current === alone, "a second request re-targets the viewer already up")
        try expect(
            alone.sheetLayer.state == .open && alone.sheetLayer.progress == 1,
            "with no motion: it stays at rest")
        try expect(
            alone.pagerState.count == 2 && alone.pagerState.index == 1 && stack.depth == 1,
            "and shows the new pictures on the one asked for, still one sheet")
        try expect(released.value == releasedBefore + 3, "the pictures it let go of were handed back")

        gtk_window_set_focus(ptr(main.window), nil)
        gtk_window_set_focus(ptr(main.window), main.entry)
        alone.perform(.close)
        try expect(alone.sheetLayer.state == .closing, "Done starts the viewer leaving")
        try expect(
            holds(main.entry),
            "the keyboard is back where it came from as the motion starts")
        try expect(stack.conversationChordsEnabled, "and the conversation's chords come back with it")
        try expect(pump(2.0) { alone.sheetLayer.state == .closed }, "the viewer finishes leaving")
        try expect(
            MediaViewer.current == nil && stack.depth == 0 && released.value == releasedBefore + 5,
            "nothing stands once it has gone and every picture was handed back")

        studio.show(.image)
        _ = pump(2.0) { studio.state == .open }
        try expect(stack.depth == 1 && stack.studioLayer.isUp && !stack.viewerLayer.isUp, "the Studio is the one sheet up")
        let studioFocus = tailscode_focused_widget(main.window)
        let over = try open(["a", "b"])
        try expect(
            over.sheetLayer.depth == 1 && stack.depth == 2 && over.sheetLayer === stack.viewerLayer,
            "a viewer opened over the Studio stands on the layer above, one level in")
        try expect(pump(2.0) { over.sheetLayer.state == .open }, "and rises")
        try expect(toplevels() == baseline, "the Studio and a viewer on it are still one toplevel")
        try expect(
            over.sheetLayer.frame.y == studio.frame.y + StudioSheetMetrics.stackInset,
            "the Studio's edge shows above the viewer")
        if let box = Gtk.bounds(of: over.sheetLayer.scrimWidget, in: main.window) {
            try expect(
                box.width == 1440 && box.height == 900,
                "the viewer's scrim covers the whole window, so every press lands on it")
        }
        let strip = gtk_widget_pick(main.overlay, 700, 20, GTK_PICK_DEFAULT)
        try expect(
            strip != nil
                && (strip == over.sheetLayer.scrimWidget
                    || gtk_widget_is_ancestor(strip, over.sheetLayer.scrimWidget) != 0),
            "a press in the strip above the Studio lands on the viewer's scrim, not the Studio's")
        let beside = gtk_widget_pick(main.overlay, 700, studio.frame.y + 6, GTK_PICK_DEFAULT)
        try expect(
            beside != nil
                && (beside == over.sheetLayer.scrimWidget
                    || gtk_widget_is_ancestor(beside, over.sheetLayer.scrimWidget) != 0),
            "and so does a press on the Studio's own top edge")

        let laneBefore = studio.lane
        let ctrlTwo = UInt32(UnicodeScalar("2").value)
        _ = stack.handleKey(keyval: ctrlTwo, state: KeyChord.controlMask)
        try expect(studio.lane == laneBefore, "Ctrl+2 under a viewer does not reach the Studio")
        try expect(stack.top === over.sheetLayer, "the viewer is the sheet that owns the keyboard")
        try expect(!stack.conversationChordsEnabled, "the conversation's chords stay locked under two sheets")

        _ = stack.handleKey(keyval: Keymap.escape, state: 0)
        try expect(
            over.sheetLayer.state == .closing && studio.state == .open,
            "Esc closes the viewer and leaves the Studio")
        try expect(
            !stack.conversationChordsEnabled && stack.top === stack.layers[0],
            "the Studio owns the keyboard again and the conversation still does not")
        try expect(pump(2.0) { over.sheetLayer.state == .closed }, "the viewer finishes leaving")
        if let studioFocus, gtk_widget_get_root(studioFocus) != nil, gtk_widget_get_mapped(studioFocus) != 0 {
            try expect(
                holds(studioFocus),
                "the keyboard went back to the Studio's own widget that had it")
        }
        _ = stack.handleKey(keyval: ctrlTwo, state: KeyChord.controlMask)
        try expect(studio.lane == .video, "with the viewer gone the Studio's own chords answer")
        _ = stack.handleKey(keyval: UInt32(UnicodeScalar("1").value), state: KeyChord.controlMask)

        let again = try open(["a", "b"])
        _ = pump(2.0) { again.sheetLayer.state == .open }
        _ = stack.handleKey(keyval: UInt32(UnicodeScalar("w").value), state: KeyChord.controlMask)
        try expect(
            again.sheetLayer.state == .closing && studio.state == .open,
            "Ctrl+W closes the viewer only")
        _ = pump(2.0) { again.sheetLayer.state == .closed }

        let third = try open(["a", "b"])
        _ = pump(2.0) { third.sheetLayer.state == .open }
        third.perform(.close)
        try expect(third.sheetLayer.state == .closing && studio.state == .open, "Done closes the viewer only")
        _ = pump(2.0) { third.sheetLayer.state == .closed }

        let fourth = try open(["a", "b"])
        _ = pump(2.0) { fourth.sheetLayer.state == .open }
        fourth.sheetLayer.dismiss()
        try expect(
            fourth.sheetLayer.state == .closing && studio.state == .open,
            "a press on the viewer's scrim closes the viewer only")
        _ = pump(2.0) { fourth.sheetLayer.state == .closed }

        _ = stack.handleKey(keyval: Keymap.escape, state: 0)
        try expect(studio.state == .closing, "then Esc closes the Studio")
        _ = pump(2.0) { studio.state == .closed }
        try expect(stack.depth == 0 && stack.conversationChordsEnabled, "nothing is left up")

        studio.show(.image)
        _ = pump(2.0) { studio.state == .open }
        let buried = try open(["a", "b"])
        _ = pump(2.0) { buried.sheetLayer.state == .open }
        studio.dismiss()
        try expect(
            buried.sheetLayer.state == .closed && MediaViewer.current == nil && studio.state == .closing,
            "the Studio leaving takes a viewer standing on it down at once")
        _ = pump(2.0) { studio.state == .closed }

        let first = try open(["a"])
        _ = pump(2.0) { first.sheetLayer.state == .open }
        studio.show(.image)
        try expect(
            MediaViewer.current == nil && !stack.viewerLayer.isUp && studio.state == .opening,
            "the Studio asked for while a viewer is up takes the viewer down at once")
        _ = pump(2.0) { studio.state == .open }
        try expect(toplevels() == baseline, "and the window is still one toplevel")
        studio.dismiss()
        _ = pump(2.0) { studio.state == .closed }

        return checks
    }

    private static func chord(_ letter: Character, control: Bool = false) -> KeyChord {
        KeyChord.canonical(
            keyval: UInt32(letter.unicodeScalars.first!.value),
            state: control ? KeyChord.controlMask : 0)!
    }

    /// How many pictures a viewer handed back, counted across the closures that do it.
    private final class ReleaseCount: @unchecked Sendable {
        private(set) var value = 0

        func add() {
            value += 1
        }
    }
}
