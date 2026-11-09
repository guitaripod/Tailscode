import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension NewChatSheet {
    /// `m`, ⌃m while typing, or a press on the pill: the composer's dial over the pill. A press
    /// while it is open closes it, the way a menu does — and a transient popover has already
    /// closed itself on the press that reaches the pill, so a press inside a breath of that close
    /// is the same press.
    func openModelDial() {
        guard chooser.server != nil else { return }
        if let dialPopover, dialPopover.isShown {
            dialPopover.close()
            return
        }
        if let dialClosedAt, Date().timeIntervalSince(dialClosedAt) < 0.3 { return }
        dialPopover = ModelDialPopover.present(
            from: dialPill, state: dialState(),
            onEffort: { [weak self] level in self?.setStartingEffort(level) },
            onPick: { [weak self] pick, effort, notice in
                self?.take(pick, effort: effort, notice: notice)
            },
            onOpenCatalog: { [weak self] in self?.chooseModelFromCatalog() },
            onPinned: { [weak self] preset in
                ModelPresetStore.pin(preset)
                self?.refreshDial()
            },
            onClosed: { [weak self] in
                self?.dialPopover = nil
                self?.dialClosedAt = Date()
                self?.syncMode()
            })
    }

    /// The dial as it would open now: the fleet with the chosen server first, the model and level
    /// the chat would start with there, and the levels that model takes.
    func dialState() -> ModelDialState {
        let server = chooser.server
        let defaults = chooser.defaults
        return ModelDialState(
            sources: ModelFleet.sources(profiles: profiles, current: server?.profileID),
            selected: defaults?.model, effort: defaults?.effort, options: effortOptions(),
            modelWord: modelWord(), agentOptions: server?.agentEfforts ?? [])
    }

    /// The pill's face from the same defaults the sentence and the stamp read.
    func renderDial(_ defaults: NewChatDefaults) {
        dialPill.setFace(
            ModelDial.face(modelWord: modelWord(), effort: defaults.effort, options: effortOptions()),
            modelTint: defaults.chip.map(MacTheme.Color.modelIdentity))
        if let dialPopover, dialPopover.isShown { dialPopover.update(state: dialState()) }
    }

    /// The levels the starting model takes: its own where the catalog names them, the agent's
    /// otherwise.
    func effortOptions() -> [String] {
        chooser.defaults?.levels ?? []
    }

    func modelWord() -> String {
        guard let server = chooser.server else { return "" }
        guard let model = chooser.defaults?.model else { return Localized.text("Auto") }
        return ModelBadge.word(for: model, in: ModelCatalogStore.cached(server.profileID))
    }

    /// A row taken in the dial: a model on the chosen machine becomes its last-used default, the
    /// way a composer pick does; a model on another machine moves the sheet there, because the
    /// chat is made where its model runs. The level the dial showed for the row goes with it.
    func take(_ pick: ModelPick, effort: EffortAsk, notice: String?) {
        guard let current = chooser.server?.profileID else { return }
        let profileID = pick.profileID.isEmpty ? current : pick.profileID
        let moves = pick.isElsewhere || profileID != current
        if moves, chooser.servers.contains(where: { $0.profileID == profileID }) {
            chooser.chooseServer(profileID)
        }
        NewChatDefaults.record(model: pick.selection, profileID: profileID)
        if case .set(let level) = effort {
            NewChatDefaults.record(effort: level, profileID: profileID)
        } else if let preset = pick.preset {
            let agent = chooser.servers.first { $0.profileID == profileID }?.agentEfforts ?? []
            let carry = preset.applied(
                currentEffort: EffortPreferenceStore.globalEffort(forContextID: profileID),
                models: ModelCatalogStore.cached(profileID), agentOptions: agent)
            NewChatDefaults.record(effort: carry.level, profileID: profileID)
        } else {
            carryEffort(to: pick.selection, on: profileID)
        }
        if let notice { announce(notice) }
        serviceListing()
        rebuild()
    }

    /// A model picked without a level keeps the one already chosen where it takes it and moves to
    /// the nearest cooler one where it does not, said aloud — the composer's own carry.
    private func carryEffort(to selection: ModelSelection?, on profileID: String) {
        let agent = chooser.servers.first { $0.profileID == profileID }?.agentEfforts ?? []
        let remembered = EffortPreferenceStore.globalEffort(forContextID: profileID)
        let carry = ModelEffort.adoption(
            remembered, for: selection, models: ModelCatalogStore.cached(profileID),
            agentOptions: agent)
        guard carry.level != remembered else { return }
        NewChatDefaults.record(effort: carry.level, profileID: profileID)
        if let notice = carry.notice(modelName: modelWord()) { announce(notice) }
    }

    /// A rung pressed on the open dial: the dial stays up for the next nudge.
    func setStartingEffort(_ level: String?) {
        guard let profileID = chooser.server?.profileID else { return }
        NewChatDefaults.record(effort: level, profileID: profileID)
        refreshDial()
    }

    /// One notch of the wheel over the pill: the level moves one stop along the starting model's
    /// own ladder, pinned at the ends, and a screen reader is told where it landed.
    func stepEffort(by delta: Int) {
        let options = effortOptions()
        guard ModelEffort.isOffered(options: options), let profileID = chooser.server?.profileID
        else { return }
        let current = chooser.defaults?.effort
        let notch = ModelDial.notch(from: current, by: delta, options: options)
        if notch.level != current {
            NewChatDefaults.record(effort: notch.level, profileID: profileID)
            refreshDial()
        }
        EffortSpeech.note(notch)
    }

    /// The whole catalog, from the fleet's own cache, as the composer opens it; a pick on another
    /// machine re-aims the sheet there rather than starting anything.
    func chooseModelFromCatalog() {
        guard let server = chooser.server else { return }
        dialPopover?.close()
        ModelChooserSheet.present(
            on: sheet, sources: ModelFleet.sources(profiles: profiles, current: server.profileID),
            selected: chooser.defaults?.model, context: .composer
        ) { [weak self] pick in
            self?.take(pick, effort: .unchanged, notice: nil)
        }
    }

    private func refreshDial() {
        guard let defaults = chooser.defaults else { return }
        renderDial(defaults)
        dialPill.setAccessibilityLabel(defaults.sentence)
    }

    private func announce(_ words: String) {
        guard !words.isEmpty else { return }
        NSAccessibility.post(
            element: sheet, notification: .announcementRequested,
            userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
