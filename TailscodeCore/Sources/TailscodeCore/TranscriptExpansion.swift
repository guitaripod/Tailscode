import Foundation

/// Which rows the reader has opened, remembered by what the row *is* rather than by where it sat.
///
/// A tool row's identity is durable — the message id and the tool-use id, which the server assigns
/// once — but the row a transcript draws is not: a lone call becomes a step inside a run the moment
/// a second step joins it, and a run re-splits whenever a board is lifted out of its middle. Keyed
/// by the drawn row, an expansion was thrown away by the arrival that reshaped the run, which reads
/// exactly like the click never landing.
///
/// A run therefore has no expansion of its own: it is open when any step inside it is, which is
/// what ``containsOpen(under:)`` answers, so folding a step into a run carries the reader's
/// decision in with it.
public struct TranscriptExpansion: Sendable, Equatable {
    private var open: Set<String> = []

    public init() {}

    public mutating func set(_ key: String, open isOpen: Bool) {
        if isOpen {
            open.insert(key)
        } else {
            open.remove(key)
        }
    }

    @discardableResult
    public mutating func toggle(_ key: String) -> Bool {
        let opened = !open.contains(key)
        set(key, open: opened)
        return opened
    }

    public func isOpen(_ key: String) -> Bool { open.contains(key) }

    /// True when anything filed under this key's own prefix is open — the question a run header
    /// asks about the steps it swallowed.
    public func containsOpen(under key: String) -> Bool {
        let prefix = key + ":"
        return open.contains { $0.hasPrefix(prefix) }
    }

    /// Whether the row drawn under this key should render open, whichever shape it currently has.
    public func reads(_ key: String) -> Bool { isOpen(key) || containsOpen(under: key) }

    public mutating func reset() { open.removeAll() }

    public var isEmpty: Bool { open.isEmpty }

    public var keys: Set<String> { open }
}
