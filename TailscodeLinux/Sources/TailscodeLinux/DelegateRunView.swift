import CAdw
import CGtkShim
import CodingAgentKit
import TailscodeCore

/// One run, drawn from its `DelegateRunReading`: the headline and its facts, the one thing that
/// matters now, the ladder, exactly one primary action beside the rest, the patch's files, and one
/// timeline. Every word is Core's; this composes widgets and hands presses back.
enum DelegateRunView {
    static func make(
        reading: DelegateRunReading, board: DelegateBoard,
        onAction: @escaping @Sendable (DelegateRunAction.Kind) -> Void,
        onFile: @escaping @Sendable (String) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 18)
        Gtk.margins(column, top: 4, bottom: 20, leading: 4, trailing: 4)
        gtk_box_append(ptr(column), header(reading))
        if let lead = reading.lead { gtk_box_append(ptr(column), leadCard(lead)) }
        gtk_box_append(ptr(column), DelegateLadderView.run(reading.ladder))
        if let actions = actions(reading, board: board, onAction: onAction) {
            gtk_box_append(ptr(column), actions)
        }
        if let title = reading.filesTitle, !reading.files.isEmpty {
            gtk_box_append(ptr(column), files(title: title, rows: reading.files, onFile: onFile))
        }
        gtk_box_append(ptr(column), timeline(reading))
        return column
    }

    private static func header(_ reading: DelegateRunReading) -> UnsafeMutablePointer<GtkWidget> {
        let block = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let title = Gtk.label(reading.headline, css: "dg-headline", wrap: true, selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(titleRow), title)
        if let badge = reading.badge {
            let pill = Gtk.label(badge, css: "pill", selectable: false)
            DelegateToneCSS.applyPill(pill, reading.tone)
            gtk_widget_set_valign(pill, GTK_ALIGN_START)
            gtk_box_append(ptr(titleRow), pill)
        }
        gtk_box_append(ptr(block), titleRow)
        if !reading.facts.isEmpty {
            gtk_box_append(ptr(block), Gtk.label(reading.facts, css: "dg-facts", wrap: true, selectable: false))
        }
        return block
    }

    static func leadCard(_ lead: DelegateRunReading.Lead) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "dg-lead")
        Gtk.addClass(card, leadClass(lead.tone))
        let top = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let title = Gtk.label(lead.title, css: "dg-lead-title", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(top), title)
        if let caption = lead.caption {
            let label = Gtk.label(caption, css: "dg-lead-caption", selectable: false)
            gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_END)
            gtk_box_append(ptr(top), label)
        }
        gtk_box_append(ptr(card), top)
        if let body = lead.body, !body.isEmpty {
            let label = Gtk.label(body, css: lead.bodyIsOutput ? "dg-lead-output" : "dg-lead-body", wrap: true, selectable: lead.bodyIsOutput)
            if lead.bodyIsOutput { gtk_label_set_wrap_mode(op(label), PANGO_WRAP_WORD_CHAR) }
            gtk_box_append(ptr(card), label)
        }
        return card
    }

    static func leadClass(_ tone: ActivityTone) -> String {
        switch tone {
        case .live: return "dg-lead-live"
        case .attention: return "dg-lead-attention"
        case .danger: return "dg-lead-danger"
        case .quiet: return "dg-lead-quiet"
        }
    }

    private static func actions(
        _ reading: DelegateRunReading, board: DelegateBoard,
        onAction: @escaping @Sendable (DelegateRunAction.Kind) -> Void
    ) -> UnsafeMutablePointer<GtkWidget>? {
        var buttons: [UnsafeMutablePointer<GtkWidget>] = []
        if let primary = reading.primary { buttons.append(button(primary, onAction: onAction)) }
        for action in reading.secondary { buttons.append(button(action, onAction: onAction)) }
        if !reading.replayTiers.isEmpty {
            let labels = board.tiers.reduce(into: [String: String]()) { $0[$1.tier] = $1.label }
            let tiers = reading.replayTiers
            buttons.append(
                Gtk.menuButton(DelegateRunReading.replayMenuTitle, css: ["flat", "dg-action"]) {
                    tiers.map { tier in
                        let label = labels[tier].flatMap { $0.isEmpty ? nil : $0 }
                        return (
                            label.map { "\(tier) · \($0)" } ?? tier, nil,
                            { Gtk.onMain { onAction(.replay(tier: tier)) } } as @Sendable () -> Void
                        )
                    }
                })
        }
        guard !buttons.isEmpty else { return nil }
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        for button in buttons { gtk_box_append(ptr(row), button) }
        return row
    }

    private static func button(
        _ action: DelegateRunAction, onAction: @escaping @Sendable (DelegateRunAction.Kind) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let css: [String]
        switch action.role {
        case .primary: css = ["suggested-action", "dg-action"]
        case .normal: css = ["dg-action"]
        case .destructive: css = ["flat", "dg-action", "dg-danger-text"]
        }
        let kind = action.kind
        let button = Gtk.button(action.title, css: css) { Gtk.onMain { onAction(kind) } }
        if let detail = action.detail { gtk_widget_set_tooltip_text(button, detail) }
        return button
    }

    private static func files(
        title: String, rows: [DelegateFileRow], onFile: @escaping @Sendable (String) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_box_append(ptr(column), sectionLabel(title))
        for row in rows {
            let button = gtk_button_new()!
            Gtk.addClass(button, "flat")
            Gtk.addClass(button, "dg-file")
            let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let names = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            gtk_widget_set_hexpand(names, 1)
            gtk_box_append(ptr(names), Gtk.label(row.name, css: "dg-file-name", selectable: false))
            if !row.folder.isEmpty {
                let folder = Gtk.label(row.folder, css: "dg-file-folder", selectable: false)
                gtk_label_set_ellipsize(op(folder), PANGO_ELLIPSIZE_START)
                gtk_box_append(ptr(names), folder)
            }
            gtk_box_append(ptr(line), names)
            if let added = row.added, let removed = row.removed {
                if added > 0 { gtk_box_append(ptr(line), Gtk.label("+\(added)", css: "dg-added", selectable: false)) }
                if removed > 0 { gtk_box_append(ptr(line), Gtk.label("−\(removed)", css: "dg-removed", selectable: false)) }
            } else if let counts = row.counts {
                gtk_box_append(ptr(line), Gtk.label(counts, css: "dg-row-meta", selectable: false))
            }
            gtk_button_set_child(ptr(button), line)
            let path = row.path
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { Gtk.onMain { onFile(path) } }
            gtk_box_append(ptr(column), button)
        }
        return column
    }

    private static func timeline(_ reading: DelegateRunReading) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        gtk_box_append(ptr(column), sectionLabel(DelegateRunReading.timelineTitle))
        if reading.timeline.isEmpty {
            gtk_box_append(ptr(column), Gtk.label(Localized.text("Nothing yet."), css: "dg-note", selectable: false))
        }
        for line in reading.timeline {
            let label = Gtk.label(line.text, css: line.isProgress ? "dg-row-meta" : "row-detail", wrap: true, selectable: true)
            if line.isProgress {
                Gtk.margins(label, leading: 16)
            } else {
                DelegateToneCSS.apply(label, line.tone)
            }
            gtk_box_append(ptr(column), label)
            if let detail = line.detail, !detail.isEmpty {
                let tail = Gtk.label(detail, css: "dg-timeline-detail", wrap: true, selectable: true)
                gtk_label_set_wrap_mode(op(tail), PANGO_WRAP_WORD_CHAR)
                Gtk.margins(tail, top: 2, bottom: 4, leading: 16)
                gtk_box_append(ptr(column), tail)
            }
        }
        return column
    }

    static func sectionLabel(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text.uppercased(), css: "dg-section", selectable: false)
        Gtk.margins(label, top: 2, bottom: 2)
        return label
    }
}

