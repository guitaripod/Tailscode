import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension TranscriptRow {
    /// A prompt that has been written and not sent, drawn as the prompt it will become — same
    /// accent rule, same words — but dimmed, marked, and pressable, because it is the one row in
    /// the transcript that is still the reader's to change. Nothing about it may read as sent.
    static func queuedSend(
        _ queued: QueueRow, position: Int, of total: Int, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let rule = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(rule, "prompt-rule")
        Gtk.addClass(rule, "queued-rule")
        gtk_widget_set_size_request(rule, 2, -1)

        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        let label = Gtk.label(
            "\(QueueReading.glyph(queued)) \(queued.title)", css: "prompt-text",
            wrap: true)
        gtk_label_set_xalign(op(label), 0)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(lines), label)
        gtk_box_append(
            ptr(lines), Gtk.label(QueueReading.hint(queued), css: "queued-hint", selectable: false))
        gtk_widget_set_hexpand(lines, 1)

        gtk_box_append(ptr(row), rule)
        gtk_box_append(ptr(row), lines)

        guard queued.canEdit else {
            Gtk.addClass(row, "queued-row")
            return row
        }
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "queued-row")
        gtk_button_set_child(ptr(button), row)
        gtk_widget_set_hexpand(button, 1)
        Tip.set(button, QueueReading.spoken(queued, position: position, of: total))
        tailscode_set_accessible_label(
            button, QueueReading.spoken(queued, position: position, of: total))
        let edit = context.editQueued
        let id = queued.id
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { edit?(id) }
        return button
    }

    /// The note under a queue a Stop paused, with the one press that lets it go on: the pause is
    /// the queue's, so Resume is drawn once beneath all of its messages.
    static func queuePaused(
        count: Int, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let line = QueueReading.pausedLine(count: count)
        let card = Gtk.groupBox(
            GTK_ORIENTATION_VERTICAL, spacing: 6, spoken: "\(line). \(QueueReading.pausedHint)")
        Gtk.addClass(card, "card")

        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(
            ptr(heading), Gtk.label(SendQueueReading.heldGlyph, css: "row-note", selectable: false))
        let title = Gtk.label(line, css: "card-title", wrap: true, selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_halign(title, GTK_ALIGN_START)
        gtk_box_append(ptr(heading), title)
        gtk_box_append(ptr(card), heading)

        let detail = Gtk.label(QueueReading.pausedHint, css: "tool-detail", wrap: true, selectable: false)
        gtk_widget_set_halign(detail, GTK_ALIGN_START)
        gtk_box_append(ptr(card), detail)

        let resume = context.resumeQueue
        let button = Gtk.button(QueueReading.resume, css: ["flat", "seam-read"]) { resume?() }
        gtk_widget_set_halign(button, GTK_ALIGN_START)
        gtk_box_append(ptr(card), button)
        return card
    }

    /// A message on its way out, drawn exactly as the server's own row for it will be — the
    /// prompt's rule, the prompt's words, folded the way a long prompt folds — so the moment the
    /// server's account replaces it changes nothing anybody can see. What is added is only what the
    /// transcript could never say: a line when the wait has become news, and, for a send that did
    /// not go or is held for the connection, the things worth doing about it. Those grow in and
    /// out of the row rather than snapping, and then hold still.
    ///
    /// The words, the strip and the acts are parked on the row so the pane restates it in place —
    /// a phase moving, a caption arriving, a failure and its retry — without tearing it down.
    static let pendingSendKey = "tailscode-pending-send"

    static let pendingRuleKey = "tailscode-pending-rule"

    static let pendingLabelKey = "tailscode-pending-label"

    static let pendingStripKey = "tailscode-pending-strip"

    static let pendingActsKey = "tailscode-pending-acts"

    /// How long a strip or a row of acts takes to grow into the row or out of it.
    static let pendingRevealMilliseconds: UInt32 = 200

    /// The message id a pending send's own rows carry, so its folded pastes sit under its words
    /// the way a sent message's sit under its own.
    static func echoMessageID(_ id: UUID) -> String { "pending-\(id.uuidString)" }

    /// The words of a send as the server's row will show them: the typed words without the brief a
    /// carried conversation wraps them in, stripped as the transcript strips a user message, and
    /// without the pastes that fold into cards of their own.
    static func echoWords(_ text: String) -> String {
        let typed = AgentMarkup.strip(typedWords(text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard PasteFold.mayHold(typed) else { return typed }
        let reading = PasteFold.split(typed, id: "echo")
        guard reading.isFolded else { return typed }
        for piece in reading.pieces {
            if case .words(let words) = piece { return words }
        }
        return ""
    }

    /// The cards of the pastes a send folds, in the order the server's row will show them.
    static func echoPastes(_ text: String) -> [FoldedPaste] {
        let typed = AgentMarkup.strip(typedWords(text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard PasteFold.mayHold(typed) else { return [] }
        let reading = PasteFold.split(typed, id: "echo")
        guard reading.isFolded else { return [] }
        return reading.pieces.compactMap { piece in
            if case .paste(let paste) = piece { return paste }
            return nil
        }
    }

    /// Where the echo's own picture is decoded, so the server's row can take it over.
    static func echoPictureKey(_ id: UUID, _ index: Int) -> String {
        "pending:\(id.uuidString):img\(index)"
    }

    /// The rows a send stands in the transcript as until the server's account carries it, shaped
    /// exactly as the server's own rows for it will be: the pictures from the bytes in memory, the
    /// words folded as a prompt folds, a paste as its own card under them. The row that can speak
    /// — a line, the acts — is the words' row, or the last of the send's rows when it has no
    /// words and something to say.
    static func echoRows(_ send: PendingSend, plan: ResumePlan?) -> [TranscriptRow] {
        let key = "pending:\(send.id.uuidString)"
        var rows: [TranscriptRow] = []
        for (index, picture) in send.pictures.enumerated() {
            rows.append(
                TranscriptRow(
                    key: echoPictureKey(send.id, index),
                    kind: .file(
                        FileReference(mime: picture.mime, filename: picture.filename), mine: true)))
        }
        let words = echoWords(send.text)
        if !words.isEmpty {
            rows.append(TranscriptRow(key: key, kind: .pendingSend(send, plan)))
        }
        for (index, paste) in echoPastes(send.text).enumerated() {
            rows.append(
                TranscriptRow(
                    key: "\(key):f\(index + 1)",
                    kind: .pastedText(paste, messageID: echoMessageID(send.id))))
        }
        if words.isEmpty, pendingSpeaks(send, plan: plan) || rows.isEmpty {
            rows.append(TranscriptRow(key: key, kind: .pendingSend(send, plan)))
        }
        return rows
    }

    /// Whether a pending row has anything to show beyond the words: a line, or acts.
    static func pendingSpeaks(_ send: PendingSend, plan: ResumePlan?, now: Date = Date()) -> Bool {
        plan != nil || PendingSendReading.caption(send, now: now) != nil || !send.acts.isEmpty
    }

    static func pendingSend(
        _ send: PendingSend, plan: ResumePlan?, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let now = Date()
        let spoken =
            plan.map { ResumeReading.spoken($0, words: send.text, now: now) }
            ?? PendingSendReading.spoken(send, now: now)
        let row = Gtk.groupBox(GTK_ORIENTATION_HORIZONTAL, spacing: 10, spoken: spoken)
        let rule = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(rule, "prompt-rule")
        Gtk.addClass(rule, "pending-rule")
        gtk_widget_set_size_request(rule, 2, -1)

        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(lines, 1)
        let words = echoWords(send.text)
        var label: UnsafeMutablePointer<GtkWidget>?
        if !words.isEmpty {
            let made = Gtk.markupLabel(
                PangoMarkdown.plainWithLinks(words, accent: MatrixTheme.palette.accent),
                css: "prompt-text")
            Gtk.addClass(made, "pending-text")
            gtk_widget_set_hexpand(made, 1)
            gtk_box_append(
                ptr(lines),
                PromptFoldView.make(
                    made, text: words, key: PromptFold.key(messageID: echoMessageID(send.id)),
                    context: context,
                    markup: { PangoMarkdown.plainWithLinks($0, accent: MatrixTheme.palette.accent) }))
            label = made
        }

        let strip = pendingReveal()
        gtk_box_append(ptr(lines), strip)
        let acts = pendingReveal()
        gtk_box_append(ptr(lines), acts)

        gtk_box_append(ptr(row), rule)
        gtk_box_append(ptr(row), lines)
        Tip.set(row, spoken)
        g_object_set_data(ptr(row), pendingRuleKey, UnsafeMutableRawPointer(rule))
        if let label { g_object_set_data(ptr(row), pendingLabelKey, UnsafeMutableRawPointer(label)) }
        g_object_set_data(ptr(row), pendingStripKey, UnsafeMutableRawPointer(strip))
        g_object_set_data(ptr(row), pendingActsKey, UnsafeMutableRawPointer(acts))
        let sendBox = Unmanaged.passRetained(PendingSendBox(send, plan: plan)).toOpaque()
        g_object_set_data_full(
            ptr(row), pendingSendKey, sendBox,
            { raw in
                guard let raw else { return }
                Unmanaged<PendingSendBox>.fromOpaque(raw).release()
            })
        paintPending(row, send: send, plan: plan, now: now, context: context, animated: false)
        return row
    }

    /// A strip that grows into its row and out of it. Hidden while closed, so the row holds no
    /// spacing for it and is the server's row to the pixel until there is something to say.
    private static func pendingReveal() -> UnsafeMutablePointer<GtkWidget> {
        let revealer = gtk_revealer_new()!
        gtk_revealer_set_transition_type(op(revealer), GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN)
        gtk_revealer_set_transition_duration(op(revealer), 0)
        gtk_revealer_set_reveal_child(op(revealer), 0)
        gtk_widget_set_visible(revealer, 0)
        gtk_widget_set_halign(revealer, GTK_ALIGN_START)
        return revealer
    }

    /// Opens or closes a strip, eased when the row is already on screen and at once otherwise.
    private static func reveal(
        _ revealer: UnsafeMutablePointer<GtkWidget>, _ shown: Bool, animated: Bool
    ) {
        let open = gtk_revealer_get_reveal_child(op(revealer)) != 0
        let motion = animated && Gtk.animationsAllowed
        gtk_revealer_set_transition_duration(op(revealer), motion ? pendingRevealMilliseconds : 0)
        if shown {
            gtk_widget_set_visible(revealer, 1)
            guard !open else { return }
            gtk_revealer_set_reveal_child(op(revealer), 1)
            return
        }
        guard open || gtk_widget_get_visible(revealer) != 0 else { return }
        gtk_revealer_set_reveal_child(op(revealer), 0)
        guard motion else {
            gtk_widget_set_visible(revealer, 0)
            return
        }
        g_object_ref(UnsafeMutableRawPointer(revealer))
        let bits = UInt(bitPattern: revealer)
        Gtk.after(pendingRevealMilliseconds + 20) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            let held: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            if gtk_revealer_get_reveal_child(op(held)) == 0 { gtk_widget_set_visible(held, 0) }
            g_object_unref(raw)
        }
    }

    /// The line under the words: the state's own glyph, breathing while the state is one that
    /// moves, and what it has to say.
    static func pendingStrip(
        _ icon: ActivityIcon, _ caption: String
    ) -> UnsafeMutablePointer<GtkWidget> {
        let status = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        Gtk.addClass(status, "pending-strip")
        gtk_widget_set_halign(status, GTK_ALIGN_START)
        let glyph = Gtk.label(icon.glyph, css: icon.glyphCSS, selectable: false)
        gtk_box_append(ptr(status), glyph)
        ActivityPulse.apply(icon, to: glyph)
        gtk_box_append(ptr(status), Gtk.label(caption, css: "queued-hint", selectable: false))
        return status
    }

    /// The acts a row offers, as the buttons every other card in the transcript wears.
    private static func pendingActs(
        _ send: PendingSend, plan: ResumePlan?, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget>? {
        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(buttons, GTK_ALIGN_START)
        if let plan, let act = context.resumeAct {
            let id = plan.id
            for choice in ResumeReading.acts {
                gtk_box_append(
                    ptr(buttons),
                    Gtk.button(ResumeReading.title(choice), css: ["flat", "seam-read"]) {
                        act(id, choice)
                    })
            }
            return buttons
        }
        guard !send.acts.isEmpty, let act = context.pendingAct else { return nil }
        let id = send.id
        for choice in send.acts {
            gtk_box_append(
                ptr(buttons),
                Gtk.button(PendingSendReading.title(choice, for: send), css: ["flat", "seam-read"]) {
                    act(id, choice)
                })
        }
        return buttons
    }

    /// What the acts strip is offering, so a restate that offers the same leaves the buttons the
    /// pointer may be resting on alone.
    private static func actsSignature(_ send: PendingSend, plan: ResumePlan?) -> String {
        if let plan { return "plan:\(plan.id.uuidString)" }
        return send.acts.map { PendingSendReading.title($0, for: send) }.joined(separator: "|")
    }

    private static let actsSignatureKey = "tailscode-pending-acts-signature"

    /// Puts a pending row in the state its send is in: the failure tone on the rule and the words
    /// (a CSS transition, so it eases and then holds), the strip, and the acts.
    private static func paintPending(
        _ row: UnsafeMutablePointer<GtkWidget>, send: PendingSend, plan: ResumePlan?, now: Date,
        context: TranscriptContext?, animated: Bool
    ) {
        if let rule = g_object_get_data(ptr(row), pendingRuleKey) {
            Gtk.setTone(ptr(rule), send.isFailed ? "pending-rule-failed" : nil, from: ["pending-rule-failed"])
        }
        if let label = g_object_get_data(ptr(row), pendingLabelKey) {
            Gtk.setTone(ptr(label), send.isFailed ? "pending-text-failed" : nil, from: ["pending-text-failed"])
        }
        if let stripRaw = g_object_get_data(ptr(row), pendingStripKey) {
            let strip: UnsafeMutablePointer<GtkWidget> = ptr(stripRaw)
            let icon = plan == nil ? PendingSendReading.icon(send) : ResumeReading.icon
            let caption =
                plan.map { ResumeReading.caption($0, now: now) }
                ?? PendingSendReading.caption(send, now: now)
            if let caption {
                if let line = gtk_revealer_get_child(op(strip)),
                    let glyph = gtk_widget_get_first_child(line),
                    let words = gtk_widget_get_next_sibling(glyph)
                {
                    gtk_label_set_text(op(glyph), icon.glyph)
                    Gtk.setTone(glyph, icon.glyphCSS, from: ActivityTone.allCases.map(\.glyphCSS))
                    ActivityPulse.apply(icon, to: glyph)
                    gtk_label_set_text(op(words), caption)
                } else {
                    gtk_revealer_set_child(op(strip), pendingStrip(icon, caption))
                }
            }
            reveal(strip, caption != nil, animated: animated)
        }
        if let actsRaw = g_object_get_data(ptr(row), pendingActsKey) {
            let acts: UnsafeMutablePointer<GtkWidget> = ptr(actsRaw)
            let signature = actsSignature(send, plan: plan)
            let held = g_object_get_data(ptr(acts), actsSignatureKey)
                .map { Unmanaged<ActsSignature>.fromOpaque($0).takeUnretainedValue().value }
            if signature != held, let context {
                if let made = pendingActs(send, plan: plan, context: context) {
                    gtk_revealer_set_child(op(acts), made)
                }
                let boxed = Unmanaged.passRetained(ActsSignature(signature)).toOpaque()
                g_object_set_data_full(
                    ptr(acts), actsSignatureKey, boxed,
                    { raw in
                        guard let raw else { return }
                        Unmanaged<ActsSignature>.fromOpaque(raw).release()
                    })
            }
            reveal(acts, plan != nil || !send.acts.isEmpty, animated: animated)
        }
        let spokenNow =
            plan.map { ResumeReading.spoken($0, words: send.text, now: now) }
            ?? PendingSendReading.spoken(send, now: now)
        Tip.set(row, spokenNow)
        tailscode_set_accessible_label(row, spokenNow)
    }

    /// Restates a pending row in place for a send whose phase, caption, wait or acts moved: the
    /// tone eases, the strip and the acts grow in or out, the spoken words follow. Answers false
    /// only when the row would need other words — a send edited into something else — and the
    /// caller rebuilds.
    @discardableResult
    static func restatePending(
        on row: UnsafeMutablePointer<GtkWidget>, send: PendingSend, plan: ResumePlan?,
        now: Date = Date(), context: TranscriptContext? = nil
    ) -> Bool {
        guard let sendRaw = g_object_get_data(ptr(row), pendingSendKey) else { return false }
        let box = Unmanaged<PendingSendBox>.fromOpaque(sendRaw).takeUnretainedValue()
        guard send.id == box.send.id, echoWords(send.text) == echoWords(box.send.text) else {
            return false
        }
        if context == nil, actsSignature(send, plan: plan) != actsSignature(box.send, plan: box.plan) {
            return false
        }
        box.send = send
        box.plan = plan
        paintPending(row, send: send, plan: plan, now: now, context: context, animated: true)
        return true
    }

    /// Ages a pending row on the clock: only a wait's countdown moves by the second, so a row with
    /// no plan is left to the wake the pane scheduled for its caption. Returns whether the row
    /// still carries something the clock is for.
    @discardableResult
    static func agePendingCaption(
        on row: UnsafeMutablePointer<GtkWidget>, now: Date = Date()
    ) -> Bool {
        guard let sendRaw = g_object_get_data(ptr(row), pendingSendKey) else { return false }
        let box = Unmanaged<PendingSendBox>.fromOpaque(sendRaw).takeUnretainedValue()
        guard let plan = box.plan else { return false }
        return restatePending(on: row, send: box.send, plan: plan, now: now)
    }
}

/// What a pending row's acts strip is offering, held on the strip's widget.
final class ActsSignature: @unchecked Sendable {
    let value: String
    init(_ value: String) { self.value = value }
}
