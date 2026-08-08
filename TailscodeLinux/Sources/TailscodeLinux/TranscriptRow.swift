import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// What a row needs from the window that is not in the row itself: which rows are open, the
/// pictures and subagent transcripts already fetched, and the callbacks that fetch more. Rows are
/// rebuilt freely; this survives them.
final class TranscriptContext: @unchecked Sendable {
    var expanded: Set<String> = []
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
    var requestImage: (@Sendable (FileReference, String) -> Void)?
    var requestSubagent: (@Sendable (ToolCall) -> Void)?
    /// A workflow agent is fetched by its own id: it has no spawning call to name it.
    var requestWorkflowAgent: (@Sendable (String) -> Void)?
    var openImage: (@Sendable (String, String) -> Void)?
    var presentText:
        (@Sendable (_ title: String, _ subtitle: String?, _ body: String, _ mono: Bool) -> Void)?
    /// A short confirmation the window floats over everything — "Command copied".
    var toast: (@Sendable (String) -> Void)?
    /// The gallery's ear while it is open: a page whose texture was still being fetched repaints
    /// the moment ``store(textureBits:data:forKey:)`` lands it.
    var onImageStored: (@Sendable (String) -> Void)?
    private var textureOrder: [String] = []

    func isExpanded(_ key: String) -> Bool { expanded.contains(key) }

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
        for message in messages {
            let rows: [TranscriptRow]
            if let hit = cache[message.id], hit.message == message {
                rows = hit.rows
            } else {
                rows = TranscriptRow.rows(for: message, cacheMarkup: message.id != writing)
            }
            next[message.id] = (message, rows)
            guard !rows.isEmpty else { continue }
            if message.role == .user, !all.isEmpty {
                all.append(TranscriptRow(key: "break:\(message.id)", kind: .turnBreak))
            }
            all += rows
        }
        cache = next
        return Preferences.compactTools ? TranscriptRow.fuse(all) : all
    }
}

