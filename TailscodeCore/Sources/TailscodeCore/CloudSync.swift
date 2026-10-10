import CodingAgentKit
import Foundation

/// A server as a device knows it and as every device can name it.
public struct CloudServer: Sendable, Equatable {
    public var profileID: String
    public var name: String
    public var backend: AgentType
    public var endpoint: String

    public init(profileID: String, name: String, backend: AgentType, endpoint: String) {
        self.profileID = profileID
        self.name = name
        self.backend = backend
        self.endpoint = endpoint
    }
}

/// What the sync reads from a device and what it is allowed to change there, in the device's own
/// terms — profile ids, never ledger keys. The real implementation is the app's stores; a test's
/// is a struct in memory, which is how two phones are made to disagree without owning two.
@MainActor
public protocol CloudDevice: AnyObject {
    func servers() -> [CloudServer]
    func seenMarks() -> [String: CloudSeen]
    func savedChats() -> [SavedChat]
    func pinnedKeys() -> [String]
    func archivedKeys() -> Set<String>
    func adoptSeen(_ marks: [String: CloudSeen])
    func adoptSaved(add: [SavedChat], remove: [(profileID: String, sessionID: String)])
    func adoptPins(order: [String])
    func adoptArchived(add: Set<String>, remove: Set<String>)
}

/// The device the app is: SessionSeenStore, SavedChatStore, SessionPinStore and ArchivedChatStore,
/// with the servers handed in by whoever owns the profiles.
@MainActor
public final class StoreBackedDevice: CloudDevice {
    private let serverList: @MainActor () -> [CloudServer]

    public init(servers: @escaping @MainActor () -> [CloudServer]) {
        serverList = servers
    }

    public func servers() -> [CloudServer] { serverList() }
    public func seenMarks() -> [String: CloudSeen] {
        SessionSeenStore.marks().filter { !$0.key.hasPrefix(Self.demoPrefix) }
    }

    private static let demoPrefix = "demo-"
    public func savedChats() -> [SavedChat] { SavedChatStore.all() }
    public func pinnedKeys() -> [String] { SessionPinStore.all() }
    public func archivedKeys() -> Set<String> { ArchivedChatStore.all() }
    public func adoptSeen(_ marks: [String: CloudSeen]) { SessionSeenStore.adopt(marks) }

    public func adoptSaved(
        add: [SavedChat], remove: [(profileID: String, sessionID: String)]
    ) {
        for chat in add { SavedChatStore.adopt(chat) }
        for gone in remove {
            SavedChatStore.remove(profileID: gone.profileID, sessionID: gone.sessionID)
        }
    }

    public func adoptPins(order: [String]) { SessionPinStore.adopt(order: order) }

    public func adoptArchived(add: Set<String>, remove: Set<String>) {
        ArchivedChatStore.adopt(add: add, remove: remove)
    }
}

/// What the sync keeps between passes: the ledger it last agreed on, what the device held when it
/// did, and the spellings by which this device's servers are known to the others.
public struct CloudSyncState: Codable, Sendable, Equatable {
    public var ledger = CloudLedger()
    public var base = CloudLocal()
    public var aliases: [String: String] = [:]
    public var initialized = false
    public var account: String?
    public var lastSyncedAt: Double?

    public init() {}
}

public protocol CloudSyncStateStore: AnyObject, Sendable {
    func load() -> CloudSyncState
    func save(_ state: CloudSyncState)
}

public final class DefaultsCloudSyncStateStore: CloudSyncStateStore, @unchecked Sendable {
    nonisolated(unsafe) private let defaults: UserDefaults
    private let key = "tailscode.cloud.state"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> CloudSyncState {
        guard let data = defaults.data(forKey: key),
            let state = try? JSONDecoder().decode(CloudSyncState.self, from: data)
        else { return CloudSyncState() }
        return state
    }

    public func save(_ state: CloudSyncState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}

public final class MemoryCloudSyncStateStore: CloudSyncStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state = CloudSyncState()

    public init() {}

