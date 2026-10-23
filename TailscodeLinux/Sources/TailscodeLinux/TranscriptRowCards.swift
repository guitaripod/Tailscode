import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension TranscriptRow {
    /// What the answer above it took: one quiet strip of glyph-and-number, tooltipped with the
    /// sentence behind each figure. It is deliberately the dimmest thing in the transcript — a
    /// reader who turned it on wants it available, not competing with the answer it describes.
    static func responseStats(
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
    static func statLabel(
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
    static func designBoard(
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

    static func answerless(
        _ turn: AnswerlessTurn, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.groupBox(GTK_ORIENTATION_VERTICAL, spacing: 6, spoken: turn.spoken)
        Gtk.addClass(card, "card")
        Gtk.addClass(card, "card-answerless")

        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(
            ptr(heading),
            Gtk.label(AnswerlessTurn.glyph, css: AnswerlessTurn.tone.glyphCSS, selectable: false))
        let title = Gtk.label(turn.title, css: "card-title", wrap: true, selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(heading), title)
        gtk_box_append(ptr(card), heading)

        let detail = Gtk.label(turn.detail, css: "tool-detail", wrap: true, selectable: false)
        gtk_widget_set_halign(detail, GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(detail, 1)
        gtk_box_append(ptr(card), detail)

        if turn.offersRemedy {
            let askAgain = context.askAgain
            let words = turn.prompt
            let button = ChatChips.plain(turn.action) { askAgain?(words) }
            gtk_widget_set_halign(button, GTK_ALIGN_START)
            gtk_box_append(ptr(card), button)
        }
        return card
    }

    /// A turn that stopped with an error. It is the answerless card's relative — what happened, the
    /// server's own words held in a quoted block and never reworded, and the one action that
    /// sends the same words again — and it holds as still as every other settled state.
    static func failedTurn(
        _ turn: FailedTurn, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.groupBox(GTK_ORIENTATION_VERTICAL, spacing: 6, spoken: turn.spoken)
        Gtk.addClass(card, "card")
        Gtk.addClass(card, "card-failed")

        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(
            ptr(heading),
            Gtk.label(FailedTurn.glyph, css: FailedTurn.tone.glyphCSS, selectable: false))
        let title = Gtk.label(turn.title, css: "card-title", wrap: true, selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(heading), title)
        gtk_box_append(ptr(card), heading)

        let detail = Gtk.label(turn.detail, css: "tool-detail", wrap: true, selectable: false)
        gtk_widget_set_halign(detail, GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(detail, 1)
        gtk_box_append(ptr(card), detail)

        let reason = Gtk.label(turn.reason, css: "failed-reason", wrap: true)
        gtk_widget_set_halign(reason, GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(reason, 1)
        gtk_box_append(ptr(card), reason)

        if turn.offersRemedy {
            let askAgain = context.askAgain
            let words = turn.prompt
            let button = ChatChips.plain(turn.action) { askAgain?(words) }
            gtk_widget_set_halign(button, GTK_ALIGN_START)
            gtk_box_append(ptr(card), button)
        }
        return card
    }

    /// A turn the machine was pulled out from under. The account of what the work had already done
    /// is the substance of it — a person decides between continuing and starting over on whether
    /// anything on that machine changed — so it is drawn as lines rather than as a sentence.
    ///
    /// Every word is Core's, including the one nobody used to be told: an undecided card stops the
    /// server carrying this session on by itself, which is a price being paid for not answering.
    /// The buttons take their titles and their sensitivity from the card's own state, so a press
    /// already in flight is visibly in flight and cannot be pressed a second time.
    static func interruptedTurn(
        _ turn: InterruptedTurn, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.groupBox(GTK_ORIENTATION_VERTICAL, spacing: 6, spoken: turn.spoken)
        Gtk.addClass(card, "card")
        Gtk.addClass(card, "card-interrupted")

        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(
            ptr(heading),
            Gtk.label(InterruptedTurn.glyph, css: InterruptedTurn.tone.glyphCSS, selectable: false))
        let title = Gtk.label(turn.title, css: "card-title", wrap: true, selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(heading), title)
        gtk_box_append(ptr(card), heading)

        if !turn.prompt.isEmpty {
            let prompt = Gtk.label(turn.prompt, css: "row-title", wrap: true, selectable: true)
            gtk_widget_set_halign(prompt, GTK_ALIGN_START)
            gtk_box_append(ptr(card), prompt)
        }

        let detail = Gtk.label(turn.detail, css: "tool-detail", wrap: true, selectable: false)
        gtk_widget_set_halign(detail, GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(detail, 1)
        gtk_box_append(ptr(card), detail)

        for line in turn.progress {
            let row = Gtk.label("· \(line)", css: "row-detail", wrap: true, selectable: false)
            gtk_widget_set_halign(row, GTK_ALIGN_START)
            gtk_box_append(ptr(card), row)
        }

        if let waiting = turn.queuedLine {
            let line = Gtk.label(waiting, css: "row-note", wrap: true, selectable: false)
            gtk_widget_set_halign(line, GTK_ALIGN_START)
            gtk_box_append(ptr(card), line)
        }

        if let cost = turn.cost {
            let price = Gtk.label(cost, css: "row-note", wrap: true, selectable: false)
            gtk_widget_set_halign(price, GTK_ALIGN_START)
            gtk_box_append(ptr(card), price)
        }

        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(buttons, GTK_ALIGN_START)
        if !turn.isResumed, let resume = context.resumeInterrupted {
            let button = Gtk.button(turn.resumeTitle, css: ["flat", "seam-read"]) { resume() }
            gtk_widget_set_sensitive(button, turn.acceptsPress ? 1 : 0)
            gtk_box_append(ptr(buttons), button)
        }
        if let dismiss = context.dismissInterrupted {
            let button = Gtk.button(turn.dismissTitle, css: ["flat"]) { dismiss() }
            gtk_widget_set_sensitive(button, turn.acceptsPress ? 1 : 0)
            gtk_box_append(ptr(buttons), button)
        }
        gtk_box_append(ptr(card), buttons)
        return card
    }

    /// A line the server wrote for the reader, never a message: small, quiet, and, unlike every
    /// card around it, carrying no author, no time and no action. The tooltip repeats it as
    /// `spoken`, which says "Note:" first, because the sentence alone can read as something
    /// somebody typed.
    static func note(_ line: TranscriptNoteLine) -> UnsafeMutablePointer<GtkWidget> {
        let textTone = line.tone == .attention ? "note-attention" : "note-quiet"
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_box_append(
            ptr(row), Gtk.label(line.glyph, css: line.tone.glyphCSS, selectable: false))
        let text = Gtk.label(line.text, css: textTone, selectable: false)
        gtk_label_set_ellipsize(op(text), PANGO_ELLIPSIZE_END)
        gtk_label_set_single_line_mode(op(text), 1)
        gtk_box_append(ptr(row), text)
        gtk_widget_set_tooltip_text(row, line.spoken)
        return dividerLine(around: row)
    }

    /// The turn waiting on its provider. It asks nothing of the person (no retry button, no stop
    /// button, stopping stays where it always is), so the only press this card ever offers is the
    /// remedy's own link, opened in the browser the way every other outside link on this desk is.
    static func providerRetry(_ card: ProviderRetryCard) -> UnsafeMutablePointer<GtkWidget> {
        let box = Gtk.groupBox(GTK_ORIENTATION_VERTICAL, spacing: 6, spoken: card.spoken)
        Gtk.addClass(box, "card")
        Gtk.addClass(box, "card-retry")

        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(
            ptr(heading),
            Gtk.label(
                ProviderRetryCard.glyph, css: ProviderRetryCard.tone.glyphCSS, selectable: false))
        let title = Gtk.label(card.title, css: "card-title", wrap: true, selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_halign(title, GTK_ALIGN_START)
        gtk_box_append(ptr(heading), title)
        gtk_box_append(ptr(box), heading)

        let reason = Gtk.label(card.reason, css: "tool-detail", wrap: true, selectable: false)
        gtk_widget_set_halign(reason, GTK_ALIGN_START)
        gtk_box_append(ptr(box), reason)

        let attempt = Gtk.label(card.attemptLine, css: "retry-attempt", wrap: true, selectable: false)
        gtk_widget_set_halign(attempt, GTK_ALIGN_START)
        gtk_box_append(ptr(box), attempt)

        if let remedy = card.remedy {
            let remedyTitle = Gtk.label(remedy.title, css: "row-title", wrap: true, selectable: false)
            gtk_widget_set_halign(remedyTitle, GTK_ALIGN_START)
            gtk_box_append(ptr(box), remedyTitle)
            let remedyMessage = Gtk.label(
                remedy.message, css: "tool-detail", wrap: true, selectable: false)
            gtk_widget_set_halign(remedyMessage, GTK_ALIGN_START)
            gtk_box_append(ptr(box), remedyMessage)
            if let link = remedy.link {
                let button = Gtk.button(remedy.label, css: ["flat", "seam-read"]) {
                    Self.open(link)
                }
                gtk_widget_set_halign(button, GTK_ALIGN_START)
                gtk_box_append(ptr(box), button)
            }
        }
        return box
    }

    /// Opens a URL the way every other outside link on this desk does: a hand-off to the desktop
    /// rather than a browser this app would then have to own.
    static func open(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [url.absoluteString]
        try? process.run()
    }

    /// A revert standing on the conversation, where the messages it set aside used to be. The
    /// button wears this device's own press (`restoring`) until the server answers, which is state
    /// the banner itself does not carry: Core hands over one steady `restoreTitle`, and the two
    /// alphabets meet only here.
    static func revertBanner(
        _ banner: RevertBanner, restoring: Bool, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.groupBox(GTK_ORIENTATION_VERTICAL, spacing: 6, spoken: banner.spoken)
        Gtk.addClass(card, "card")
        Gtk.addClass(card, "card-revert")

        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(
            ptr(heading),
            Gtk.label(RevertBanner.glyph, css: RevertBanner.tone.glyphCSS, selectable: false))
        let title = Gtk.label(banner.title, css: "card-title", wrap: true, selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_halign(title, GTK_ALIGN_START)
        gtk_box_append(ptr(heading), title)
        gtk_box_append(ptr(card), heading)

        let detail = Gtk.label(banner.detail, css: "tool-detail", wrap: true, selectable: false)
        gtk_widget_set_halign(detail, GTK_ALIGN_START)
        gtk_box_append(ptr(card), detail)

        let (shown, more) = banner.files(upTo: 6)
        for file in shown {
            let text = [file.path, file.change, file.counts].compactMap { $0 }.joined(separator: " · ")
            let row = Gtk.label(text, css: "row-detail", wrap: true, selectable: false)
            gtk_widget_set_halign(row, GTK_ALIGN_START)
            gtk_box_append(ptr(card), row)
        }
        if let more {
            let line = Gtk.label(more, css: "row-note", wrap: true, selectable: false)
            gtk_widget_set_halign(line, GTK_ALIGN_START)
            gtk_box_append(ptr(card), line)
        }

        let button = Gtk.button(
            restoring ? RevertReading.restoringTitle : banner.restoreTitle, css: ["flat", "seam-read"]
        ) { context.restoreRevert?() }
        gtk_widget_set_sensitive(button, restoring ? 0 : 1)
        gtk_widget_set_halign(button, GTK_ALIGN_START)
        gtk_box_append(ptr(card), button)
        return card
    }
}
