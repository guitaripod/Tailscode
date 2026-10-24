import AppKit
import CodingAgentKit
import TailscodeCore

extension ChatChecks {
    private static let partyKey = "tailscode.modelParty"

    private static func partyPreset(_ provider: String, _ model: String, _ effort: PresetEffort)
        -> ModelPreset
    {
        ModelPreset(
            selection: ModelSelection(providerID: provider, modelID: model), effort: effort)
    }

    private static func settled(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    /// What the party's popover draws, from six held slots over the fixture fleet: six cards, the
    /// in-use mark on the one the chat runs and on no other, a rename through the party's own
    /// store, a swap, a step of the level, a release, and the frames of the six staying apart at
    /// the popover's width in both modes. The party is this device's, so the store is put back as
    /// it was found.
    static func party(_ expect: (Bool, String) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let kept = defaults.string(forKey: partyKey)
        defer {
            if let kept {
                defaults.set(kept, forKey: partyKey)
            } else {
                defaults.removeObject(forKey: partyKey)
            }
        }
        defaults.set("[null,null,null,null,null,null]", forKey: partyKey)
        let opus = partyPreset("anthropic", "claude-opus-5", .level("high"))
        let sonnet = partyPreset("anthropic", "claude-sonnet-5", .level("low"))
        let qwen = partyPreset("ollama", "qwen3-coder:30b", .keep)
        let gemini = partyPreset("google", "gemini-3.5-pro-preview-0731", .server)
        let deepseek = partyPreset("deepseek", "deepseek-v4-pro", .level("medium"))
        let haiku = partyPreset("anthropic", "claude-haiku-4-5", .keep)
        ModelParty.replace(slot: 0, with: opus)
        ModelParty.replace(slot: 1, with: sonnet)
        ModelParty.replace(slot: 2, with: qwen)
        ModelParty.replace(slot: 3, with: gemini)
        ModelParty.replace(slot: 4, with: deepseek)
        ModelParty.replace(slot: 5, with: haiku, name: "The reviewer who reads everything twice")
        try expect(
            ModelParty.slot(5)?.name?.count == ModelParty.nameLimit,
            "a name is kept at most \(ModelParty.nameLimit) characters")

        let sources = ModelChooserDemo.sources()
        let running = opus.selection
        let model = PartyPanelModel(
            cards: {
                PartyReading.cards(
                    slots: ModelParty.slots(), sources: sources, model: running, effort: "high",
                    agentOptions: [])
            },
            recents: {
                PartyReading.recents(
                    slots: ModelParty.slots(), sources: sources, recent: ModelChooserDemo.recents)
            },
            levels: { card in
                guard let preset = card.resolved ?? card.preset else { return [] }
                let models = sources.first { $0.profileID == card.profileID }?.models ?? []
                return ModelEffort.options(
                    models: models, selection: preset.selection, agentOptions: [])
            },
            isRunning: { false })
        let actions = PartyPanelActions(
            take: { _ in }, fill: { _ in }, replace: { _ in }, recent: { _ in },
            addRecent: { _ in }, browse: {})
        let panel = PartyPanelView(mode: .party, model: model, actions: actions)
        panel.frame = NSRect(origin: .zero, size: panel.preferredSize)
        stage(panel)
        settled(panel)

        try expect(panel.cardViews.count == 6, "the party draws six cards")
        try expect(
            abs(panel.frame.width - PartyMetrics.width) < 1
                && abs(PartyMetrics.width - 612 * PartyMetrics.scale) < 3,
            "the popover is about 612 points wide at the type size in force, not \(panel.frame.width)")
        try expect(
            panel.cardViews.map(\.card.isInUse) == [true, false, false, false, false, false],
            "the in-use mark stands on the slot the chat runs and on no other")
        try expect(
            panel.cardViews[2].card.machine == sources[1].title
                && panel.cardViews[2].card.machine != nil
                && panel.cardViews[0].card.machine == nil,
            "a slot on another machine wears that machine and this machine's slot wears none")
        try separate(panel, expect, "a held party")
        try dumpParty(panel)

        let sprint = panel.cardViews[1]
        panel.setEditing(true)
        settled(panel)
        try expect(panel.isEditing, "edit mode is on")
        try expect(
            panel.cardViews.allSatisfy { $0.isEditing }, "every card is editable in edit mode")
        sprint.onRename?(sprint, "  Sprint   fast  ")
        try expect(
            ModelParty.slot(1)?.name == "Sprint fast"
                && panel.cardViews[1].card.title == "Sprint fast",
            "a rename is committed through the party, trimmed, and the card says it")
        sprint.onRename?(sprint, "   ")
        try expect(
            ModelParty.slot(1)?.name == nil
                && panel.cardViews[1].card.title == panel.cardViews[1].card.modelWord,
            "an emptied name gives the model's own word back")
        try separate(panel, expect, "a party in edit mode")

        let before0 = ModelParty.slot(0)
        let before2 = ModelParty.slot(2)
        ModelParty.swap(0, 2)
        panel.reload()
        settled(panel)
        try expect(
            ModelParty.slot(0) == before2 && ModelParty.slot(2) == before0
                && panel.cardViews[0].card.preset == before2?.preset
                && panel.cardViews[2].card.preset == before0?.preset,
            "a swap changes two slots' places and the cards follow")
        try expect(
            panel.cardViews.map(\.card.isInUse) == [false, false, true, false, false, false],
            "the in-use mark goes with the model it marks")

        ModelParty.swap(0, 2)
        panel.reload()
        panel.stepLevel(panel.cardViews[0])
        try expect(
            ModelParty.slot(0)?.preset.effort == .server,
            "the level steps from the model's last level to the server's own choice")
        panel.stepLevel(panel.cardViews[0])
        try expect(
            ModelParty.slot(0)?.preset.effort == .level("low"),
            "and from the server's choice round to the coldest level")

        ModelParty.release(slot: 5)
        panel.reload()
        settled(panel)
        try expect(panel.cardViews[5].card.isHollow, "a released slot is hollow again")
        try separate(panel, expect, "a party with a hollow slot")
        panel.setEditing(false)
        try expect(!panel.isEditing, "Done leaves edit mode")
    }

    private static func separate(
        _ panel: PartyPanelView, _ expect: (Bool, String) throws -> Void, _ what: String
    ) throws {
        settled(panel)
        let frames = panel.cardFrames()
        var apart = true
        for first in frames.indices {
            for second in frames.indices where second > first {
                if frames[first].intersects(frames[second]) { apart = false }
            }
        }
        try expect(apart, "\(what): no two cards overlap at \(Int(PartyMetrics.width)) points")
        try expect(
            panel.editFrame.width > 0 && panel.bounds.contains(panel.editFrame)
                && !panel.editFrame.intersects(panel.titleFrame),
            "\(what): the Edit button stands inside the header, clear of the title")
        try expect(
            panel.recentFrames.allSatisfy { panel.bounds.contains($0) },
            "\(what): every recent chip stands inside the popover")
        try expect(
            frames.allSatisfy { panel.bounds.contains($0) },
            "\(what): every card stands inside the popover")
        try expect(
            panel.preferredSize.height >= (frames.map(\.maxY).max() ?? 0),
            "\(what): the popover is as tall as its cards")
    }

    /// With `TAILSCODE_PARTY_OUT` set, the party drawn to a picture, so the look can be read
    /// without a screen.
    private static func dumpParty(_ panel: PartyPanelView) throws {
        guard let directory = ProcessInfo.processInfo.environment["TAILSCODE_PARTY_OUT"] else {
            return
        }
        for editing in [false, true] {
            panel.setEditing(editing)
            settled(panel)
            panel.window?.displayIfNeeded()
            defer { panel.setEditing(false) }
            guard let rep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else {
                continue
            }
            panel.cacheDisplay(in: panel.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent(
                    editing ? "party-edit.png" : "party.png"))
        }
    }
}