    public func load() -> CloudSyncState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func save(_ state: CloudSyncState) {
        lock.lock()
        self.state = state
        lock.unlock()
    }
}

public enum CloudSyncStatus: Sendable, Equatable {
    case off
    case unavailable
    case syncing
    case synced(Date?)
}

/// Keeps what follows a person — which chats they have read, kept, pinned or set aside — the same
/// on every device they are signed in to iCloud on.
///
/// The decision of what to keep is ``CloudReconciler``'s, and it is arithmetic. This is only the
/// part that has to touch the world: it reads the device, reads the cloud, asks for the answer,
/// applies the part of it that differs, and writes the part of it the cloud did not already have.
/// A pass changes nothing when nothing changed, and does not wait on a server or the network —
/// the cloud's own store is local until the system moves it — so it is safe to run whenever a
/// screen asks.
@MainActor
public final class CloudSync {
    public static let shared = CloudSync()

    public static let didChange = Notification.Name("tailscode.cloud.didChange")
    public nonisolated static let enabledKey = "tailscode.cloud.enabled"

    private static let keys = (
        seen: "tailscode.cloud.seen", saved: "tailscode.cloud.saved",
        pinned: "tailscode.cloud.pinned", archived: "tailscode.cloud.archived"
    )

    private var store: CloudKeyValueStore
    private var stateStore: CloudSyncStateStore
    private(set) var device: CloudDevice?
    private var observation: AnyObject?
    private var observers: [NSObjectProtocol] = []
    private var scheduled: Task<Void, Never>?
    private let now: @Sendable () -> Date
    nonisolated(unsafe) private let defaults: UserDefaults

    public private(set) var status: CloudSyncStatus = .off {
        didSet {
            guard status != oldValue else { return }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    init(
        store: CloudKeyValueStore? = nil, stateStore: CloudSyncStateStore? = nil,
        defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        #if canImport(Darwin)
            self.store = store ?? UbiquitousKeyValueCloud()
        #else
            self.store = store ?? InMemoryCloudStore()
        #endif
        self.stateStore = stateStore ?? DefaultsCloudSyncStateStore(defaults: defaults)
        self.defaults = defaults
        self.now = now
    }

    public var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// The person's choice as the standard defaults hold it, readable off the main actor — a
    /// settings row asks while it is being drawn.
    public nonisolated static var preferenceEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            schedule(after: 0)
        } else {
            status = .off
        }
    }

    /// Begins keeping `device` in step with the cloud. Safe to call once per launch; the first
    /// pass waits a few seconds so the launch is not asked to do it while the first screen draws.
    public func start(device: CloudDevice, firstPassAfter delay: TimeInterval = 4) {
        attach(device)
        status = isEnabled ? .syncing : .off
        observeStores()
        observation = store.observe { [weak self] in
            Task { @MainActor in self?.schedule(after: 0.3) }
        }
        schedule(after: delay)
    }

    func attach(_ device: CloudDevice) { self.device = device }

    public func stop() {
        scheduled?.cancel()
        scheduled = nil
        observation = nil
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
    }

