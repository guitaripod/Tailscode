#if DEBUG
    import CodingAgentKit
    import TailscodeCore

    /// The state a scripted walk through the model dial leans on, shared by the chat and Home.
    @MainActor
    enum DialTour {
        static func pinPairs() {
            for preset in [
                ModelPreset(
                    selection: ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5"),
                    effort: .level("medium")),
                ModelPreset(
                    selection: ModelSelection(providerID: "anthropic", modelID: "claude-opus-4-8"),
                    effort: .level("xhigh")),
            ] where !ModelPresetStore.all().contains(preset) {
                ModelPresetStore.pin(preset)
            }
        }

        static func pinFixturePairs() {
            for preset in [
                ModelPreset(
                    selection: ModelSelection(providerID: "anthropic", modelID: "claude-opus-5"),
                    effort: .level("high")),
                ModelPreset(
                    selection: ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5"),
                    effort: .level("low")),
            ] where !ModelPresetStore.all().contains(preset) {
                ModelPresetStore.pin(preset)
            }
        }

        /// Fills an empty party with the models the demo catalog names, so a screenshot of the
        /// sheet shows named balls at different levels, one hollow slot and a lone slot in use.
        static func fillParty() {
            guard ModelParty.presets().isEmpty else { return }
            let fixtures: [(String, PresetEffort, String?)] = [
                ("claude-opus-4-8", .level("high"), "Daily"),
                ("claude-sonnet-5", .level("low"), "Sprint"),
                ("claude-fable-5", .level("xhigh"), nil),
                ("claude-haiku-4-5", .server, "Quick"),
            ]
            for (slot, fixture) in fixtures.enumerated() {
                ModelParty.replace(
                    slot: slot,
                    with: ModelPreset(selection: selection(fixture.0), effort: fixture.1),
                    name: fixture.2)
            }
        }

        /// Replaces the party with six models from both machines, cloud and local, so a screenshot
        /// of the sheet shows a full room whichever machine the chat it opens from lives on.
        /// `localLevel` is what the local Bolt slot asks of the level: `.keep` makes taking it say
        /// what happened to the level the chat was on, which is the toast a take is filmed for.
        static func fillFleetParty(localLevel: PresetEffort = .server) {
            let fixtures: [(String, PresetEffort, String?)] = [
                ("claude-fable-5", .level("max"), "Deep dive"),
                ("claude-opus-4-8", .level("xhigh"), nil),
                ("claude-sonnet-5", .level("high"), "Daily"),
                ("llama-server^qwen3-coder-30b-a3b", localLevel, nil),
                ("llama-server^qwen3.6-27b", .server, nil),
                ("openai^gpt-5.1-codex", .level("high"), nil),
            ]
            for (slot, fixture) in fixtures.enumerated() {
                ModelParty.replace(
                    slot: slot,
                    with: ModelPreset(selection: selection(fixture.0), effort: fixture.1),
                    name: fixture.2)
            }
        }

        static func star(_ modelID: String) {
            let starred = ModelPreset(selection: selection(modelID), effort: .keep)
            if !ModelPresetStore.all().contains(starred) { ModelPresetStore.pin(starred) }
        }

        /// A model named the way a script writes it: `claude-opus-4-8` is Anthropic's, and
        /// `ollama^qwen3:14b` names the door before the id.
        static func selection(_ named: String) -> ModelSelection {
            let parts = named.split(separator: "^", maxSplits: 1).map(String.init)
            return parts.count == 2
                ? ModelSelection(providerID: parts[0], modelID: parts[1])
                : ModelSelection(providerID: "anthropic", modelID: named)
        }
    }
#endif