/// One agent action in the order it happened — a thought or a tool call — folded together into a
/// run row the same way the iOS app groups them, so the three clients read the middle of a turn
/// alike.
enum ActivityStep: Hashable {
    case reasoning(String)
    case tool(ToolCall)
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
        case reasoning(String)
        case tool(ToolCall)
        case run([ActivityStep])
        case subagent(ToolCall)
        case workflow(ToolCall)
        case file(FileReference)
        case compaction(Compaction)
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
    static func rows(for message: ChatMessage, cacheMarkup: Bool = true) -> [TranscriptRow] {
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
                    }
                }
            case .reasoning(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                rows.append(TranscriptRow(key: key, kind: .reasoning(trimmed)))
            case .tool(let call):
                if call.asksUserQuestion, call.isAwaitingAnswer { continue }
                let kind: Kind
                if call.summaryKind == .workflow {
                    kind = .workflow(call)
                } else {
                    kind = call.spawnsSubagent ? .subagent(call) : .tool(call)
                }
                rows.append(TranscriptRow(key: key, kind: kind))
            case .file(let reference):
                rows.append(TranscriptRow(key: key, kind: .file(reference)))
            case .compaction(let compaction):
                rows.append(TranscriptRow(key: key, kind: .compaction(compaction)))
            case .unknown:
                continue
            }
        }
        return rows
    }

    /// Rows for a whole transcript, with a hairline between turns so the reading rhythm survives
    /// density.
    static func rows(for messages: [ChatMessage]) -> [TranscriptRow] {
        var all: [TranscriptRow] = []
        for message in messages {
            let rows = Self.rows(for: message)
            guard !rows.isEmpty else { continue }
            if message.role == .user, !all.isEmpty {
                all.append(TranscriptRow(key: "break:\(message.id)", kind: .turnBreak))
            }
            all += rows
        }
        return Preferences.compactTools ? fuse(all) : all
    }

    /// Compact mode: everything the agent did between two messages — the thoughts and the tool
    /// calls, failures included — folds to one line. Twelve greps, four edits and the thinking
    /// around them are one fact: "it worked". The run keeps every step inside it, one tap away;
    /// only what is its own card (a subagent, a workflow, a picture) never joins a run, and a run
    /// with no tools stays its own thought rows so a lone reflection still reads as one.
    static func fuse(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        var fused: [TranscriptRow] = []
        var run: [ActivityStep] = []
        var runKey = ""

        func flush() {
            guard !run.isEmpty else { return }
            let tools = run.compactMap { step -> ToolCall? in
                if case .tool(let call) = step { return call }
                return nil
            }
            if tools.isEmpty {
                for step in run {
                    if case .reasoning(let text) = step {
                        fused.append(TranscriptRow(key: runKey, kind: .reasoning(text)))
                    }
                }
            } else if tools.count == 1, run.count == 1 {
                fused.append(TranscriptRow(key: runKey, kind: .tool(tools[0])))
            } else {
                fused.append(TranscriptRow(key: "run:\(runKey)", kind: .run(run)))
            }
            run = []
        }

        for row in rows {
            switch row.kind {
            case .tool(let call):
                if run.isEmpty { runKey = row.key }
                run.append(.tool(call))
            case .reasoning(let text):
                if run.isEmpty { runKey = row.key }
                run.append(.reasoning(text))
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
        case .tool(let call), .subagent(let call), .workflow(let call):
            return Self.searchText(for: call)
        case .run(let steps):
            return steps.map { step -> String in
                switch step {
                case .reasoning(let text): return text
                case .tool(let call): return Self.searchText(for: call)
                }
            }.joined(separator: " ")
        case .file(let reference):
            return reference.filename ?? reference.path ?? ""
        case .compaction(let compaction):
            return compaction.summary ?? ""
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
        case .file(let reference):
            return Self.filePart(reference, key: key, context: context)
        case .compaction(let compaction):
            return Self.seam(compaction, key: key, context: context)
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
        let label = Gtk.label(text, css: "prompt-text", wrap: true)
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
            }
        }
        return column
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

        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).count
        let text = Gtk.markupLabel(
            PangoSyntax.render(body, language: language, palette: MatrixTheme.palette),
            css: "code-body", wrap: false)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_propagate_natural_width(op(scroller), 0)
        if lines > 18, body.count > 600 {
            gtk_scrolled_window_set_max_content_height(op(scroller), 320)
        }
        gtk_scrolled_window_set_child(op(scroller), text)
        gtk_box_append(ptr(column), scroller)
        return column
    }

    static func reasoning(_ text: String, key: String, context: TranscriptContext)
        -> UnsafeMutablePointer<GtkWidget>
    {
        context.liveReasoning[key] = text
        let header = Gtk.label(Self.thoughtHeader(text), css: "dim", selectable: false)
        let toggle = context.onToggle
        return Gtk.disclosure(
            header: header, expanded: context.isExpanded(key),
            onToggle: { open in toggle?(key, open) }
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
        _ reference: FileReference, key: String, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let name = reference.filename ?? reference.path.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? "file"
        let isImage = (reference.mime ?? "").hasPrefix("image/")
        guard isImage else {
            return Gtk.label("📎 \(name)", css: "attachment")
        }
        let thumbWidth: Int32 = 220
        let thumbHeight: Int32 = 140
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

    /// A compaction is a seam, not a message: the rule says the transcript restarted here, the
    /// line says what was traded for what, and the CLI's machine-facing summary — tens of
    /// thousands of words — opens in a reader window rather than cramped into the flow.
    private static func seam(
        _ compaction: Compaction, key: String, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_box_append(ptr(column), Gtk.hairline())

        var facts: [String] = []
        if let before = compaction.tokensBefore, let after = compaction.tokensAfter {
            facts.append("\(StatusFacts.tokens(before)) → \(StatusFacts.tokens(after))")
        }
        if let duration = compaction.duration, duration > 0 {
            facts.append(StatusFacts.clock(duration))
        }
        if let kept = compaction.preservedMessageCount {
            facts.append(Localized.text("%@ messages kept", "\(kept)"))
        }
        if compaction.trigger == .auto { facts.append(Localized.text("automatic")) }
        let title = facts.isEmpty
            ? Localized.text("COMPACTED") : "COMPACTED · " + facts.joined(separator: " · ")

        if let summary = compaction.summary, !summary.isEmpty {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
            gtk_box_append(ptr(row), Gtk.label(title, css: "seam-text", selectable: false))
            let present = context.presentText
            let facts = title
            let read = Gtk.button(Localized.text("read summary"), css: ["flat", "seam-read"]) {
                present?(Localized.text("Compaction summary"), facts, summary, false)
            }
            gtk_widget_set_valign(read, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(row), read)
            gtk_box_append(ptr(column), row)
        } else {
            gtk_box_append(ptr(column), Gtk.label(title, css: "seam-text", selectable: false))
        }
        gtk_box_append(ptr(column), Gtk.hairline())
        return column
    }
}
