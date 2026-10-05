import TailscodeCore
import CodingAgentKit
import UIKit

/// The model and reasoning effort a turn runs with. A nil model means the
/// server decides.
struct ModelChoice: Equatable {
    var model: ModelSelection?
    var effort: String?
}

extension ModelCatalog {
    /// A server's catalog changed under a surface that already read it. The refresh behind a
    /// warm cache is what makes a model the server gained today reachable without relaunching,
    /// so it has to be able to say so rather than land silently into the store.
    static let didChange = Notification.Name("tailscode.modelCatalog.didChange")
}

/// Per-server model catalogs, kept in memory and on disk so a chip can name the
/// model on the first frame instead of after a round trip to the server.
@MainActor
enum ModelCatalog {
    private static let prefix = "tailscode.modelCatalog."
    private static var memory: [String: [ModelInfo]] = [:]
    private static var inFlight: Set<String> = []

    static func cached(for profileID: String) -> [ModelInfo] {
        if let models = memory[profileID] { return models }
        guard let data = UserDefaults.standard.data(forKey: prefix + profileID),
            let models = try? JSONDecoder().decode([ModelInfo].self, from: data)
        else { return [] }
        memory[profileID] = models
        return models
    }

    /// Cached models immediately when there are any — a stale catalog names the
    /// model correctly and a refresh lands in the background — otherwise the
    /// first fetch is awaited.
    static func models(for profileID: String, backend: any CodingAgentBackend) async -> [ModelInfo] {
        let known = cached(for: profileID)
        guard known.isEmpty else {
            refresh(profileID: profileID, backend: backend)
            return known
        }
        return await fetch(profileID: profileID, backend: backend)
    }

    /// A fetch that lands before it answers — the picker's open path, where a
    /// stale name is a row for a model the server no longer has. Chips keep the
    /// warm cache because they only need to name a choice.
    static func fresh(for profileID: String, backend: any CodingAgentBackend) async -> [ModelInfo] {
        await fetch(profileID: profileID, backend: backend)
    }

    private static func refresh(profileID: String, backend: any CodingAgentBackend) {
        guard !inFlight.contains(profileID) else { return }
        Task { _ = await fetch(profileID: profileID, backend: backend) }
    }

    @discardableResult
    private static func fetch(
        profileID: String, backend: any CodingAgentBackend
    ) async -> [ModelInfo] {
        guard inFlight.insert(profileID).inserted else { return cached(for: profileID) }
        defer { inFlight.remove(profileID) }
        guard let models = try? await backend.availableModels(), !models.isEmpty else {
            return cached(for: profileID)
        }
        let changed = cached(for: profileID).map(\.id) != models.map(\.id)
        memory[profileID] = models
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: prefix + profileID)
        }
        if changed {
            NotificationCenter.default.post(
                name: ModelCatalog.didChange, object: nil, userInfo: ["profileID": profileID])
        }
        return models
    }
}

/// Keeps a presented picker honest against one server: the ordinary fresh fetch answers the moment
/// the server does, and the retrying watch is what makes a chooser opened across a restart list the
/// new models the moment the machine is back rather than the next time the app launches.
@MainActor
enum PickerCatalogWatch {
    static func keep(
        picker: ModelPickerViewController, profileID: String, backend: any CodingAgentBackend,
        sources: @escaping ([ModelInfo]) -> [ModelSource]
    ) -> Task<Void, Never> {
        Task { @MainActor in
            for await reading in ModelCatalogWatch.readings(profileID: profileID, backend: backend) {
                picker.update(sources: sources(reading.models))
            }
        }
    }
}

/// Which model and effort a chat on a given server will actually run with —
/// resolved identically for a session that exists and for one the composer
/// hasn't created yet, so what Home promises is what the chat delivers.
@MainActor
enum ChatModelResolver {
    /// Claude Code runs whatever model its CLI is configured with unless the app
    /// names one, so "unset" is a real, useful state there and must not be
    /// quietly replaced with a guess. Every other backend resolves to a concrete
    /// default the app can name and send.
    static func honoursServerDefault(_ backend: any CodingAgentBackend) -> Bool {
        backend.agentType == .claudeCode
    }

