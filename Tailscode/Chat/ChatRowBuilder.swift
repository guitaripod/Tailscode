import CodingAgentKit
import Foundation
import TailscodeCore
import UIKit

/// Builds transcript rows from messages — pure mapping, no view ownership.
enum ChatRowBuilder {
    static func makeRows(
        from messages: [ChatMessage], agents: ChatViewController.SubagentPlacement,
        runs: [String: WorkflowRun] = [:]
    ) -> [ChatRow] {
        var rows: [ChatRow] = []
        var lastDate: Date?
        var seenMessageIDs = Set<String>()
        var pendingUnattached = agents.unattached
        for message in messages {
            guard seenMessageIDs.insert(message.id).inserted else { continue }
            if let prev = lastDate, message.createdAt.timeIntervalSince(prev) > 300 {
                rows.append(ChatRow(
                    id: "ts:\(message.id)", messageID: message.id, role: .system,
                    content: .timestamp(Self.relativeTimestamp(message.createdAt))))
            }
            if lastDate == nil || message.createdAt > (lastDate ?? .distantPast) {
                lastDate = message.createdAt
            }
            var steps: [ActivityStep] = []
            var groupID: String?

            func flushActivity() {
                guard !steps.isEmpty, let groupID else { return }
                rows.append(
                    ChatRow(
                        id: "\(message.id):activity:\(groupID)", messageID: message.id,
                        role: message.role, content: .activity(steps)))
                steps = []
            }

            for part in message.parts {
                let id = "\(message.id):\(part.id)"
                switch part.kind {
                case .reasoning(let text):
                    if text.isEmpty { continue }
                    if steps.isEmpty { groupID = part.id }
                    steps.append(.reasoning(text))
                case .tool(let call):
                    if var card = agents.byToolUse[call.id] {
                        flushActivity()
                        card.spawnSummary = call.summary.displayOutput ?? call.sanitizedOutput
                        rows.append(
                            ChatRow(
                                id: "agent:\(card.agentID)", messageID: message.id,
                                role: message.role, content: .subagent(card)))
                        continue
                    }
                    if let run = runs[call.id] {
                        flushActivity()
                        rows.append(
                            ChatRow(
                                id: "workflow:\(call.id)", messageID: message.id,
                                role: message.role, content: .workflow(run)))
                        pendingUnattached = []
                        continue
                    }
                    if steps.isEmpty { groupID = part.id }
                    steps.append(.tool(call))
                    if call.summary.kind == .workflow, !pendingUnattached.isEmpty {
                        flushActivity()
                        rows.append(
                            contentsOf: Self.agentRows(
                                pendingUnattached, groupID: call.id, messageID: message.id,
                                role: message.role, expandedGroups: agents.expandedGroups))
                        pendingUnattached = []
                    }
                case .text(let text):
                    flushActivity()
                    if text.isEmpty { continue }
                    if message.role == .user {
                        let (interrupted, remainder) = Self.strippedInterruption(text)
                        if interrupted {
                            rows.append(
                                ChatRow(
                                    id: "\(id):interrupted", messageID: message.id,
                                    role: .system,
                                    content: .timestamp(String(localized: "interrupted"))))
                        }
                        if !remainder.isEmpty {
                            rows.append(
                                ChatRow(
                                    id: id, messageID: message.id, role: message.role,
                                    content: .text(remainder)))
                        }
                    } else {
                        let segments = MessageSegment.split(text)
                        for (index, segment) in segments.enumerated() {
                            let segID = segments.count == 1 ? id : "\(id):seg\(index)"
                            let content: ChatRow.Content
                            switch segment {
                            case .text(let value): content = .text(value)
                            case .code(let block): content = .code(block)
                            }
                            rows.append(
                                ChatRow(id: segID, messageID: message.id, role: message.role, content: content))
                        }
                    }
                case .file(let file):
                    flushActivity()
                    rows.append(
                        ChatRow(
                            id: id, messageID: message.id, role: message.role,
                            content: file.isImage ? .image(file) : .file(file)))
                case .compaction(let compaction):
                    flushActivity()
                    rows.append(
                        ChatRow(
                            id: id, messageID: message.id, role: .system,
                            content: .compaction(
                                CompactionRow(id: id, state: .done(compaction)))))
                case .unknown:
                    continue
                }
            }
            flushActivity()
            if let error = message.error, !error.isEmpty, message.role == .assistant {
                rows.append(ChatRow(
                    id: "\(message.id):error", messageID: message.id, role: message.role,
                    content: .error(error)))
            }
        }
        rows.append(
            contentsOf: Self.agentRows(
                pendingUnattached, groupID: "session", messageID: "agents", role: .assistant,
                expandedGroups: agents.expandedGroups))
        return fuseActivity(rows)
    }

