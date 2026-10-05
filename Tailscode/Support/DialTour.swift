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