    /// - Parameter contextID: which memory the pick is read from, for a surface that keeps its
    ///   own aim on a server rather than the server's — a quick ask, whose model is deliberately
    ///   not the composer's. Defaults to the server itself.
    static func choice(
        profileID: String, backend: any CodingAgentBackend, sessionKey: String? = nil,
        contextID: String? = nil
    ) async -> ModelChoice {
        ModelChoice(
            model: await model(
                profileID: profileID, backend: backend, sessionKey: sessionKey,
                contextID: contextID),
            effort: effort(
                profileID: profileID, backend: backend, sessionKey: sessionKey,
                contextID: contextID))
    }

    static func model(
        profileID: String, backend: any CodingAgentBackend, sessionKey: String? = nil,
        sessionModel: String? = nil, sessionModelProviderID: String? = nil,
        contextID: String? = nil
    ) async -> ModelSelection? {
        let context = contextID ?? profileID
        let stored =
            sessionKey.flatMap { ModelPreferenceStore.model(forKey: $0) }
            ?? ModelPreferenceStore.resolveSessionModel(
                sessionModel, contextID: context, providerID: sessionModelProviderID)
            ?? ModelPreferenceStore.globalModel(forContextID: context)
        if let stored { return stored }
        guard !honoursServerDefault(backend) else { return nil }
        return await serverDefault(profileID: profileID, backend: backend)
    }

    static func effort(
        profileID: String, backend: any CodingAgentBackend, sessionKey: String? = nil,
        sessionEffort: String? = nil, contextID: String? = nil
    ) -> String? {
        guard backend.capabilities.supportsReasoningEffort else { return nil }
        return EffortPreferenceStore.initialEffort(
            sessionKey: sessionKey, contextID: contextID ?? profileID, sessionEffort: sessionEffort)
    }

    private static let defaultPrefix = "tailscode.defaultModel."
    private static var defaults: [String: ModelSelection] = [:]

    /// The server default this device has already been told, without asking again — for a line
    /// that names what a machine will run before anybody aims at it.
    static func knownServerDefault(profileID: String) -> ModelSelection? {
        if let known = defaults[profileID] { return known }
        return UserDefaults.standard.string(forKey: defaultPrefix + profileID)
            .flatMap(ModelSelection.init(string:))
    }

    private static func serverDefault(
        profileID: String, backend: any CodingAgentBackend
    ) async -> ModelSelection? {
        if let known = defaults[profileID] { return known }
        if let raw = UserDefaults.standard.string(forKey: defaultPrefix + profileID),
            let stored = ModelSelection(string: raw)
        {
            defaults[profileID] = stored
            return stored
        }
        let fetched = (try? await backend.defaultModel()) ?? nil
        guard let fetched else { return nil }
        defaults[profileID] = fetched
        UserDefaults.standard.set(fetched.rawValue, forKey: defaultPrefix + profileID)
        return fetched
    }
}

/// The one model menu in the app: Home's composer pill, the chat's pill and the server screen's
/// default-model chip build the same list from it, so a model picked before a chat exists and one
/// picked inside it look and behave identically.
///
/// Pinned pairs lead — a model and a level, one tap for both — then the models a person has
/// reached for, then the way to the whole catalog. The level itself is the pill's rail, so the
/// pill's menu leaves it out; a surface with no rail (the server screen) asks for it inline.
@MainActor
enum ModelMenu {
    struct Actions {
        var selectModel: (ModelSelection?) -> Void
        var selectEffort: (String?) -> Void
        var selectPreset: ((ModelPreset) -> Void)?
        var browseAll: (() -> Void)?
        /// A model on another machine: the work moves there, the way the full picker moves it. A
        /// surface without this can only change its own machine, and lists that machine alone.
        var selectElsewhere: ((ModelPick) -> Void)?

        init(
            selectModel: @escaping (ModelSelection?) -> Void,
            selectEffort: @escaping (String?) -> Void,
            selectPreset: ((ModelPreset) -> Void)? = nil,
            browseAll: (() -> Void)? = nil,
            selectElsewhere: ((ModelPick) -> Void)? = nil
        ) {
            self.selectModel = selectModel
            self.selectEffort = selectEffort
            self.selectPreset = selectPreset
            self.browseAll = browseAll
            self.selectElsewhere = selectElsewhere
        }
    }

    /// Catalogs run from four aliases (Claude Code) to several hundred entries
    /// (opencode); past this many the menu shows recents and sends the rest to
    /// the searchable picker.
    private static let inlineLimit = 8

