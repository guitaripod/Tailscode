import AppKit
import Foundation
import TailscodeCore

extension StudioCheck {
    static func sheetKeys(_ expect: (Bool, String) -> Void) {
        expect(
            StudioKey.allCases.filter(\.sharesChordWithConversation) == [.generate, .enhance, .editThis],
            "exactly three of the Studio's chords are also a conversation's: Generate, Enhance and Edit this")
        expect(
            StudioKey.allCases.filter(\.sharesChordWithConversation).allSatisfy { $0.chord.command },
            "and they are ⌘ chords, the only kind a menu item can hold first")
    }

    static func sheetMenu(_ expect: (Bool, String) -> Void) {
        let allowed = ["studioVerb:", "openStudio", "videoForge", "closeFront:", "support", "reportIssue", "privacy"]
        for name in allowed {
            expect(MainMenu.answersWhileStudioIsUp(NSSelectorFromString(name)), "\(name) is answered while the sheet is up")
        }
        let conversation = [
            "send", "stop", "newChat", "quickAsk", "find", "findNext", "toggleSaved", "toggleArchived", "toggleUnread",
            "rename", "fork", "copySessionID", "copyProjectPath", "deleteChat", "toggleMarked", "markAll",
            "toggleSidebar", "toggleTerminal", "toggleArchiveView", "splitRight", "splitDown", "closeSplit",
            "zoomSplit", "focusSplitLeft", "exchangeSplit", "paneVerb:", "paneArrangement:", "openDial",
            "effortHotter", "takePreset:", "allModels", "nextChat", "previousChat", "zoomIn", "cheatsheet",
            "settings", "software", "pro", "openDelegate", "monthInNumbers",
        ]
        for name in conversation {
            expect(!MainMenu.answersWhileStudioIsUp(NSSelectorFromString(name)), "\(name) is disabled while the sheet is up")
        }
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
        let toolbar = NSToolbar(identifier: "sheet.check")
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.autoresizingMask = [.width, .height]
        let opener = FocusProbe(frame: NSRect(x: 20, y: 20, width: 80, height: 24))
        content.addSubview(opener)
        window.contentView = content
        window.makeFirstResponder(opener)
        return (window, opener)
    }

