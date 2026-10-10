import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

/// The cloud as the sync sees it: a handful of named blobs that another device may replace at any
/// moment, and a way to hear that one did. Small on purpose — the engine above it decides every
/// merge, so the store only has to hold bytes and say when they changed underneath.
public protocol CloudKeyValueStore: AnyObject, Sendable {
    /// Whether anything can be stored at all: a person signed in to iCloud, on a build that
    /// carries the entitlement to use it.
    var isAvailable: Bool { get }

    /// Names the account the bytes belong to, so a different account's state is never merged into
    /// this one's. Nil when there is none to name.
    var accountFingerprint: String? { get }

    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func synchronize()

    /// Calls `handler` whenever another device's change lands. The returned token keeps the
    /// observation alive; letting go of it ends it.
    func observe(_ handler: @escaping @Sendable () -> Void) -> AnyObject
}

/// A cloud that lives in memory, shared by every device handed the same instance. It is what a
/// test uses for the account two phones are both signed in to.
public final class InMemoryCloudStore: CloudKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]
    private var handlers: [UUID: @Sendable () -> Void] = [:]
    public var isAvailable = true
    public var accountFingerprint: String? = "account"

    public init() {}

    public func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return blobs[key]
    }

    public func set(_ data: Data, forKey key: String) {
        lock.lock()
        blobs[key] = data
        let listeners = Array(handlers.values)
        lock.unlock()
        for listener in listeners { listener() }
    }

    public func synchronize() {}

    private final class Token {
        let end: () -> Void
        init(_ end: @escaping () -> Void) { self.end = end }
        deinit { end() }
    }

    public func observe(_ handler: @escaping @Sendable () -> Void) -> AnyObject {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return Token { [weak self] in
            self?.lock.lock()
            self?.handlers[id] = nil
            self?.lock.unlock()
        }
    }
}

#if canImport(Darwin)
    /// iCloud's key-value store, which Apple syncs between a person's devices on its own schedule
    /// and which holds up to a megabyte. A change another device made arrives as a notification;
    /// one made here leaves when the system next gets to it, so the engine writes only what moved.
    public final class UbiquitousKeyValueCloud: CloudKeyValueStore, @unchecked Sendable {
        private let store = NSUbiquitousKeyValueStore.default

        public init() {}

        public var isAvailable: Bool {
            FileManager.default.ubiquityIdentityToken != nil && store.synchronize()
        }

        public var accountFingerprint: String? {
            guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
            let data = (try? NSKeyedArchiver.archivedData(
                withRootObject: token, requiringSecureCoding: false)) ?? Data()
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        public func data(forKey key: String) -> Data? { store.data(forKey: key) }

        public func set(_ data: Data, forKey key: String) { store.set(data, forKey: key) }

        public func synchronize() { store.synchronize() }

        private final class Observation {
            let token: NSObjectProtocol
            init(_ token: NSObjectProtocol) { self.token = token }
            deinit { NotificationCenter.default.removeObserver(token) }
        }

        public func observe(_ handler: @escaping @Sendable () -> Void) -> AnyObject {
            Observation(
                NotificationCenter.default.addObserver(
                    forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                    object: store, queue: nil
                ) { _ in handler() })
        }
    }
#endif
