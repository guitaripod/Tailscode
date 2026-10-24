import AppKit
import CodingAgentKit
import TailscodeCore

/// The agents one message spawned, when there are more than a transcript reads card by card. Each
/// member keeps the key its own row would have had, so what a reader opened inside it is still
/// open after the fan-out is grouped, and a group is the same row whether it is open or not.
struct SubagentFanout: Hashable {
    struct Member: Hashable {
        let key: String
        let call: ToolCall
    }

    let id: String
    let members: [Member]

    /// Beyond this many siblings the agents collapse behind one row, on every client.
    static let inlineLimit = 3
}

extension TranscriptRow.Kind {
    /// The calls this row spawned an agent for, which is what a fact about an agent finds its row
    /// by: one for a card, all of them for a group.
    var spawnedCalls: [ToolCall] {
        switch self {
        case .subagent(let call): return [call]
        case .subagentGroup(let fanout): return fanout.members.map(\.call)
        default: return []
        }
    }
}

extension TranscriptRow {
    /// Whether this row draws a call the record still says is running — the rows whose marks have
    /// to be redrawn the moment the turn ends, because nothing about their value changes when it
    /// does.
    var hasOpenWork: Bool {
        switch kind {
        case .tool(let call), .subagent(let call), .workflow(let call):
            return call.status == .running
        case .subagentGroup(let fanout):
            return fanout.members.contains { $0.call.status == .running }
        case .run(let steps):
            return steps.contains {
                if case .tool(_, let call) = $0 { return call.status == .running }
                return false
            }
        default:
            return false
        }
    }
}

/// One agent action in the order it happened — a thought or a tool call — folded together into a
/// run row the same way the iOS app groups them, so the three clients read the middle of a turn
/// alike.
enum ActivityStep: Hashable {
    case reasoning(key: String, String)
    case tool(key: String, ToolCall)

    /// The row's own durable key, carried in rather than re-derived from where the step ended up.
    /// A step's position inside a run moves whenever the run is re-split, and a key that moves is
    /// a reader's expansion thrown away.
    var key: String {
        switch self {
        case .reasoning(let key, _), .tool(let key, _): return key
        }
    }
}

/// One line of the transcript, in the CLIs' grammar: the prompt behind an accent rule, the
/// agent's answer as prose at full measure, code as blocks that copy byte-exactly, edits as
/// diffs, reasoning and tool output behind a disclosure, a compaction as a seam, a picture as
/// the picture. No bubbles — the material lives in the chrome around this.
struct TranscriptRow: Hashable {
    enum Kind: Hashable {
        case userText(String, messageID: String)
        case interruption
        /// The rendering rides in the row, computed where the rows are computed, so painting a
        /// prose row is a label set, not a markdown parse.
        case agentProse(text: String, rendered: NSAttributedString)
        case codeBlock(language: String?, body: String)
        /// The one-line rail under a run of prose, holding every address the run mentioned. It
        /// arrives when the run has closed, so it is never under text that is still being written
        /// into, and it fetches its own faces: nothing it learns moves another row.
        case linkRail(urls: [String])
        case table(MarkdownTable)
        /// A table still being written: its card, its count, and none of its rows measured.
        case tableDraft(TableDraft)
        case reasoning(String)
        case tool(ToolCall)
        case run([ActivityStep])
        case subagent(ToolCall)
        /// More agents than a transcript reads card by card, spawned by one message: they stand
        /// behind one disclosure row at the place the first of them was spawned.
        case subagentGroup(SubagentFanout)
        case workflow(ToolCall)
        case file(FileReference, mine: Bool, messageID: String)
        /// Pictures the agent made, consecutive ones sharing one square of tiles that opens the
        /// conversation's viewer.
        case pictures([GalleryPicture])
        /// A board of design alternatives the agent wrote, standing where the manifest that made
        /// it was written rather than as a line about a file.
        case designBoard(DesignSighting)
        case taskBoard(TaskBoard)
        case compaction(Compaction)
        /// The answering model changed here: one flat line before the answer that the new model
        /// wrote, so the change is read where it happened and not inferred from a footer.
        case modelSeam(ModelSwitch)
        /// The first row of a chat that was carried from another: where it came from, opening the
        /// brief it rode in on.
        case carried(CarryReading)
        case answerless(AnswerlessTurn)
        /// A turn the server ended with an error: the card stands after the turn's own rows, quoting
        /// what the server said and offering the same words again.
        case failedTurn(FailedTurn)
        /// What the answer above it took, drawn only where the reader asked for it.
        case responseStats(ResponseStats)
        /// Written, not sent: a prompt waiting behind the turn that is running.
        case queuedSend(QueueRow, position: Int, of: Int)
        /// The queue a Stop paused, with something in it: nothing goes until it is resumed.
        case queuePaused(count: Int)
        case pendingSend(PendingSend, ResumePlan?, now: Date)
        /// Not `interruption`, which is the escape key: this is the machine stopping mid-answer.
        case interruptedTurn(InterruptedTurn)
        /// A line the server wrote for the reader rather than for the model: the model or the
        /// agent changing hands, a restart picking a turn back up, work it left running reporting
        /// back. Read into words only where it is drawn, so a client with no catalog yet still
        /// shows Core's own fallback rather than a value baked in too early.
        case note(TranscriptNote)
        /// The turn is waiting on its provider between attempts.
        case providerRetry(ProviderRetryCard)
        /// The conversation wound back to one of the reader's own messages, with the way back
        /// still open. `restoring` is this device's own press on Restore, in flight.
        case revertBanner(RevertBanner, restoring: Bool)
        /// An undo this device asked for, standing where the banner will land once the server
        /// answers.
        case revertPending
        /// Everything the agent did in one turn before it answered, drawn as one head. The model
        /// lives in the pane's `BrainStore`; this is only the identity and what repaints it.
        case brain(BrainRow)
        case turnBreak
    }

