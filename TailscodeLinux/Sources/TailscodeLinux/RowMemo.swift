import CodingAgentKit
import Foundation
import TailscodeCore

/// What each message was drawn as, kept for every builder in the process and for every chat the
/// window has shown lately rather than for the one transcript the last build read.
///
/// A message id is unique, so one table serves all of them, and a message is reused only while it
/// is byte-identical to the one the rows were made from, sealed the same way and drawn in the same
/// look. Returning to a chat therefore builds nothing for the history it already drew — the build
/// that took a quarter of a second for three hundred messages finds every one of them here — and
/// a chat that was being hovered a moment before it was opened has had its rows made by then.
final class RowMemo: @unchecked Sendable {
    static let shared = RowMemo()

    /// Messages kept: a few chats' worth of the tail a pane builds. Past it the least recently
    /// used go, a fifth at a time so the sort is not paid per message.
    static let capacity = 2400

    private struct Entry {
        let message: ChatMessage
        let sealed: Bool
        let look: String
        let rows: [TranscriptRow]
        var stamp: UInt64
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var tick: UInt64 = 0
    private var reliefToken: MemoryReliefToken?

    init() {
        reliefToken = MemoryRelief.shared.register(name: "message rows") { [weak self] depth in
            self?.relieve(depth)
        }
    }

    deinit {
        reliefToken?.cancel()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func rows(for message: ChatMessage, sealed: Bool, look: String) -> [TranscriptRow]? {
        lock.lock()
        let entry = entries[message.id]
        lock.unlock()
        guard let entry, entry.sealed == sealed, entry.look == look, entry.message == message
        else { return nil }
        lock.lock()
        tick &+= 1
        entries[message.id]?.stamp = tick
        lock.unlock()
        return entry.rows
    }

    func store(_ rows: [TranscriptRow], for message: ChatMessage, sealed: Bool, look: String) {
        lock.lock()
        defer { lock.unlock() }
        tick &+= 1
        entries[message.id] = Entry(
            message: message, sealed: sealed, look: look, rows: rows, stamp: tick)
        if entries.count > Self.capacity + Self.capacity / 5 { trim(to: Self.capacity) }
    }

    func removeAll() {
        lock.lock()
        entries = [:]
        lock.unlock()
    }

    private func relieve(_ depth: ReliefDepth) {
        lock.lock()
        defer { lock.unlock() }
        switch depth {
        case .half: trim(to: Self.capacity / 2)
        case .all: entries = [:]
        }
    }

    private func trim(to limit: Int) {
        guard entries.count > limit else { return }
        let drop = entries.count - limit
        for key in entries.sorted(by: { $0.value.stamp < $1.value.stamp }).prefix(drop).map(\.key) {
            entries[key] = nil
        }
    }
}
