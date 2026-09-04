import CAdw
import CGtkShim
import TailscodeCore

/// One run, drawn: the ladder it climbed, the story in the daemon's own lines, every attempt, and
/// the two or three actions the run earns. `DelegateRunStory` and `DelegateBoard` decide every
/// word; this only composes rows from them, the way `ForgeBoardView`/`TaskBoardView` do for their
/// own boards.
enum DelegateRunView {
    static func make(
        story: DelegateRunStory, board: DelegateBoard,
        onApprove: @escaping @Sendable () -> Void,
        onHold: @escaping @Sendable () -> Void,
        onCancel: @escaping @Sendable () -> Void,
        onReplay: @escaping @Sendable (String) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 14)
        Gtk.margins(column, top: 4, bottom: 16, leading: 4, trailing: 4)

        gtk_box_append(ptr(column), header(story))
        gtk_box_append(ptr(column), ladder(story))
        if let actions = actions(story, board: board, onApprove: onApprove, onHold: onHold, onCancel: onCancel, onReplay: onReplay) {
            gtk_box_append(ptr(column), actions)
        }
        gtk_box_append(ptr(column), sectionLabel(Localized.text("Story")))
        gtk_box_append(ptr(column), lines(story))
        if !story.attempts.isEmpty {
            gtk_box_append(ptr(column), sectionLabel(Localized.text("Attempts")))
            gtk_box_append(ptr(column), attempts(story))
        }
        return column
    }

    private static func header(_ story: DelegateRunStory) -> UnsafeMutablePointer<GtkWidget> {
        let block = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let title = Gtk.label(story.headline, css: "row-title-unread", wrap: true, selectable: true)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(titleRow), title)
        if let badge = story.badge {
            let pill = Gtk.label(badge, css: "pill", selectable: false)
            DelegateToneCSS.applyPill(pill, story.tone)
            gtk_widget_set_valign(pill, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(titleRow), pill)
        }
        gtk_box_append(ptr(block), titleRow)
        let subtitle = Gtk.label(story.subtitle, css: "row-detail", wrap: true, selectable: true)
        gtk_box_append(ptr(block), subtitle)
        return block
    }

    private static func ladder(_ story: DelegateRunStory) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        for rung in story.ladder.rungs {
            let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
            Gtk.addClass(card, "delegate-rung")
            Gtk.margins(card, top: 6, bottom: 6, leading: 10, trailing: 10)
            let name = Gtk.label(
                rung.label.isEmpty ? rung.tier : rung.label, css: "row-title", selectable: false)
            gtk_box_append(ptr(card), name)
            let word = Gtk.label(DelegateLadder.word(rung.state), css: "row-detail", selectable: false)
            DelegateToneCSS.apply(word, rung.state.tone)
            gtk_box_append(ptr(card), word)
            if let model = rung.model, !model.isEmpty {
                let modelLabel = Gtk.label(model, css: "watch-meta", selectable: false)
                gtk_label_set_ellipsize(op(modelLabel), PANGO_ELLIPSIZE_END)
                gtk_label_set_max_width_chars(op(modelLabel), 20)
                gtk_box_append(ptr(card), modelLabel)
            }
            gtk_box_append(ptr(row), card)
        }
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
        gtk_scrolled_window_set_child(op(scroller), row)
        return scroller
    }

    private static func actions(
        _ story: DelegateRunStory, board: DelegateBoard,
        onApprove: @escaping @Sendable () -> Void, onHold: @escaping @Sendable () -> Void,
        onCancel: @escaping @Sendable () -> Void, onReplay: @escaping @Sendable (String) -> Void
    ) -> UnsafeMutablePointer<GtkWidget>? {
        var buttons: [UnsafeMutablePointer<GtkWidget>] = []
        if story.needsApproval {
            buttons.append(
                Gtk.button(Localized.text("Approve"), css: ["suggested-action", "pill"]) {
                    Gtk.onMain(onApprove)
                })
            buttons.append(
                Gtk.button(Localized.text("Hold"), css: ["pill"]) { Gtk.onMain(onHold) })
        }
        if story.isLive {
            buttons.append(
                Gtk.button(Localized.text("Cancel"), css: ["destructive-action", "pill"]) {
                    Gtk.onMain(onCancel)
                })
        }
        let tiers = story.tierOrder.isEmpty ? board.tierOrder : story.tierOrder
        if !tiers.isEmpty {
            let labels = board.tiers.reduce(into: [String: String]()) { $0[$1.tier] = $1.label }
            buttons.append(
                Gtk.menuButton(Localized.text("Replay on…"), css: ["pill"]) {
                    tiers.map { tier in
                        let title = labels[tier].map { "\($0.isEmpty ? tier : $0)" } ?? tier
                        return (title, nil, { Gtk.onMain { onReplay(tier) } } as @Sendable () -> Void)
                    }
                })
        }
        guard !buttons.isEmpty else { return nil }
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        for button in buttons { gtk_box_append(ptr(row), button) }
        return row
    }

    static func sectionLabel(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text.uppercased(), css: "watch-section-detail", selectable: false)
        Gtk.margins(label, top: 4)
        return label
    }

    private static func lines(_ story: DelegateRunStory) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
        if story.lines.isEmpty {
            gtk_box_append(
                ptr(column), Gtk.label(Localized.text("Nothing yet."), css: "dim", selectable: false))
        }
        for line in story.lines {
            let label = Gtk.label(line.text, css: line.isProgress ? "watch-meta" : "row-detail", wrap: true, selectable: true)
            if !line.isProgress { DelegateToneCSS.apply(label, line.tone) }
            if line.isProgress { Gtk.margins(label, leading: 16) }
            gtk_box_append(ptr(column), label)
        }
        return column
    }

    private static func attempts(_ story: DelegateRunStory) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        for outcome in story.attempts {
            let block = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
            let label = Gtk.label(
                DelegateRunStory.attemptLine(outcome), css: "row-detail", wrap: true, selectable: true)
            DelegateToneCSS.apply(label, DelegateWords.tone(outcome.status))
            gtk_box_append(ptr(block), label)
            if outcome.status == .fail, !outcome.verifyTail.isEmpty {
                let tail = Gtk.label(outcome.verifyTail, css: "tool-line", wrap: true, selectable: true)
                gtk_label_set_max_width_chars(op(tail), 80)
                gtk_box_append(ptr(block), tail)
            }
            gtk_box_append(ptr(column), block)
        }
        return column
    }
}
