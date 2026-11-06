import Foundation

/// Values decoded out of the defaults, kept by key for any thread that reads or writes one. On
/// Linux a read of a stored blob costs about 50 ns a byte, so a store read on every redraw keeps
/// what it decoded here and keeps it current on its own writes.
final class DecodedCache<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Value] = [:]

    func value(for key: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    /// What a write stored, which replaces whatever was kept.
    func keep(_ value: Value, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[key] = value
    }

    /// What a read decoded, kept only where nothing is yet: a write that landed while the read was
    /// decoding is newer than what the read saw.
    func adopt(_ value: Value, for key: String) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let kept = entries[key] { return kept }
        entries[key] = value
        return value
    }

    func drop(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[key] = nil
    }
}
