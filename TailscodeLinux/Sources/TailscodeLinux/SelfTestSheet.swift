import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension SelfTest {
    /// What the Studio sheet promises that does not need a person looking: its frame is Core's for
    /// six window sizes, its state machine takes show/show/dismiss the way the table says, Esc and
    /// Ctrl+W obey Core's order, the keyboard is the sheet's alone while it is up and the
    /// conversation's the moment it leaves, a Tab cannot leave it, reduced motion cross-fades with no
    /// travel, nothing inside re-lays-out while it moves, both lanes are reachable and every
    /// dialog's parent is the one main window.
    static func checkStudioSheet() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("studio sheet: \(label)") }
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
        func chord(_ letter: Character, control: Bool = false, shift: Bool = false) -> (UInt32, UInt32) {
            var state: UInt32 = 0
            if control { state |= KeyChord.controlMask }
            if shift { state |= KeyChord.shiftMask }
            return (UInt32(letter.unicodeScalars.first!.value), state)
        }

        struct Rig {
            let window: UnsafeMutablePointer<GtkWidget>
            let overlay: UnsafeMutablePointer<GtkWidget>
            let sheet: StudioSheet
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
            let sheet = StudioSheet(
                overlay: overlay, content: content, window: window, titlebar: { 46 })
            gtk_window_present(ptr(window))
            _ = pump(1.5) { gtk_widget_get_width(overlay) == width && gtk_widget_get_height(overlay) == height }
            return Rig(window: window, overlay: overlay, sheet: sheet)
        }
        func finish(_ rig: Rig) {
            rig.sheet.retire()
            gtk_window_destroy(ptr(rig.window))
            _ = pump(0.2)
        }

        for size in [(1440, 900), (1180, 820), (960, 640), (2560, 1400), (1008, 700), (640, 600)] {
            let rig = rig(width: Int32(size.0), height: Int32(size.1))
            defer { finish(rig) }
            let width = Double(gtk_widget_get_width(rig.overlay))
            let height = Double(gtk_widget_get_height(rig.overlay))
            try expect(
                width == Double(size.0) && height == Double(size.1),
                "the window is \(size.0)x\(size.1) (is \(Int(width))x\(Int(height)))")
            rig.sheet.relayout()
            let expected = StudioSheetGeometry.frame(
                windowWidth: width, windowHeight: height, titlebar: 46)
            try expect(
                rig.sheet.frame == expected,
                "the frame at \(size.0)x\(size.1) is Core's \(expected)")
            try expect(
                gtk_widget_get_margin_start(rig.sheet.hostWidget) == Int32(expected.x.rounded())
                    && gtk_widget_get_margin_top(rig.sheet.hostWidget) == Int32(expected.y.rounded()),
                "the sheet's host sits at Core's inset at \(size.0)x\(size.1)")
        }

        let main = rig(width: 1440, height: 900)
        defer { finish(main) }
        let sheet = main.sheet
        let baseline = toplevels()

        try expect(sheet.state == .closed && StudioSheet.current == nil, "a sheet nobody opened is closed")
        try expect(
            sheet.state.conversationChordsEnabled && !sheet.capturesKeys,
            "closed, the conversation owns the keyboard")

        sheet.show(.image)
        try expect(sheet.state == .opening && sheet.lane == .image, "show from closed rises on its lane")
        try expect(StudioSheet.current === sheet, "the sheet is current while it rises")
        try expect(
            !sheet.state.conversationChordsEnabled && sheet.capturesKeys,
            "rising, the keyboard is the sheet's alone")
        sheet.show(.video)
        try expect(
            sheet.state == .opening && sheet.lane == .video,
            "show while opening changes lane and keeps the state")
        try expect(sheet.imagePane != nil && sheet.forge != nil, "both lanes are reachable in one sheet")
        try expect(toplevels() == baseline, "opening the Studio makes no second toplevel (\(toplevels()) vs \(baseline))")
        try expect(
            sheet.paneHosts.allSatisfy { $0 == main.window },
            "every dialog the Studio opens names the one main window")
        try expect(sheet.dialogParent == main.window, "and so does the sheet")
        try expect(
            tailscode_accessible_role(sheet.sheetWidget) == Int32(GTK_ACCESSIBLE_ROLE_DIALOG.rawValue),
            "the sheet announces itself as a dialog")
        try expect(pump(2.0) { sheet.state == .open }, "the motion finishes and the sheet is open")
        try expect(
            abs(sheet.progress - 1) < 0.0001 && sheet.layoutPasses >= 0,
            "at rest the sheet is fully present")
        try expect(
            gtk_widget_get_width(sheet.sheetWidget) == Int32(sheet.frame.width.rounded())
                && gtk_widget_get_height(sheet.sheetWidget) == Int32(sheet.frame.height.rounded()),
            "the sheet is allocated at Core's size (\(gtk_widget_get_width(sheet.sheetWidget))x\(gtk_widget_get_height(sheet.sheetWidget)))")
        if let box = Gtk.bounds(of: sheet.sheetWidget, in: main.window) {
            try expect(
                abs(box.x - sheet.frame.x) < 1.5 && abs(box.y - sheet.frame.y) < 1.5,
                "and sits at Core's place (\(box.x),\(box.y))")
        } else {
            throw SelfTestFailure("studio sheet: the sheet has no bounds in the window")
        }
        try expect(
            abs(gtk_widget_get_opacity(sheet.scrimWidget)
                - StudioSheetMotion.scrimAlpha(for: sheet.appearance)) < 0.005,
            "the scrim rests at the face's alpha (\(gtk_widget_get_opacity(sheet.scrimWidget)) vs \(StudioSheetMotion.scrimAlpha(for: sheet.appearance)))")

        let (ctrlOne, ctrlOneState) = chord("1", control: true)
        try expect(sheet.handleKey(keyval: ctrlOne, state: ctrlOneState) && sheet.lane == .image, "Ctrl+1 is the image lane")
        let (ctrlTwo, ctrlTwoState) = chord("2", control: true)
        try expect(sheet.handleKey(keyval: ctrlTwo, state: ctrlTwoState) && sheet.lane == .video, "Ctrl+2 is the video lane")
        _ = sheet.handleKey(keyval: ctrlOne, state: ctrlOneState)
        _ = sheet.handleKey(keyval: ctrlTwo, state: ctrlTwoState)
        _ = pump(0.4)

        let before = sheet.layoutPasses
        let sizeBefore = (gtk_widget_get_width(sheet.sheetWidget), gtk_widget_get_height(sheet.sheetWidget))
        let paneBefore = sheet.forge?.chrome.size
        for presence in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0] {
            sheet.hold(at: presence)
            _ = pump(0.05)
            try expect(
                sheet.layoutPasses == before,
                "no layout pass inside the sheet at presence \(presence) (\(sheet.layoutPasses) vs \(before))")
            try expect(
                (gtk_widget_get_width(sheet.sheetWidget), gtk_widget_get_height(sheet.sheetWidget)) == sizeBefore,
                "the sheet keeps its allocation while it moves")
            let paneNow = sheet.forge?.chrome.size
            try expect(
                paneNow?.width == paneBefore?.width && paneNow?.height == paneBefore?.height,
                "the lane inside is never re-measured while the sheet moves")
        }
        sheet.hold(at: 0.5)
        _ = pump(0.1)
        if let box = Gtk.bounds(of: sheet.sheetWidget, in: main.window) {
            let travel = StudioSheetMotion.translation(
                progress: 0.5, sheetHeight: sheet.frame.height, reduced: false)
            try expect(
                abs(box.y - (sheet.frame.y + travel)) < 1.5,
                "half-way the sheet is the travel below its rest (\(box.y) vs \(sheet.frame.y + travel))")
            try expect(
                abs(gtk_widget_get_opacity(sheet.sheetWidget) - 1) < 0.005,
                "the sheet is opaque from its first frame")
        }
        sheet.hold(at: 1)
        sheet.release()
        _ = pump(1.0) { sheet.state == .open }

        let (w, wState) = chord("w", control: true)
        try expect(StudioSheetKeys.closes(KeyChord.canonical(keyval: w, state: wState)!), "Ctrl+W is the sheet's close")
        try expect(sheet.capturesKeys, "so the sheet is asked before the window")
        try expect(sheet.handleKey(keyval: w, state: wState), "Ctrl+W is taken by the sheet")
        try expect(sheet.state == .closing, "and it starts the sheet leaving")
        try expect(
            sheet.state.conversationChordsEnabled && !sheet.capturesKeys,
            "the conversation's chords come back as the motion starts")
        sheet.dismiss()
        try expect(sheet.state == .closing, "dismiss while closing is ignored")
        try expect(pump(2.0) { sheet.state == .closed }, "the sheet finishes leaving")
        try expect(StudioSheet.current == nil, "a closed sheet is not current")
        try expect(
            sheet.imagePane == nil && sheet.forge == nil,
            "the panes are let go of once the sheet has left")
        try expect(toplevels() == baseline, "closing leaves exactly the toplevels it found")

        sheet.show(.image)
        _ = pump(2.0) { sheet.state == .open }
        sheet.dismiss()
        try expect(sheet.state == .closing, "a sheet asked to leave is leaving")
        sheet.hold(at: 0.5)
        let leaving = sheet.progress
        sheet.show(.video)
        try expect(
            sheet.state == .opening && sheet.lane == .video && leaving < 1 && leaving > 0,
            "show while closing rises again from where the motion is (\(leaving))")
        _ = pump(2.0) { sheet.state == .open }
        try expect(sheet.state == .open, "and arrives")

        try expect(
            StudioSheetKeys.escape(renderIsOut: true) == .stopRender
                && StudioSheetKeys.escape(renderIsOut: false) == .closeSheet,
            "Esc stops a render that is out and otherwise closes")
        try expect(!sheet.renderIsOut, "no render is out in this run")
        try expect(
            sheet.handleKey(keyval: Keymap.escape, state: 0) && sheet.state == .closing,
            "Esc with nothing out closes the sheet")
        _ = pump(2.0) { sheet.state == .closed }

        try expect(
            StudioSheetTab.route(inPopover: true, moved: false) == .leaveToPopover
                && StudioSheetTab.route(inPopover: false, moved: true) == .moveWithin
                && StudioSheetTab.route(inPopover: false, moved: false) == .wrap,
            "a Tab inside a popover is the popover's, one that moves is plain and one that would leave wraps")

        sheet.show(.image)
        _ = pump(2.0) { sheet.state == .open }
        for round in 0..<40 {
            let back = round % 2 == 1
            _ = sheet.handleKey(
                keyval: back ? 0xFE20 : Keymap.tab, state: back ? KeyChord.shiftMask : 0)
            _ = pump(0.01)
            guard let focused = tailscode_focused_widget(main.window) else { continue }
            try expect(
                gtk_widget_is_ancestor(focused, sheet.sheetWidget) != 0,
                "Tab \(round) leaves focus inside the sheet")
        }
        sheet.dismiss()
        _ = pump(2.0) { sheet.state == .closed }

        tailscode_set_animations_enabled(0)
        sheet.show(.image)
        sheet.hold(at: 0.5)
        _ = pump(0.1)
        if let box = Gtk.bounds(of: sheet.sheetWidget, in: main.window) {
            try expect(
                abs(box.y - sheet.frame.y) < 1.5,
                "reduced motion has no travel (\(box.y) vs \(sheet.frame.y))")
        }
        try expect(
            abs(gtk_widget_get_opacity(sheet.sheetWidget) - 0.5) < 0.005,
            "reduced motion cross-fades the sheet")
        sheet.release()
        let started = Date()
        try expect(pump(1.0) { sheet.state == .open }, "reduced motion still arrives")
        try expect(
            Date().timeIntervalSince(started) < 0.5,
            "in the cross-fade's 120 ms and not the travel's 320")
        sheet.dismiss()
        _ = pump(1.0) { sheet.state == .closed }
        tailscode_set_animations_enabled(1)

        return checks
    }
}
