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

/// The one model-and-effort menu in the app: Home's composer chip and the chat
/// screen's title chip build the same list from it, so a model picked before a
/// chat exists and one picked inside it look and behave identically.
@MainActor
enum ModelMenu {
    struct Actions {
        var selectModel: (ModelSelection?) -> Void
        var selectEffort: (String?) -> Void
        var browseAll: (() -> Void)?
    }

    /// Catalogs run from four aliases (Claude Code) to several hundred entries
    /// (opencode); past this many the menu shows recents and sends the rest to
    /// the searchable picker.
    private static let inlineLimit = 8

    /// The menu and the picker are one list at two lengths, so the shortlist rule lives in the Kit
    /// beside the folding — a model the menu offers is the same folded row the picker shows.
    private static func shortlist(
        _ models: [ModelInfo], selected: ModelSelection?
    ) -> [ModelCandidate] {
        ModelChooser.shortlist(models, selected: selected, limit: inlineLimit)
    }

    /// A model the account cannot spend on right now says so in the menu as well as in the picker,
    /// with what ran out and when it comes back — the quick list and the full one are one list, and
    /// a fact that only the long version carries is a fact the short version is lying about.
    private static func subtitle(
        _ candidate: ModelCandidate, quotas: [UsageQuota], showsProvider: Bool
    ) -> String? {
        let who =
            candidate.isLocal
            ? String(localized: "\(candidate.primary.providerName) · local")
            : (showsProvider ? candidate.providerNames.joined(separator: " · ") : nil)
        guard let wall = ModelChooser.wall(for: candidate, quotas: quotas) else { return who }
        let note = QuotaSurface.rowNote(wall)
        guard let who else { return note }
        return "\(note) · \(who)"
    }

    static func elements(
        models: [ModelInfo], choice: ModelChoice, efforts: [String],
        allowsServerDefault: Bool, quotas: [UsageQuota] = [], actions: Actions
    ) -> [UIMenuElement] {
        var sections: [UIMenuElement] = []
        let shortlist = shortlist(models, selected: choice.model)
        var picks: [UIMenuElement] = []
        if allowsServerDefault {
            picks.append(
                UIAction(
                    title: String(localized: "Auto"),
                    subtitle: String(localized: "Whatever the server runs"),
                    image: UIImage(systemName: "wand.and.stars"),
                    state: choice.model == nil ? .on : .off
                ) { _ in actions.selectModel(nil) })
        }
        let showsProvider = Set(models.map(\.providerID)).count > 1
        picks += shortlist.map { candidate in
            let walled = ModelChooser.wall(for: candidate, quotas: quotas) != nil
            return UIAction(
                title: candidate.name,
                subtitle: subtitle(candidate, quotas: quotas, showsProvider: showsProvider),
                image: walled
                    ? UIImage(systemName: "gauge.with.dots.needle.100percent") : nil,
                state: candidate.carries(choice.model) ? .on : .off
            ) { _ in actions.selectModel(candidate.selection) }
        }
        if picks.isEmpty {
            picks.append(
                UIAction(title: String(localized: "No models reported"), attributes: .disabled) { _ in })
        }
        sections.append(UIMenu(options: .displayInline, children: picks))
        if let browseAll = actions.browseAll,
            ModelChooser.fold(models).count > shortlist.count
        {
            sections.append(
                UIMenu(
                    options: .displayInline,
                    children: [
                        UIAction(
                            title: String(localized: "All models…"),
                            subtitle: ModelChooser(
                                models: models, selected: choice.model, quotas: quotas
                            ).summary,
                            image: UIImage(systemName: "magnifyingglass")
                        ) { _ in browseAll() }
                    ]))
        }
        if !efforts.isEmpty {
            var levels: [UIMenuElement] = [
                UIAction(
                    title: String(localized: "Default"), state: choice.effort == nil ? .on : .off
                ) { _ in actions.selectEffort(nil) }
            ]
            levels += efforts.map { level in
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
