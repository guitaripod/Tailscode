import AppKit
import CodingAgentKit
import TailscodeCore

/// `--selftest`'s claims about the viewer sheet and the stack it stands in: the pager, the zoom and the key
/// table apart from any view, how many sheets may stand on one another and which of them a key, a press or
/// ⌘W reaches, the frame a stacked sheet has against Core's, what a gallery does when it is pointed
/// elsewhere while open, that a sheet in motion lays nothing out, and where focus goes back to.
@MainActor
enum MediaViewerCheck {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }
        pager(expect)
        zoom(expect)
        keys(expect)
        stack(expect)
        stacked(expect)
        gallery(expect)
        clip(expect)
        return failures
    }

    private final class FocusProbe: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private static func offscreen(_ width: CGFloat, _ height: CGFloat) -> (NSWindow, FocusProbe) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "viewer.check")
        window.toolbarStyle = .unified
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.autoresizingMask = [.width, .height]
        let opener = FocusProbe(frame: NSRect(x: 20, y: 20, width: 80, height: 24))
        content.addSubview(opener)
        window.contentView = content
        window.makeFirstResponder(opener)
        return (window, opener)
    }

    private static let sizes: [(CGFloat, CGFloat)] = [
        (1440, 900), (1180, 760), (960, 640), (880, 640), (690, 500), (2560, 1400),
    ]

    private static func pager(_ expect: (Bool, String) -> Void) {
        var pager = ViewerPager(count: 3)
        expect(pager.index == 0 && pager.counter != nil, "the pager starts at the first picture and says where it is")
        pager.step(-1)
        expect(pager.index == 2, "paging back from the first wraps to the last")
        pager.step(1)
        expect(pager.index == 0, "and forward from the last wraps to the first")
        pager.last()
        expect(pager.index == 2, "End is the last picture")
        pager.first()
        expect(pager.index == 0, "Home is the first")
        pager.step(7)
        expect(pager.index == 1, "a step larger than the set still lands inside it")
        expect(ViewerPager(count: 1).counter == nil, "a single picture has no place among others to name")
        expect(ViewerPager(count: 3, index: 9).index == 2, "a start past the end is the last picture")
        var empty = ViewerPager(count: 0)
        empty.step(1)
        expect(empty.index == 0, "an empty gallery pages nowhere")
    }

    private static func zoom(_ expect: (Bool, String) -> Void) {
        let pane = CGSize(width: 800, height: 600)
        var zoom = ViewerZoom()
        let large = CGSize(width: 3200, height: 2400)
        expect(
            zoom.scale(pane: pane, image: large, backingScale: 2) == 0.25,
            "fit shrinks a picture larger than the pane to the pane")
        expect(
            zoom.scale(pane: pane, image: CGSize(width: 100, height: 80), backingScale: 2) == 0.5,
            "fit never enlarges: a small picture stays at its true pixels")
        zoom.toggle()
        expect(zoom.mode == .actual && zoom.scale(pane: pane, image: large, backingScale: 2) == 0.5, "1:1 is one image pixel per screen pixel")
        zoom.toggle()
        expect(zoom.mode == .fit, "the toggle goes back to fit")
        let up = zoom.stepped(from: 0.5, in: 1)
        expect(up == 0.625 && zoom.mode == .custom && zoom.scale(pane: pane, image: large, backingScale: 2) == nil, "+ steps up by a quarter and leaves the scale to the hand")
        expect(zoom.stepped(from: 0.5, in: -1) == 0.4, "− steps down by a quarter")
        expect(zoom.stepped(from: 12, in: 1) == 12 && zoom.stepped(from: 0.02, in: -1) == 0.02, "the steps stop at the limits")
        zoom.toggle()
        expect(zoom.mode == .actual, "the toggle from a custom scale goes to true pixels")
        expect(
            ViewerZoom().scale(pane: pane, image: large, backingScale: 2, margin: 20).map { abs($0 - 560.0 / 2400.0) < 0.0001 } == true,
            "a fitted picture keeps its margin clear of the pane")
        expect(
            ViewerZoom().scale(pane: .zero, image: large, backingScale: 2) == 0.5,
            "a pane with no size yet asks for true pixels rather than dividing by it")
    }

    private static func keys(_ expect: (Bool, String) -> Void) {
        func key(_ code: UInt16, _ character: String = "", command: Bool = false, shift: Bool = false, other: Bool = false) -> ViewerKey? {
            ViewerKey.match(keyCode: code, character: character, command: command, shift: shift, other: other)
        }
        expect(key(53) == .close && key(123) == .previous && key(124) == .next, "Esc closes and the arrows page")
        expect(key(115) == .first && key(119) == .last && key(49, " ") == .advance, "Home, End and Space")
        expect(key(24, "+", shift: true) == .zoomIn && key(24, "=") == .zoomIn && key(27, "-") == .zoomOut, "+ and − zoom")
        expect(key(29, "0") == .fit && key(18, "1") == .actual && key(6, "z") == .toggleZoom, "0 fits, 1 is true pixels, z toggles")
        expect(key(8, "c", command: true) == .copy && key(1, "s", command: true) == .save, "⌘C copies the picture and ⌘S saves it")
        expect(key(8, "c") == nil && key(1, "s") == nil, "a bare c or s is nobody's")
        expect(key(123, other: true) == nil && key(8, "c", command: true, other: true) == nil, "Control and Option make somebody else's chord")
        expect(key(8, "c", command: true, shift: true) == nil, "⌘⇧C is not a copy")
    }

    private static func bitmap(_ width: Int, _ height: Int, seed: Int) -> DecodedImage? {
        guard let data = StudioDemo.png(StudioDemo.bokeh(seed: seed, width: width, height: height)) else { return nil }
        return ImageStore.decode(data)
    }

    private static func items(_ count: Int, tag: String) -> [ImageViewer.Item] {
        (0..<count).map { index in
            let key = "\(tag):\(index)"
            if let entry = bitmap(640 + index * 80, 420, seed: index) { ImageStore.shared.store(entry, forKey: key) }
            return ImageViewer.Item(key: key, name: "\(tag)-\(index).png", reference: FileReference(path: "/nonexistent/\(key)"))
        }
    }

    private static func stack(_ expect: (Bool, String) -> Void) {
        let stack = SheetStack()
        let (window, _) = offscreen(1180, 760)
        func presenter() -> SheetPresenter {
            let presenter = SheetPresenter(
                sheet: SheetView(content: NSView(), toolbar: NSView(), dialogName: "Check, dialog", closeLabel: "Close check"),
                stack: stack)
            presenter.reducedMotion = { false }
            return presenter
        }
        let lower = presenter()
        let upper = presenter()
        let third = presenter()
        expect(stack.conversationChordsEnabled && stack.keyOwner == nil, "with nothing up the conversation's chords are on and nobody owns the keys")
        lower.show(in: window)
        lower.motionFinished()
        upper.show(in: window)
        upper.motionFinished()
        expect(lower.sheet.depth == 0 && upper.sheet.depth == 1, "the first sheet stands at depth 0 and the second at depth 1")
        expect(third.show(in: window) == .none && third.state == .closed && !stack.presenters.contains { $0 === third }, "a third is refused: \(StudioSheetMetrics.maximumDepth) is the most that may stand on one another")
        expect(third.sheet.superview == nil, "and nothing of it was put in the window")
        expect(stack.keyOwner === upper && !stack.conversationChordsEnabled, "the top sheet owns the keys and the conversation's chords are off")
        expect(!lower.ownsKeys && upper.ownsKeys, "the sheet beneath owns none")
        for (width, height) in sizes {
            window.setContentSize(NSSize(width: width, height: height))
            window.contentView?.layoutSubtreeIfNeeded()
            lower.sheet.layoutSubtreeIfNeeded()
            upper.sheet.layoutSubtreeIfNeeded()
            let clearance = SheetView.titlebarClearance(in: window)
            for level in 0...1 {
                let sheet = level == 0 ? lower.sheet : upper.sheet
                let core = StudioSheetGeometry.frame(
                    windowWidth: Double(sheet.bounds.width), windowHeight: Double(sheet.bounds.height), titlebar: clearance, depth: level)
                let actual = sheet.sheetFrame
                expect(
                    abs(actual.minX - core.x) < 0.5 && abs(actual.minY - core.y) < 0.5 && abs(actual.width - core.width) < 0.5
                        && abs(actual.height - core.height) < 0.5,
                    "the sheet at depth \(level) has Core's frame for a window of \(Int(width))×\(Int(height)): \(actual) against \(core.x),\(core.y) \(core.width)×\(core.height)")
            }
            let beneath = StudioSheetGeometry.frame(
                windowWidth: Double(upper.sheet.bounds.width), windowHeight: Double(upper.sheet.bounds.height), titlebar: clearance)
            let dim = upper.sheet.dimFrame
            expect(
                abs(dim.minX - beneath.x) < 0.5 && abs(dim.minY - beneath.y) < 0.5 && abs(dim.width - beneath.width) < 0.5,
                "the scrim of the stacked sheet darkens the sheet beneath and no more at \(Int(width))×\(Int(height))")
            expect(lower.sheet.dimFrame.size == lower.sheet.bounds.size, "while the first sheet's scrim darkens the whole window at \(Int(width))×\(Int(height))")
        }
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.contentView?.layoutSubtreeIfNeeded()
        let studioEdge = lower.sheet.sheetFrame.minY
        expect(
            abs(upper.sheet.sheetFrame.minY - studioEdge - CGFloat(StudioSheetMetrics.stackInset)) < 0.5,
            "the beneath sheet's edge shows \(Int(StudioSheetMetrics.stackInset)) points above the one on it")

        let closeChord = KeyChord.canonical(keyval: UInt32(UnicodeScalar("w").value), state: 0)!
        expect(stack.closesTop(chord: closeChord, command: true, keyWindow: window), "⌘W with two sheets up is answered")
        expect(upper.state == .closing && lower.state == .open, "and closes the top one only")
        expect(stack.keyOwner === lower && !stack.conversationChordsEnabled, "the keys are the lower sheet's again and the chords stay off while it stands")
        expect(!stack.closesTop(chord: closeChord, command: false, keyWindow: window), "Ctrl+W's chord on the ⌘ flag is not ⌘W")
        upper.motionFinished()
        expect(upper.state == .closed && stack.presenters.count == 1, "finished takes the top sheet out of the stack")
        lower.sheet.onScrimPress?()
        expect(lower.state == .closing && stack.conversationChordsEnabled, "a press on the last sheet's scrim closes it, and the chords are back as it leaves")
        lower.motionFinished()
        expect(stack.presenters.isEmpty && lower.sheet.superview == nil, "and the stack is empty and the window is as it was")
        window.close()
    }

    private static func stacked(_ expect: (Bool, String) -> Void) {
        let stack = SheetStack()
        let controller = StudioWindowController(
            studio: MacImageStudio(endpoint: ImageGenEndpoint(host: "127.0.0.1")), stack: stack)
        controller.reducedMotionOverride = false
        let viewer = MediaViewer(stack: stack)
        viewer.presenter.reducedMotion = { false }
        let (window, opener) = offscreen(1180, 760)
        controller.show(lane: .image, in: window)
        controller.motionFinished()
        let held = window.firstResponder
        expect(controller.sheetOwnsKeys(in: window), "the Studio owns the keys with nothing on it")

        let pictures = items(3, tag: "m5stack")
        viewer.showPictures(items: pictures, startKey: pictures[1].key, host: nil, fetch: { _, _ in }, toast: nil)
        expect(viewer.state == .opening && viewer.sheet.host === window, "a viewer asked for with no window rises in the Studio's")
        expect(viewer.sheet.depth == 1 && controller.sheet?.depth == 0, "stacked on the Studio, at depth 1")
        expect(!controller.sheetOwnsKeys(in: window) && viewer.presenter.ownsKeys, "the Studio's chords are locked while the viewer is on it")
        expect(!stack.conversationChordsEnabled, "and the conversation's stay off")
        expect(window.contentView?.subviews.last === viewer.sheet, "the viewer is the topmost overlay")
        expect(controller.sheet?.isAccessibilityHidden() == true, "the Studio is hidden from assistive technology behind it")
        expect(window.firstResponder === (viewer.surface as? PictureGalleryView)?.focusTarget, "the viewer's canvas holds the keyboard, not the Studio's words box")
        viewer.presenter.motionFinished()

        expect(!controller.closesSheet(chord: KeyChord.canonical(keyval: 0x31, state: 0)!, command: true, keyWindow: window), "a ⌘ chord that is not W reaches no sheet")
        expect(viewer.press(.close), "Esc in the viewer is answered")
        expect(viewer.state == .closing && controller.state == .open, "and closes the viewer only; the Studio stays")
        expect(controller.sheetOwnsKeys(in: window), "the Studio's chords are its own again the moment the viewer starts to leave")
        expect(window.firstResponder === held, "focus is back where the Studio had it")
        viewer.presenter.motionFinished()
        expect(viewer.state == .closed && viewer.surface == nil, "the viewer is gone, with what it held")
        expect(controller.state == .open, "the Studio is still up")
        controller.escapePressed()
        controller.motionFinished()
        expect(controller.state == .closed, "the next Esc closes the Studio")
        expect(window.firstResponder === opener, "and focus goes back to whoever opened the Studio")
        expect(stack.conversationChordsEnabled && stack.presenters.isEmpty, "with the conversation's chords back on")

        controller.show(lane: .image, in: window)
        controller.motionFinished()
        viewer.showPictures(items: pictures, startKey: pictures[0].key, host: nil, fetch: { _, _ in }, toast: nil)
        viewer.presenter.motionFinished()
        let done = (viewer.surface as? PictureGalleryView)?.toolbar.trailing.last as? NSButton
        done?.performClick(nil)
        expect(viewer.state == .closing && controller.state == .open, "Done closes the viewer only")
        viewer.presenter.motionFinished()
        viewer.showPictures(items: pictures, startKey: pictures[0].key, host: nil, fetch: { _, _ in }, toast: nil)
        viewer.presenter.motionFinished()
        if let point = viewer.sheet.scrimPointInWindow, let content = window.contentView {
            let local = content.convert(point, from: nil)
            expect(
                viewer.sheet.hitTest(viewer.sheet.convert(local, from: content)) is SheetScrim,
                "a point beside the sheet lands on the scrim")
        } else {
            expect(false, "the stacked sheet has a scrim to press")
        }
        viewer.sheet.onScrimPress?()
        expect(viewer.state == .closing && controller.state == .open, "a press on the viewer's scrim closes the viewer only")
        viewer.presenter.motionFinished()

        viewer.showPictures(items: pictures, startKey: pictures[0].key, host: nil, fetch: { _, _ in }, toast: nil)
        controller.show(lane: .video, in: window)
        expect(viewer.state == .closing && controller.current == .video, "the Studio asked for while a viewer is on it closes the viewer and changes lane")
        viewer.presenter.motionFinished()
        controller.dismiss()
        controller.motionFinished()
        window.close()
    }

    private static func gallery(_ expect: (Bool, String) -> Void) {
        let stack = SheetStack()
        let viewer = MediaViewer(stack: stack)
        viewer.presenter.reducedMotion = { false }
        let (window, opener) = offscreen(1180, 760)
        let pictures = items(4, tag: "m5gallery")
        var fetched: [String] = []
        viewer.showPictures(
            items: pictures, startKey: pictures[1].key, host: window, fetch: { _, key in fetched.append(key) }, toast: nil)
        guard let view = viewer.surface as? PictureGalleryView else {
            expect(false, "showing pictures builds a gallery")
            return
        }
        expect(viewer.sheet.depth == 0 && viewer.sheet.host === window, "a viewer over the conversation is a sheet at depth 0")
        expect(view.pager.index == 1 && view.currentItem.key == pictures[1].key, "the gallery opens at the picture asked for")
        expect(
            viewer.sheet.motionSummary.map { abs($0.duration - StudioSheetMotion.openDuration) < 0.001 && $0.travel > 0 && !$0.fades } == true,
            "it rises along Core's open motion")
        expect(view.toolbar.leading.count == 2 && view.toolbar.trailing.count == 4, "the toolbar carries previous and next, then zoom, copy, save and Done")
        expect(fetched.isEmpty, "pictures already held are not fetched again")

        let passes = view.layoutPasses
        for step in stride(from: 0.0, through: 1.0, by: 0.1) { viewer.sheet.apply(presence: step) }
        viewer.sheet.apply(presence: 1)
        expect(view.layoutPasses == passes, "moving the viewer through its whole travel lays nothing out inside it")
        viewer.presenter.motionFinished()

        viewer.sheet.cancelMotion(settingPresence: 1)
        expect(view.magnification > 0 && view.zoom.mode == .fit, "the page opens fitted")
        let fitted = view.magnification
        _ = viewer.press(.advance)
        expect(view.pager.index == 2, "Space pages forward")
        _ = viewer.press(.last)
        _ = viewer.press(.next)
        expect(view.pager.index == 0, "→ from the last wraps to the first")
        _ = viewer.press(.previous)
        expect(view.pager.index == 3, "← from the first wraps to the last")
        _ = viewer.press(.first)
        expect(view.pager.index == 0, "Home is the first picture")
        _ = viewer.press(.actual)
        let backing = window.backingScaleFactor
        expect(
            view.zoom.mode == .actual && abs(view.magnification - 1 / backing) < 0.001 && view.zoomTitle == Localized.text("Fit"),
            "1 shows true pixels and the button offers Fit")
        _ = viewer.press(.fit)
        expect(view.zoom.mode == .fit && abs(view.magnification - fitted) < 0.2, "0 fits again")
        _ = viewer.press(.zoomIn)
        expect(view.zoom.mode == .custom, "+ leaves the scale to the hand")
        _ = viewer.press(.next)
        expect(view.zoom.mode == .fit, "a new page opens fitted")
        window.setContentSize(NSSize(width: 960, height: 640))
        window.contentView?.layoutSubtreeIfNeeded()
        viewer.sheet.layoutSubtreeIfNeeded()
        expect(view.zoom.mode == .fit && view.magnification > 0, "a resize keeps a fitted page fitted")

        let more = items(2, tag: "m5retarget")
        viewer.showPictures(items: more, startKey: more[1].key, host: window, fetch: { _, _ in }, toast: nil)
        expect(viewer.state == .open && !viewer.sheet.isMoving, "opening another picture while one is up changes no state and moves nothing")
        expect(viewer.surface === view && view.items.count == 2 && view.pager.index == 1 && view.currentItem.key == more[1].key, "it points the gallery that is up at the new picture")
        expect(view.zoom.mode == .fit, "and opens it fitted")

        expect(viewer.press(.toggleZoom) && view.zoom.mode == .actual, "z toggles to true pixels")
        viewer.presenter.dismiss()
        expect(window.firstResponder === opener, "closing the viewer from the conversation returns focus to whoever opened it")
        viewer.presenter.motionFinished()
        expect(viewer.surface == nil && stack.presenters.isEmpty, "the viewer lets go of the gallery when it is gone")

        let missing = [ImageViewer.Item(key: "m5gallery:missing", name: "later.png", reference: FileReference(path: "/nonexistent/later"))]
        var asked: [String] = []
        viewer.showPictures(items: missing, startKey: "m5gallery:missing", host: window, fetch: { _, key in asked.append(key) }, toast: nil)
        expect(asked == ["m5gallery:missing"], "a picture whose bytes are not here yet is asked for")
        if let entry = bitmap(500, 300, seed: 3), let later = viewer.surface as? PictureGalleryView {
            ImageStore.shared.store(entry, forKey: "m5gallery:missing")
            expect(later.magnification > 0, "and paints the moment its bytes land")
        } else {
            expect(false, "a page that was waiting for bytes paints when they land")
        }
        viewer.presenter.teardown()
        window.close()
    }

    private static func clip(_ expect: (Bool, String) -> Void) {
        let stack = SheetStack()
        let viewer = MediaViewer(stack: stack)
        viewer.presenter.reducedMotion = { false }
        let (window, _) = offscreen(1180, 760)
        var saved = 0
        viewer.play(
            clip: URL(fileURLWithPath: "/nonexistent/clip.mp4"), title: "clip.mp4", host: window,
            save: { _ in saved += 1 }, share: { _ in })
        guard let player = viewer.surface as? ClipPlayerView else {
            expect(false, "playing a clip builds the player")
            return
        }
        expect(player.hasControls, "the player has the system's own controls")
        expect(player.toolbar.trailing.count == 3 && player.toolbar.trailing.last is NSButton, "the clip's toolbar carries Save, Share and Done")
        expect(viewer.press(.save) && saved == 1, "⌘S saves the clip through the lane's own save")
        expect(viewer.press(.advance), "Space is the player's")
        expect(!viewer.press(.next) && !viewer.press(.zoomIn), "and the picture keys are nobody's on a clip")
        let pictures = items(2, tag: "m5clip")
        viewer.showPictures(items: pictures, startKey: pictures[0].key, host: window, fetch: { _, _ in }, toast: nil)
        expect(viewer.surface is PictureGalleryView && viewer.state == .opening || viewer.state == .open, "pictures asked for over a clip take its place in the same sheet")
        viewer.presenter.teardown()
        window.close()
    }
}