    static func sheet(_ expect: (Bool, String) -> Void) {
        let controller = StudioWindowController(studio: MacImageStudio(endpoint: ImageGenEndpoint(host: "127.0.0.1")))
        controller.reducedMotionOverride = false
        let (window, opener) = offscreen(1180, 760)
        expect(controller.state == .closed && controller.state.conversationChordsEnabled, "the sheet starts closed and the conversation's chords are on")

        controller.show(lane: .image, in: window)
        guard let sheet = controller.sheet else {
            expect(false, "showing the Studio builds the sheet")
            return
        }
        expect(controller.state == .opening && !controller.state.conversationChordsEnabled, "show from closed starts the rise, and the chords go off with it")
        expect(sheet.superview === window.contentView, "the overlay is the window content's own subview")
        expect(window.contentView?.subviews.last === sheet, "and the topmost, above everything the window holds")
        expect(sheet.holds(window.firstResponder as? NSView), "the words box holds the keyboard from the first frame")
        expect(controller.sheetOwnsKeys(in: window) && controller.isKey, "and the sheet owns the keys")
        expect(opener.isAccessibilityHidden(), "what is behind it is hidden from assistive technology")
        expect(
            sheet.motionSummary.map { abs($0.duration - StudioSheetMotion.openDuration) < 0.001 && $0.travel > 0 && !$0.fades } == true,
            "the rise takes Core's open duration, travels, and the sheet is opaque from its first frame")

        let sizes: [(CGFloat, CGFloat)] = [(1440, 900), (1180, 760), (960, 640), (880, 640), (690, 500), (2560, 1400)]
        for (width, height) in sizes {
            window.setContentSize(NSSize(width: width, height: height))
            window.contentView?.layoutSubtreeIfNeeded()
            sheet.layoutSubtreeIfNeeded()
            let core = StudioSheetGeometry.frame(
                windowWidth: Double(sheet.bounds.width), windowHeight: Double(sheet.bounds.height),
                titlebar: StudioSheetView.titlebarClearance(in: window))
            let actual = sheet.sheetFrame
            expect(
                abs(actual.minX - core.x) < 0.5 && abs(actual.minY - core.y) < 0.5 && abs(actual.width - core.width) < 0.5
                    && abs(actual.height - core.height) < 0.5,
                "the sheet's frame is Core's for a window of \(Int(width))×\(Int(height)): \(actual) against \(core.x),\(core.y) \(core.width)×\(core.height)")
            expect(sheet.bounds.size == window.contentView?.bounds.size, "and the overlay follows the window's content at \(Int(width))×\(Int(height))")
        }
        expect(StudioSheetView.titlebarClearance(in: window) > 0, "the title-bar clearance is read off the window, not assumed zero")

        let passes = sheet.workspace.layoutPasses
        for step in stride(from: 0.0, through: 1.0, by: 0.1) { sheet.apply(presence: step) }
        sheet.apply(presence: 1)
        expect(sheet.workspace.layoutPasses == passes, "moving the sheet through its whole travel lays nothing out inside it")

        controller.show(lane: .image, in: window)
        expect(controller.state == .opening && controller.current == .image, "show while rising keeps the state")
        controller.motionFinished()
        expect(controller.state == .open, "finished settles the rise")
        controller.show(lane: .image, in: window)
        expect(controller.state == .open && controller.current == .image, "show while open keeps the state")
        expect(controller.activeLane?.id == .image, "the lane is the one asked for")

        StudioDemo.apply("rewrite", to: controller.image.studio)
        expect(controller.activeLane?.offers(.stop) == true, "a lane with something to stop offers Stop")
        controller.escapePressed()
        expect(controller.state == .open, "Esc with something to stop spends itself on that and does not close the sheet")
        expect(controller.activeLane?.offers(.stop) == false, "which is gone")
        controller.escapePressed()
        expect(controller.state == .closing && controller.state.conversationChordsEnabled, "the next Esc closes it, and the chords are back as it starts to leave")
        expect(!opener.isAccessibilityHidden(), "the accessibility tree is back as it starts to leave")
        expect(window.firstResponder === opener, "and the keyboard is back with whoever held it")
        expect(
            sheet.motionSummary.map { abs($0.duration - StudioSheetMotion.closeDuration) < 0.001 } == true,
            "the way out takes Core's close duration")
        expect(
            !controller.closesSheet(chord: closeChord, command: true, keyWindow: nil),
            "⌘W with the sheet already leaving is the window's")
        controller.motionFinished()
        expect(controller.state == .closed && sheet.superview == nil, "finished takes the overlay out of the window")
        expect(window.makeFirstResponder(opener) && !opener.isAccessibilityHidden(), "and leaves the window as it found it")

        controller.show(lane: .image, in: window)
        expect(
            controller.closesSheet(chord: closeChord, command: true, keyWindow: window),
            "⌘W with the sheet up closes the sheet")
        expect(controller.state == .closing, "and starts it leaving")
        expect(
            !controller.closesSheet(chord: closeChord, command: true, keyWindow: window),
            "the second ⌘W is not the sheet's, so it reaches the window")
        controller.motionFinished()
        controller.show(lane: .image, in: window)
        expect(
            !controller.closesSheet(chord: closeChord, command: false, keyWindow: window),
            "Ctrl+W's chord on the Mac's ⌘ flag is not ⌘W")
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        expect(
            !controller.closesSheet(chord: closeChord, command: true, keyWindow: other),
            "and a window the sheet is not in keeps its own ⌘W")
        controller.motionFinished()
        controller.dismiss()
        controller.motionFinished()
        expect(controller.state == .closed, "dismiss and finished close it from open")

        controller.reducedMotionOverride = true
        controller.show(lane: .image, in: window)
        expect(
            sheet.motionSummary.map { abs($0.duration - StudioSheetMotion.reducedDuration) < 0.001 && $0.travel == 0 && $0.fades } == true,
            "reduced motion is a 120 ms cross-fade with no travel")
        controller.motionFinished()
        controller.dismiss()
        expect(
            sheet.motionSummary.map { abs($0.duration - StudioSheetMotion.reducedDuration) < 0.001 && $0.travel == 0 && $0.fades } == true,
            "and the way out is the same")
        controller.motionFinished()
        controller.reducedMotionOverride = false

        controller.show(lane: .image, in: window)
        controller.motionFinished()
        controller.dismiss()
        controller.show(lane: .image, in: window)
        expect(controller.state == .opening, "show while closing rises again")
        expect(abs(sheet.presence - 1) < 0.001 && sheet.isMoving, "from where it was, to rest, without a jump")
        controller.motionFinished()

        let (second, probe) = offscreen(900, 700)
        controller.show(lane: .image, in: second)
        expect(sheet.host === second && sheet.superview === second.contentView, "opening from another window moves the one sheet there")
        expect(window.contentView?.subviews.contains(sheet) == false && !opener.isAccessibilityHidden(), "and leaves the first window as it was")
        expect(probe.isAccessibilityHidden() && controller.state == .open, "while the second is held behind it")
        controller.dismiss()
        controller.motionFinished()
        expect(controller.state == .closed, "and it closes from there")

        controller.show(lane: .image, in: window)
        window.close()
        expect(controller.state == .closed && sheet.superview == nil, "a window closed with the sheet in it takes the sheet with it")
        second.close()
        other.close()
    }

