import Foundation

/// How deep a cache is asked to cut.
public enum ReliefDepth: Sendable, Equatable {
    /// Trim to half the cache's cap.
    case half
    /// Empty it.
    case all
}

/// Every cache that can give memory back, in one place.
///
/// A cache that grows under load and never shrinks is how a busy afternoon becomes a frozen
/// machine, so every cache in the tiling runtime registers an eviction here, and the governor
/// relieves them together: at shed level 3 they trim to half their cap, at 4 they empty. A cache
/// that does not register fails review.
public final class MemoryRelief: @unchecked Sendable {
    public static let shared = MemoryRelief()

    private struct Handler {
        let name: String
        let evict: @Sendable (ReliefDepth) -> Void
    }

    private let lock = NSLock()
    private var handlers: [UInt64: Handler] = [:]
    private var nextID: UInt64 = 0

    public init() {}

    /// Registers an eviction; the token unregisters it. `evict` is called outside the registry's
    /// lock, on whichever thread relieves.
    @discardableResult
    public func register(
        name: String, evict: @escaping @Sendable (ReliefDepth) -> Void
    ) -> MemoryReliefToken {
        lock.lock()
        nextID += 1
        let id = nextID
        handlers[id] = Handler(name: name, evict: evict)
        lock.unlock()
        return MemoryReliefToken(id: id, registry: self)
    }

    /// Relieves for a shed level: nothing below 3, half at 3, everything at 4. Returns the names
    /// of the caches asked, in registration order, for the recorder.
    @discardableResult
    public func relieve(level: ShedLevel) -> [String] {
        guard let depth = Self.depth(for: level) else { return [] }
        return relieve(depth)
    }

    @discardableResult
    public func relieve(_ depth: ReliefDepth) -> [String] {
        lock.lock()
        let running = handlers.sorted { $0.key < $1.key }.map(\.value)
        lock.unlock()
        for handler in running { handler.evict(depth) }
        return running.map(\.name)
    }

    public static func depth(for level: ShedLevel) -> ReliefDepth? {
        switch level {
        case .calm, .busy, .loaded: return nil
        case .strained: return .half
        case .critical: return .all
        }
    }

    public var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return handlers.sorted { $0.key < $1.key }.map(\.value.name)
    }

    func unregister(_ id: UInt64) {
        lock.lock()
        handlers[id] = nil
        lock.unlock()
    }
}

/// A registration in `MemoryRelief`; idempotent `cancel()`.
public final class MemoryReliefToken: @unchecked Sendable {
    private let id: UInt64
    private weak var registry: MemoryRelief?

    init(id: UInt64, registry: MemoryRelief) {
        self.id = id
        self.registry = registry
    }

    public func cancel() {
        registry?.unregister(id)
        registry = nil
    }
}
