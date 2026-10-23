import AgentTestSupport
import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    static func checkPaneHitTest() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("hit test case failed: \(label)") }
            checks += 1
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        func pane(_ frame: NSRect) -> NSViewController {
            let controller = NSViewController()
            controller.view = NSView(frame: frame)
            window.contentView?.addSubview(controller.view)
            return controller
        }
        let left = pane(NSRect(x: 0, y: 0, width: 195, height: 200))
        let right = pane(NSRect(x: 205, y: 0, width: 195, height: 200))
        let hidden = pane(NSRect(x: 0, y: 0, width: 400, height: 200))
        hidden.view.isHidden = true
        let detached = NSViewController()
        detached.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let panes = [left, right, hidden, detached]

        func hit(_ x: Double, _ y: Double) -> NSViewController? {
            SplitPaneHost.hitTest(panes, at: NSPoint(x: x, y: y))
        }
        try expect(hit(40, 100) === left, "a press in the left pane is the left pane's")
        try expect(hit(300, 100) === right, "a press in the right pane is the right pane's")
        try expect(hit(200, 100) == nil, "a press on the divider belongs to no pane")
        try expect(hit(194.5, 100) === left, "the pane owns its own last column")
        try expect(hit(-5, 100) == nil, "a press outside the tree belongs to no pane")
        try expect(hit(40, 260) == nil, "a press above the tree belongs to no pane")
        try expect(
            hit(40, 100) !== hidden, "a pane the zoom has hidden never takes the press")
        try expect(
            SplitPaneHost.hitTest([detached], at: NSPoint(x: 40, y: 100)) == nil,
            "a pane in no window takes nothing")
        return checks
    }

    /// The pane verbs on this toolkit: the menu names every verb with the keys it is on, a divider
    /// that holds focus answers the keyboard and says what it is to VoiceOver, and a strip carries
    /// its pane under a type no chat target mistakes. What the tree does with each verb is Core's.
    static func checkPaneVerbs() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("pane verbs: \(label)") }
            checks += 1
        }

        final class Probe: NSObject {
            @objc func verb(_ sender: NSMenuItem) {}
            @objc func arrangement(_ sender: NSMenuItem) {}
        }
        let probe = Probe()
        let set = ShortcutSet.build(overrides: [:])
        let holders = PaneMenu.items(
            keys: { set.effective[$0]?.joined(separator: " / ") }, verb: #selector(Probe.verb(_:)),
            arrangement: #selector(Probe.arrangement(_:)), target: probe)
        try expect(
            holders.map(\.title) == SplitMenu.groups.map(\.title),
            "one submenu per Core group, in Core's order")
        let arrange = holders[0].submenu?.items.filter { !$0.isSeparatorItem } ?? []
        try expect(
            arrange.compactMap { $0.representedObject as? SplitArrangement }
                == SplitMenu.arrangements,
            "the arrange submenu names every shape")
        let verbs = holders.flatMap { $0.submenu?.items ?? [] }
            .filter { $0.representedObject is KeyAction }
        let expected = SplitMenu.groups.flatMap(\.shortcutIDs)
        try expect(verbs.count == expected.count, "every Core verb has an item")
        for (item, id) in zip(verbs, expected) {
            try expect(
                item.representedObject as? KeyAction == SplitMenu.definition(id)?.action,
                "\(id) dispatches its own action")
            let keys = set.effective[id]?.joined(separator: " / ") ?? ""
            try expect(
                item.attributedTitle?.string.contains(keys) == true && !keys.isEmpty,
                "\(id) wears the keys it is on")
        }
        let wider = verbs.first { ($0.representedObject as? KeyAction) == .resizeSplit(.right) }
        try expect(wider?.attributedTitle?.string.contains("^w >") == true, "wider shows ^w >")
        let rebound = ShortcutSet.build(overrides: ["split.growWider": ["ctrl+w ctrl+l"]])
        try expect(
            rebound.effective["split.growWider"]?.first != set.effective["split.growWider"]?.first,
            "a rebinding changes the keys the menu would show")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        let divider = DividerSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        divider.isVertical = true
        divider.dividerStyle = .thin
        divider.addArrangedSubview(NSView())
        divider.addArrangedSubview(NSView())
        window.contentView = divider
        divider.layoutSubtreeIfNeeded()
        divider.setPosition(300, ofDividerAt: 0)
        var keys: [DividerKey] = []
        divider.onDividerKey = {
            keys.append($0)
            return true
        }
        divider.accessibilityReading = {
            DividerAccessibilityReading(
                label: "Divider between A and B", value: "42 percent", position: 300,
                minimum: 280, maximum: 700)
        }
        try expect(divider.acceptsFirstResponder, "a divider with a key handler takes focus")
        let splitters = (divider.accessibilityChildren() ?? []).compactMap {
            $0 as? NSAccessibilityElement
        }
        try expect(splitters.count == 1, "exactly one splitter is announced")
        let element = splitters[0]
        try expect(element.accessibilityRole() == .splitter, "the divider is a splitter")
        try expect(
            element.accessibilityLabel() == "Divider between A and B", "it names the two panes")
        try expect((element.accessibilityValue() as? NSNumber)?.doubleValue == 300, "it reads its place")
        try expect(
            (element.accessibilityMinValue() as? NSNumber)?.doubleValue == 280
                && (element.accessibilityMaxValue() as? NSNumber)?.doubleValue == 700,
            "it reads its extremes")
        try expect(element.accessibilityValueDescription() == "42 percent", "it says where it stands")
        try expect(element.accessibilityPerformIncrement(), "VoiceOver can step it forward")
        try expect(element.accessibilityPerformDecrement(), "and back")
        try expect(keys == [.forward(large: false), .back(large: false)], "by the keyboard step")
        let frame = element.accessibilityFrame()
        try expect(frame.width > 0 && frame.height > 0, "it has a place on the screen")

        func key(_ code: UInt16, shift: Bool = false, command: Bool = false) -> NSEvent? {
            var flags: NSEvent.ModifierFlags = []
            if shift { flags.insert(.shift) }
            if command { flags.insert(.command) }
            return NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
        }
        keys = []
        for event in [key(124), key(124, shift: true), key(123), key(126, shift: true), key(115), key(119)] {
            guard let event else { throw SelfTestFailure("pane verbs: could not build a key event") }
            divider.keyDown(with: event)
        }
        try expect(
            keys == [
                .forward(large: false), .forward(large: true), .back(large: false),
                .back(large: true), .lowest, .highest,
            ],
            "arrows step, shift steps far, Home and End go to the extremes")
        try expect(
            key(124, command: true).flatMap(DividerSplitView.dividerKey(for:)) == nil,
            "a command chord is not a divider's")
        try expect(
            key(0).flatMap(DividerSplitView.dividerKey(for:)) == nil, "a letter is not a divider's")

        let strip = PaneStripView(views: [])
        let probeID = PaneID()
        let item = PaneStripView.pasteboardItem(for: PaneMovePayload(pane: probeID))
        try expect(
            item.string(forType: .tailscodePane).flatMap(PaneMovePayload.decode)?.pane == probeID,
            "the strip carries its pane under the pane type")
        try expect(item.string(forType: .tailscodeChat) == nil, "and never as a chat")
        try expect(item.string(forType: .string) == nil, "and never as plain text")
        try expect(PaneStripView.operation == .move, "a pane in flight moves")
        try expect(strip.hitTest(NSPoint(x: -5, y: -5)) == nil, "the strip takes only its own presses")
        return checks
    }

    /// The catalog is proved as arithmetic in Core; what this checks is the half Core cannot see —
    /// that a saved id reaches an `NSColor` on this toolkit, that both faces of a theme come back
    /// different, that the accent the cascade leads with is the accent the tokens hand out, and
    /// that no two meanings collapsed into one colour on the way across.
    static func checkTheme() throws -> Int {
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
        }
        var checks = 0
        try expect(
            ThemePalette.palette(themeID: ThemeSelection.systemID, dark: true) == nil,
            "the system choice resolved to a palette")
        for theme in AppTheme.all {
            let night = ThemePalette.palette(themeID: theme.id, dark: true)
            let day = ThemePalette.palette(themeID: theme.id, dark: false)
            try expect(night?.name == theme.dark.name, "\(theme.id) does not reach its night")
            try expect(day?.name == theme.light.name, "\(theme.id) does not reach its day")
            try expect(
                NSColor(hex: theme.dark.corrected().accent) != nil,
                "\(theme.id) has an accent AppKit cannot make")
            checks += 1
        }
        for face in [NSAppearance(named: .darkAqua), NSAppearance(named: .aqua)] {
            guard let face else { throw SelfTestFailure("AppKit has no such appearance") }
            var resolved: [String: String] = [:]
            face.performAsCurrentDrawingAppearance {
                resolved = [
                    "accent": CascadeTint.hex(MacTheme.Color.accent),
                    "warning": CascadeTint.hex(MacTheme.Color.warning),
                    "danger": CascadeTint.hex(MacTheme.Color.danger),
                    "info": CascadeTint.hex(MacTheme.Color.info),
                    "mark": CascadeTint.hex(MacTheme.Color.mark),
                ]
            }
            try expect(
                Set(resolved.values).count == resolved.count,
                "two meanings wear one colour under \(face.name.rawValue)")
            checks += 1
        }
        try expect(
            CascadeTint.hex(CascadeTint.edge(ultracode: false, phase: 0.5))
                == CascadeTint.hex(MacTheme.Color.accent),
            "the wave leads with an accent the tokens do not know")
        checks += 1
        return checks
    }

    /// One conversation, two desks: the level a turn was picked at on another machine is the
    /// listing's, and it has to reach a pane that is already open — and be what that pane sends
    /// next — while a pick made here still wins until it is sent, which is the rule every client
    /// keeps. Composer only, no window: the rule is the store order, not a drawing.
    static func checkSessionSync() throws -> Int {
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
        }
        let profileID = "session-sync-check"
        let key = "\(profileID)/ses_sync"
        defer {
            EffortPreferenceStore.setEffort(nil, forKey: key)
            ModelPreferenceStore.setModel(nil, forKey: key)
            EffortPreferenceStore.setGlobalEffort(nil, forContextID: profileID)
            ModelPreferenceStore.setGlobalModel(nil, forContextID: profileID)
        }
        func entry(_ effort: String?, _ model: String?) -> SessionEntry {
            SessionEntry(
                profileID: profileID, profileName: "sync", host: "sync", backendType: .openCode,
                session: AgentSession(
                    id: "ses_sync", agentType: .openCode, title: "sync",
                    createdAt: Date(), updatedAt: Date(), model: model,
                    modelProviderID: model == nil ? nil : "opencode-go",
                    reasoningEffort: effort))
        }
        let backend = MockBackend(
            agentType: .openCode, reasoningEffortOptions: ["low", "high", "max"])
        let composer = ComposerView()
        composer.prepare(for: entry("high", "deepseek-v4.1-flash"), backend: backend)
        try expect(composer.shownEffort == "high", "a pane does not open at the session's level")
        composer.adopt(entry("max", "deepseek-v4.1-flash"))
        try expect(composer.shownEffort == "max", "a level another desk picked never reaches the pane")
        try expect(composer.activeEffort == "max", "and a send from here carries the old level")
        EffortPreferenceStore.recordPick("low", sessionKey: key, contextID: profileID)
        composer.adopt(entry("high", "deepseek-v4.1-flash"))
        try expect(composer.shownEffort == "low", "a pick made here loses to the listing")
        return 4
    }
}
