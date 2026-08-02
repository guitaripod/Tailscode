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
    var textures: [String: UInt] = [:]
    var imageData: [String: Data] = [:]
    var subagentRows: [String: [TranscriptRow]] = [:]
    var onToggle: (@Sendable (String, Bool) -> Void)?
    var requestImage: (@Sendable (FileReference, String) -> Void)?
    var requestSubagent: (@Sendable (ToolCall) -> Void)?
    var openImage: (@Sendable (String, String) -> Void)?

    func isExpanded(_ key: String) -> Bool { expanded.contains(key) }
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
        for message in messages {
            let rows: [TranscriptRow]
            if let hit = cache[message.id], hit.message == message {
                rows = hit.rows
            } else {
                rows = TranscriptRow.rows(for: message)
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

/// One line of the transcript, in the CLIs' grammar: the prompt behind an accent rule, the
/// agent's answer as prose at full measure, code as blocks that copy byte-exactly, edits as
/// diffs, reasoning and tool output behind a disclosure, a compaction as a seam, a picture as
/// the picture. No bubbles — the material lives in the chrome around this.
struct TranscriptRow: Hashable {
    enum Kind: Hashable {
        case userText(String)
        /// The markup rides in the row, computed where the rows are computed — off the GLib main
        /// context — so painting a prose row is a label set, not a markdown parse. The palette's
        /// colors are baked into it, which is what makes a theme change a row change the diff sees.
        case agentProse(text: String, markup: String)
        case codeBlock(language: String?, body: String)
        case reasoning(String)
        case tool(ToolCall)
        case toolRun([ToolCall])
        case subagent(ToolCall)
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

    static func rows(for message: ChatMessage) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        for part in message.parts {
            let key = "\(message.id):\(part.id)"
            switch part.kind {
            case .text(let text):
                let stripped = AgentMarkup.strip(text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !stripped.isEmpty else { continue }
                if message.role == .user {
                    rows.append(TranscriptRow(key: key, kind: .userText(stripped)))
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
                                        accent: palette.accent))))
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
                rows.append(
                    TranscriptRow(
                        key: key, kind: call.spawnsSubagent ? .subagent(call) : .tool(call)))
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

    /// Compact mode: a run of ordinary tool calls collapses to one line. Twelve greps in a row are
    /// one fact — "it searched" — and spending twelve lines on them pushes the answer off the
    /// screen. The run keeps every call inside it, one tap away, and anything that is not an
    /// ordinary tool call (an error, a subagent, a picture) never joins a run.
    static func fuse(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        var fused: [TranscriptRow] = []
        var run: [ToolCall] = []
        var runKey = ""

        func flush() {
            guard !run.isEmpty else { return }
            if run.count == 1 {
                fused.append(TranscriptRow(key: runKey, kind: .tool(run[0])))
            } else {
                fused.append(TranscriptRow(key: "run:\(runKey)", kind: .toolRun(run)))
            }
            run = []
        }

        for row in rows {
            if case .tool(let call) = row.kind, call.status != .error, !call.asksUserQuestion {
                if run.isEmpty { runKey = row.key }
                run.append(call)
                continue
            }
            flush()
            fused.append(row)
        }
        flush()
        return fused
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
        case .tool(let call), .subagent(let call):
            return Self.searchText(for: call)
        case .toolRun(let calls):
            return calls.map(Self.searchText(for:)).joined(separator: " ")
        case .file(let reference):
            return reference.filename ?? reference.path ?? ""
        case .compaction(let compaction):
            return compaction.summary ?? ""
        case .turnBreak:
            return ""
        }
    }

    func makeWidget(context: TranscriptContext) -> UnsafeMutablePointer<GtkWidget> {
        switch kind {
        case .userText(let text):
            return Self.prompt(text)
        case .agentProse(_, let markup):
            return Gtk.markupLabel(markup, css: "agent-text")
        case .codeBlock(let language, let body):
            return Self.codeBlock(language: language, body: body)
        case .reasoning(let text):
            return Self.reasoning(text, key: key, context: context)
        case .tool(let call):
            return ToolRowView.make(call, key: key, context: context)
        case .toolRun(let calls):
            return ToolRowView.makeRun(calls, key: key, context: context)
        case .subagent(let call):
            return SubagentRowView.make(call, key: key, context: context)
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

    private static func codeBlock(language: String?, body: String)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(column, "code-block")

        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let tag = Gtk.label(language ?? "text", css: "code-header", selectable: false)
        gtk_widget_set_hexpand(tag, 1)
        gtk_box_append(ptr(header), tag)
        let bytes = body
        gtk_box_append(
            ptr(header),
            Gtk.button(Localized.text("copy"), css: ["flat", "code-copy"]) {
                Gtk.copyToClipboard(bytes)
            })
        gtk_box_append(ptr(column), header)

        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).count
        let text = Gtk.label(body, css: "code-body", wrap: true)
        if lines > 18, body.count > 600 {
            let scroller = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
            gtk_scrolled_window_set_max_content_height(op(scroller), 320)
            gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
            gtk_scrolled_window_set_child(op(scroller), text)
            gtk_box_append(ptr(column), scroller)
        } else {
            gtk_box_append(ptr(column), text)
        }
        return column
    }

    private static func reasoning(_ text: String, key: String, context: TranscriptContext)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let words = text.split(separator: " ").count
        let header = Gtk.label(
            Localized.text("⌄ Thought · %@ words", "\(words)"), css: "dim", selectable: false)
        let toggle = context.onToggle
        return Gtk.disclosure(
            header: header, expanded: context.isExpanded(key),
            onToggle: { open in toggle?(key, open) }
        ) {
            let body = Gtk.label(text, css: "reasoning-body", wrap: true)
            Gtk.margins(body, leading: 14)
            return body
        }
    }

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
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        if let bits = context.textures[key], bits != 0 {
            let texture = OpaquePointer(bitPattern: Int(bitPattern: bits))
            let picture = tailscode_picture_for_texture(texture)!
            gtk_widget_set_size_request(picture, -1, min(420, tailscode_texture_height(texture)))
            Gtk.addClass(picture, "image-part")
            let width = tailscode_texture_width(texture)
            let height = tailscode_texture_height(texture)
            let opener = gtk_button_new()!
            Gtk.addClass(opener, "flat")
            gtk_widget_set_halign(opener, GTK_ALIGN_START)
            gtk_button_set_child(ptr(opener), picture)
            let open = context.openImage
            Gtk.connect(UnsafeMutableRawPointer(opener), "clicked") {
                open?(key, name)
            }
            gtk_box_append(ptr(column), opener)
            gtk_box_append(
                ptr(column),
                Gtk.label("\(name) · \(width)×\(height)", css: "row-detail", selectable: false))
        } else {
            gtk_box_append(
                ptr(column),
                Gtk.label(Localized.text("🖼 %@ — loading…", name), css: "dim", selectable: false))
            context.requestImage?(reference, key)
        }
        return column
    }

    /// A compaction is a seam, not a message: the rule says the transcript restarted here, the
    /// card says what was traded for what, and the CLI's machine-facing summary stays behind a
    /// disclosure rather than in the flow.
    private static func seam(
        _ compaction: Compaction, key: String, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_box_append(ptr(column), Gtk.hairline())

        var facts: [String] = []
        if let before = compaction.tokensBefore, let after = compaction.tokensAfter {
            facts.append("\(Self.tokens(before)) → \(Self.tokens(after))")
        }
        if let duration = compaction.duration, duration > 0 {
            facts.append(Self.clock(duration))
        }
        if let kept = compaction.preservedMessageCount {
            facts.append(Localized.text("%@ messages kept", "\(kept)"))
        }
        if compaction.trigger == .auto { facts.append(Localized.text("automatic")) }
        let title = facts.isEmpty
            ? Localized.text("COMPACTED") : "COMPACTED · " + facts.joined(separator: " · ")

        if let summary = compaction.summary, !summary.isEmpty {
            let header = Gtk.label(title, css: "seam-text", selectable: false)
            let toggle = context.onToggle
            gtk_box_append(
                ptr(column),
                Gtk.disclosure(
                    header: header, expanded: context.isExpanded(key),
                    onToggle: { open in toggle?(key, open) }
                ) {
                    let body = Gtk.label(summary, css: "reasoning-body", wrap: true)
                    Gtk.margins(body, leading: 14)
                    let scroller = gtk_scrolled_window_new()!
                    gtk_scrolled_window_set_policy(
                        op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
                    gtk_scrolled_window_set_max_content_height(op(scroller), 340)
                    gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
                    gtk_scrolled_window_set_child(op(scroller), body)
                    return scroller
                })
        } else {
            gtk_box_append(ptr(column), Gtk.label(title, css: "seam-text", selectable: false))
        }
        gtk_box_append(ptr(column), Gtk.hairline())
        return column
    }

    static func tokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }

    static func clock(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}
