import Foundation
import TailscodeCore

extension TranscriptRow {
    /// What this row is for the purpose of the air around it. Cards that are blocks in their own
    /// right — a table, a board, a plan, a card that asks something of the reader — take the code
    /// block's gap, so a flat line beside them is not set as tightly as two lines beside each
    /// other. The turn break is not a class: it is a rule, and ``TranscriptGaps`` splits the turn
    /// gap across it.
    var chatClass: ChatRowClass? {
        switch kind {
        case .userText, .pendingSend, .queuedSend, .interruption:
            return .prompt
        case .agentProse:
            return .prose
        case .codeBlock, .table, .tableDraft, .workflow, .designBoard, .taskBoard, .answerless,
            .interruptedTurn, .providerRetry, .revertBanner:
            return .code
        case .reasoning, .tool, .run, .subagent, .note, .responseStats:
            return .furniture
        case .compaction:
            return .seam
        case .linkRail:
            return .rail
        case .pictureStrip:
            return .picture
        case .file:
            return .picture
        case .turnBreak:
            return nil
        }
    }
}

/// The margin above each row of a transcript, from `ChatMetrics.gap(from:to:)` over the rows'
/// classes. One function, so the transcript's rhythm is one table and not a spacing per widget.
enum TranscriptGaps {
    /// The top margin of every row in order. The first row has none; a turn break takes half the
    /// turn gap above its rule and the row after it the other half, so a turn is set apart by
    /// the same distance whether or not the rule is drawn between.
    static func margins(for rows: [TranscriptRow], metrics: ChatMetrics) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(rows.count)
        var previous: ChatRowClass?
        var afterBreak = false
        for (index, row) in rows.enumerated() {
            if row.kind == .turnBreak {
                result.append(index == 0 ? 0 : metrics.turnGap / 2)
                afterBreak = true
                continue
            }
            let next = row.chatClass
            if afterBreak {
                result.append(metrics.turnGap / 2)
            } else if let next {
                result.append(metrics.gap(from: previous, to: next))
            } else {
                result.append(0)
            }
            afterBreak = false
            previous = next
        }
        return result
    }

    /// The numbers every pointer transcript is laid out with.
    static var metrics: ChatMetrics {
        ChatMetrics.metrics(for: Preferences.chatDensity, input: .pointer)
    }
}