    /// A model the account cannot spend on right now says so in the menu as well as in the picker,
    /// with what ran out and when it comes back — the quick list and the full one are one list, and
    /// a fact that only the long version carries is a fact the short version is lying about.
    private static func subtitle(
        _ candidate: ModelCandidate, quotas: [UsageQuota], showsProvider: Bool,
        namesMachine: Bool = true
    ) -> String? {
        let who =
            candidate.isLocal
            ? String(localized: "\(candidate.primary.providerName) · local")
            : (showsProvider ? candidate.providerNames.joined(separator: " · ") : nil)
        let where_ = candidate.isElsewhere && namesMachine ? candidate.serverName : nil
        var parts: [String] = []
        if let where_ { parts.append(where_) }
        if let wall = ModelChooser.wall(for: candidate, quotas: quotas) {
            parts.append(QuotaSurface.rowNote(wall))
        }
        if let who { parts.append(who) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func identity(_ candidate: ModelCandidate) -> UIColor {
        let chip = ModelBadge.chip(selection: candidate.selection, effort: nil)
        return chip.map { Theme.Color.modelIdentity($0) } ?? Theme.Color.tertiaryLabel
    }

    /// The pinned pairs this server can run, as rows: the model's name over its level, wearing the
    /// family's dot and the level's bars. The pins it cannot run follow, dimmed, each naming the
    /// machine that runs it — a pin is never silently missing from the list it was pinned to.
    private static func pinned(
        _ placement: PinPlacement, sources: [ModelSource], candidates: [ModelCandidate],
        choice: ModelChoice, efforts: [String], actions: Actions
    ) -> [UIMenuElement] {
        guard let select = actions.selectPreset else { return [] }
        let models = sources.first(where: \.isCurrent)?.models ?? []
        let away: [UIMenuElement] = placement.away.map { pin in
            let name =
                candidates.first { $0.carries(pin.preset.selection) }?.name
                ?? ModelBadge.shortName(pin.preset.selection.modelID)
            return UIAction(
                title: name,
                subtitle: pin.serverName.map { Localized.text("On %@", $0) }
                    ?? ProviderIdentity.displayName(pin.preset.selection.providerID),
                image: EffortMeterView.dotImage(Theme.Color.tertiaryLabel),
                attributes: .disabled
            ) { _ in }
        }
        return placement.reachable.map { preset in
            let candidate = candidates.first { $0.carries(preset.selection) }
            let name =
                candidate?.name ?? ModelBadge.shortName(preset.selection.modelID)
            let levels = ModelEffort.options(
                models: models, selection: preset.selection, agentOptions: efforts)
            let asked = preset.asks(current: choice.effort)
            let level = ModelEffort.carry(asked, options: levels).level
            let hue =
                ModelBadge.chip(selection: preset.selection, effort: nil)
                .map { Theme.Color.modelIdentity($0) } ?? Theme.Color.tertiaryLabel
            let image: UIImage
            var detail: String?
            if ModelEffort.isOffered(options: levels), preset.effort != .keep {
                image = EffortMeterView.image(
                    for: EffortMeterView.Reading(level: level, options: levels), dot: hue)
                detail = level.map { ModelDial.isPower($0) ? Ultracode.menuTitle.lowercased() : $0 }
                    ?? String(localized: "server decides")
            } else {
                image = EffortMeterView.dotImage(hue)
            }
            return UIAction(
                title: name, subtitle: detail, image: image,
                state: preset.matches(model: choice.model, effort: choice.effort) ? .on : .off
            ) { _ in select(preset) }
        } + away
    }

    private static func row(
        _ entry: ModelMenuEntry, choice: ModelChoice, quotas: [UsageQuota], showsProvider: Bool,
        namesMachine: Bool, action: @escaping () -> Void
    ) -> UIAction {
        let candidate = entry.candidate
        let walled = ModelChooser.wall(for: candidate, quotas: quotas) != nil
        return UIAction(
            title: candidate.name,
            subtitle: subtitle(
                candidate, quotas: quotas, showsProvider: showsProvider, namesMachine: namesMachine),
            image: walled
                ? UIImage(systemName: "gauge.with.dots.needle.100percent")
                : EffortMeterView.dotImage(identity(candidate)),
            state: !candidate.isElsewhere && candidate.carries(choice.model) ? .on : .off
        ) { _ in action() }
    }

    /// The quick menu answers over the whole fleet, not the one server whose pill was pressed —
    /// recents and other machines' models belong inline where the pick happens.
    static func elements(
        sources: [ModelSource], choice: ModelChoice, efforts: [String],
        allowsServerDefault: Bool, quotas: [UsageQuota] = [], includesEffort: Bool = true,
        actions: Actions
    ) -> [UIMenuElement] {
        var sections: [UIMenuElement] = []
        let directory = ModelChooser(sources: sources, selected: choice.model, quotas: quotas)
        let candidates = directory.candidates
        let layout = ModelMenuLayout.build(
            sources: sources, selected: choice.model,
            presets: actions.selectPreset == nil ? [] : ModelPresetStore.all(),
            showsElsewhere: actions.selectElsewhere != nil, limit: inlineLimit)
        let pairs = pinned(
            layout.pins, sources: sources, candidates: candidates, choice: choice,
            efforts: efforts, actions: actions)
        if !pairs.isEmpty {
            sections.append(
                UIMenu(
                    title: String(localized: "Pinned"), options: .displayInline, children: pairs))
        }
        var picks: [UIMenuElement] = []
        if allowsServerDefault {
            picks.append(
                UIAction(
                    title: String(localized: "Server default"),
                    subtitle: String(localized: "Whatever this server runs"),
                    image: UIImage(systemName: "circle"),
                    state: choice.model == nil ? .on : .off
                ) { _ in actions.selectModel(nil) })
        }
        let showsProvider = Set(candidates.flatMap { $0.offers.map(\.providerID) }).count > 1
        picks += layout.here.map { entry in
            row(
                entry, choice: choice, quotas: quotas, showsProvider: showsProvider,
                namesMachine: true
            ) { actions.selectModel(entry.selection) }
        }
        if let elsewhere = actions.selectElsewhere {
            picks += layout.elsewhere.map { group in
                UIMenu(
                    title: group.title, subtitle: group.detail,
                    image: UIImage(
                        systemName: group.state.wearsDot
                            ? "desktopcomputer.trianglebadge.exclamationmark" : "desktopcomputer"),
                    children: group.entries.map { entry in
                        row(
                            entry, choice: choice, quotas: quotas, showsProvider: showsProvider,
                            namesMachine: false
                        ) { elsewhere(entry.pick) }
                    })
            }
        }
        if picks.isEmpty {
            picks.append(
                UIAction(title: String(localized: "No models reported"), attributes: .disabled) { _ in })
        }
        sections.append(
            UIMenu(
                title: pairs.isEmpty ? "" : String(localized: "Recent"), options: .displayInline,
                children: picks))
        if let browseAll = actions.browseAll, layout.offersBrowse {
            sections.append(
                UIMenu(
                    options: .displayInline,
                    children: [
                        UIAction(
                            title: String(localized: "All models…"),
                            subtitle: directory.summary,
                            image: UIImage(systemName: "magnifyingglass")
                        ) { _ in browseAll() }
                    ]))
        }
        guard includesEffort else { return sections }
        let options = ModelEffort.options(
            models: sources.flatMap(\.models), selection: choice.model, agentOptions: efforts)
        if !options.isEmpty {
            var levels: [UIMenuElement] = [
                UIAction(
                    title: String(localized: "Default"), state: choice.effort == nil ? .on : .off
                ) { _ in actions.selectEffort(nil) }
            ]
            levels += options.map { level in
                guard level == Ultracode.effortLevel else {
                    return UIAction(
                        title: level.capitalized, state: choice.effort == level ? .on : .off
                    ) { _ in actions.selectEffort(level) }
                }
                return UIAction(
                    title: Ultracode.menuTitle, subtitle: Ultracode.menuSubtitle,
                    image: UIImage(systemName: "sparkles"),
                    state: choice.effort == level ? .on : .off
                ) { _ in actions.selectEffort(level) }
            }
            sections.append(
                UIMenu(
                    title: String(localized: "Reasoning effort"),
                    subtitle: choice.effort?.capitalized ?? String(localized: "Default"),
                    image: UIImage(systemName: "gauge.with.dots.needle.50percent"),
                    children: levels))
        }
        return sections
    }

}
