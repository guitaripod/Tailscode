import CodingAgentKit
import Foundation

/// A sentence for what an agent is doing, and the raw words under it when no rule knew them.
public struct PlainLine: Sendable, Equatable {
    public let text: String
    /// What a model could say better, set only when the rules could not read it: an unknown
    /// command or an unknown tool. Nil for everything the rules understood.
    public let rewritable: String?

    public init(_ text: String, rewritable: String? = nil) {
        self.text = text
        self.rewritable = rewritable
    }
}

/// What an agent does, said so that anyone can read it: "Running the tests", "Looking at
/// Backoff.swift", "Clearing the build folder → Building the project", never `swift test
/// --parallel` or a tool's name. Rules only, offline and the same on every client; a command no
/// rule knows becomes "Running a command" and hands its raw words to whatever may say them better.
///
/// It never softens what it cannot read: a command piped into an interpreter, a forced push and
/// a hard reset are named for what they are, `sudo` is said, and an approval keeps its command
/// whole beside these words.
public enum AgentPlain {
    public enum Tense: Sendable {
        case running
        case done
    }

    public static func words(for call: ToolCall) -> PlainLine {
        let tense: Tense = AgentLine.outcome(of: call) == .running ? .running : .done
        let line = line(for: call, tense: tense)
        guard AgentLine.outcome(of: call) == .failed else { return line }
        return PlainLine(Localized.text("%@, failed", line.text), rewritable: line.rewritable)
    }

    /// What an agent is doing right now, as `AgentLine.doing` says it but plainly.
    public static func doing(in state: ConversationState) -> PlainLine? {
        let calls = LiveActivityReading.turnCalls(in: state)
        switch ActivityKind.inFlight(in: state) {
        case .needsApproval?, .needsAnswer?:
            return PlainLine(Localized.text("Waiting for you"))
        case .compacting?:
            return PlainLine(Localized.text("Tidying up the conversation to free room"))
        case .retrying?:
            return PlainLine(Localized.text("The AI service is busy, trying again"))
        case .writing?:
            return PlainLine(Localized.text("Writing the answer"))
        case .thinking?:
            return PlainLine(Localized.text("Thinking"))
        case .usingTool?:
            guard let call = calls.last(where: { AgentLine.outcome(of: $0) == .running }) ?? calls.last
            else { return PlainLine(Localized.text("Working")) }
            return words(for: call)
        default:
            return nil
        }
    }

    /// A shell command in plain words; `.running` for one that is out, `.done` for one that came back.
    public static func command(_ raw: String, tense: Tense) -> PlainLine {
        let reading = ShellReading(raw)
        guard let sentence = reading.sentence(tense) else {
            return PlainLine(unknown(tense), rewritable: AgentLine.bounded(raw, to: 400))
        }
        return PlainLine(reading.isElevated ? Localized.text("%@, as administrator", sentence) : sentence)
    }

    /// What a subagent's tool does, as a few plain words: "Searching the code" for Grep. Nil when
    /// the name is not one the rules know.
    public static func tool(named name: String) -> String? {
        switch name.lowercased() {
        case "read": return Localized.text("Reading files")
        case "grep", "search": return Localized.text("Searching the code")
        case "glob", "find", "ls": return Localized.text("Looking for files")
        case "edit", "multiedit", "notebookedit", "apply_patch", "patch": return Localized.text("Changing files")
        case "write": return Localized.text("Writing files")
        case "bash", "shell", "exec": return Localized.text("Running commands")
        case "webfetch": return Localized.text("Reading web pages")
        case "websearch": return Localized.text("Searching the web")
        case "task", "agent": return Localized.text("Handing work to a helper")
        case "todowrite", "todoread": return Localized.text("Updating its to-do list")
        case "skill": return Localized.text("Following a playbook")
        default: return nil
        }
    }