/// The ladder as one row of connected rungs, cheapest first: on the board each rung carries its
/// model, its health and its record; on a run each carries where it stands for that run.
enum DelegateLadderView {
    static func board(_ rungs: [DelegateBoardRung]) -> UnsafeMutablePointer<GtkWidget> {
        row(rungs.map { rung in
            card(
                title: rung.title, model: rung.model, fullModel: rung.fullModel,
                notes: [(rung.health, rung.tone), (rung.record ?? Localized.text("untried"), .quiet)],
                state: nil)
        })
    }

    static func run(_ ladder: DelegateLadder) -> UnsafeMutablePointer<GtkWidget> {
        let widget = row(ladder.rungs.map { rung in
            card(
                title: rung.label.isEmpty ? rung.tier : "\(rung.tier) · \(rung.label)",
                model: rung.model.map(DelegateWords.shortModel), fullModel: rung.model,
                notes: [(ladder.word(for: rung), rung.state.tone)], state: rung.state)
        })
        gtk_widget_set_tooltip_text(widget, ladder.spoken)
        return widget
    }

    private static func row(_ cards: [UnsafeMutablePointer<GtkWidget>]) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        for (index, card) in cards.enumerated() {
            if index > 0 {
                let link = Gtk.label("›", css: "dg-rung-link", selectable: false)
                gtk_widget_set_valign(link, GTK_ALIGN_CENTER)
                gtk_box_append(ptr(row), link)
            }
            gtk_widget_set_hexpand(card, 1)
            gtk_box_append(ptr(row), card)
        }
        return row
    }

    private static func card(
        title: String, model: String?, fullModel: String?, notes: [(String?, ActivityTone)],
        state: DelegateRungState?
    ) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        Gtk.addClass(card, "dg-rung")
        if let state { Gtk.addClass(card, stateClass(state)) }
        gtk_box_append(ptr(card), Gtk.label(title, css: "dg-rung-label", selectable: false))
        if let model, !model.isEmpty {
            let label = Gtk.label(model, css: "dg-rung-model", selectable: false)
            gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_END)
            if let fullModel { gtk_widget_set_tooltip_text(label, fullModel) }
            gtk_box_append(ptr(card), label)
        }
        for (text, tone) in notes {
            guard let text, !text.isEmpty else { continue }
            let label = Gtk.label(text, css: "dg-rung-note", selectable: false)
            gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_END)
            if tone != .quiet { DelegateToneCSS.apply(label, tone) }
            gtk_box_append(ptr(card), label)
        }
        return card
    }

    private static func stateClass(_ state: DelegateRungState) -> String {
        switch state {
        case .current, .passed: return "dg-rung-lit"
        case .failed: return "dg-rung-failed"
        case .held: return "dg-rung-held"
        case .belowStart, .beyondCeiling, .skipped: return "dg-rung-off"
        case .pending: return "dg-rung-pending"
        }
    }

    /// The run's ladder at the size of a row: one pip per rung, lit where it passed or is working.
    static func pips(_ states: [DelegateRungState]) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 3)
        gtk_widget_set_valign(row, GTK_ALIGN_CENTER)
        for state in states {
            let pip = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            Gtk.addClass(pip, "dg-pip")
            switch state {
            case .current, .passed: Gtk.addClass(pip, "dg-pip-lit")
            case .failed: Gtk.addClass(pip, "dg-pip-failed")
            case .held: Gtk.addClass(pip, "dg-pip-held")
            case .belowStart, .beyondCeiling, .skipped: Gtk.addClass(pip, "dg-pip-off")
            case .pending: break
            }
            gtk_widget_set_valign(pip, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(row), pip)
        }
        return row
    }
}
