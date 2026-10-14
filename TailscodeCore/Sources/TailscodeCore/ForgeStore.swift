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
    /// The machine that wrote the file. A renderer numbers its files for itself, so
    /// `forge_00007.mp4` is a different clip on every machine this device has rendered on — and a
    /// receipt that asked whichever machine is chosen now would play, save or continue the wrong
    /// one. Nil for a receipt filed before the machine was recorded, which is read as the one
    /// chosen now.
    public let endpoint: ForgeEndpoint?

    public init(
        id: String, recipe: ForgeRecipe, asset: ForgeAsset?, failure: String? = nil,
        finishedAt: Date = Date(), endpoint: ForgeEndpoint? = nil
    ) {
        self.id = id
        self.recipe = recipe
        self.asset = asset
        self.failure = failure
        self.finishedAt = finishedAt
        self.endpoint = endpoint
    }

    /// The receipt for a job that has stopped. A job still running has nothing to file, so this
    /// answers nothing rather than filing a half-render somebody would later click on.
    public init?(job: ForgeJob, endpoint: ForgeEndpoint? = nil, at moment: Date = Date()) {
        guard let promptID = job.promptID else { return nil }
        switch job.phase {
        case .done(let asset):
            self.init(
                id: promptID, recipe: job.recipe, asset: asset, finishedAt: moment, endpoint: endpoint)
        case .failed(let reason):
            self.init(
                id: promptID, recipe: job.recipe, asset: nil, failure: reason, finishedAt: moment,
                endpoint: endpoint)
        case .drafting, .submitting, .queued, .running, .cancelled:
            return nil
        }
    }

    /// What the clip is called when it is written somewhere of the person's own: the words that
    /// made it and its seed. The machine's own name for the file is a counter that means nothing
    /// off that machine, and two clips from two desks would be told apart by nothing at all.
    private static let fileNameLimit = 48

    public var fileName: String {
        let suffix = asset.map { ($0.filename as NSString).pathExtension.lowercased() } ?? ""
        let ext = suffix.isEmpty ? "mp4" : suffix
        var words: [String] = []
        var word = ""
        for scalar in recipe.prompt.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        var slug = ""
        for next in words {
            let joined = slug.isEmpty ? next : slug + "-" + next
            if joined.count > Self.fileNameLimit {
                if slug.isEmpty { slug = String(next.prefix(Self.fileNameLimit)) }
                break
            }
            slug = joined
        }
        return "\(slug.isEmpty ? "clip" : slug)-\(recipe.seed).\(ext)"
    }

    /// Whether the file is on the machine renders go to now. A receipt that never recorded its
    /// machine is given the benefit of the doubt.
    public func isOn(_ machine: ForgeEndpoint?) -> Bool {
        guard let endpoint else { return true }
        return endpoint == machine
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

/// A render that has been asked for and not yet filed, kept so that closing the app does not lose
/// the clip. The render happens on the other machine whether or not anybody is watching, and the
/// machine keeps its answer in history under the job's id, so the id — with the client id the
/// socket was opened under, the machine, and what was asked — is everything it takes to find the
/// clip again after a quit, a crash or an install that restarted the app mid-render.
public struct ForgePending: Sendable, Codable, Equatable {
    public let promptID: String
    public let clientID: String
    public let endpoint: ForgeEndpoint
    public let recipe: ForgeRecipe
    public let startedAt: Date
    /// The posted graph's node count, which the bar is finished over.
    public let nodes: Int
    /// Whether the machine has said it took the job. A render written down before the post leaves
    /// has only been intended: if the app dies in that gap the machine may never have heard of it,
    /// and a job it does not know is then nothing to report rather than a loss.
    public var confirmed: Bool

    public init(
        promptID: String, clientID: String, endpoint: ForgeEndpoint, recipe: ForgeRecipe,
        startedAt: Date, nodes: Int, confirmed: Bool = false
    ) {
        self.promptID = promptID
        self.clientID = clientID
        self.endpoint = endpoint
        self.recipe = recipe
        self.startedAt = startedAt
        self.nodes = nodes
        self.confirmed = confirmed
    }
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
    static let renderersKey = "tailscode.forge.renderers"
    static let clockKey = "tailscode.forge.clock"
    static let pendingKey = "tailscode.forge.pending"
    public static let didChange = Notification.Name("tailscode.forge.didChange")

    /// Enough history to be a history and not a filesystem. The files are on the other machine and
    /// this list is only the way back to them.
    private static let historyCapacity = 40

    /// How many machines are worth offering back. Nobody has eight graphics cards; the list exists
    /// so a person who has a desktop and a laptop that both render never types either address a
    /// second time.
    private static let rendererCapacity = 8

    /// Puts a key back to nothing. Removing it is not enough on the desktop that keeps its
    /// settings in a file of its own: that file only ever learns values, so a key that was merely
    /// removed comes back from it at the next launch — a forgotten machine, a cleared history, a
    /// render long since settled. An empty value is a value, and every reader here treats it as
    /// nothing.
    private static func clear(_ key: String) {
        defaults.set(Data(), forKey: key)
    }

    /// The machine renders currently go to, with the name this device last filed for it. Nil when
    /// nobody has pointed at one yet.
    public static func currentRenderer() -> ForgeRenderer? {
        guard let endpoint = endpoint() else { return nil }
        return renderers().first { $0.endpoint == endpoint }
            ?? ForgeRenderer(endpoint: endpoint)
    }

    /// The word a chip should wear for this address: a name this device filed, else the machine
    /// itself, never the MagicDNS string.
    public static func label(for endpoint: ForgeEndpoint?) -> String? {
        guard let endpoint else { return nil }
        return renderers().first { $0.endpoint == endpoint }?.name ?? endpoint.shortName
    }

    public static func endpoint() -> ForgeEndpoint? {
        guard let data = defaults.data(forKey: endpointKey), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(ForgeEndpoint.self, from: data)
    }

    public static func remember(_ endpoint: ForgeEndpoint?) {
        guard let endpoint else {
            clear(endpointKey)
            NotificationCenter.default.post(name: didChange, object: nil)
            return
        }
        guard let data = try? JSONEncoder().encode(endpoint) else { return }
        defaults.set(data, forKey: endpointKey)
        file(ForgeRenderer(endpoint: endpoint))
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Points renders at a machine and files it among the ones this device has used, which is the
    /// whole of what "remembered" means here — the second time costs a tap rather than an address
    /// somebody has to go and look up again.
    public static func remember(_ renderer: ForgeRenderer) {
        guard let data = try? JSONEncoder().encode(renderer.endpoint) else { return }
        defaults.set(data, forKey: endpointKey)
        file(renderer)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Every renderer this device has pointed at, most recently used first.
    public static func renderers() -> [ForgeRenderer] {
        guard let data = defaults.data(forKey: renderersKey) else { return [] }
        return (try? JSONDecoder().decode([ForgeRenderer].self, from: data)) ?? []
    }

    /// Drops one from the list. The machine renders currently go to is dropped with it, because a
    /// renderer nobody wants offered is not one to keep sending work to either.
    public static func forgetRenderer(_ id: String) {
        writeRenderers(renderers().filter { $0.id != id })
        if endpoint()?.displayHost == id {
            clear(endpointKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// A machine used again moves to the front rather than appearing twice, and a name learned on
    /// the second visit — from a scan, say, after the address was first typed blind — replaces the
    /// blank one rather than being thrown away.
    private static func file(_ renderer: ForgeRenderer) {
        var list = renderers()
        let previous = list.first { $0.id == renderer.id }
        list.removeAll { $0.id == renderer.id }
        list.insert(
            ForgeRenderer(
                endpoint: renderer.endpoint, name: renderer.name ?? previous?.name,
                usedAt: renderer.usedAt),
            at: 0)
        writeRenderers(Array(list.prefix(rendererCapacity)))
    }

    private static func writeRenderers(_ list: [ForgeRenderer]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: renderersKey)
    }

    /// What the next draft starts as. The prompt, the sound and the start picture are deliberately
    /// dropped — a person opening the box wants to describe something new, and a clip that quietly
    /// opened on yesterday's picture is not it — while the settings are what they would otherwise
    /// set again every single time.
    public static func recipe() -> ForgeRecipe {
        guard let data = defaults.data(forKey: recipeKey),
            let stored = try? JSONDecoder().decode(ForgeRecipe.self, from: data)
        else { return ForgeRecipe() }
        var fresh = stored
        fresh.prompt = ""
        fresh.sound = ""
        fresh.frame = nil
        return fresh
    }

    public static func remember(_ recipe: ForgeRecipe) {
        guard let data = try? JSONEncoder().encode(recipe) else { return }
        defaults.set(data, forKey: recipeKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// What renders have cost on the machines this device has used. One clock for all of them:
    /// a person with two cards is rare, and a clock per machine would say nothing on the second
    /// until it had been measured again.
    public static func clock() -> ForgeClock {
        guard let data = defaults.data(forKey: clockKey),
            let stored = try? JSONDecoder().decode(ForgeClock.self, from: data)
        else { return ForgeClock() }
        return stored
    }

    public static func remember(clock: ForgeClock) {
        guard let data = try? JSONEncoder().encode(clock) else { return }
        defaults.set(data, forKey: clockKey)
    }

    public static func history() -> [ForgeEntry] {
        guard let data = defaults.data(forKey: historyKey), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([ForgeEntry].self, from: data)) ?? []
    }

    /// Files a receipt. Filing a clip is what settles the render it came from, so the pending
    /// record is let go in the same breath — a render still pending is one whose clip nobody has
    /// filed. A failure does not settle it: a render that was only lost sight of is still on the
    /// machine, and the clip filed over its failure when it is found.
    public static func record(_ entry: ForgeEntry) {
        var list = history().filter { $0.id != entry.id }
        list.insert(entry, at: 0)
        write(Array(list.prefix(historyCapacity)))
        if entry.asset != nil { clearPending(entry.id) }
    }

    @discardableResult
    public static func record(
        _ job: ForgeJob, on endpoint: ForgeEndpoint? = nil, at moment: Date = Date()
    ) -> ForgeEntry? {
        guard let entry = ForgeEntry(job: job, endpoint: endpoint, at: moment) else { return nil }
        record(entry)
        return entry
    }

    /// How long a render stays worth looking for. The machine keeps a finished job's answer only
    /// until it restarts, and a clip found a day later is no longer the one somebody was waiting
    /// for.
    public static let pendingLifetime: TimeInterval = 12 * 3600

    /// The render that was out when this device last stopped looking, if it is still worth
    /// looking for.
    public static func pending(now: Date = Date()) -> ForgePending? {
        guard let data = defaults.data(forKey: pendingKey), !data.isEmpty,
            let stored = try? JSONDecoder().decode(ForgePending.self, from: data)
        else { return nil }
        guard now.timeIntervalSince(stored.startedAt) < pendingLifetime else {
            clear(pendingKey)
            return nil
        }
        return stored
    }

    public static func remember(pending: ForgePending) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        defaults.set(data, forKey: pendingKey)
    }

    /// Lets go of the pending render, or of one render in particular: a late call about a render
    /// that was already replaced by another must not erase the newer one.
    public static func clearPending(_ promptID: String? = nil) {
        if let promptID, pending()?.promptID != promptID { return }
        clear(pendingKey)
    }

    public static func remove(_ id: String) {
        write(history().filter { $0.id != id })
    }

    public static func forget() {
        clear(historyKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func write(_ list: [ForgeEntry]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: historyKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
