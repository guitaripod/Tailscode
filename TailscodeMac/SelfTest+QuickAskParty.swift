import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    private static let partyKey = "tailscode.modelParty"
    private static let recentsKey = "tailscode.recentModels"

    /// The party in the quick ask, over two fixture machines and a fixture party, with every key it
    /// touches put back as it was found: the pill opens it on the first press, a slot taken re-aims
    /// model, level and machine (across machines too), the in-use mark follows the aim, the chords
    /// and the ring take slots, the chooser it opens is the new-chat one, the popover stands on the
    /// display wherever the panel is, and Esc, focus and the one shared party all behave.
    /// `TAILSCODE_QUICKASK_OUT=<dir>` writes the closed, open and taken faces as PNGs. It runs after
    /// the chat child has reported, because that child writes the party into this same preferences
    /// domain while it runs.
    static func checkQuickAskParty() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
            checks += 1
        }
        await settleQuickAsk()
        let defaults = UserDefaults.standard
        let keptParty = defaults.string(forKey: partyKey)
        let keptRecents = defaults.stringArray(forKey: recentsKey)
        let hosted = ModelChooserDemo.sources()[0]
        let local = ModelChooserDemo.sources()[1]
        let arch = ConnectionProfile(
            id: "selftest-qa-arch", name: hosted.name, backend: .openCode,
            baseURL: URL(string: "http://127.0.0.1:9")!)
        let macbook = ConnectionProfile(
            id: "selftest-qa-macbook", name: local.name, backend: .openCode,
            baseURL: URL(string: "http://127.0.0.1:9")!)
        ModelCatalogStore.store(hosted.models, for: arch.id)
        ModelCatalogStore.store(local.models, for: macbook.id)
        defer {
            for profile in [arch, macbook] {
                QuickAskDefaults.clearOwnAim(forProfileID: profile.id)
                ModelCatalogStore.forget(profile.id)
            }
            if let keptParty { defaults.set(keptParty, forKey: partyKey) } else { defaults.removeObject(forKey: partyKey) }
            if let keptRecents { defaults.set(keptRecents, forKey: recentsKey) } else { defaults.removeObject(forKey: recentsKey) }
        }
        func preset(_ provider: String, _ model: String, _ effort: PresetEffort) -> ModelPreset {
            ModelPreset(selection: ModelSelection(providerID: provider, modelID: model), effort: effort)
        }
        let opus = preset("anthropic", "claude-opus-5", .level("high"))
        let sonnet = preset("anthropic", "claude-sonnet-5", .level("low"))
        let qwen = preset("ollama", "qwen3-coder:30b", .keep)
        func holdParty() {
            defaults.set("[null,null,null,null,null,null]", forKey: partyKey)
            for (slot, held) in [opus, sonnet, qwen].enumerated() {
                ModelParty.replace(slot: slot, with: held)
            }
            ModelParty.replace(slot: 3, with: preset("google", "gemini-3.5-pro-preview-0731", .server))
            ModelParty.replace(
                slot: 4, with: preset("anthropic", "claude-haiku-4-5", .keep), name: "Quick")
        }
        holdParty()
        await settleQuickAsk()
        holdParty()

        let panel = QuickAskPanel(
            servers: [arch, macbook], preferredServer: arch.id, recents: [],
            onAsk: { _, _, _, done in done(nil) }, onResume: { _ in })
        let screen = NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(
            NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 24))
        panel.hidesOnDeactivate = false
        panel.orderFrontRegardless()
        defer { panel.close() }
        try expect(panel.isVisible, "the panel is on screen")
        QuickAskDefaults.recordModel(opus.selection, forProfileID: arch.id)
        QuickAskDefaults.recordEffort("high", forProfileID: arch.id)
        panel.aim(at: arch.id)
        panel.refreshAim()
        try dumpQuickAsk(panel, "quickask-closed.png")

        try expect(panel.partyCards().count == 6, "the quick ask reads six cards")
        try expect(
            panel.partyCards().map(\.isInUse) == [true, false, false, false, false, false],
            "IN USE stands on the slot the aim already runs and on no other")
        try expect(
            panel.partyCards()[2].machine == ServerLabel.display(name: macbook.name, backend: macbook.backend) && panel.partyCards()[0].machine == nil,
            "a slot on the other machine wears it, this machine's wears none")

        panel.dialPill.onPress?()
        try expect(
            panel.partyPopover != nil && panel.dialPopover == nil,
            "the first press on the model control opens the party and not the dial")
        await settleQuickAsk()
        try dumpQuickAsk(panel, "quickask-party.png", popover: panel.partyPopover)
        try expect(
            panel.partyPopover?.panel.cardViews.map(\.card.isInUse)
                == [true, false, false, false, false, false],
            "the open party marks the same slot in use")
        if let popover = panel.partyPopover, popover.isShown, let frame = popover.windowFrame {
            try expect(
                visible.insetBy(dx: -1, dy: -1).contains(frame),
                "a panel at the bottom of the display opens the party inside it: \(frame) in \(visible)")
            let pill = panel.convertToScreen(panel.dialPill.convert(panel.dialPill.bounds, to: nil))
            try expect(
                !frame.intersects(pill.insetBy(dx: 0, dy: 4)),
                "the party stands clear of the model pill it opened from")
        }
        try expect(panel.partyPopover?.isShown == true, "the party is on screen")
        try await closeAndAwait(panel)
        try expect(panel.partyPopover == nil, "the party is gone once it has closed")
        try expect(panel.isVisible, "closing the party leaves the panel up")
        try expect(panel.editor.hasFocus, "the prompt has the keyboard back after the party closes")

        try placement(expect)

        panel.openModelParty()
        let cards = panel.partyCards()
        panel.takePartyCard(cards[1])
        await settleQuickAsk()
        try expect(
            QuickAskDefaults.model(forProfileID: arch.id) == sonnet.selection
                && QuickAskDefaults.effort(forProfileID: arch.id) == "low"
                && panel.targetServer.id == arch.id,
            "taking a slot on this machine aims the model and the level")
        try expect(
            panel.partyCards().map(\.isInUse) == [false, true, false, false, false, false],
            "IN USE follows the take")
        try expect(panel.partyPopover == nil && panel.isVisible, "a take closes the party and keeps the panel")
        try expect(panel.editor.hasFocus, "the prompt has the keyboard after a take")
        try expect(
            QuickAskDefaults.hasOwnAim(forProfileID: arch.id),
            "a take files the aim like a normal pick")

        panel.takePartyCard(panel.partyCards()[2])
        await settleQuickAsk()
        let carried = ModelEffort.adoption(
            "low", for: qwen.selection, models: local.models, agentOptions: []).level
        try expect(
            panel.targetServer.id == macbook.id
                && QuickAskDefaults.model(forProfileID: macbook.id) == qwen.selection
                && QuickAskDefaults.effort(forProfileID: macbook.id) == carried,
            "a slot on the other machine re-aims the machine, the model and the level")
        try expect(
            panel.partyCards().map(\.isInUse) == [false, false, true, false, false, false]
                && panel.partyCards()[2].machine == nil && panel.partyCards()[1].machine == ServerLabel.display(name: arch.name, backend: arch.backend),
            "after a cross-machine take the slot is in use and the machines swap places")
        try dumpQuickAsk(panel, "quickask-taken.png")
        try expect(
            QuickAskDefaults.model(forProfileID: arch.id) == sonnet.selection,
            "the machine left keeps its own aim")

        panel.takePartyCard(panel.partyCards()[0])
        try expect(
            panel.targetServer.id == arch.id
                && QuickAskDefaults.model(forProfileID: arch.id) == opus.selection
                && QuickAskDefaults.effort(forProfileID: arch.id) == "high",
            "a slot back on the first machine re-aims there with its own level")

        try expect(panel.handlePartyKey(chord("2", 19, window: panel)), "the registry's slot chord is taken")
        try expect(
            panel.partyCards().map(\.isInUse) == [false, true, false, false, false, false],
            "control-option-2 takes slot 2")
        try expect(panel.handlePartyKey(chord("\u{F703}", 124, window: panel)), "the ring's chord is taken")
        try expect(
            panel.targetServer.id == macbook.id
                && panel.partyCards().map(\.isInUse) == [false, false, true, false, false, false],
            "control-option-right walks the ring to the next slot, across machines")
        let before = QuickAskDefaults.model(forProfileID: macbook.id)
        try expect(panel.handlePartyKey(chord("6", 22, window: panel)), "a hollow slot's chord is taken")
        try expect(
            panel.status.stringValue == Localized.text("Slot %d is empty", 6)
                && QuickAskDefaults.model(forProfileID: macbook.id) == before,
            "a hollow slot says so and aims nothing")
        let plain = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "2",
            charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19)!
        try expect(!panel.handlePartyKey(plain), "a bare digit stays the field's")

        try await chooserContexts(panel, expect)

        ModelParty.rename(slot: 0, to: "Daily")
        try expect(
            panel.partyCards()[0].title == "Daily",
            "a rename made through the shared store reaches the quick ask")
        panel.openModelParty()
        panel.partyPopover?.panel.cardViews[1].onRename?(panel.partyPopover!.panel.cardViews[1], "Sprint")
        try expect(
            ModelParty.slot(1)?.name == "Sprint",
            "a rename made in the quick ask's party lands in the one store")
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(partyKey) }
        try expect(keys == [partyKey], "one party key, not a copy: \(keys)")

        try await escapeOrder(panel, expect)
        return checks
    }

    private static func chord(_ characters: String, _ keyCode: UInt16, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    private static func settleQuickAsk(until done: (@MainActor () -> Bool)? = nil) async {
        guard let done else {
            try? await Task.sleep(for: .milliseconds(400))
            return
        }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            if done() { return }
        }
    }

    private static func closeAndAwait(_ panel: QuickAskPanel) async throws {
        panel.partyPopover?.close()
        await settleQuickAsk { panel.partyPopover == nil }
    }

    private static func placement(_ expect: (Bool, String) throws -> Void) throws {
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let content = NSSize(width: 612, height: 361)
        let low = NSRect(x: 400, y: 60, width: 150, height: 26)
        let near = PartyPopoverPlacement.decide(
            anchor: low, content: content, visible: visible, prefers: .below)
        try expect(near.side == .above, "near the bottom edge the party flips above the pill")
        try expect(
            visible.contains(near.contentFrame(anchor: low, size: content, visible: visible)),
            "and stands inside the display")
        let high = NSRect(x: 400, y: 820, width: 150, height: 26)
        let top = PartyPopoverPlacement.decide(
            anchor: high, content: content, visible: visible, prefers: .below)
        try expect(top.side == .below, "near the menu bar it stays below the pill")
        try expect(
            visible.contains(top.contentFrame(anchor: high, size: content, visible: visible)),
            "and stands under the menu bar")
        let middle = NSRect(x: 1380, y: 400, width: 150, height: 26)
        let edge = top.contentFrame(anchor: middle, size: content, visible: visible)
        try expect(visible.contains(edge), "an anchor at the right edge slides the party back inside")
        let small = NSRect(x: 0, y: 0, width: 900, height: 260)
        let squeezed = PartyPopoverPlacement.decide(
            anchor: NSRect(x: 100, y: 120, width: 150, height: 26), content: content,
            visible: small, prefers: .below)
        try expect(
            squeezed.maxHeight < content.height
                && small.contains(
                    squeezed.contentFrame(
                        anchor: NSRect(x: 100, y: 120, width: 150, height: 26), size: content,
                        visible: small)),
            "on a display shorter than the party its height is held to the display")
    }

    private static func chooserContexts(
        _ panel: QuickAskPanel, _ expect: (Bool, String) throws -> Void
    ) async throws {
        panel.openModelDirectoryNow()
        try expect(
            panel.modelSheet?.openedFor == .composer,
            "All models from the party is the new-chat chooser, with no carry wording")
        panel.modelSheet?.dismiss()
        await settleQuickAsk { panel.modelSheet == nil }
        try expect(panel.isVisible && panel.modelSheet == nil, "closing the chooser leaves the panel up")
        try expect(panel.editor.hasFocus, "the prompt has the keyboard after the chooser closes")
        panel.openPartyChooser(slot: 5)
        try expect(panel.modelSheet?.openedFor == .party, "a hollow slot opens the chooser in fill mode")
        panel.modelSheet?.dismiss()
        await settleQuickAsk()
        try expect(panel.isVisible, "closing the fill chooser leaves the panel up")
    }

    private static func escapeOrder(
        _ panel: QuickAskPanel, _ expect: (Bool, String) throws -> Void
    ) async throws {
        guard let popover = panel.partyPopover, popover.isShown, let window = popover.panel.window
        else { return }
        let handled = window.firstResponder?.tryToPerform(
            #selector(NSResponder.cancelOperation(_:)), with: nil) ?? false
        await settleQuickAsk { panel.partyPopover == nil }
        try expect(panel.partyPopover == nil, "the first Esc closes the party (handled: \(handled))")
        try expect(panel.isVisible, "and leaves the panel up")
        panel.cancelOperation(nil)
        try expect(!panel.isVisible, "the next Esc closes the panel")
    }

    private static func dumpQuickAsk(
        _ panel: QuickAskPanel, _ name: String, popover: PartyPopover? = nil
    ) throws {
        guard let directory = ProcessInfo.processInfo.environment["TAILSCODE_QUICKASK_OUT"],
            let view = popover?.panel ?? panel.contentView
        else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
