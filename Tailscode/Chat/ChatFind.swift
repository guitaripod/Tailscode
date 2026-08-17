import CodingAgentKit
import Foundation
import TailscodeCore

/// What a row answers a text search with, and how matches are ordered — toolkit-free so the
/// find bar can stay about chrome while this stays about the transcript.
enum ChatFind {
    /// The same fields the desktop transcripts index: prose, code, tool names and their output,
    /// file names, subagent titles, seams and errors.
    static func searchText(for row: ChatRow) -> String {
        switch row.content {
        case .text(let text):
            return text
        case .code(let block):
            return "\(block.language ?? "") \(block.source)"
        case .table(let table):
            return (table.header + table.rows.flatMap { $0 }).joined(separator: " ")
        case .activity(let steps):
            return steps.map { step in
                switch step {
                case .reasoning(let text): return text
                case .tool(let call):
                    return "\(call.name) \(call.title ?? "") \(call.output?.prefix(4000) ?? "")"
                }
            }.joined(separator: " ")
        case .subagent(let card):
            return "\(card.agentType ?? "") \(card.title)"
        case .workflow(let run):
            return "\(run.name) \(run.summary ?? "") \(run.result ?? "")"
        case .subagentGroup(let group):
            return group.title
        case .compaction(let row):
            return row.compaction?.summary ?? "compaction"
        case .taskBoard(let board):
            return board.items.map(\.subject).joined(separator: " ")
        case .designBoard(let sighting):
            let reading = DesignCardReading.make(sighting: sighting, board: nil)
            return "\(reading.title) \(reading.detail)"
        case .file(let reference), .image(let reference):
            return reference.filename ?? reference.path ?? ""
        case .timestamp:
            return ""
        case .error(let message):
            return message
        case .answerless(let turn):
            return "\(turn.title) \(turn.detail)"
        case .responseStats(let stats):
            return stats.spoken
        }
    }

    /// One match per row that contains the needle, in transcript order. Empty needle matches nothing.
    static func matchingIDs(
        needle: String, orderedIDs: [String], rowsByID: [String: ChatRow]
    ) -> [String] {
        let key = needle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return [] }
        return orderedIDs.filter { id in
            guard let row = rowsByID[id] else { return false }
            return searchText(for: row).lowercased().contains(key)
        }
    }

    /// Where the cursor should land after a retarget or a re-scan that kept a previous hit.
    static func cursor(
        matches: [String], previousID: String?, previousCursor: Int, retarget: Bool
    ) -> Int {
        if matches.isEmpty { return 0 }
        if retarget { return matches.count - 1 }
        if let previousID, let kept = matches.firstIndex(of: previousID) { return kept }
        return min(previousCursor, matches.count - 1)
    }
}
