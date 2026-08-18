import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// What a row needs from the window that is not in the row itself: which rows are open, the
/// pictures and subagent transcripts already fetched, and the callbacks that fetch more. Rows are
/// rebuilt freely; this survives them.
final class TranscriptContext: @unchecked Sendable {
    var expanded = TranscriptExpansion()
    /// The newest text of a thought that is still being written. A reasoning row's header counts
    /// its words, so it changes on every arrival — and rebuilding the row for that is a flicker.
    /// The row is updated in place instead, and a body opened afterwards reads the current text
    /// from here rather than the one its closure was built with.
    var liveReasoning: [String: String] = [:]
    /// Preview textures and their original bytes and pixel size. The preview is downsampled to
    /// `bubbleMaxDimension` so a transcript full of agent screenshots stays out of VRAM; the
    /// bytes are kept for the gallery's 1:1 page and the save, and the size for the caption.
    var textures: [String: UInt] = [:]
    var imageData: [String: Data] = [:]
    var imageDimensions: [String: (Int32, Int32)] = [:]
    var subagentRows: [String: [TranscriptRow]] = [:]
    /// Live facts for the agents of the running fan-out, keyed by spawning tool-use id — what an
    /// inline agent card shows for progress while its transcript is still being written.
    var agentFacts: [String: SubagentSummary] = [:]
    /// The workflow runs of this conversation, keyed by the Workflow call that started each. A run
    /// outlives its tool call by minutes, so the card reads its state from here rather than from a
    /// call that has said all it will say.
    var workflowRuns: [String: WorkflowRun] = [:]
    /// The clock the live parts of a workflow card are drawn against, moved by the pane's ticker so
    /// every spinner and elapsed reading in one frame agrees.
    var workflowNow: Date = Date()
    var onToggle: (@Sendable (String, Bool) -> Void)?
    /// Called with a just-opened disclosure's widget bits: the pane scrolls the minimum needed to
    /// show the opened body, never past the point where the clicked header would leave the top.
    var revealRow: (@Sendable (UInt) -> Void)?
    var requestImage: (@Sendable (FileReference, String) -> Void)?
    var requestSubagent: (@Sendable (ToolCall) -> Void)?
    /// A workflow agent is fetched by its own id: it has no spawning call to name it.
    var requestWorkflowAgent: (@Sendable (String) -> Void)?
    var openImage: (@Sendable (String, String) -> Void)?
    var presentText:
        (@Sendable (_ title: String, _ subtitle: String?, _ body: String, _ mono: Bool) -> Void)?
    /// A short confirmation the window floats over everything — "Command copied".
    var toast: (@Sendable (String) -> Void)?
    /// The words of a turn that said nothing, sent again — the pane's own send, so the retry is a
    /// message like any other rather than a second road into the backend.
    var askAgain: (@Sendable (String) -> Void)?
    /// A board of design alternatives, opened. The pane owns it because reading the mocks is the
    /// server's file route and building one is the pane's own send.
    var openDesign: (@Sendable (DesignSource) -> Void)?
    /// What each board in this transcript turned out to be, so its card can name it rather than
    /// its folder. Filled by the pane the first time a card asks.
    var designBoards: [String: DesignManifest] = [:]
    var requestDesignBoard: (@Sendable (String) -> Void)?
    /// A message still waiting behind the running turn, opened for rewriting. It is the one row in
    /// a transcript that has not happened yet, so it is the one row a press means something on.
    var editQueued: (@Sendable (UUID) -> Void)?
    var pendingAct: (@Sendable (UUID, PendingSend.Act) -> Void)?
    /// A turn the server's machine cut off, picked back up or let go on that machine. Both go
    /// through the pane, which is the one place that knows which conversation is being looked at.
    var resumeInterrupted: (@Sendable () -> Void)?
    var dismissInterrupted: (@Sendable () -> Void)?
    /// The gallery's ear while it is open: a page whose texture was still being fetched repaints
    /// the moment ``store(textureBits:data:forKey:)`` lands it.
    var onImageStored: (@Sendable (String) -> Void)?
    private var textureOrder: [String] = []

    /// A run reads as open when any step inside it is, so folding a step into a run carries the
    /// reader's decision in with it rather than collapsing it.
    func isExpanded(_ key: String) -> Bool { expanded.reads(key) }

    /// The longest side a transcript picture is kept at. A 4K screenshot downsampled to this
    /// side is ~10 MB of texture instead of ~33 MB, and the 1:1 pixel view never touches the
    /// cache — the gallery decodes the original for the page it is showing, one at a time.
    static let bubbleMaxDimension: Int32 = 1600

    private static let textureByteCap = 256 * 1024 * 1024
    private var previewBytes: [String: Int] = [:]
    private var cachedBytes = 0

    /// Decoded pictures are kept across chat switches, bounded: past the cap the least recently
    /// decoded is released — its bytes are still on disk, one frame away. The bound is on
    /// preview texture bytes, not a count, because what it protects is VRAM: one giant
    /// screenshot and one small logo are not the same cost.
    func store(textureBits: UInt, data: Data, dimensions: (Int32, Int32), forKey key: String) {
        if let existing = textures[key], existing != 0,
            let stale = OpaquePointer(bitPattern: Int(bitPattern: existing))
        {
            g_object_unref(UnsafeMutableRawPointer(stale))
        }
        textures[key] = textureBits
        imageData[key] = data
        imageDimensions[key] = dimensions
        let preview = Self.previewBytes(dimensions)
        previewBytes[key] = preview
        cachedBytes += preview
        onImageStored?(key)
        textureOrder.removeAll { $0 == key }
        textureOrder.append(key)
        while cachedBytes > Self.textureByteCap, let evicted = textureOrder.first {
            textureOrder.removeFirst()
            if let bits = textures[evicted], bits != 0,
                let texture = OpaquePointer(bitPattern: Int(bitPattern: bits))
            {
                g_object_unref(UnsafeMutableRawPointer(texture))
            }
            textures[evicted] = nil
            imageData[evicted] = nil
            imageDimensions[evicted] = nil
            cachedBytes -= previewBytes[evicted] ?? 0
            previewBytes[evicted] = nil
        }
    }