    static func strippedInterruption(_ text: String) -> (interrupted: Bool, remainder: String) {
        guard text.hasPrefix("[Request interrupted") else { return (false, text) }
        guard let close = text.firstIndex(of: "]") else { return (true, "") }
        let remainder = String(text[text.index(after: close)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (true, remainder)
    }

    static let inlineAgentLimit = 3



    static func agentRows(
        _ cards: [SubagentCard], groupID: String, messageID: String, role: MessageRole,
        expandedGroups: Set<String>
    ) -> [ChatRow] {
        guard !cards.isEmpty else { return [] }
        func card(_ card: SubagentCard) -> ChatRow {
            ChatRow(
                id: "agent:\(card.agentID)", messageID: messageID, role: role,
                content: .subagent(card))
        }
        guard cards.count > inlineAgentLimit else { return cards.map(card) }
        let id = "agents:\(groupID)"
        let expanded = expandedGroups.contains(id)
        let header = ChatRow(
            id: id, messageID: messageID, role: role,
            content: .subagentGroup(
                SubagentGroup(
                    id: id, total: cards.count, live: cards.count(where: \.isActive),
                    expanded: expanded)))
        return expanded ? [header] + cards.map(card) : [header]
    }

    static func liveProgress(_ agent: SubagentSummary) -> String? {
        guard agent.isActive else { return nil }
        var parts: [String] = []
        if let done = agent.todosDone, let total = agent.todosTotal, total > 0 {
            parts.append("\(done)/\(total)")
            if let current = agent.currentTodo, !current.isEmpty {
                parts.append(String(current.prefix(40)))
            }
        } else if let current = agent.currentTool, !current.isEmpty {
            if let count = agent.toolCount {
                parts.append(String(localized: "\(count) tools"))
            }
            parts.append(String(current.prefix(40)))
        }
        guard !parts.isEmpty else { return nil }
        if let started = agent.startedAt {
            let seconds = Int(max(0, Date().timeIntervalSince(started)))
            parts.append(seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s")
        }
        return parts.joined(separator: " · ")
    }

    static func digest(_ messages: [ChatMessage]?) -> (steps: [ActivityStep], report: String?) {
        guard let messages else { return ([], nil) }
        var steps: [ActivityStep] = []
        var report: String?
        for message in messages where message.role == .assistant {
            for part in message.parts {
                switch part.kind {
                case .reasoning(let text):
                    if !text.isEmpty { steps.append(.reasoning(text)) }
                case .tool(let call):
                    steps.append(.tool(call))
                case .text(let text):
                    if !text.isEmpty { report = text }
                case .file, .compaction, .unknown:
                    continue
                }
            }
        }
        return (steps, report)
    }

    static func relativeTimestamp(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return String(localized: "Today \(time)") }
        if Calendar.current.isDateInYesterday(date) {
            return String(localized: "Yesterday \(time)")
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }

    static func fuseActivity(_ rows: [ChatRow]) -> [ChatRow] {
        var merged: [ChatRow] = []
        for row in rows {
            if case .activity(let steps) = row.content, let last = merged.last,
                case .activity(let prior) = last.content
            {
                merged[merged.count - 1] = ChatRow(
                    id: last.id, messageID: last.messageID, role: last.role,
                    content: .activity(prior + steps))
            } else {
                merged.append(row)
            }
        }
        return merged
    }

}
