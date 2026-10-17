import Foundation

/// Finds an answer that is on the page twice without reading the page again on every token.
///
/// The doubling is intermittent and heals itself a few seconds later, which is exactly the shape of
/// bug that cannot be read off a screenshot: by the time anyone looks, the evidence has been swept.
/// Both candidate causes leave the same mark and are told apart by the two keys alone — one message
/// id under two segment names is the row naming re-identifying settled prose, two message ids
/// carrying one answer is the transcript holding the same reply twice. Only lengths, hashes and
/// keys are ever written, because a log a person is invited to paste into a bug report must never
/// carry what was said.
///
/// A row is read once for each length it has had: its key and the byte count of its text are the
/// memo, and a row whose text did not change since the last pass costs a dictionary lookup. Only
/// the row being streamed into is hashed again, and the passage a hash stood for is forgotten when
/// the row's text moves on, so a growing answer never leaves a hundred stale prefixes behind to be
/// mistaken for a copy of itself.
struct DoubledRowWatch {
    struct Found {
        let hash: Int
        let chars: Int
        let first: String
        let second: String
    }

    /// Short lines repeat honestly — an agent says "Done." twice in a transcript and neither one is
    /// a bug. Only a passage long enough to be an answer is worth a word.
    private static let floor = 160

    private struct Reading {
        let bytes: Int
        let hash: Int
    }

    private var readings: [String: Reading] = [:]
    private var owners: [Int: String] = [:]

    mutating func read(_ rows: [TranscriptRow]) -> [Found] {
        var found: [Found] = []
        var seen = Set<String>()
        seen.reserveCapacity(rows.count)
        for row in rows {
            let body: String
            switch row.kind {
            case .agentProse(let text, _): body = text
            case .codeBlock(_, let code): body = code
            default: continue
            }
            let bytes = body.utf8.count
            guard bytes >= Self.floor else {
                forget(row.key)
                continue
            }
            seen.insert(row.key)
            if let held = readings[row.key], held.bytes == bytes { continue }
            forget(row.key)
            let hash = body.hashValue
            readings[row.key] = Reading(bytes: bytes, hash: hash)
            if let first = owners[hash], first != row.key {
                found.append(Found(hash: hash, chars: body.count, first: first, second: row.key))
            } else {
                owners[hash] = row.key
            }
        }
        if readings.count > seen.count {
            for key in readings.keys where !seen.contains(key) { forget(key) }
        }
        return found
    }

    private mutating func forget(_ key: String) {
        guard let held = readings.removeValue(forKey: key) else { return }
        if owners[held.hash] == key { owners[held.hash] = nil }
    }
}
