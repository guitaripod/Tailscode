import TailscodeCore
import CodingAgentKit
import Foundation

extension ChatViewModel {
    func availableModels() async -> [ModelInfo] {
        let models = await ModelCatalog.models(for: contextID, backend: backend)
        if !models.isEmpty { knownModels = models }
        return models
    }

    /// A refresh that landed behind the cached catalog this chat opened on. What the model can be
    /// handed is read from `knownModels`, so without taking the landing the composer keeps
    /// answering from the catalog it started with.
    func adoptCatalog(_ models: [ModelInfo]) {
        if !models.isEmpty { knownModels = models }
    }

    func usage() async -> AgentUsage? {
        if let cached = cachedUsage, Date().timeIntervalSince(cached.at) < 30 {
            return cached.value
        }
        let value = try? await backend.sessionUsage(session.id)
        cachedUsage = (value, Date())
        return value
    }

    func acknowledgeFailure() {
        dismissedFailure = state.lastFailure
    }

    /// Picks the model for the next turns. The level the chip is showing rides along by Core's
    /// carry — to the nearest cooler level the new model takes, never hotter — and what became of
    /// it is handed back so the screen can say so instead of changing a word on its own.
    @discardableResult
    func selectModel(_ model: ModelSelection?) -> EffortCarry {
        let asked = displayedEffort ?? currentEffort
        selectedModel = model
        ModelPreferenceStore.recordPick(model, sessionKey: persistKey, contextID: contextID)
        let carry = ModelEffort.adoption(
            asked, for: model, models: knownModels, agentOptions: backend.reasoningEffortOptions)
        if carry.moved || (currentEffort != nil && carry.level != currentEffort) {
            currentEffort = carry.level
            EffortPreferenceStore.recordPick(carry.level, sessionKey: persistKey, contextID: contextID)
        }
        onModelChange?()
        return carry
    }

    /// The pinned pairs this server can run, in the order they were pinned.
    var reachablePresets: [ModelPreset] {
        presetPlacement(elsewhere: []).reachable
    }

    /// Where every pin stands from this chat's server: the same predicate the model menu and Home
    /// use, so a pin the menu offers is one the swipe reaches and the other way round.
    func presetPlacement(elsewhere: [ModelSource]) -> PinPlacement {
        ModelPresetCycle.placement(
            ModelPresetStore.all(),
            models: knownModels.isEmpty ? ModelCatalog.cached(for: contextID) : knownModels,
            acceptsAnyModelID: ModelFleet.acceptsAnyModelID(backend.agentType),
            elsewhere: elsewhere)
    }

    /// A pinned pair: the model, then the level it asks for through the same carry as any pick.
    @discardableResult
    func apply(_ preset: ModelPreset) -> EffortCarry {
        let asked = preset.asks(current: displayedEffort ?? currentEffort)
        selectedModel = preset.selection
        ModelPreferenceStore.recordPick(preset.selection, sessionKey: persistKey, contextID: contextID)
        let carry = ModelEffort.adoption(
            asked, for: preset.selection, models: knownModels,
            agentOptions: backend.reasoningEffortOptions)
        currentEffort = carry.level
        EffortPreferenceStore.recordPick(carry.level, sessionKey: persistKey, contextID: contextID)
        onModelChange?()
        return carry
    }

    /// The pair a step along the pinned list lands on, or nil with nothing pinned that this server
    /// can run.
    func presetStep(by delta: Int) -> ModelPreset? {
        ModelPresetCycle.step(
            reachablePresets, model: displayedModel, effort: displayedEffort, by: delta)
    }

    /// The nth pinned pair, 1-based, as a hardware key names it.
    func preset(number: Int) -> ModelPreset? {
        let presets = reachablePresets
        return presets.indices.contains(number - 1) ? presets[number - 1] : nil
    }

    func setEffort(_ level: String?) {
        currentEffort = level
        EffortPreferenceStore.recordPick(level, sessionKey: persistKey, contextID: contextID)
        onModelChange?()
    }

    /// Applies the model and effort chosen before this session existed — Home's
    /// composer picks them, then creates the session on send — so the first turn
    /// runs on the intended model instead of racing the async default lookup.
    func seed(_ choice: ModelChoice) {
        if let model = choice.model {
            selectedModel = model
            ModelPreferenceStore.setModel(model, forKey: persistKey)
        }
        if let effort = choice.effort {
            currentEffort = effort
            EffortPreferenceStore.setEffort(effort, forKey: persistKey)
        }
    }

    func clearConversation() {
        Task {
            try? await backend.clearConversation(session.id)
            try? await conversation.refresh()
        }
    }

    func loadDefaultModelIfNeeded() async {
        if supportsReasoningEffort, currentEffort == nil {
            currentEffort = ChatModelResolver.effort(
                profileID: contextID, backend: backend, sessionKey: persistKey,
                sessionEffort: session.reasoningEffort)
        }
        guard supportsModelSelection, selectedModel == nil else {
            onModelChange?()
            return
        }
        selectedModel = await ChatModelResolver.model(
            profileID: contextID, backend: backend, sessionKey: persistKey,
            sessionModel: session.model, sessionModelProviderID: session.modelProviderID)
        onModelChange?()
    }

    /// What the turn is doing, in the words the Live Activity uses. What it *is* is decided once
    /// in `ActivityKind.inFlight`, so the badge in the navigation bar, the row in the list and the
    /// card on the lock screen can never disagree about the same second; the sentence is Core's,
    /// because a lock screen has room for a sentence where a band has room for a word.
    static func liveLine(for state: ConversationState) -> String {
        LiveActivityReading.live(in: state).line
    }

    static func readable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
