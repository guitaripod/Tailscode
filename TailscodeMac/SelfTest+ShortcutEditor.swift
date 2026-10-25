import AppKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// A key event as the keyboard would deliver it, without a keyboard: the function and
    /// navigation keys carry private-use characters, which is exactly why they are named by code.
    private static func keyEvent(
        code: UInt16, characters: String = "", flags: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)
    }

    /// The picture of a view on the window's own ground, written when `TAILSCODE_SHORTCUTS_OUT`
    /// names a directory: the only way to look at a sheet from a build loop with no screen.
    private static func snapshot(_ view: NSView?, as name: String, dark: Bool = false) {
        guard let view,
            let directory = ProcessInfo.processInfo.environment["TAILSCODE_SHORTCUTS_OUT"],
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.appearance = appearance
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        appearance?.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    private static func milliseconds(_ body: () -> Void) -> Double {
        let start = MachClock.now()
        body()
        return (MachClock.now() - start) * 1000
    }

    /// The shortcut editor on the Mac without a screen: the new actions resolve, the keys the
    /// editor needs arrive from NSEvent in the registry's space, the words the sheet says are
    /// right for every kind of key, an edit goes to a temporary file and back, a file that cannot
    /// be read is said so and never written over, and the list of every shortcut builds, filters
    /// and lays out. Returns the checks that held and the timings worth reading.
    static func checkShortcutEditor() throws -> (checks: Int, note: String) {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("shortcut editor case failed: \(label)") }
            checks += 1
        }

        let previous = ShortcutSet.configDirectoryOverride
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscode-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ShortcutSet.configDirectoryOverride = directory
        defer {
            ShortcutSet.configDirectoryOverride = previous
            try? FileManager.default.removeItem(at: directory)
        }
        let file = ShortcutSet.configURL

        let appIDs: [(String, KeyAction)] = [
            ("app.settings", .openSettings), ("app.servers", .openServers),
            ("app.updates", .openUpdates), ("app.usage", .openUsage),
            ("app.appearance", .toggleAppearance), ("app.fullscreen", .toggleFullscreen),
            ("composer.compactTools", .toggleCompactTools),
            ("composer.vimMode", .toggleVimComposer),
        ] + (1...9).map { ("chat.open\($0)", KeyAction.openChat($0)) }
        let probe = KeyChord.canonical(
            keyval: Keymap.functionKey(9), state: KeyChord.controlMask | KeyChord.altMask)
        for (id, action) in appIDs {
            try expect(ShortcutRegistry.definition(id)?.action == action, "\(id) is registered")
            let rebound = ShortcutSet.build(overrides: [id: ["ctrl+alt+f9"]])
            let outcome = probe.map {
                rebound.resolve($0, context: .normal, pending: [], awaitingApproval: false)
            }
            try expect(outcome == .run(action), "\(id) resolves to its action when bound")
        }
        let shipped = ShortcutSet.build(overrides: [:])
        try expect(shipped.issues.isEmpty, "the new defaults add no conflicts: \(shipped.issues)")
        let f11 = KeyChord.canonical(keyval: Keymap.functionKey(11), state: 0)
        try expect(
            f11.map {
                shipped.resolve($0, context: .normal, pending: [], awaitingApproval: false)
            } == .run(.toggleFullscreen), "F11 is full screen as shipped")

        let sidebar = SidebarViewController()
        try expect(!sidebar.open(number: 1), "an empty list opens no chat and lets the key on")
        try expect(!sidebar.open(number: 0), "chat zero is not a chat")
        try expect(!sidebar.open(number: 9), "a number past the end is declined")

        for number in 1...12 {
            let code: UInt16 = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111][number - 1]
            let scalar = String(UnicodeScalar(UInt32(0xF703 + number))!)
            let chord = keyEvent(code: code, characters: scalar).flatMap(MacKeys.chord(for:))
            try expect(chord?.keyval == Keymap.functionKey(number), "F\(number) by key code")
        }
        let named: [(UInt16, UInt32, String)] = [
            (115, Keymap.home, "Home"), (119, Keymap.end, "End"),
            (116, Keymap.pageUp, "Page Up"), (121, Keymap.pageDown, "Page Down"),
            (117, Keymap.delete, "Forward Delete"),
        ]
        for (code, keyval, name) in named {
            let chord = keyEvent(code: code, characters: "\u{F729}").flatMap(MacKeys.chord(for:))
            try expect(chord?.keyval == keyval, "\(name) by key code")
        }
        let shiftedF5 = keyEvent(code: 96, characters: "\u{F708}", flags: .shift)
            .flatMap(MacKeys.chord(for:))
        try expect(shiftedF5?.shift == true && shiftedF5?.keyval == 0xFFC2, "shift+F5 keeps shift")
        try expect(
            keyEvent(code: 96, characters: "\u{F708}", flags: .command)
                .flatMap(MacKeys.chord(for:)) == nil, "⌘F5 belongs to the menu bar")

        let a = KeyChord.canonical(keyval: 0x61, state: 0)!
        let b = KeyChord.canonical(keyval: 0x62, state: 0)!
        let c = KeyChord.canonical(keyval: 0x63, state: 0)!
        try expect(ShortcutCaptureVerdict.pressed(a, after: []) == [a], "first press is a chord")
        try expect(ShortcutCaptureVerdict.pressed(b, after: [a]) == [a, b], "second is a sequence")
        try expect(ShortcutCaptureVerdict.pressed(c, after: [a, b]) == [c], "third starts over")

        let bindings = ShortcutBindings.load()
        let free = ShortcutCaptureVerdict(typed: "f9", for: "chat.archive", in: bindings)
        try expect(
            free.tone == .free && free.canAdd && !free.takesKeys && free.addTitle == "Add key",
            "an unused key is free: \(free.message)")
        let taken = ShortcutCaptureVerdict(typed: "n", for: "chat.archive", in: bindings)
        let owner = ShortcutRegistry.definition("chat.new")?.title ?? ""
        try expect(
            taken.takesKeys && taken.addTitle == "Take it" && taken.message.contains(owner),
            "a used key names its owner by title: \(taken.message)")
        let sequence = ShortcutCaptureVerdict(typed: "n n", for: "chat.archive", in: bindings)
        try expect(
            sequence.takesKeys && sequence.message.contains(owner)
                && sequence.message.contains("first key"),
            "a sequence over a single key says it would never be reached: \(sequence.message)")
        if let archive = ShortcutCaptureSheet(id: "chat.archive", onChange: {}) {
            archive.take(KeySpec.parse("n")?.chords ?? [])
            snapshot(archive.window.contentView, as: "sheet-takes")
            archive.take(KeySpec.parse("g g")?.chords ?? [])
            snapshot(archive.window.contentView, as: "sheet-takes-dark", dark: true)
        }
        let refused = ShortcutCaptureVerdict(typed: "x", for: "composer.send", in: bindings)
        try expect(!refused.canAdd && refused.tone == .warning, "a typed letter is refused in the box")
        try expect(
            !ShortcutCaptureVerdict(typed: "bogus+key", for: "chat.new", in: bindings).canAdd,
            "nonsense is not a key")
        try expect(
            ShortcutCaptureVerdict(typed: "n", for: "chat.new", in: bindings).spec == nil,
            "a key the action already has is not added twice")
        try expect(ShortcutCaptureVerdict.menuBar.message.contains("⌘"), "⌘ is explained")
        try expect(
            ShortcutCaptureVerdict(chords: [], for: "chat.new", in: bindings) == .idle,
            "nothing pressed says what to do")

        let extra = "ctrl+alt+n"
        let extraChord = KeySpec.parse(extra)?.chords.first
        try expect(extraChord != nil, "the extra key parses")
        let plan = ShortcutEditor.adding(extra, to: "chat.new", in: bindings)
        let written = try ShortcutEditor.apply(plan)
        try expect(written.keys(for: "chat.new") == ["n", extra], "the file adds the key")
        let loaded = ShortcutSet.load()
        try expect(
            extraChord.map {
                loaded.resolve($0, context: .normal, pending: [], awaitingApproval: false)
            } == .run(.newChat), "the added key resolves to a new chat")
        try expect(written.isCustomized("chat.new") && written.customizedCount == 1, "one changed")
        try expect(
            ShortcutEditor.apply(ShortcutEditor.restoring("chat.new", in: written))
                .customizedCount == 0, "restoring puts the shipped keys back")
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        try expect(after?["chat.new"] == nil, "the file no longer pins chat.new")

        var changed = 0
        guard let sheet = ShortcutCaptureSheet(id: "chat.new", onChange: { changed += 1 })
        else { throw SelfTestFailure("shortcut editor case failed: the sheet did not open") }
        snapshot(sheet.window.contentView, as: "sheet-idle")
        sheet.take(extraChord.map { [$0] } ?? [])
        snapshot(sheet.window.contentView, as: "sheet-free")
        try expect(sheet.verdict.spec == extra && sheet.verdict.tone == .free, "the sheet judges a press")
        sheet.commit()
        try expect(
            changed == 1 && ShortcutBindings.load().keys(for: "chat.new").contains(extra),
            "Add key writes the file and tells the window")
        sheet.remove(extra)
        try expect(
            changed == 2 && !ShortcutBindings.load().isCustomized("chat.new"),
            "removing the added key leaves the shipped one")
        let fitted = sheet.window.contentView?.fittingSize ?? .zero
        try expect(
            fitted.width == ShortcutCaptureSheet.width && (200...600).contains(fitted.height),
            "the sheet is a sane size: \(fitted)")
        let stray = keyEvent(code: 0, characters: "a")
        try expect(
            stray.flatMap { sheet.hear($0) } === stray, "a key for another window is not eaten")
        try expect(!sheet.isHearing, "a sheet that is not key hears nothing")

        let broken = Data("{ not json".utf8)
        try broken.write(to: file)
        do {
            try ShortcutEditor.apply(ShortcutEditor.adding(extra, to: "chat.new", in: .load()))
            throw SelfTestFailure("shortcut editor case failed: a broken file was written over")
        } catch ShortcutFile.Failure.unreadable {
            checks += 1
        }
        try expect((try? Data(contentsOf: file)) == broken, "the broken file is left as it was")
        sheet.take(extraChord.map { [$0] } ?? [])
        sheet.commit()
        snapshot(sheet.window.contentView, as: "sheet-broken")
        try expect(
            sheet.fileProblem?.contains("not valid JSON") == true && changed == 2,
            "the sheet says the file cannot be read")
        try FileManager.default.removeItem(at: file)

        let list = ShortcutListView()
        let built = milliseconds { list.reload() }
        let expected = ShortcutRegistry.all.filter { !ShortcutSet.unavailable.contains($0.id) }.count
        try expect(list.rowCount == expected, "a row for every shortcut: \(list.rowCount)")
        list.frame = NSRect(x: 0, y: 0, width: 552, height: list.intrinsicContentSize.height)
        let laid = milliseconds { list.layoutSubtreeIfNeeded() }
        let height = list.intrinsicContentSize.height
        try expect(height > CGFloat(expected) * 30, "the list is tall enough for its rows: \(height)")
        list.frame.size.height = height
        list.layoutSubtreeIfNeeded()
        var painted = 0.0
        if let image = list.bitmapImageRepForCachingDisplay(in: list.bounds) {
            painted = milliseconds { list.cacheDisplay(in: list.bounds, to: image) }
        }
        var floor: CGFloat = 0
        for row in list.visibleRows() {
            try expect(row.frame.width == 552 && row.frame.minY >= floor, "rows stack without overlap")
            floor = row.frame.maxY
        }
        try expect(floor <= height, "the last row is inside the list")
        let shown = milliseconds { list.filter("archive") }
        let narrowed = list.visibleRowCount
        try expect((1..<20).contains(narrowed), "searching narrows the list: \(narrowed)")
        list.filter("zzzzqq")
        try expect(list.visibleRowCount == 0, "nothing matches nonsense")
        list.filter("")
        try expect(list.visibleRowCount == expected, "an empty search shows every shortcut")

        let preferences = PreferencesWindow(
            onComposerChanged: {}, onTranscriptChanged: {}, onReloadShortcuts: { changed += 1 })
        preferences.install(selecting: PreferencesWindow.page(named: "keyboard"))
        preferences.window?.contentView?.layoutSubtreeIfNeeded()
        let page = preferences.shortcutList
        try expect(page?.rowCount == expected, "the Keyboard page carries the list")
        try expect((page?.frame.width ?? 0) > 400, "the list fills the page: \(page?.frame.width ?? 0)")
        try expect(
            (page?.frame.height ?? 0) == page?.intrinsicContentSize.height,
            "the page gives the list the height it asks for")
        snapshot(preferences.window?.contentView, as: "keyboard-page")
        snapshot(preferences.window?.contentView, as: "keyboard-page-dark", dark: true)
        preferences.changeShortcut("chat.new")
        try expect(preferences.captureSheet?.id == "chat.new", "Change… opens the sheet")
        preferences.captureSheet?.stopHearing()
        preferences.window?.close()

        let note = String(
            format: "list %d rows: built %.0f ms, laid out %.0f ms, painted whole %.0f ms, search %.0f ms",
            expected, built, laid, painted, shown)
        return (checks, note)
    }
}