    /// Asks for a pass soon. Bursts of changes — a swipe through a list marks a dozen chats read —
    /// collapse into the one pass that follows the last of them.
    public func schedule(after delay: TimeInterval = 1.5) {
        guard device != nil, isEnabled else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pass()
        }
    }

    public func syncNow() { schedule(after: 0) }

    public func foreground() { schedule(after: 0.5) }

    private func observeStores() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [
            SessionSeenStore.didChange, SavedChatStore.didChange, SessionPinStore.didChange,
            ArchivedChatStore.didChange,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
        }
    }

    /// One reconciliation, synchronous from start to end.
    public func pass() {
        guard let device else { return }
        guard isEnabled else {
            status = .off
            return
        }
        guard store.isAvailable else {
            status = .unavailable
            return
        }
        status = .syncing
        store.synchronize()
        var state = stateStore.load()
        adoptAccount(&state)
        let servers = device.servers()
        let remote = readRemote()
        var aliases = state.aliases
        let discovered = CloudKeyMapper.discoverAliases(
            servers: servers, existing: aliases, ledgers: [state.ledger, remote])
        if !discovered.isEmpty {
            for (local, canonical) in discovered {
                aliases[local] = canonical
                state.ledger = state.ledger.renamingEndpoint(local, to: canonical)
                state.base = state.base.renamingEndpoint(local, to: canonical)
            }
        }
        let keys = CloudKeyMapper(servers: servers, aliases: aliases)
        let local = keys.local(from: device)
        let result = CloudReconciler.reconcile(
            local: local, base: keys.resolvable(state.base), ledger: state.ledger, remote: remote,
            now: now().timeIntervalSince1970, legacy: !state.initialized)
        keys.apply(result.patch, to: device)
        state.ledger = result.ledger
        state.base = keys.local(from: device)
        state.aliases = aliases
        state.initialized = true
        state.lastSyncedAt = now().timeIntervalSince1970
        stateStore.save(state)
        writeRemote(result.ledger, previous: remote)
        status = .synced(now())
    }

    private func adoptAccount(_ state: inout CloudSyncState) {
        let account = store.accountFingerprint
        guard account != state.account else { return }
        let hadAccount = state.account != nil
        state.account = account
        guard hadAccount else { return }
        state.ledger = CloudLedger()
        state.base = CloudLocal()
        state.aliases = [:]
        state.initialized = false
    }

    private func readRemote() -> CloudLedger {
        func marks(_ key: String) -> [String: CloudMark] {
            guard let data = store.data(forKey: key),
                let decoded = try? JSONDecoder().decode([String: CloudMark].self, from: data)
            else { return [:] }
            return decoded
        }
        var ledger = CloudLedger()
        ledger.seen = marks(Self.keys.seen)
        ledger.saved = marks(Self.keys.saved)
        ledger.pinned = marks(Self.keys.pinned)
        ledger.archived = marks(Self.keys.archived)
        return ledger
    }

    private func writeRemote(_ ledger: CloudLedger, previous: CloudLedger) {
        func write(_ marks: [String: CloudMark], was: [String: CloudMark], key: String) {
            guard marks != was else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let data = try? encoder.encode(marks) else { return }
            store.set(data, forKey: key)
        }
        write(ledger.seen, was: previous.seen, key: Self.keys.seen)
        write(ledger.saved, was: previous.saved, key: Self.keys.saved)
        write(ledger.pinned, was: previous.pinned, key: Self.keys.pinned)
        write(ledger.archived, was: previous.archived, key: Self.keys.archived)
    }

    public var lastSyncedAt: Date? {
        stateStore.load().lastSyncedAt.map { Date(timeIntervalSince1970: $0) }
    }
}

extension CloudLedger {
    func renamingEndpoint(_ from: String, to: String) -> CloudLedger {
        func rename(_ marks: [String: CloudMark]) -> [String: CloudMark] {
            var out: [String: CloudMark] = [:]
            for (key, mark) in marks {
                let renamed = CloudKeys.rename(key, from: from, to: to)
                if let existing = out[renamed], !mark.outranks(existing) { continue }
                out[renamed] = mark
            }
            return out
        }
        var out = self
        out.saved = rename(saved)
        out.pinned = rename(pinned)
        out.archived = rename(archived)
        return out
    }
}

extension CloudLocal {
    func renamingEndpoint(_ from: String, to: String) -> CloudLocal {
        var out = self
        out.saved = Dictionary(
            saved.map { (CloudKeys.rename($0.key, from: from, to: to), $0.value) },
            uniquingKeysWith: { first, _ in first })
        out.pinned = pinned.map { CloudKeys.rename($0, from: from, to: to) }
        out.archived = Set(archived.map { CloudKeys.rename($0, from: from, to: to) })
        return out
    }
}

extension CloudKeys {
    static func rename(_ key: String, from: String, to: String) -> String {
        guard let parts = split(key), parts.endpoint == from else { return key }
        return conversation(endpoint: to, sessionID: parts.sessionID)
    }
}