    /// One picture of a gallery: the row key its pixels are cached under, and what to fetch.
    struct GalleryPicture: Hashable {
        let key: String
        let reference: FileReference
    }

    let key: String
    let kind: Kind

    /// Whether this row is part of what the person sent — the words, or a picture clipped to
    /// them — which is the block that rises to the top when a prompt goes.
    var isPromptBlock: Bool {
        switch kind {
        case .userText, .pendingSend, .carried: return true
        case .file(_, let mine, _): return mine
        default: return false
        }
    }

    /// The same switch every desktop reads: an environment override for screenshots and headless
    /// runs, then the shared `tailscode.*` default. On by default, like the iOS app, so a turn
    /// reads as ask → answer until opened.
    static var compactTools: Bool {
        if let raw = ProcessInfo.processInfo.environment["TAILSCODE_COMPACT"] { return raw == "1" }
        if UserDefaults.standard.object(forKey: "tailscode.compactTools") == nil { return true }
        return UserDefaults.standard.bool(forKey: "tailscode.compactTools")
    }

    /// A Workflow call is its run, not a tool line; everything else that spawns work is an agent.
    static func kind(for call: ToolCall) -> Kind {
        if call.summaryKind == .workflow { return .workflow(call) }
        return call.spawnsSubagent ? .subagent(call) : .tool(call)
    }

    static func searchText(for call: ToolCall) -> String {
        let summary = call.summary
        return [
            call.name, summary.title, call.title, summary.detail, summary.command,
            summary.filePath, summary.displayOutput.map { String($0.prefix(4000)) },
        ].compactMap { $0 }.joined(separator: " ")
    }

    /// What in-conversation search reads for this row: the words a person saw, not widget state.
    var searchText: String {
        switch kind {
        case .userText(let text, _), .reasoning(let text):
            return text
        case .agentProse(let text, _):
            return text
        case .codeBlock(let language, let body):
            return "\(language ?? "") \(body)"
        case .linkRail(let urls):
            return urls.joined(separator: " ")
        case .table(let table):
            return (table.header + table.rows.flatMap { $0 }).joined(separator: " ")
        case .tableDraft(let draft):
            return draft.reading
        case .tool(let call), .subagent(let call), .workflow(let call):
            return Self.searchText(for: call)
        case .subagentGroup(let fanout):
            return fanout.members.map { Self.searchText(for: $0.call) }.joined(separator: " ")
        case .run(let steps):
            return steps.map { step -> String in
                switch step {
                case .reasoning(_, let text): return text
                case .tool(_, let call): return Self.searchText(for: call)
                }
            }.joined(separator: " ")
        case .file(let reference, _, _):
            return reference.filename ?? reference.path ?? ""
        case .pictures(let pictures):
            return pictures.map { $0.reference.filename ?? $0.reference.path ?? "" }
                .joined(separator: " ")
        case .taskBoard(let board):
            return board.items.map(\.subject).joined(separator: " ")
        case .compaction(let compaction):
            return compaction.summary ?? ""
        case .modelSeam(let change):
            return change.line
        case .carried(let reading):
            return reading.line
        case .designBoard(let sighting):
            let reading = DesignCardReading.make(sighting: sighting, board: nil)
            return "\(reading.title) \(reading.detail)"
        case .answerless(let turn):
            return "\(turn.title) \(turn.detail)"
        case .failedTurn(let turn):
            return "\(turn.title) \(turn.detail) \(turn.reason)"
        case .responseStats(let stats):
            return stats.spoken
        case .queuedSend(let row, _, _):
            return row.title
        case .queuePaused(let count):
            return QueueReading.pausedLine(count: count)
        case .pendingSend(let send, let plan, let now):
            guard let plan else { return PendingSendReading.spoken(send, now: now) }
            return ResumeReading.spoken(plan, words: send.text, now: now)
        case .interruptedTurn(let turn):
            return "\(turn.title) \(turn.prompt)"
        case .note(let note):
            return TranscriptNoteReading.read(note).text
        case .providerRetry(let card):
            return card.spoken
        case .revertBanner(let banner, _):
            return banner.spoken
        case .revertPending:
            return RevertReading.undoingTitle
        case .brain:
            return ""
        case .interruption:
            return "interrupted"
        case .turnBreak:
            return ""
        }
    }
}
