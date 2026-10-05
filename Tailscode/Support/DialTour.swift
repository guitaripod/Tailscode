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

        static func star(_ modelID: String) {
            let starred = ModelPreset(
                selection: ModelSelection(providerID: "anthropic", modelID: modelID), effort: .keep)
            if !ModelPresetStore.all().contains(starred) { ModelPresetStore.pin(starred) }
        }
    }
#endif
