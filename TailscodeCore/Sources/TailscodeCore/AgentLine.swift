import CodingAgentKit
import Foundation

/// How a step ended, as far as the transcript says.
public enum AgentOutcome: Sendable, Equatable {
    case running
    case done
    case failed
    case stopped
}

/// One thing an agent did, in the words a person would use.
public struct AgentStep: Sendable, Hashable, Identifiable {
    public let id: String
    public let words: String
    public let outcome: AgentOutcome
    /// When this device first saw the step. A tool call carries no duration of its own, so this
    /// is the only age there is, and it is said as that: "seen", never "took".
    public var seen: Date?

    public init(id: String, words: String, outcome: AgentOutcome, seen: Date? = nil) {
        self.id = id
        self.words = words
        self.outcome = outcome
        self.seen = seen
    }
}

/// The thing a call is about, under the words that say what is happening: the whole command, or
/// the file's path with how many lines an edit adds and removes.
public struct AgentObject: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case command
        case path
    }

    public let kind: Kind
    public let text: String
    public let added: Int?
    public let removed: Int?

    public init(kind: Kind, text: String, added: Int? = nil, removed: Int? = nil) {
        self.kind = kind
        self.text = text
        self.added = added
        self.removed = removed
    }
}

/// A tool call said as a short sentence, never as a tool's name: "Editing Backoff.swift", "Ran swift
/// test", "Searched “jitter”". One reading for every surface that says what an agent is doing, so
/// the board, its peek and its hour never describe the same call two ways.
///
/// The tense follows the call: a call that is out on the machine is said as it happens, one that
/// came back as it happened, and one that failed says so.
public enum AgentLine {
    static let longest = 72

    public static func words(for call: ToolCall) -> String {
        let summary = call.summary
        let outcome = Self.outcome(of: call)
        let object = object(of: summary, call: call)
        let template: (running: String, done: String)
        switch summary.kind {
        case .shell:
            template = (Localized.text("Running %@"), Localized.text("Ran %@"))
        case .fileRead:
            template = (Localized.text("Reading %@"), Localized.text("Read %@"))
        case .fileEdit:
            template = (Localized.text("Editing %@"), Localized.text("Edited %@"))
        case .fileWrite:
            template = (Localized.text("Writing %@"), Localized.text("Wrote %@"))
        case .fileSearch:
            template = (Localized.text("Searching %@"), Localized.text("Searched %@"))
        case .webSearch:
            return outcome == .running
                ? Localized.text("Searching the web") : Localized.text("Searched the web")
        case .webFetch:
            template = (Localized.text("Fetching %@"), Localized.text("Fetched %@"))
        case .taskTracking:
            return outcome == .running
                ? Localized.text("Updating the plan") : Localized.text("Updated the plan")
        case .subagent:
            template = (Localized.text("Delegating to %@"), Localized.text("Delegated to %@"))
        case .workflow:
            return outcome == .running
                ? Localized.text("Running a workflow") : Localized.text("Ran a workflow")
        case .skill:
            template = (Localized.text("Using %@"), Localized.text("Used %@"))
        case .question:
            return outcome == .running ? Localized.text("Asking you") : Localized.text("Asked you")
        case .other:
            template = (Localized.text("Using %@"), Localized.text("Used %@"))
        }
        let sentence = String(
            format: outcome == .running ? template.running : template.done, object)
        return outcome == .failed ? Localized.text("%@, failed", sentence) : sentence
    }

    static func outcome(of call: ToolCall) -> AgentOutcome {
        switch call.status {
        case .pending, .running: return .running
        case .completed: return .done
        case .error: return .failed
        case .stopped: return .stopped
        }
    }

    private static func object(of summary: ToolCallSummary, call: ToolCall) -> String {
        switch summary.kind {
        case .shell:
            let line = (summary.command ?? summary.title ?? call.name)
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first
                .map(String.init) ?? call.name
            return bounded(line)
        case .fileRead, .fileEdit, .fileWrite:
            return bounded(basename(summary.filePath ?? summary.title ?? call.name))
        case .fileSearch:
            guard let query = summary.title, !query.isEmpty else {
                return Localized.text("files")
            }
            return "\u{201C}\(bounded(query))\u{201D}"
        case .webFetch:
            guard let link = summary.links.first?.url.host ?? summary.title else {
                return Localized.text("a page")
            }
            return bounded(link)
        case .subagent:
            return bounded(summary.title ?? summary.detail ?? SubagentSummary.untitled)
        case .skill:
            return bounded(summary.title ?? Localized.text("a skill"))
        case .other:
            return bounded(call.name)
        case .webSearch, .taskTracking, .workflow, .question:
            return ""
        }
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func bounded(_ text: String, to limit: Int = longest) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// What an agent is doing right now: the call that is out, or the thing a turn does between
    /// calls. Nil when nothing is running.
    public static func doing(in state: ConversationState) -> String? {
        let calls = LiveActivityReading.turnCalls(in: state)
        switch ActivityKind.inFlight(in: state) {
        case .needsApproval?, .needsAnswer?:
            return Localized.text("Waiting for you")
        case .compacting?:
            return Localized.text("Compacting the conversation")
        case .retrying?:
            return Localized.text("Waiting on the provider")
        case .writing?:
            return Localized.text("Writing the answer")
        case .thinking?:
            return Localized.text("Thinking")
        case .usingTool?:
            guard let call = calls.last(where: { outcome(of: $0) == .running }) ?? calls.last
            else { return Localized.text("Working") }
            return words(for: call)
        default:
            return nil
        }
    }

    static let longestObject = 600

    /// The object of the call that is out, in full, for the line under "Doing now". Nil when the
    /// agent is between calls or the call has no object a person could read.
    public static func object(in state: ConversationState) -> AgentObject? {
        guard case .usingTool? = ActivityKind.inFlight(in: state) else { return nil }
        let calls = LiveActivityReading.turnCalls(in: state)
        guard let call = calls.last(where: { outcome(of: $0) == .running }) ?? calls.last else {
            return nil
        }
        let summary = call.summary
        switch summary.kind {
        case .shell:
            guard let command = summary.command ?? summary.title, !command.isEmpty else { return nil }
            return AgentObject(kind: .command, text: bounded(command, to: longestObject))
        case .fileRead, .fileEdit, .fileWrite:
            guard let path = summary.filePath ?? summary.title, !path.isEmpty else { return nil }
            return AgentObject(
                kind: .path, text: path, added: summary.diffStats?.added,
                removed: summary.diffStats?.removed)
        default:
            return nil
        }
    }

    /// The last few steps of the latest turn, newest first. Only the steps asked for are said:
    /// building a call's reading parses its input, which is not a price to pay for a whole turn.
    public static func steps(in state: ConversationState, limit: Int = 5) -> [AgentStep] {
        LiveActivityReading.turnCalls(in: state).suffix(limit).reversed().map { call in
            AgentStep(id: call.id, words: words(for: call), outcome: outcome(of: call))
        }
    }

    /// The files the latest turn changed, newest last, each once.
    public static func touched(in state: ConversationState, limit: Int = 12) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for call in LiveActivityReading.turnCalls(in: state) {
            switch call.summaryKind {
            case .fileEdit, .fileWrite:
                let summary = call.summary
                guard let path = summary.filePath ?? summary.title else { continue }
                let name = basename(path)
                if seen.insert(name).inserted { names.append(name) }
            default:
                continue
            }
        }
        return Array(names.suffix(limit))
    }
}