    static func capsulePresses(_ expect: (Bool, String) -> Void) {
        let studio = MacImageStudio(endpoint: ImageGenEndpoint(host: "127.0.0.1"))
        StudioDemo.apply("done", to: studio)
        let controller = StudioWindowController(studio: studio)
        controller.reducedMotionOverride = true
        let (window, _) = offscreen(1180, 760)
        controller.show(lane: .image, in: window)
        controller.motionFinished()
        window.contentView?.layoutSubtreeIfNeeded()
        guard let capsule = first(StudioVerbsCapsule.self, in: window.contentView),
            let exhibit = studio.exhibit
        else {
            expect(false, "a finished picture draws the verbs capsule")
            return
        }
        let expected = StudioVerbs.faces(
            state: .done, kept: exhibit.isKept, hasWords: studio.hasWords(exhibit)
        ).map(\.id)
        let buttons = all(StudioVerbButton.self, in: capsule)
        expect(
            buttons.map(\.verb.id) == expected,
            "the capsule draws one button per verb the stage offers, in its order")
        expect(!capsule.isHidden && capsule.alphaValue == 1, "and it is on the stage")
        for size in [NSSize(width: 1180, height: 760), NSSize(width: 640, height: 600)] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            for button in all(StudioVerbButton.self, in: capsule) {
                expect(
                    pressed(button, in: window),
                    "the \(button.verb.id) button answers a press at \(Int(size.width))×\(Int(size.height))")
                expect(
                    pressFires(button, in: window),
                    "and a click on the \(button.verb.id) button fires its action at \(Int(size.width))×\(Int(size.height))")
            }
            expect(
                clearOfTheDock(capsule, in: window),
                "and the capsule stands clear of the dock at \(Int(size.width))×\(Int(size.height))")
        }
        controller.dismiss()
        controller.motionFinished()
        window.close()
    }

    private static func clearOfTheDock(_ capsule: StudioVerbsCapsule, in window: NSWindow) -> Bool {
        guard let stage = capsule.superview as? StudioStageView,
            let workspace = stage.superview,
            let dock = workspace.subviews.first(where: { $0 is StudioDockView })
        else { return false }
        return capsule.convert(capsule.bounds, to: workspace).maxY <= dock.frame.minY
    }

    private static func pressed(_ button: StudioVerbButton, in window: NSWindow) -> Bool {
        guard let root = window.contentView else { return false }
        let centre = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        return root.hitTest(root.convert(centre, from: nil)) is StudioVerbButton
    }

    /// A real click on the view the window hit-tests at the button's centre, with the button's
    /// action swapped for a counter: proof that the press lands on the button and that the button
    /// then runs what it was given, which hit-testing alone never showed.
    private static func pressFires(_ button: StudioVerbButton, in window: NSWindow) -> Bool {
        guard let root = window.contentView else { return false }
        let original = button.onPress
        var fired = 0
        button.onPress = { fired += 1 }
        defer { button.onPress = original }
        let centre = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        guard let target = root.hitTest(root.convert(centre, from: nil)) as? StudioVerbButton else {
            return false
        }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: centre, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        target.mouseDown(with: down)
        target.mouseUp(with: up)
        return fired == 1
    }

    private static func first<T: NSView>(_ type: T.Type, in root: NSView?) -> T? {
        guard let root else { return nil }
        if let match = root as? T { return match }
        for child in root.subviews {
            if let found = first(type, in: child) { return found }
        }
        return nil
    }

    private static func all<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        if let match = root as? T { found.append(match) }
        for child in root.subviews { found += all(type, in: child) }
        return found
    }

    private static var closeChord: KeyChord {
        KeyChord.canonical(keyval: UInt32(UnicodeScalar("w").value), state: 0)!
    }

    static func laneSwitch(_ expect: (Bool, String) -> Void) {
        let studio = MacImageStudio(endpoint: ImageGenEndpoint(host: "127.0.0.1"))
        StudioDemo.apply("drafting", to: studio)
        let image = ImageLane(studio: studio)
        ForgeRunner.shared.stage(ForgeDemo.board("history"))
        let video = VideoLane(runner: .shared)
        let workspace = StudioWorkspaceView(scoped: true)
        workspace.setLane(image)
        image.dock.take(brief: "a lighthouse on a cliff")
        expect(workspace.lane === image, "the workspace holds the lane it was given")
        workspace.setLane(video)
        expect(workspace.lane === video, "and the Video lane replaces it")
        video.dock.take(brief: "a cat asleep on a roof")
        workspace.setLane(image)
        expect((image.dock as? StudioDockView)?.text == "a lighthouse on a cliff", "switching back finds each lane's own words")
        workspace.setLane(video)
        expect(
            (video.dock as? StudioDockView)?.text == "a cat asleep on a roof"
                && ForgeRunner.shared.board.recipe.prompt == "a cat asleep on a roof",
            "in both directions, and the clip's words are the board's, which outlives the sheet")
        expect(
            image.shelfTitle != video.shelfTitle && image.id != video.id,
            "each lane brings its own shelf")
        ForgeRunner.shared.demonstrate("history")
        video.select(tile: "demo-1")
        expect(video.selectedTile == "demo-1", "what a lane had on stage is still on it")
        workspace.setLane(image)
        workspace.setLane(video)
        expect(video.selectedTile == "demo-1", "after the other lane has been in front")
        expect(
            !video.offers(.imageLane) && !video.offers(.videoLane),
            "the lane switch is the shell's, never a lane's")
    }
}
