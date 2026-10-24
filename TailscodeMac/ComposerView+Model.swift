import AppKit
import CodingAgentKit
import MidgarCore
import TailscodeCore

extension ComposerView {
    func refreshPills() {
        let folder = entry?.session.directory.map {
            URL(fileURLWithPath: $0, isDirectory: true).lastPathComponent
        }
        let variants = [
            [entry.map { ServerLabel.display(name: $0.profileName, backend: $0.backendType) }, folder],
            [entry?.profileName, folder],
            [entry?.profileName],
        ].map { $0.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
        pills.setDestination(variants)
        let face = ModelDial.face(
            modelWord: modelPillText(), effort: displayedEffort(), options: effortOptions())
        let activeModel = activeModelID
        pills.setFace(
            face,
            modelTint: activeModel.flatMap {
                ModelBadge.chip(model: $0, effort: nil, providerID: nil, catalog: models)
            }
                .map(MacTheme.Color.modelIdentity))
        if let dialPopover, dialPopover.isShown { dialPopover.update(state: dialState()) }
        if let partyPopover, partyPopover.isShown { partyPopover.panel.reload() }
        pills.setAttachShown(abilities.attachments)
        dropUnsendableAttachments()
        updateVimUI()
    }

    /// What the chat is actually being answered by, which is not always what the session record
    /// says: a `/model` typed into the CLI changes the model for every later turn without the
    /// server's stored session ever hearing about it. The transcript is the authority — the last
    /// assistant message names the model that wrote it — and the session record is the fallback
    /// for a chat that has no answer in it yet.
    var activeModelID: String? {
        chosenModel?.modelID ?? observedModelID() ?? entry?.session.model
    }

    private func modelPillText() -> String {
        if let chosenModel { return ModelBadge.word(for: chosenModel, in: models) }
        if let observed = observedModelID() {
            return ModelBadge.label(
                model: ModelSelection(providerID: "server", modelID: observed), effort: nil,
                catalog: models)
        }
        if let stored = entry?.session.model {
            return ModelBadge.label(
                model: ModelSelection(providerID: "server", modelID: stored), effort: nil,
                catalog: models)
        }
        return Localized.text("model")
    }

    private func observedModelID() -> String? {
        guard let messages = lastState?.messages else { return nil }
        for message in messages.reversed() where message.role == .assistant {
            if let id = message.modelID, !id.isEmpty { return id }
        }
        return nil
    }

    /// The level the dial shows and the wheel steps from: the pick, else the session's own
    /// record, else what the last answer ran at — each surviving what the model takes — or nil,
    /// which the dial draws as the server deciding.
    func displayedEffort() -> String? {
        let options = effortOptions()
        guard !options.isEmpty else { return nil }
        if let kept = ModelEffort.surviving(chosenEffort, options: options) { return kept }
        if let stored = ModelEffort.surviving(entry?.session.reasoningEffort, options: options) {
            return stored
        }
        return ModelEffort.surviving(observedEffort(), options: options)
    }

    private func observedEffort() -> String? {
        guard let messages = lastState?.messages else { return nil }
        for message in messages.reversed() where message.role == .assistant {
            if let effort = message.reasoningEffort, !effort.isEmpty { return effort }
        }
        return nil
    }

    /// Effort is a property of the model on servers whose catalog says so (opencode's variants
    /// differ per model); the backend-wide list is the fallback for agents like Claude Code
    /// where every model takes the same levels. The rule is Core's, so what this offers and what
    /// the phone offers for the same model can never differ.
    func effortOptions() -> [String] {
        ModelEffort.options(
            models: models,
            selection: chosenModel
                ?? activeModelID.map { ModelSelection(providerID: "server", modelID: $0) },
            agentOptions: backend?.reasoningEffortOptions ?? [])
    }

    /// What the picked model can be handed. A capability is the model's far more often than the
    /// server's — one opencode machine fronts a hundred, and half of them cannot see a picture.
    var abilities: ModelAbilities {
        ModelAbilities.resolve(
            supportsAttachments: attachmentsSupported, models: models,
            selection: chosenModel
                ?? activeModelID.map { ModelSelection(providerID: "server", modelID: $0) })
    }

    /// A model switch is the one way something already picked becomes unsendable. It is dropped
    /// out loud rather than left to fail on the other machine.
    private func dropUnsendableAttachments() {
        let able = abilities
        let kept = attachments.filter { able.accepts(mime: $0.mime) }
        guard kept.count != attachments.count else { return }
        let dropped = attachments.count - kept.count
        attachments = kept
        syncChips()
        onToast?(ModelAbilities.dropped(dropped))
    }

    /// Every server the app knows, with this conversation's own first — the list both the pill's
    /// menu and the full chooser answer from, so the two are one catalog at two lengths and stars
    /// read the same in each.
    func modelSources() -> [ModelSource] {
        ModelChooserSheet.fleetSources(
            profiles: ServerDirectory.shared.profiles, current: entry?.profileID,
            currentModels: models, backend: backend?.agentType, allowsServerDefault: true,
            reachable: entry.flatMap { reachableByProfile[$0.profileID] })
    }

    func openModelChooser() {
        presentModelChooser(sources: modelSources(), selected: chosenModel)
    }

    /// The chooser over a fleet that exists only as a fixture, so the surface can be looked at and
    /// measured on a desk with no servers on it — `--open models` from the command line.
    /// `script` is the sheet's own `demonstrate` steps, plus `unreachable`, which takes the last
    /// machine off the tailnet before the sheet is drawn. The fixture's wall always stands, so the
    /// spent register is on screen beside the rest.
    func openDemoModelChooser(script: String = "") {
        var sources = ModelChooserDemo.sources()
        if script.split(separator: ",").contains("unreachable"), let last = sources.popLast() {
            sources.append(
                ModelSource(
                    profileID: last.profileID, name: last.name, backend: last.backend,
                    models: last.models, isCurrent: last.isCurrent,
                    allowsServerDefault: last.allowsServerDefault,
                    acceptsAnyModelID: last.acceptsAnyModelID, isReachable: false))
        }
        presentModelChooser(
            sources: sources, selected: ModelChooserDemo.selected,
            quotas: ModelChooserDemo.quotas())
        modelSheet?.demonstrate(script)
    }

    private func presentModelChooser(
        sources: [ModelSource], selected: ModelSelection?, quotas: [UsageQuota]? = nil
    ) {
        guard let host = window else { return }
        modelSheet = ModelChooserSheet.present(
            on: host, sources: sources, selected: selected,
            quotas: quotas ?? quotasForModels?() ?? [],
            onAddToParty: { [weak self] pick in self?.addToParty(pick) }
        ) { [weak self] pick in
            self?.modelSheet = nil
            self?.handleModelPick(pick)
        }
    }

    /// Whether an answer can be asked again of another model: it has a question of the person's
    /// own before it, which is the thing a branch puts back in the box.
    func offersBranch(from answerID: String) -> Bool {
        guard let messages = lastState?.messages, entry != nil, window != nil else { return false }
        return ConversationBrief.question(before: answerID, in: messages) != nil
    }

    /// "Try with another model…": the chooser over the whole fleet, every machine saying that a
    /// pick branches this chat from that question. Any pick, here or on another machine, opens a
    /// new chat there that carries what came before the question and holds the question, unsent.
    func openBranchChooser(from answerID: String) {
        guard let host = window, offersBranch(from: answerID) else { return }
        modelSheet = ModelChooserSheet.present(
            on: host, sources: modelSources(), selected: chosenModel,
            quotas: quotasForModels?() ?? [], context: .branch
        ) { [weak self] pick in
            self?.modelSheet = nil
            self?.branch(from: answerID, pick: pick)
        }
    }

    private func branch(from answerID: String, pick: ModelPick) {
        guard let entry, let messages = lastState?.messages else { return }
        let plan = CarryPlan.branching(
            pick: pick, title: entry.session.title, messages: messages, answerID: answerID)
        MidgarLog.info(
            "branch from \(answerID) to \(pick.profileID), carrying \(plan.brief != nil)",
            category: .chat)
        ModelFleet.adopt(pick)
        onMoveToServer?(pick.profileID, plan)
    }

    /// A pick's whole answer: this chat changes model, or the work moves to the machine that runs
    /// it — remembered there first (`adopt`, with the level the dial showed for it), then opened
    /// as a new chat that arrives already on it. `notice` is the dial's own sentence for a level
    /// the pick moved, said once the pick has landed.
    func handleModelPick(
        _ pick: ModelPick, effort: EffortAsk = .unchanged, notice: String? = nil
    ) {
        guard pick.isElsewhere else {
            setModel(
                pick.selection, effort: effort, notice: notice,
                modelName: pick.modelName.isEmpty ? nil : pick.modelName)
            return
        }
        let plan = CarryPlan.continuing(
            pick: pick, title: entry?.session.title ?? "", messages: lastState?.messages ?? [])
        let words = plan.moveWords(for: pick)
        MacDialogs.confirm(
            on: window, title: words.title, body: words.body, confirmLabel: words.action,
            destructive: false
        ) { [weak self] in
            ModelFleet.adopt(pick)
            if case .set(let level) = effort {
                EffortPreferenceStore.recordPick(level, sessionKey: nil, contextID: pick.profileID)
            }
            self?.onMoveToServer?(pick.profileID, plan.brief == nil ? nil : plan)
        }
    }

    /// Effort is the model's on servers whose catalog says so, so a pick can strand a level the
    /// new model does not offer. A pair names its level (`.set`), which is carried onto the model's
    /// own levels; a model alone keeps the level where it is, and a level the model lacks moves to
    /// the nearest cooler one it takes and says so — never hotter, and never silently.
    private func setModel(
        _ selection: ModelSelection?, effort: EffortAsk = .unchanged, notice: String? = nil,
        modelName: String? = nil
    ) {
        chosenModel = selection
        if let entry {
            ModelPreferenceStore.recordPick(
                selection, sessionKey: Self.preferenceKey(entry), contextID: entry.profileID)
        }
        let asked: String?
        switch effort {
        case .unchanged: asked = chosenEffort
        case .set(let level): asked = level
        }
        let carry = ModelEffort.adoption(
            asked, for: selection, models: models,
            agentOptions: backend?.reasoningEffortOptions ?? [])
        let name = modelName ?? ModelBadge.label(model: selection, effort: nil, catalog: models)
        if let said = notice ?? carry.notice(modelName: name) { onToast?(said) }
        if effort != .unchanged || carry.level != chosenEffort {
            setEffort(carry.level)
            return
        }
        refreshPills()
        onModelChanged?()
    }

    /// One notch of the wheel or one ⌃⌥ arrow: the next stop cold-to-hot from the level the dial
    /// shows, pinned at both ends. Nothing opens and nothing is written — the pill's word and bars
    /// move under the pointer, which is the whole answer to anyone who can see them, and a screen
    /// reader is told where the level landed — except for a model that takes no level, which says
    /// so rather than letting the wheel turn in silence.
    func stepEffort(by delta: Int) {
        let options = effortOptions()
        guard ModelEffort.isOffered(options: options) else {
            onDialToast?(ModelDial.headline(modelName: modelPillText(), options: []))
            return
        }
        let notch = ModelDial.notch(from: displayedEffort(), by: delta, options: options)
        if notch.level != displayedEffort() { setEffort(notch.level) }
        EffortSpeech.note(notch)
    }

    /// The level handed back to the machine, from the Model menu: the server's own stop on the
    /// ladder, reached without opening anything. The pill goes hollow, which is the answer.
    func setServerDecidesEffort() {
        let options = effortOptions()
        guard ModelEffort.isOffered(options: options) else {
            onDialToast?(ModelDial.headline(modelName: modelPillText(), options: []))
            return
        }
        if displayedEffort() != nil { setEffort(nil) }
    }

    /// The pinned pairs this chat's machine can run, in the order they were pinned, each with the
    /// word it is said by and whether it is what the chat runs now — what the Model menu lists and
    /// the ⌃⌥ digits count.
    func reachablePresets() -> [(preset: ModelPreset, title: String, isCurrent: Bool)] {
        let model = activeSelection
        let effort = displayedEffort()
        return ModelPresetCycle.reachable(
            ModelParty.ring(), models: models,
            acceptsAnyModelID: backend.map { ModelFleet.acceptsAnyModelID($0.agentType) } ?? false
        ).map { preset in
            (
                preset,
                ModelPresetCycle.said(
                    preset,
                    modelName: ModelBadge.label(
                        model: preset.selection, effort: nil, catalog: models)),
                preset.matches(model: model, effort: effort)
            )
        }
    }

    /// ⌃⌥→ and ⌃⌥←: the next pinned pair round the ring from the one the chat runs.
    func stepPreset(by delta: Int) {
        let reachable = reachablePresets().map(\.preset)
        guard
            let preset = ModelPresetCycle.step(
                reachable, model: activeSelection, effort: displayedEffort(), by: delta)
        else {
            onDialToast?(Self.noPresetsHint)
            return
        }
        applyPreset(preset)
    }

    /// ⌃⌥1 to ⌃⌥9. With a party, a chord names a slot and never the nth filled one, so a slot left
    /// hollow or living on another machine says so; with none, it is the nth pinned pair this
    /// machine can run, exactly as before the party.
    func applyPreset(number: Int) {
        guard !ModelParty.presets().isEmpty else {
            applyPinnedPreset(number: number)
            return
        }
        takePartySlot(number - 1)
    }

    private func applyPinnedPreset(number: Int) {
        let reachable = reachablePresets()
        guard !reachable.isEmpty else {
            onDialToast?(Self.noPresetsHint)
            return
        }
        guard reachable.indices.contains(number - 1) else {
            onDialToast?(
                Localized.text("Only %d pinned pairs run on this machine", reachable.count))
            return
        }
        applyPreset(reachable[number - 1].preset)
    }

    /// A pair taken without opening the dial is the same pick the dial makes: the model first, then
    /// the level the pair asks for, carried onto the model's own levels — and one toast saying
    /// which pair it was and, when the level had to move, where it went.
    func applyPreset(_ preset: ModelPreset) {
        let name = ModelBadge.label(model: preset.selection, effort: nil, catalog: models)
        let carry = preset.applied(
            currentEffort: displayedEffort(), models: models,
            agentOptions: backend?.reasoningEffortOptions ?? [])
        setModel(preset.selection, effort: .set(carry.level), notice: nil, modelName: name)
        let said = ModelPresetCycle.said(preset, modelName: name)
        onDialToast?(carry.notice(modelName: name).map { said + "\n" + $0 } ?? said)
    }

    static var noPresetsHint: String {
        Localized.text("Pin a model and level with ⌃S in the model dial")
    }

    /// The dial opened on its own pill. Pressing it while open closes it, the way a menu does.
    func openModelDial() {
        if let dialPopover, dialPopover.isShown {
            dialPopover.close()
            return
        }
        if let dialClosedAt, Date().timeIntervalSince(dialClosedAt) < 0.3 { return }
        dialPopover = ModelDialPopover.present(
            from: pills.dialAnchor, state: dialState(),
            onEffort: { [weak self] level in self?.setEffort(level) },
            onPick: { [weak self] pick, effort, notice in
                self?.handleModelPick(pick, effort: effort, notice: notice)
            },
            onOpenCatalog: { [weak self] in self?.openModelChooser() },
            onPinned: { preset in ModelPresetStore.pin(preset) },
            onClosed: { [weak self] in
                self?.dialPopover = nil
                self?.dialClosedAt = Date()
            })
    }

    /// The dial over the fixture fleet the chooser demo uses, so the popover can be drawn and
    /// measured on a desk with no servers on it — `--open dial` from the command line, or
    /// `--open dial:pill` for the closed pill alone.
    /// `face` draws the closed pill in one of the shapes it has to survive: `long` (a local
    /// build's whole name), `nolevels`, `think` (a model whose only levels are think and nothink)
    /// and `server` (the level left to the machine).
    func openDemoModelDial(
        popover: Bool, query: String? = nil, cursor: Int? = nil, face: String? = nil
    ) {
        var options = ["low", "medium", "high", "xhigh", "max", Ultracode.effortLevel]
        var word = "Opus"
        var effort: String? = "high"
        var tinted = ModelChooserDemo.selected.modelID
        switch face {
        case "long":
            let local = ModelChooserDemo.sources().flatMap(\.models)
            let pick = ModelSelection(providerID: "ollama", modelID: "nemotron-3.5-lightning:30b-mlx")
            word = ModelBadge.word(for: pick, in: local)
            tinted = pick.modelID
        case "nolevels":
            options = []
            effort = nil
        case "think":
            options = ["nothink", "think"]
            effort = "think"
        case "server":
            effort = nil
        default:
            break
        }
        pills.setFace(
            ModelDial.face(modelWord: word, effort: effort, options: options),
            modelTint: ModelBadge.chip(
                model: tinted, effort: nil, providerID: nil,
                catalog: ModelChooserDemo.sources().flatMap(\.models)
            ).map(MacTheme.Color.modelIdentity))
        guard popover else { return }
        var state = ModelDialState(
            sources: ModelChooserDemo.sources(), selected: ModelChooserDemo.selected,
            effort: effort, options: options, modelWord: word, quotas: ModelChooserDemo.quotas(),
            recents: ModelChooserDemo.recents, presets: ModelDialDemo.presets,
            agentOptions: [])
        if let query { state.search(query) }
        if let cursor { state.move(to: cursor) }
        dialPopover = ModelDialPopover.present(
            from: pills.dialAnchor, state: state,
            onEffort: { _ in }, onPick: { _, _, _ in }, onOpenCatalog: {}, onPinned: { _ in },
            onClosed: { [weak self] in self?.dialPopover = nil })
    }

    private func dialState() -> ModelDialState {
        ModelDialState(
            sources: modelSources(), selected: chosenModel, effort: displayedEffort(),
            options: effortOptions(), modelWord: modelPillText(),
            quotas: quotasForModels?() ?? [],
            agentOptions: backend?.reasoningEffortOptions ?? [])
    }

    private func setEffort(_ level: String?) {
        chosenEffort = level
        if let entry {
            EffortPreferenceStore.recordPick(
                level, sessionKey: Self.preferenceKey(entry), contextID: entry.profileID)
        }
        refreshPills()
        refreshAura()
        onModelChanged?()
    }
}
