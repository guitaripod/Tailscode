import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension NewChatWindow {
    /// The pill the composer and the quick ask wear, so the model a chat starts on is chosen with
    /// the control a person already knows: a press opens the dial, the wheel steps the level, and
    /// the dial's last row opens the whole catalog. What it names is `NewChatDefaults`, the value
    /// the minted chat is stamped with.
    static func makeDial() -> DialPill {
        DialPill(
            css: ["chip-ctl"],
            dial: ModelDialPopover(
                makeState: {
                    NewChatWindow.open?.dialState()
                        ?? ModelDialState(
                            sources: [], selected: nil, effort: nil, options: [], modelWord: "")
                },
                onPick: { pick, effort, notice in
                    Gtk.onMain { NewChatWindow.open?.take(pick, effort: effort, notice: notice) }
                },
                onEffort: { level in
                    Gtk.onMain { NewChatWindow.open?.setStartingEffort(level) }
                },
                onOpenCatalog: { Gtk.onMain { NewChatWindow.open?.chooseModelFromCatalog() } })
        ) { delta in
            Gtk.onMain { NewChatWindow.open?.stepEffort(by: delta) }
        }
    }

    /// Whether the dial has the keyboard: its own keys walk its rows, so the modal's grammar
    /// stands aside until it closes.
    var dialIsOpen: Bool {
        guard let dial else { return false }
        return gtk_widget_get_mapped(dial.dial.popover) != 0
    }

    /// `m`, or ⌃m while typing: the dial opens over the pill, the way a press would.
    func openModelDial() {
        guard chooser.server != nil else { return }
        dial.open()
    }

    /// The dial as it would open now: the fleet with the chosen server first, the model and level
    /// the chat would start with there, and the levels that model takes.
    func dialState() -> ModelDialState {
        let server = chooser.server
        let defaults = chooser.defaults
        return ModelDialState(
            sources: ModelFleet.sources(profiles: profiles, current: server?.profileID),
            selected: defaults?.model, effort: defaults?.effort,
            options: effortOptions(), modelWord: modelWord(),
            agentOptions: server?.agentEfforts ?? [])
    }

    /// The pill's face from the same defaults the sentence and the stamp read.
    func renderDial(_ defaults: NewChatDefaults) {
        dial.render(
            ModelDial.face(modelWord: modelWord(), effort: defaults.effort, options: effortOptions()),
            modelTint: defaults.chip.map {
                ModelTint.identityClass(family: $0.family, name: $0.name)
            })
    }

    /// The levels the starting model takes: its own where the catalog names them, the agent's
    /// otherwise.
    func effortOptions() -> [String] {
        chooser.defaults?.levels ?? []
    }

    func modelWord() -> String {
        guard let server = chooser.server else { return "" }
        let catalog = ModelCatalogStore.cached(server.profileID)
        guard let model = chooser.defaults?.model else {
            return Localized.text("Auto")
        }
        return ModelBadge.word(for: model, in: catalog)
    }

    /// A row taken in the dial: a model on the chosen machine becomes its last-used default, the
    /// way a composer pick does; a model on another machine moves the modal there, because the
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
        SettingsFile.capture()
        AppLog.write(.ui, "NEWCHAT model=\(pick.selection?.rawValue ?? "server") on=\(profileID)")
        if let notice { announce(notice) }
        rerender()
    }

    /// A model picked without a level keeps the one already chosen where it takes it and moves to
    /// the nearest cooler one where it does not, said aloud — the composer's own carry.
    private func carryEffort(to selection: ModelSelection?, on profileID: String) {
        let agentOptions = chooser.servers.first { $0.profileID == profileID }?.agentEfforts ?? []
        let carry = ModelEffort.adoption(
            EffortPreferenceStore.globalEffort(forContextID: profileID), for: selection,
            models: ModelCatalogStore.cached(profileID), agentOptions: agentOptions)
        guard carry.level != EffortPreferenceStore.globalEffort(forContextID: profileID) else {
            return
        }
        NewChatDefaults.record(effort: carry.level, profileID: profileID)
        if let notice = carry.notice(modelName: modelWord()) { announce(notice) }
    }

    /// A rung pressed on the open dial: the dial stays up for the next nudge.
    func setStartingEffort(_ level: String?) {
        guard let profileID = chooser.server?.profileID else { return }
        NewChatDefaults.record(effort: level, profileID: profileID)
        SettingsFile.capture()
        AppLog.write(.ui, "NEWCHAT effort=\(level ?? "server")")
        render()
    }

    /// One notch of the wheel over the pill: the level moves one stop along the starting model's
    /// own ladder, pinned at the ends, and a screen reader is told where it landed.
    func stepEffort(by delta: Int) {
        let options = effortOptions()
        guard ModelEffort.isOffered(options: options), let profileID = chooser.server?.profileID
        else { return }
        let current = chooser.defaults?.effort
        let notch = ModelDial.notch(from: current, by: delta, options: options)
        effortVoice.note(notch)
        guard notch.level != current else { return }
        NewChatDefaults.record(effort: notch.level, profileID: profileID)
        SettingsFile.capture()
        render()
    }

    /// The whole catalog, from the fleet's own cache, as the composer opens it; a pick on another
    /// machine re-aims the modal there rather than starting anything.
    func chooseModelFromCatalog() {
        guard let server = chooser.server else { return }
        ModelChooserWindow.present(
            sources: ModelFleet.sources(profiles: profiles, current: server.profileID),
            selected: chooser.defaults?.model, parent: window, context: .composer,
            onRefresh: { NewChatWindow.refreshCatalog(profileID: server.profileID) }
        ) { pick in
            Gtk.onMain { NewChatWindow.open?.take(pick, effort: .unchanged, notice: nil) }
        }
    }

    /// A press in the open chooser asks the machine for its models again; the window redraws
    /// from the fleet's cache once it answers.
    static func refreshCatalog(profileID: String) {
        Task {
            let profiles = await ServerDirectory.shared.profiles()
            guard let profile = profiles.first(where: { $0.id == profileID }),
                let backend = await ServerDirectory.shared.backend(for: profile)
            else { return }
            _ = await ModelCatalogWatch.refreshOnce(profileID: profileID, backend: backend)
            Gtk.onMain {
                guard let open = NewChatWindow.open else { return }
                ModelChooserWindow.updateOpen(
                    sources: ModelFleet.sources(
                        profiles: open.profiles, current: open.chooser.server?.profileID))
                open.render()
            }
        }
    }

    private func announce(_ words: String) {
        guard tailscode_can_announce() != 0, !words.isEmpty else { return }
        tailscode_accessible_announce(window, words, 0)
    }
}