    /// What a tool that no rule names is called, as words: `mcp__zvec_grep__search` is "zvec grep
    /// search".
    static func humanName(_ name: String) -> String {
        var parts = name.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
        if parts.first == "mcp" { parts.removeFirst() }
        let spaced = parts.joined(separator: " ").replacingOccurrences(of: "-", with: " ")
        var words = ""
        for character in spaced {
            if character.isUppercase, let last = words.last, last.isLowercase { words.append(" ") }
            words.append(character)
        }
        return words.lowercased()
    }

    private static func unknown(_ tense: Tense) -> String {
        tense == .running ? Localized.text("Running a command") : Localized.text("Ran a command")
    }

    private static func line(for call: ToolCall, tense: Tense) -> PlainLine {
        let summary = call.summary
        let running = tense == .running
        if call.name.hasPrefix("mcp__") { return unnamed(call, tense) }
        switch summary.kind {
        case .shell:
            return command(summary.command ?? summary.title ?? call.name, tense: tense)
        case .fileRead:
            return PlainLine(file(summary, call, running: Localized.text("Looking at %@"), done: Localized.text("Looked at %@"), tense))
        case .fileEdit:
            return PlainLine(file(summary, call, running: Localized.text("Changing %@"), done: Localized.text("Changed %@"), tense))
        case .fileWrite:
            return PlainLine(file(summary, call, running: Localized.text("Writing %@"), done: Localized.text("Wrote %@"), tense))
        case .fileSearch:
            return PlainLine(search(summary, call, tense))
        case .webSearch:
            return PlainLine(running ? Localized.text("Searching the web") : Localized.text("Searched the web"))
        case .webFetch:
            if let host = summary.links.first?.url.host {
                return PlainLine(
                    String(format: running ? Localized.text("Reading a page on %@") : Localized.text("Read a page on %@"), host))
            }
            return PlainLine(running ? Localized.text("Reading a web page") : Localized.text("Read a web page"))
        case .taskTracking:
            return PlainLine(running ? Localized.text("Updating its to-do list") : Localized.text("Updated its to-do list"))
        case .subagent:
            return PlainLine(running ? Localized.text("Handing work to a helper") : Localized.text("Handed work to a helper"))
        case .workflow:
            return PlainLine(running ? Localized.text("Running a multi-step workflow") : Localized.text("Ran a multi-step workflow"))
        case .skill:
            guard let title = summary.title, !title.isEmpty else {
                return PlainLine(running ? Localized.text("Using a skill") : Localized.text("Used a skill"))
            }
            return PlainLine(
                String(format: running ? Localized.text("Using the %@ skill") : Localized.text("Used the %@ skill"), AgentLine.bounded(title)))
        case .question:
            return PlainLine(running ? Localized.text("Asking you") : Localized.text("Asked you"))
        case .other:
            return unnamed(call, tense)
        }
    }

    /// A tool no rule names: said by its own name, and offered to a model.
    private static func unnamed(_ call: ToolCall, _ tense: Tense) -> PlainLine {
        if let known = tool(named: call.name) { return PlainLine(known) }
        let name = humanName(call.name)
        return PlainLine(
            String(
                format: tense == .running ? Localized.text("Using the %@ tool") : Localized.text("Used the %@ tool"),
                name),
            rewritable: call.name)
    }

    private static func file(
        _ summary: ToolCallSummary, _ call: ToolCall, running: String, done: String, _ tense: Tense
    ) -> String {
        let name = AgentLine.bounded(AgentLine.basename(summary.filePath ?? summary.title ?? call.name))
        return String(format: tense == .running ? running : done, name)
    }

    private static func search(_ summary: ToolCallSummary, _ call: ToolCall, _ tense: Tense) -> String {
        let running = tense == .running
        let name = call.name.lowercased()
        let query = summary.title.flatMap { $0.isEmpty ? nil : "\u{201C}\(AgentLine.bounded($0))\u{201D}" }
        if name.contains("glob") || name == "find" || name == "ls" {
            return running ? Localized.text("Looking for files") : Localized.text("Looked for files")
        }
        guard let query else {
            return running ? Localized.text("Searching the code") : Localized.text("Searched the code")
        }
        return String(
            format: running ? Localized.text("Searching the code for %@") : Localized.text("Searched the code for %@"), query)
    }
}