    /// What a preview of `dimensions` costs in VRAM at `bubbleMaxDimension`.
    private static func previewBytes(_ dimensions: (Int32, Int32)) -> Int {
        let scale =
            min(1, Double(bubbleMaxDimension) / Double(max(1, max(dimensions.0, dimensions.1))))
        let width = max(1, Int(Double(dimensions.0) * scale))
        let height = max(1, Int(Double(dimensions.1) * scale))
        return width * height * 4
    }
}

/// Folds messages into rows with a per-message memo: a streamed token changes one message, so
/// re-deriving the other two hundred and ninety-nine — markdown and all — on every state was the
/// seconds-long silence between "Loading…" and the transcript. Only messages whose value actually
/// changed are re-folded; a palette change invalidates everything, because the markup carries the
/// palette's colors baked in.
final class TranscriptRowBuilder: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: (message: ChatMessage, rows: [TranscriptRow])] = [:]
    private var paletteName = ""

    func rows(for messages: [ChatMessage]) -> [TranscriptRow] {
        lock.lock()
        defer { lock.unlock() }
        let palette = MatrixTheme.palette.name
        if palette != paletteName {
            cache.removeAll(keepingCapacity: true)
            paletteName = palette
        }
        var all: [TranscriptRow] = []
        var next: [String: (message: ChatMessage, rows: [TranscriptRow])] = [:]
        next.reserveCapacity(messages.count)
        let writing = messages.last?.id
        var prompt: ChatMessage?
        for message in messages {
            let rows: [TranscriptRow]
            if let hit = cache[message.id], hit.message == message {
                rows = hit.rows
            } else {
                rows = TranscriptRow.rows(
                    for: message, prompt: prompt, cacheMarkup: message.id != writing)
            }
            if message.role == .user { prompt = message }
            next[message.id] = (message, rows)
            guard !rows.isEmpty else { continue }
            if message.role == .user, !all.isEmpty {
                all.append(TranscriptRow(key: "break:\(message.id)", kind: .turnBreak))
            }
            all += rows
        }
        cache = next
        all = TranscriptRow.placeBoard(in: all)
        return Preferences.compactTools ? TranscriptRow.fuse(all) : all
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
        case userText(String)
        case interruption
        /// The markup rides in the row, computed where the rows are computed — off the GLib main
        /// context — so painting a prose row is a label set, not a markdown parse. The palette's
        /// colors are baked into it, which is what makes a theme change a row change the diff sees.
        case agentProse(text: String, markup: String)
        case codeBlock(language: String?, body: String)
        case table(MarkdownTable)
        case reasoning(String)
        case tool(ToolCall)
        case run([ActivityStep])
        case subagent(ToolCall)
        case workflow(ToolCall)
        case file(FileReference, mine: Bool)
        /// A board of design alternatives the agent wrote, standing where the manifest that made it
        /// was written rather than as a line about a file.
        case designBoard(DesignSighting)
        case taskBoard(TaskBoard)
        case compaction(Compaction)
        case answerless(AnswerlessTurn)
        /// What the answer above it took, drawn only where the reader asked for it.
        case responseStats(ResponseStats)
        /// Written, not sent: a prompt waiting behind the turn that is running.
        case queuedSend(QueuedSend, position: Int, of: Int)
        case pendingSend(PendingSend)
        /// Not ``interruption``, which is the escape key: this is the machine stopping mid-answer.
        case interruptedTurn(InterruptedTurn)
        case turnBreak
    }

    let key: String
    let kind: Kind

    static func searchText(for call: ToolCall) -> String {
        let summary = call.summary
        return [
            call.name, summary.title, call.title, summary.detail, summary.command,
            summary.filePath, summary.displayOutput.map { String($0.prefix(4000)) },
        ].compactMap { $0 }.joined(separator: " ")
    }

    /// The CLI records an Escape as a user line reading `[Request interrupted by user]` (or
    /// `… for tool use]`, sometimes with the next real prompt appended). That is a seam in the
    /// turn, not something the person said — it renders as a dim marker, and only the text they
    /// actually typed gets a prompt row.
    static func strippedInterruption(_ text: String) -> (interrupted: Bool, remainder: String) {
        guard text.hasPrefix("[Request interrupted") else { return (false, text) }
        guard let close = text.firstIndex(of: "]") else { return (true, "") }
        let remainder = String(text[text.index(after: close)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (true, remainder)
    }

    /// - Parameter cacheMarkup: whether the prose this message renders is worth remembering. The
    ///   message a turn is currently writing into is a different string on every arrival, so
    ///   remembering its markup fills the memo with a thousand prefixes of one answer and evicts
    ///   the settled segments the memo exists for.
    static func rows(
        for message: ChatMessage, prompt: ChatMessage? = nil, cacheMarkup: Bool = true
    ) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        for part in message.parts {
            let key = "\(message.id):\(part.id)"
            switch part.kind {
            case .text(let text):
                let stripped = AgentMarkup.strip(text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !stripped.isEmpty else { continue }
                if message.role == .user {
                    let (interrupted, remainder) = Self.strippedInterruption(stripped)
                    if interrupted {
                        rows.append(TranscriptRow(key: "\(key):int", kind: .interruption))
                    }
                    if !remainder.isEmpty {
                        rows.append(TranscriptRow(key: key, kind: .userText(remainder)))
                    }
                    continue
                }
                for (index, segment) in MessageSegment.split(stripped).enumerated() {
                    switch segment {
                    case .prose(let prose):
                        let palette = MatrixTheme.palette
                        rows.append(
                            TranscriptRow(
                                key: "\(key):s\(index)",
                                kind: .agentProse(
                                    text: prose,
                                    markup: PangoMarkdown.render(
                                        prose, dim: palette.textDim, code: palette.info,
                                        accent: palette.accent, cache: cacheMarkup))))
                    case .code(let language, let body):
                        rows.append(
                            TranscriptRow(
                                key: "\(key):s\(index)",
                                kind: .codeBlock(language: language, body: body)))
                    case .table(let table):
                        rows.append(TranscriptRow(key: "\(key):s\(index)", kind: .table(table)))
                    }
                }
            case .reasoning(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                rows.append(TranscriptRow(key: key, kind: .reasoning(trimmed)))
            case .tool(let call):
                if call.asksUserQuestion, call.isAwaitingAnswer { continue }
                let kind: Kind
                if let sighting = DesignReading.sighting(of: call, in: message) {
                    kind = .designBoard(sighting)
                } else if call.summaryKind == .workflow {
                    kind = .workflow(call)
                } else {
                    kind = call.spawnsSubagent ? .subagent(call) : .tool(call)
                }
                rows.append(TranscriptRow(key: key, kind: kind))
            case .file(let reference):
                rows.append(
                    TranscriptRow(key: key, kind: .file(reference, mine: message.role == .user)))
            case .compaction(let compaction):
                rows.append(TranscriptRow(key: key, kind: .compaction(compaction)))
            case .unknown:
                continue
            }
        }
        if let answerless = AnswerlessTurnReading.read(message, prompt: prompt) {
            rows.append(
                TranscriptRow(key: "\(message.id):answerless", kind: .answerless(answerless)))
        }
        if Preferences.responseStats, !rows.isEmpty,
            let stats = ResponseStats(turn: message, promptedAt: prompt?.createdAt)
        {
            rows.append(
                TranscriptRow(key: "\(message.id):stats", kind: .responseStats(stats)))
        }
        return rows
    }

    /// Rows for a whole transcript, with a hairline between turns so the reading rhythm survives
    /// density.
    static func rows(for messages: [ChatMessage]) -> [TranscriptRow] {
        var all: [TranscriptRow] = []
        var prompt: ChatMessage?
        for message in messages {
            let rows = Self.rows(for: message, prompt: prompt)
            if message.role == .user { prompt = message }
            guard !rows.isEmpty else { continue }
            if message.role == .user, !all.isEmpty {
                all.append(TranscriptRow(key: "break:\(message.id)", kind: .turnBreak))
            }
            all += rows
        }
        all = placeBoard(in: all)
        return Preferences.compactTools ? fuse(all) : all
    }

    /// The agent's plan shows once: the last call that moved the to-do list becomes the board —
    /// the fold of every board call before it — and every earlier one stays the one-line tool row
    /// it was, so a long run reads as one plan updating rather than twenty snapshots.
    ///
    /// The row keeps one identity wherever it lands. Naming it after the call it is standing on
    /// re-identified the whole card every time the agent revised its plan: a delete and an insert
    /// where a person sees one card counting up, and on a keyed diff a move rather than a repaint.
    /// There is only ever one board in a transcript, so it can simply say so.
    static func placeBoard(in rows: [TranscriptRow]) -> [TranscriptRow] {
        let calls = rows.compactMap { row -> ToolCall? in
            guard case .tool(let call) = row.kind, TaskBoard.isBoardCall(call.name) else {
                return nil
            }
            return call
        }
        let board = TaskBoard.fold(calls)
        guard !board.isEmpty, let anchor = calls.last?.id else { return rows }
        return rows.map { row in
            guard case .tool(let call) = row.kind, call.id == anchor else { return row }
            return TranscriptRow(key: Self.boardKey, kind: .taskBoard(board))
        }
    }

    /// One board, one identity.
    static let boardKey = "board"

    /// Compact mode: everything the agent did between two messages — the thoughts and the tool
    /// calls, failures included — folds to one line. Twelve greps, four edits and the thinking
    /// around them are one fact: "it worked". The run keeps every step inside it, one tap away;
    /// only what is its own card (a subagent, a workflow, a picture) never joins a run, and a run
    /// with no tools stays its own thought rows so a lone reflection still reads as one.
    ///
    /// Those thought rows get one key each, suffixed by their position in the run the way a run's
    /// own body names its steps. A run's key is the key of the row that opened it, and handing that
    /// one key to every thought in a tool-less stretch made two rows the same row to everything
    /// downstream: the diff's anchor resolved to the first of them and tore the tail down on every
    /// arrival, only the first animated its entrance, and opening one thought opened all of them.
    static func fuse(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        var fused: [TranscriptRow] = []
        var run: [ActivityStep] = []
        var runKey = ""

        func flush() {
            guard !run.isEmpty else { return }
            let tools = run.compactMap { step -> ToolCall? in
                if case .tool(_, let call) = step { return call }
                return nil
            }
            if tools.isEmpty {
                for step in run {
                    if case .reasoning(let key, let text) = step {
                        fused.append(TranscriptRow(key: key, kind: .reasoning(text)))
                    }
                }
            } else if tools.count == 1, run.count == 1 {
                fused.append(TranscriptRow(key: "run:\(runKey)", kind: .tool(tools[0])))
            } else {
                fused.append(TranscriptRow(key: "run:\(runKey)", kind: .run(run)))
            }
            run = []
        }

        for row in rows {
            switch row.kind {
            case .tool(let call):
                if run.isEmpty { runKey = row.key }
                run.append(.tool(key: row.key, call))
            case .reasoning(let text):
                if run.isEmpty { runKey = row.key }
                run.append(.reasoning(key: row.key, text))
            default:
                flush()
                fused.append(row)
            }
        }
        flush()
        return fused
    }

    /// The text the agent is still writing into, when this row is the kind that grows a character
    /// at a time. Everything else — a tool call, a picture, a seam — arrives whole and has nothing
    /// for the cascade to pace.
    var streamedText: String? {
        switch kind {
        case .agentProse(let text, _): return text
        case .codeBlock(_, let body): return body
        default: return nil
        }
    }

    /// Whether the text this row streams is prose, whose half-open inline markdown the gate has to
    /// hold back, or code, which has none of it to protect and everything to lose by being judged
    /// as if it did: `**kwargs`, `*ptr`, `self._value` and an odd count of backticks in a comment
    /// are all unclosed markdown tokens and all ordinary syntax, so a code block read through the
    /// gate freezes behind the first one, dumps when the gate gives up, and freezes again.
    var streamsMarkdown: Bool {
        if case .codeBlock = kind { return false }
        return true
    }

    /// Whether this row's arrival is worth a fade. A prompt the person typed has been on screen
    /// since they pressed Enter — it is echoed locally and only later confirmed by the server under
    /// the server's own key — so animating it, and the turn break above it, blinks the words they
    /// just wrote out of the transcript and fades them back in.
    var announcesArrival: Bool {
        switch kind {
        case .userText, .turnBreak: return false
        default: return true
        }
    }

    /// The same row with only the part of its text that has been revealed. The markup is rebuilt
    /// uncached: a growing prefix is a new string sixty times a second and none of them will ever
    /// be asked for again.
    func truncated(to visible: String) -> TranscriptRow {
        switch kind {
        case .agentProse:
            let palette = MatrixTheme.palette
            return TranscriptRow(
                key: key,
                kind: .agentProse(
                    text: visible,
                    markup: PangoMarkdown.render(
                        visible, dim: palette.textDim, code: palette.info,
                        accent: palette.accent, cache: false)))
        case .codeBlock(let language, _):
            return TranscriptRow(key: key, kind: .codeBlock(language: language, body: visible))
        default:
            return self
        }
    }

    /// What in-conversation search reads for this row: the words a person saw, not widget state.
    var searchText: String {
        switch kind {
        case .userText(let text), .reasoning(let text):
            return text
        case .agentProse(let text, _):
            return text
        case .codeBlock(let language, let body):
            return "\(language ?? "") \(body)"
        case .table(let table):
            return (table.header + table.rows.flatMap { $0 }).joined(separator: " ")
        case .tool(let call), .subagent(let call), .workflow(let call):
            return Self.searchText(for: call)
        case .run(let steps):
            return steps.map { step -> String in
                switch step {
                case .reasoning(_, let text): return text
                case .tool(_, let call): return Self.searchText(for: call)
                }
            }.joined(separator: " ")
        case .file(let reference, _):
            return reference.filename ?? reference.path ?? ""
        case .designBoard(let sighting):
            let reading = DesignCardReading.make(sighting: sighting, board: nil)
            return "\(reading.title) \(reading.detail)"
        case .taskBoard(let board):
            return board.items.map(\.subject).joined(separator: " ")
        case .compaction(let compaction):
            return compaction.summary ?? ""
        case .answerless(let turn):
            return "\(turn.title) \(turn.detail)"
        case .responseStats(let stats):
            return stats.spoken
        case .queuedSend(let send, _, _):
            return SendQueueReading.rowTitle(send)
        case .pendingSend(let send):
            return PendingSendReading.spoken(send, now: Date())
        case .interruptedTurn(let turn):
            return "\(turn.title) \(turn.prompt)"
        case .interruption:
            return "interrupted"
        case .turnBreak:
            return ""
        }
    }

    func makeWidget(context: TranscriptContext) -> UnsafeMutablePointer<GtkWidget> {
        switch kind {
        case .userText(let text):
            return Self.prompt(text)
        case .interruption:
            let label = Gtk.label(
                "⌧ " + Localized.text("interrupted"), css: "interruption", selectable: false)
            gtk_widget_set_halign(label, GTK_ALIGN_START)
            return label
        case .agentProse(_, let markup):
            return Gtk.markupLabel(markup, css: "agent-text")
        case .codeBlock(let language, let body):
            return Self.codeBlock(language: language, body: body, context: context)
        case .table(let table):
            return Self.table(table)
        case .reasoning(let text):
            return Self.reasoning(text, key: key, context: context)
        case .tool(let call):
            return ToolRowView.make(call, key: key, context: context)
        case .run(let steps):
            return ToolRowView.makeRun(steps, key: key, context: context)
        case .subagent(let call):
            return SubagentRowView.make(call, key: key, context: context)
        case .workflow(let call):
            return WorkflowCardView.make(call, key: key, context: context)
        case .file(let reference, let mine):
            return Self.filePart(reference, mine: mine, key: key, context: context)
        case .designBoard(let sighting):
            return Self.designBoard(sighting, context: context)
        case .taskBoard(let board):
            return TaskBoardView.make(board)
        case .compaction(let compaction):
            return Self.seam(compaction, key: key, context: context)
        case .answerless(let turn):
            return Self.answerless(turn, context: context)
        case .responseStats(let stats):
            return Self.responseStats(stats)
        case .queuedSend(let send, let position, let total):
            return Self.queuedSend(send, position: position, of: total, context: context)
        case .pendingSend(let send):
            return Self.pendingSend(send, context: context)
        case .interruptedTurn(let turn):
            return Self.interruptedTurn(turn, context: context)
        case .turnBreak:
            let rule = Gtk.hairline()
            Gtk.margins(rule, top: 10, bottom: 10)
            return rule
        }
    }

    private static func prompt(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let rule = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(rule, "prompt-rule")
        gtk_widget_set_size_request(rule, 2, -1)
        let label = Gtk.markupLabel(
            PangoMarkdown.plainWithLinks(text, accent: MatrixTheme.palette.accent),
            css: "prompt-text")
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(row), rule)
        gtk_box_append(ptr(row), label)
        return row
    }

    /// Markdown as the transcript renders it — headings, emphasis, lists, links, fenced code with
    /// its own copy — for prose that lives outside the transcript: a compaction summary in the
    /// reader, where the CLI's own formatting is the only structure the text has.
    static func richBody(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        let palette = MatrixTheme.palette
        for segment in MessageSegment.split(text) {
            switch segment {
            case .prose(let prose):
                for chunk in paragraphChunks(prose) {
                    let markup = PangoMarkdown.render(
                        chunk, dim: palette.textDim, code: palette.info, accent: palette.accent)
                    gtk_box_append(ptr(column), Gtk.markupLabel(markup, css: "agent-text"))
                }
            case .code(let language, let body):
                gtk_box_append(ptr(column), codeBlock(language: language, body: body, context: nil))
            case .table(let table):
                gtk_box_append(ptr(column), Self.table(table))
            }
        }
        return column
    }

    /// A pipe table as columns: GtkGrid does the sizing, a hairline seats the header, and every
    /// cell is a wrapping label carrying its inline markdown — so a wide table folds its longest
    /// column instead of running out of the pane.
    static func table(_ table: MarkdownTable) -> UnsafeMutablePointer<GtkWidget> {
        let palette = MatrixTheme.palette
        let widget = gtk_grid_new()!
        let grid: UnsafeMutablePointer<GtkGrid> = ptr(UnsafeMutableRawPointer(widget))
        Gtk.addClass(widget, "md-table")
        gtk_grid_set_column_spacing(grid, 16)
        gtk_grid_set_row_spacing(grid, 3)
        gtk_widget_set_halign(widget, GTK_ALIGN_START)

        func cell(_ text: String, header: Bool, column: Int) -> UnsafeMutablePointer<GtkWidget> {
            let inline = PangoMarkdown.inline(text, code: palette.info, accent: palette.accent)
            let label = Gtk.markupLabel(
                header ? "<b>\(inline)</b>" : inline,
                css: header ? "md-table-header" : "md-table-cell")
            gtk_label_set_max_width_chars(op(label), 40)
            gtk_widget_set_halign(label, GTK_ALIGN_FILL)
            gtk_widget_set_valign(label, GTK_ALIGN_START)
            switch table.alignment(of: column) {
            case .leading: gtk_label_set_xalign(op(label), 0)
            case .center: gtk_label_set_xalign(op(label), 0.5)
            case .trailing: gtk_label_set_xalign(op(label), 1)
            }
            return label
        }

        for (column, title) in table.header.enumerated() {
            gtk_grid_attach(grid, cell(title, header: true, column: column), Int32(column), 0, 1, 1)
        }
        let rule = Gtk.spanningHairline()
        Gtk.margins(rule, top: 2, bottom: 2)
        gtk_grid_attach(grid, rule, 0, 1, Int32(table.columnCount), 1)
        for row in table.rows.indices {
            for (column, text) in table.cells(in: row).enumerated() {
                gtk_grid_attach(
                    grid, cell(text, header: false, column: column),
                    Int32(column), Int32(row + 2), 1, 1)
            }
        }
        return widget
    }

    /// Bounded labels: one Pango layout over forty thousand words takes a visible pause to
    /// measure, so prose breaks at blank lines into pieces each small enough to lay out in a
    /// frame, and the reading is unchanged.
    static func paragraphChunks(_ prose: String, limit: Int = 3000) -> [String] {
        guard prose.count > limit else { return [prose] }
        var chunks: [String] = []
        var current: [String] = []
        var size = 0
        for paragraph in prose.components(separatedBy: "\n\n") {
            if size > 0, size + paragraph.count > limit {
                chunks.append(current.joined(separator: "\n\n"))
                current = []
                size = 0
            }
            current.append(paragraph)
            size += paragraph.count + 2
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n\n")) }
        return chunks
    }

    private static func codeBlock(
        language: String?, body: String, context: TranscriptContext?
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(column, "code-block")

        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let tag = Gtk.label(
            SyntaxHighlighter.displayName(for: language, source: body), css: "code-header",
            selectable: false)
        gtk_widget_set_hexpand(tag, 1)
        gtk_box_append(ptr(header), tag)
        let bytes = body
        let toast = context?.toast
        gtk_box_append(
            ptr(header),
            Gtk.button(Localized.text("copy"), css: ["flat", "code-copy"]) {
                Gtk.copyToClipboard(bytes)
                toast?(Localized.text("Code copied"))
            })
        gtk_box_append(ptr(column), header)

        let text = Gtk.markupLabel(
            PangoSyntax.render(body, language: language, palette: MatrixTheme.palette),
            css: "code-body", wrap: false)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_propagate_natural_width(op(scroller), 0)
        // A block short enough to read whole is drawn whole; only a long one is held to a
        // screenful, and that height is stated rather than inferred.
        if !TranscriptBlocks.fitsInline(body) {
            let height = Int32(TranscriptBlocks.cappedHeight)
            gtk_scrolled_window_set_min_content_height(op(scroller), height)
            gtk_scrolled_window_set_max_content_height(op(scroller), height)
        }
        gtk_scrolled_window_set_child(op(scroller), text)
        gtk_box_append(ptr(column), scroller)
        return column
    }

    static func reasoning(_ text: String, key: String, context: TranscriptContext)
        -> UnsafeMutablePointer<GtkWidget>
    {
        context.liveReasoning[key] = text
        let header = Gtk.label(Self.thoughtHeader(text), css: "reasoning-label", selectable: false)
        let toggle = context.onToggle
        let reveal = context.revealRow
        return Gtk.disclosure(
            header: header, expanded: context.isExpanded(key),
            onToggle: { open, bits in
                toggle?(key, open)
                if open { reveal?(bits) }
            }
        ) { [weak context] in
            let body = Gtk.label(
                context?.liveReasoning[key] ?? text, css: "reasoning-body", wrap: true)
            Gtk.margins(body, leading: 14)
            return body
        }
    }

    static func thoughtHeader(_ text: String) -> String {
        Localized.text("Thought · %@ words", "\(text.split(separator: " ").count)")
    }

    /// A thought growing under its own disclosure, written into the widget it already has. The
    /// header counts words, so it changes with every arrival; tearing the row down and building it
    /// again twenty times a second is the flicker, not the counting.
    static func restateReasoning(
        _ widget: UnsafeMutablePointer<GtkWidget>, text: String, key: String,
        context: TranscriptContext
    ) -> Bool {
        func isLabel(_ candidate: UnsafeMutablePointer<GtkWidget>) -> Bool {
            let instance = UnsafeMutableRawPointer(candidate).assumingMemoryBound(
                to: GTypeInstance.self)
            return g_type_check_instance_is_a(instance, gtk_label_get_type()) != 0
        }
        guard let button = gtk_widget_get_first_child(widget),
            let header = Gtk.disclosureHeader(button), isLabel(header)
        else { return false }
        context.liveReasoning[key] = text
        gtk_label_set_text(op(header), thoughtHeader(text))
        if let body = gtk_widget_get_next_sibling(button), isLabel(body) {
            gtk_label_set_text(op(body), text)
        }
        return true
    }

    /// A thumbnail, not a poster: the transcript is for reading, and a picture in it is a
    /// reference — small, scaled to fit, one click from the full-window viewer. Until the bytes
    /// arrive, the placeholder holds a thumbnail-sized space so the arrival replaces it instead
    /// of shoving everything below it down — the difference between a photo developing and a
    /// transcript twitching.
    private static func filePart(
        _ reference: FileReference, mine: Bool, key: String, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let name = reference.filename ?? reference.path.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? "file"
        let isImage = (reference.mime ?? "").hasPrefix("image/")
        guard isImage else {
            return Gtk.label("📎 \(name)", css: "attachment")
        }
        let thumbWidth = Int32(ImagePreview.deskBound(ImagePreview.deskWidth, mine: mine))
        let thumbHeight = Int32(ImagePreview.deskBound(ImagePreview.deskHeight, mine: mine))
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        if let bits = context.textures[key], bits != 0 {
            let texture = OpaquePointer(bitPattern: Int(bitPattern: bits))
            let picture = tailscode_picture_for_texture(texture)!
            let width = tailscode_texture_width(texture)
            let height = tailscode_texture_height(texture)
            let scale = min(
                Double(thumbWidth) / Double(max(1, width)),
                Double(thumbHeight) / Double(max(1, height)), 1)
            gtk_picture_set_content_fit(op(picture), GTK_CONTENT_FIT_CONTAIN)
            gtk_widget_set_size_request(
                picture, Int32(Double(width) * scale), Int32(Double(height) * scale))
            Gtk.addClass(picture, "image-part")
            let opener = gtk_button_new()!
            Gtk.addClass(opener, "flat")
            gtk_widget_set_halign(opener, GTK_ALIGN_START)
            gtk_button_set_child(ptr(opener), picture)
            let open = context.openImage
            Gtk.connect(UnsafeMutableRawPointer(opener), "clicked") {
                open?(key, name)
            }
            gtk_box_append(ptr(column), opener)
            let dims = context.imageDimensions[key] ?? (width, height)
            gtk_box_append(
                ptr(column),
                Gtk.label("\(name) · \(dims.0)×\(dims.1)", css: "row-detail", selectable: false))
        } else {
            let frame = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            Gtk.addClass(frame, "image-part")
            gtk_widget_set_size_request(frame, thumbWidth, thumbHeight)
            gtk_widget_set_halign(frame, GTK_ALIGN_START)
            let label = Gtk.label(
                Localized.text("🖼 %@ — loading…", name), css: "dim", selectable: false)
            gtk_widget_set_halign(label, GTK_ALIGN_CENTER)
            gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
            gtk_widget_set_vexpand(label, 1)
            gtk_box_append(ptr(frame), label)
            gtk_box_append(ptr(column), frame)
            context.requestImage?(reference, key)
        }
        return column
    }

    /// A compaction is a seam, not a message: the rule says the transcript restarted here, and the
    /// card says what was traded for what — the trade in tokens, the sliver of context the summary
    /// still occupies drawn as a bar, and what carried over. The CLI's machine-facing summary —
    /// tens of thousands of words — opens in a reader window rather than cramped into the flow.
    private static func seam(
        _ compaction: Compaction, key: String, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let story = CompactionStory.done(compaction)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        gtk_box_append(ptr(column), Gtk.hairline())

        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "card")
        Gtk.addClass(card, "card-compaction")

        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(heading), Gtk.label("◆", css: "glyph-done", selectable: false))
        let title = Gtk.label(story.title, css: "card-title", wrap: true, selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_halign(title, GTK_ALIGN_START)
        gtk_box_append(ptr(heading), title)
        gtk_box_append(ptr(card), heading)

        let detail = Gtk.label(story.detail, css: "tool-detail", wrap: true, selectable: false)
        gtk_widget_set_halign(detail, GTK_ALIGN_START)
        gtk_box_append(ptr(card), detail)

        if let kept = story.keptFraction {
            let bar = gtk_progress_bar_new()!
            Gtk.addClass(bar, "seam-bar")
            gtk_progress_bar_set_fraction(op(bar), kept)
            gtk_box_append(ptr(card), bar)
        }

        if let footnote = story.footnote {
            let label = Gtk.label(footnote, css: "seam-footnote", wrap: true, selectable: false)
            gtk_widget_set_halign(label, GTK_ALIGN_START)
            gtk_box_append(ptr(card), label)
        }

        if let summary = story.summary, story.isReadable {
            let present = context.presentText
            let header = CompactionStory.summaryHeader(compaction)
            let read = Gtk.button(Localized.text("Read the summary"), css: ["flat", "seam-read"]) {
                present?(Localized.text("Compaction summary"), header, summary, false)
            }
            gtk_widget_set_halign(read, GTK_ALIGN_START)
            gtk_box_append(ptr(card), read)
        }

        gtk_box_append(ptr(column), card)
        gtk_box_append(ptr(column), Gtk.hairline())
        return column
    }

    /// A prompt that has been written and not sent, drawn as the prompt it will become — same
    /// accent rule, same words — but dimmed, marked, and pressable, because it is the one row in
    /// the transcript that is still the reader's to change. Nothing about it may read as sent.
    private static func queuedSend(
        _ send: QueuedSend, position: Int, of total: Int, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let rule = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(rule, "prompt-rule")
        Gtk.addClass(rule, "queued-rule")
        gtk_widget_set_size_request(rule, 2, -1)

        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        let label = Gtk.label(
            "\(SendQueueReading.glyph) \(SendQueueReading.rowTitle(send))", css: "prompt-text",
            wrap: true)
        gtk_label_set_xalign(op(label), 0)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(lines), label)
        gtk_box_append(
            ptr(lines), Gtk.label(SendQueueReading.hint, css: "queued-hint", selectable: false))
        gtk_widget_set_hexpand(lines, 1)

        gtk_box_append(ptr(row), rule)
        gtk_box_append(ptr(row), lines)

        guard !send.isCommand else {
            Gtk.addClass(row, "queued-row")
            return row
        }
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "queued-row")
        gtk_button_set_child(ptr(button), row)
        gtk_widget_set_hexpand(button, 1)
        gtk_widget_set_tooltip_text(button, SendQueueReading.spoken(send, position: position, of: total))
        let edit = context.editQueued
        let id = send.id
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { edit?(id) }
        return button
    }

    /// A message on its way out: the words drawn as the prompt they will become, with a line
    /// under them saying whether they went.
    ///
    /// It is the prompt's own rule and the prompt's own words because that is what it is — what
    /// is added is the one thing the transcript could never say, which is that this message is
    /// not in the server's account yet. A send that failed keeps its words right here and offers
    /// the three things worth doing about them, rather than dropping them back into a composer
    /// the reader has to notice.
    ///
    /// The caption ages on the cell's own clock: the label pointer is parked on the row so the
    /// pane's ticker can rewrite the words without tearing the widget down every second.
    static let pendingCaptionKey = "tailscode-pending-caption"
    static let pendingSendKey = "tailscode-pending-send"

    private static func pendingSend(
        _ send: PendingSend, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let now = Date()
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let rule = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(rule, "prompt-rule")
        if send.isFailed { Gtk.addClass(rule, "pending-rule-failed") }
        gtk_widget_set_size_request(rule, 2, -1)

        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        let label = Gtk.markupLabel(
            PangoMarkdown.plainWithLinks(send.text, accent: MatrixTheme.palette.accent),
            css: "prompt-text")
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(lines), label)

        let icon = PendingSendReading.icon(send)
        let status = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_halign(status, GTK_ALIGN_START)
        gtk_box_append(
            ptr(status), Gtk.label(icon.glyph, css: icon.glyphCSS, selectable: false))
        let caption = Gtk.label(
            PendingSendReading.caption(send, now: now), css: "queued-hint", selectable: false)
        gtk_box_append(ptr(status), caption)
        gtk_box_append(ptr(lines), status)

        if !send.acts.isEmpty, let act = context.pendingAct {
            let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            gtk_widget_set_halign(buttons, GTK_ALIGN_START)
            let id = send.id
            for choice in send.acts {
                gtk_box_append(
                    ptr(buttons),
                    Gtk.button(PendingSendReading.title(choice), css: ["flat", "seam-read"]) {
                        act(id, choice)
                    })
            }
            gtk_box_append(ptr(lines), buttons)
        }

        gtk_widget_set_hexpand(lines, 1)
        gtk_box_append(ptr(row), rule)
        gtk_box_append(ptr(row), lines)
        gtk_widget_set_tooltip_text(row, PendingSendReading.spoken(send, now: now))
        g_object_set_data(ptr(row), pendingCaptionKey, UnsafeMutableRawPointer(caption))
        let sendBox = Unmanaged.passRetained(PendingSendBox(send)).toOpaque()
        g_object_set_data_full(
            ptr(row), pendingSendKey, sendBox,
            { raw in
                guard let raw else { return }
                Unmanaged<PendingSendBox>.fromOpaque(raw).release()
            })
        return row
    }

    /// Ages the caption under a pending row without rebuilding it. Returns whether the row still
    /// carries a send that needs the clock.
    @discardableResult
    static func agePendingCaption(
        on row: UnsafeMutablePointer<GtkWidget>, now: Date = Date()
    ) -> Bool {
        guard let sendRaw = g_object_get_data(ptr(row), pendingSendKey),
            let captionRaw = g_object_get_data(ptr(row), pendingCaptionKey)
        else { return false }
        let send = Unmanaged<PendingSendBox>.fromOpaque(sendRaw).takeUnretainedValue().send
        let caption: UnsafeMutablePointer<GtkWidget> = ptr(captionRaw)
        gtk_label_set_text(op(caption), PendingSendReading.caption(send, now: now))
        gtk_widget_set_tooltip_text(row, PendingSendReading.spoken(send, now: now))
        switch send.phase {
        case .failed: return false
        case .sending, .accepted: return true
        }
    }

    /// What the answer above it took: one quiet strip of glyph-and-number, tooltipped with the
    /// sentence behind each figure. It is deliberately the dimmest thing in the transcript — a
    /// reader who turned it on wants it available, not competing with the answer it describes.
    private static func responseStats(
        _ stats: ResponseStats
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        Gtk.addClass(row, "response-stats")
        Gtk.margins(row, top: 2, bottom: 2, leading: 2)
        gtk_widget_set_halign(row, GTK_ALIGN_START)
        for fact in stats.facts {
            let cell = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 4)
            gtk_box_append(ptr(cell), Self.statLabel(fact.glyph, css: "response-stat-glyph"))
            gtk_box_append(ptr(cell), Self.statLabel(fact.value, css: "response-stat-value"))
            gtk_widget_set_tooltip_text(cell, "\(fact.label) — \(fact.detail)")
            gtk_box_append(ptr(row), cell)
        }
        return row
    }

    /// A figure is never abbreviated. `Gtk.label` ellipsizes by default, which is right for a name
    /// and wrong for a number — "41…" and "~<$0.0…" are not smaller readings of 410 and a
    /// hundredth of a cent, they are unreadable — so the strip keeps every character it has and
    /// lets the row be as wide as its facts.
    private static func statLabel(
        _ text: String, css: String
    ) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: css, selectable: false)
        gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
        gtk_label_set_xalign(op(label), 0)
        return label
    }

    /// A turn that finished having said nothing. It is a card rather than a prose row because
    /// there is no prose — the transcript would otherwise show the question and then simply the
    /// next thing, with the whole turn missing.
    /// A board of alternatives, offered rather than described. The letters are on the card because
    /// they are what the reader will pick by, and the whole row is the way in — a design that has
    /// to be found through a file path is a design nobody looks at.
    private static func designBoard(
        _ sighting: DesignSighting, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        var board: DesignBoard?
        if case .board(let directory) = sighting.source {
            if let manifest = context.designBoards[directory] {
                board = DesignBoard(directory: directory, manifest: manifest)
            } else {
                context.requestDesignBoard?(directory)
            }
        }
        let reading = DesignCardReading.make(sighting: sighting, board: board)
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "card")
        Gtk.addClass(card, "card-design")

        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(heading), Gtk.label("▣", css: "glyph-info", selectable: false))
        let title = Gtk.label(reading.title, css: "card-title", wrap: true, selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_halign(title, GTK_ALIGN_START)
        gtk_box_append(ptr(heading), title)
        gtk_box_append(ptr(card), heading)

        let detail = Gtk.label(reading.detail, css: "tool-detail", wrap: true, selectable: false)
        gtk_widget_set_halign(detail, GTK_ALIGN_START)
        gtk_box_append(ptr(card), detail)

        if !reading.letters.isEmpty {
            let strip = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
            for letter in reading.letters {
                gtk_box_append(
                    ptr(strip), Gtk.label(letter, css: "design-letter", selectable: false))
            }
            gtk_widget_set_halign(strip, GTK_ALIGN_START)
            gtk_box_append(ptr(card), strip)
        }

        let open = context.openDesign
        let source = sighting.source
        let button = Gtk.button(reading.action, css: ["flat", "seam-read"]) { open?(source) }
        gtk_widget_set_halign(button, GTK_ALIGN_START)
        gtk_box_append(ptr(card), button)
        return card
    }

    private static func answerless(
        _ turn: AnswerlessTurn, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "card")
        Gtk.addClass(card, "card-answerless")

        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(
            ptr(heading),
            Gtk.label(AnswerlessTurn.glyph, css: AnswerlessTurn.tone.glyphCSS, selectable: false))
        let title = Gtk.label(turn.title, css: "card-title", wrap: true, selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_halign(title, GTK_ALIGN_START)
        gtk_box_append(ptr(heading), title)
        gtk_box_append(ptr(card), heading)

        let detail = Gtk.label(turn.detail, css: "tool-detail", wrap: true, selectable: false)
        gtk_widget_set_halign(detail, GTK_ALIGN_START)
        gtk_box_append(ptr(card), detail)

        if turn.offersRemedy {
            let askAgain = context.askAgain
            let words = turn.prompt
            let button = Gtk.button(turn.action, css: ["flat", "seam-read"]) {
                askAgain?(words)
            }
            gtk_widget_set_halign(button, GTK_ALIGN_START)
            gtk_box_append(ptr(card), button)
        }
        return card
    }

    /// A turn the machine was pulled out from under. The account of what the work had already done
    /// is the substance of it — a person decides between continuing and starting over on whether
    /// anything on that machine changed — so it is drawn as lines rather than as a sentence.
    private static func interruptedTurn(
        _ turn: InterruptedTurn, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "card")
        Gtk.addClass(card, "card-interrupted")

        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(
            ptr(heading),
            Gtk.label(InterruptedTurn.glyph, css: InterruptedTurn.tone.glyphCSS, selectable: false))
        let title = Gtk.label(turn.title, css: "card-title", wrap: true, selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_halign(title, GTK_ALIGN_START)
        gtk_box_append(ptr(heading), title)
        gtk_box_append(ptr(card), heading)

        if !turn.prompt.isEmpty {
            let prompt = Gtk.label(turn.prompt, css: "row-title", wrap: true, selectable: true)
            gtk_widget_set_halign(prompt, GTK_ALIGN_START)
            gtk_box_append(ptr(card), prompt)
        }

        let detail = Gtk.label(turn.detail, css: "tool-detail", wrap: true, selectable: false)
        gtk_widget_set_halign(detail, GTK_ALIGN_START)
        gtk_box_append(ptr(card), detail)

        for line in turn.progress {
            let row = Gtk.label("· \(line)", css: "row-detail", wrap: true, selectable: false)
            gtk_widget_set_halign(row, GTK_ALIGN_START)
            gtk_box_append(ptr(card), row)
        }

        if !turn.queued.isEmpty {
            let waiting = Gtk.label(
                turn.queued.count == 1
                    ? Localized.text("One prompt was waiting behind it and never ran.")
                    : Localized.text(
                        "%@ prompts were waiting behind it and never ran.", "\(turn.queued.count)"),
                css: "row-note", wrap: true, selectable: false)
            gtk_widget_set_halign(waiting, GTK_ALIGN_START)
            gtk_box_append(ptr(card), waiting)
        }

        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(buttons, GTK_ALIGN_START)
        if !turn.isResumed, let resume = context.resumeInterrupted {
            gtk_box_append(
                ptr(buttons),
                Gtk.button(turn.resumeTitle, css: ["flat", "seam-read"]) { resume() })
        }
        if let dismiss = context.dismissInterrupted {
            gtk_box_append(
                ptr(buttons), Gtk.button(turn.dismissTitle, css: ["flat"]) { dismiss() })
        }
        gtk_box_append(ptr(card), buttons)
        return card
    }
}

/// Holds a ``PendingSend`` on a GTK widget without asking the value type to be a class.
private final class PendingSendBox: @unchecked Sendable {
    let send: PendingSend
    init(_ send: PendingSend) { self.send = send }
}
