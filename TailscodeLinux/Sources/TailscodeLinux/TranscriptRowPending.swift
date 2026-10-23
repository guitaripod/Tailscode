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
        gtk_widget_set_tooltip_text(button, QueueReading.spoken(queued, position: position, of: total))
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

    /// A message on its way out: the words drawn as the prompt they will become, with a line
    /// under them saying whether they went.
    ///
    /// It is the prompt's own rule and the prompt's own words because that is what it is — what
    /// is added is the one thing the transcript could never say, which is that this message is
    /// not in the server's account yet. The state is told by ink rather than by a word: a send on
    /// the wire is drawn faint and fills in when the server has it, and a line appears under the
    /// words only when the wait has become news. A send that failed keeps its words right here,
    /// in the danger tone, and offers the three things worth doing about them.
    ///
    /// The bubble, the lines and the send are parked on the row so the pane can restate it in
    /// place — fill the ink in, grow a strip — without tearing the widget down.
    static let pendingBubbleKey = "tailscode-pending-bubble"

    static let pendingLinesKey = "tailscode-pending-lines"

    static let pendingStripKey = "tailscode-pending-strip"

    static let pendingSendKey = "tailscode-pending-send"

    static func pendingSend(
        _ send: PendingSend, plan: ResumePlan?, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let now = Date()
        let row = Gtk.groupBox(
            GTK_ORIENTATION_HORIZONTAL, spacing: 10,
            spoken: plan.map { ResumeReading.spoken($0, words: send.text, now: now) }
                ?? PendingSendReading.spoken(send, now: now))
        let bubble = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(bubble, "pending-ink")
        gtk_widget_set_hexpand(bubble, 1)
        let rule = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(rule, "prompt-rule")
        if send.isFailed { Gtk.addClass(rule, "pending-rule-failed") }
        gtk_widget_set_size_request(rule, 2, -1)

        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        let label = Gtk.markupLabel(
            PangoMarkdown.plainWithLinks(send.text, accent: MatrixTheme.palette.accent),
            css: "prompt-text")
        if send.isFailed { Gtk.addClass(label, "pending-text-failed") }
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(lines), label)

        if let plan {
            gtk_box_append(
                ptr(lines),
                pendingStrip(ResumeReading.icon, ResumeReading.caption(plan, now: now)))
        } else if let caption = PendingSendReading.caption(send, now: now) {
            gtk_box_append(ptr(lines), pendingStrip(PendingSendReading.icon(send), caption))
        }

        if let plan, let act = context.resumeAct {
            let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            gtk_widget_set_halign(buttons, GTK_ALIGN_START)
            let id = plan.id
            for choice in ResumeReading.acts {
                gtk_box_append(
                    ptr(buttons),
                    Gtk.button(ResumeReading.title(choice), css: ["flat", "seam-read"]) {
                        act(id, choice)
                    })
            }
            gtk_box_append(ptr(lines), buttons)
        } else if !send.acts.isEmpty, let act = context.pendingAct {
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
        gtk_box_append(ptr(bubble), rule)
        gtk_box_append(ptr(bubble), lines)
        gtk_box_append(ptr(row), bubble)
        applyInk(to: bubble, send: send, plan: plan)
        let spokenNow =
            plan.map { ResumeReading.spoken($0, words: send.text, now: now) }
            ?? PendingSendReading.spoken(send, now: now)
        gtk_widget_set_tooltip_text(row, spokenNow)
        tailscode_set_accessible_label(row, spokenNow)
        g_object_set_data(ptr(row), pendingBubbleKey, UnsafeMutableRawPointer(bubble))
        g_object_set_data(ptr(row), pendingLinesKey, UnsafeMutableRawPointer(lines))
        let sendBox = Unmanaged.passRetained(PendingSendBox(send, plan: plan)).toOpaque()
        g_object_set_data_full(
            ptr(row), pendingSendKey, sendBox,
            { raw in
                guard let raw else { return }
                Unmanaged<PendingSendBox>.fromOpaque(raw).release()
            })
        return row
    }

    /// The line under the words, drawn only when there is one: the state's own glyph and what it
    /// has to say.
    static func pendingStrip(
        _ icon: ActivityIcon, _ caption: String
    ) -> UnsafeMutablePointer<GtkWidget> {
        let status = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        Gtk.addClass(status, "pending-strip")
        gtk_widget_set_halign(status, GTK_ALIGN_START)
        gtk_box_append(ptr(status), Gtk.label(icon.glyph, css: icon.glyphCSS, selectable: false))
        gtk_box_append(ptr(status), Gtk.label(caption, css: "queued-hint", selectable: false))
        return status
    }

    /// The ink is a CSS class, so the fill from faint to full is the theme's own transition on the
    /// display's clock — and nothing at all where animations are off.
    static func applyInk(
        to bubble: UnsafeMutablePointer<GtkWidget>, send: PendingSend, plan: ResumePlan?
    ) {
        Gtk.setTone(bubble, nil, from: ["pending-faint"])
    }

    /// Restates a pending row for a send whose phase or wait moved without rebuilding it: the ink
    /// fills in, the strip appears or goes, the spoken words follow. Answers false when the row
    /// needs a shape it does not have — a failure's tone and acts, a wait's countdown buttons —
    /// and the caller rebuilds.
    @discardableResult
    static func restatePending(
        on row: UnsafeMutablePointer<GtkWidget>, send: PendingSend, plan: ResumePlan?,
        now: Date = Date()
    ) -> Bool {
        guard let sendRaw = g_object_get_data(ptr(row), pendingSendKey),
            let bubbleRaw = g_object_get_data(ptr(row), pendingBubbleKey),
            let linesRaw = g_object_get_data(ptr(row), pendingLinesKey)
        else { return false }
        let box = Unmanaged<PendingSendBox>.fromOpaque(sendRaw).takeUnretainedValue()
        guard send.id == box.send.id, send.text == box.send.text, !send.isFailed,
            !box.send.isFailed, plan?.id == box.plan?.id, plan?.attempt == box.plan?.attempt
        else { return false }
        box.send = send
        box.plan = plan
        let bubble: UnsafeMutablePointer<GtkWidget> = ptr(bubbleRaw)
        let lines: UnsafeMutablePointer<GtkWidget> = ptr(linesRaw)
        applyInk(to: bubble, send: send, plan: plan)
        let icon = plan == nil ? PendingSendReading.icon(send) : ResumeReading.icon
        let caption =
            plan.map { ResumeReading.caption($0, now: now) }
            ?? PendingSendReading.caption(send, now: now)
        let existing = g_object_get_data(ptr(row), pendingStripKey)
            ?? firstStrip(in: lines)
        switch (existing, caption) {
        case (nil, nil):
            break
        case (let strip?, nil):
            gtk_box_remove(ptr(lines), ptr(strip))
            g_object_set_data(ptr(row), pendingStripKey, nil)
        case (nil, let caption?):
            let strip = pendingStrip(icon, caption)
            let first = gtk_widget_get_first_child(lines)
            gtk_box_insert_child_after(ptr(lines), strip, first)
            g_object_set_data(ptr(row), pendingStripKey, UnsafeMutableRawPointer(strip))
        case (let strip?, let caption?):
            if let glyph = gtk_widget_get_first_child(ptr(strip) as UnsafeMutablePointer<GtkWidget>),
                let words = gtk_widget_get_next_sibling(glyph)
            {
                gtk_label_set_text(op(glyph), icon.glyph)
                gtk_label_set_text(op(words), caption)
            }
        }
        let spokenNow =
            plan.map { ResumeReading.spoken($0, words: send.text, now: now) }
            ?? PendingSendReading.spoken(send, now: now)
        gtk_widget_set_tooltip_text(row, spokenNow)
        tailscode_set_accessible_label(row, spokenNow)
        return true
    }

    static func firstStrip(
        in lines: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutableRawPointer? {
        var child = gtk_widget_get_first_child(lines)
        while let widget = child {
            if gtk_widget_has_css_class(widget, "pending-strip") != 0 {
                return UnsafeMutableRawPointer(widget)
            }
            child = gtk_widget_get_next_sibling(widget)
        }
        return nil
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
