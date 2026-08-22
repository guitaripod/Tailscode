import Foundation

/// A clip that was made, kept so the app has something to show. A render is slow and expensive and
/// the file lives on the other machine, so what this device keeps is the receipt: the words, the
/// settings, the seed, and the three fields that fetch the file back. That is enough to show a
/// history, play any of it again, and — the thing a seed is for — ask for the same clip twice.
public struct ForgeEntry: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let recipe: ForgeRecipe
    public let asset: ForgeAsset?
    public let failure: String?
    public let finishedAt: Date

    public init(
        id: String, recipe: ForgeRecipe, asset: ForgeAsset?, failure: String? = nil,
        finishedAt: Date = Date()
    ) {
        self.id = id
        self.recipe = recipe
        self.asset = asset
        self.failure = failure
        self.finishedAt = finishedAt
    }

    /// The receipt for a job that has stopped. A job still running has nothing to file, so this
    /// answers nothing rather than filing a half-render somebody would later click on.
    public init?(job: ForgeJob, at moment: Date = Date()) {
        guard let promptID = job.promptID else { return nil }
        switch job.phase {
        case .done(let asset):
            self.init(id: promptID, recipe: job.recipe, asset: asset, finishedAt: moment)
        case .failed(let reason):
            self.init(id: promptID, recipe: job.recipe, asset: nil, failure: reason, finishedAt: moment)
        case .drafting, .submitting, .queued, .running, .cancelled:
            return nil
        }
    }

    public var title: String {
        let trimmed = recipe.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Localized.text("New video") }
        let line = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return line.count > 72 ? String(line.prefix(71)) + "…" : line
    }

    public var detail: String { failure ?? recipe.summary }

    public var badge: String? {
        guard asset != nil else { return Localized.text("failed") }
        return Localized.text("%@s", "\(recipe.seconds)")
    }

    public var isPlayable: Bool { asset != nil }
}

/// Everything the forge keeps on this device: which machine renders, what the last render was set
/// to, and the clips that came back. Device-local on purpose — the renderer holds the files and
/// has no idea who asked for them, and the settings somebody last used are a habit rather than a
/// document. Nothing here is a secret, so it is all plain `UserDefaults`.
public enum ForgeStore {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    static let endpointKey = "tailscode.forge.endpoint"
    static let recipeKey = "tailscode.forge.recipe"
    static let historyKey = "tailscode.forge.history"
    public static let didChange = Notification.Name("tailscode.forge.didChange")

    /// Enough history to be a history and not a filesystem. The files are on the other machine and
    /// this list is only the way back to them.
    private static let historyCapacity = 40

    public static func endpoint() -> ForgeEndpoint? {
        guard let data = defaults.data(forKey: endpointKey) else { return nil }
        return try? JSONDecoder().decode(ForgeEndpoint.self, from: data)
    }

    public static func remember(_ endpoint: ForgeEndpoint?) {
        guard let endpoint else {
            defaults.removeObject(forKey: endpointKey)
            NotificationCenter.default.post(name: didChange, object: nil)
            return
        }
        guard let data = try? JSONEncoder().encode(endpoint) else { return }
        defaults.set(data, forKey: endpointKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// What the next draft starts as. The prompt is deliberately dropped — a person opening the
    /// box wants to describe something new, and the settings are what they would otherwise set
    /// again every single time.
    public static func recipe() -> ForgeRecipe {
        guard let data = defaults.data(forKey: recipeKey),
            let stored = try? JSONDecoder().decode(ForgeRecipe.self, from: data)
        else { return ForgeRecipe() }
        var fresh = stored
        fresh.prompt = ""
        return fresh
    }

    public static func remember(_ recipe: ForgeRecipe) {
        guard let data = try? JSONEncoder().encode(recipe) else { return }
        defaults.set(data, forKey: recipeKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func history() -> [ForgeEntry] {
        guard let data = defaults.data(forKey: historyKey) else { return [] }
        return (try? JSONDecoder().decode([ForgeEntry].self, from: data)) ?? []
    }

    public static func record(_ entry: ForgeEntry) {
        var list = history().filter { $0.id != entry.id }
        list.insert(entry, at: 0)
        write(Array(list.prefix(historyCapacity)))
    }

    @discardableResult
    public static func record(_ job: ForgeJob, at moment: Date = Date()) -> ForgeEntry? {
        guard let entry = ForgeEntry(job: job, at: moment) else { return nil }
        record(entry)
        return entry
    }

    public static func remove(_ id: String) {
        write(history().filter { $0.id != id })
    }

    public static func forget() {
        defaults.removeObject(forKey: historyKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func write(_ list: [ForgeEntry]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: historyKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
