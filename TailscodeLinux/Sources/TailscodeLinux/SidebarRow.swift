import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Every kind of row the chat list can draw, in one place: a section heading, a conversation, the
/// banner that says a server stopped answering, and the line that admits there is nothing here.
enum SidebarRow {
    /// A section's heading and the one figure worth putting beside it: how many agents are waiting
    /// or working, or how many rows under it are new. The "new" label is always built and handed
    /// back, so a count that moves is written into the heading that is standing rather than
    /// costing a rebuild of the list under it.
    static func header(_ heading: SectionHeading)
        -> (row: UnsafeMutablePointer<GtkWidget>, fresh: UnsafeMutablePointer<GtkWidget>)
    {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let label = Gtk.label(heading.title, css: "section-header", selectable: false)
        gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
        if heading.needsYou { Gtk.addClass(label, "section-needs") }
        gtk_box_append(ptr(row), label)
        let fresh = Gtk.label("", css: "section-fresh", selectable: false)
        gtk_label_set_ellipsize(op(fresh), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_hexpand(fresh, 1)
        gtk_box_append(ptr(row), fresh)
        setFresh(fresh, heading.freshLabel)
        if let total = heading.total {
            let tally = Gtk.label("\(total)", css: "section-header", selectable: false)
            if heading.needsYou { Gtk.addClass(tally, "section-needs") }
            gtk_label_set_ellipsize(op(tally), PANGO_ELLIPSIZE_NONE)
            gtk_label_set_xalign(op(tally), 1)
            gtk_widget_set_size_request(tally, 34, -1)
            gtk_box_append(ptr(row), tally)
        }
        tailscode_set_accessible_label(row, heading.spoken)
        return (row, fresh)
    }

    /// Writes how many rows under a heading are new, or takes the words away when none are.
    static func setFresh(_ label: UnsafeMutablePointer<GtkWidget>, _ words: String?) {
        gtk_label_set_text(op(label), words ?? "")
        gtk_widget_set_opacity(label, words == nil ? 0 : 1)
    }

    static func banner(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: "row-detail", wrap: true, selectable: false)
        Gtk.addClass(label, "glyph-error")
        Gtk.margins(label, top: 8, bottom: 8, leading: 12, trailing: 12)
        return label
    }

    /// The heading over what happened while nobody was here, with the way to dismiss the lot. The
    /// clear lives in the header rather than on each row: the list is read all at once or not at
    /// all, and a per-row dismiss turns catching up into filing.
    static func missedHeader(count: Int, onClear: @escaping @Sendable () -> Void)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let label = Gtk.label(
            Localized.text("MISSED"), css: "section-header", selectable: false)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(row), label)
        let clear = Gtk.button(Localized.text("clear"), css: ["flat", "dim"], onClick: onClear)
        gtk_widget_set_valign(clear, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(
            clear, Localized.text("Clear all %@ missed notices", "\(count)"))
        gtk_box_append(ptr(row), clear)
        return row
    }

    /// One thing that happened out of sight: what it was, in which chat, and how long ago.
    static func missed(_ item: MissedActivity, onOpen: @escaping @Sendable () -> Void)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "session-row")

        let face = item.reason.face
        let glyph = NotificationPlate.badge(face: face, side: 26)
            ?? Gtk.label(
                face.glyph,
                css: item.isBlocking
                    ? face.tone.glyphCSS : item.reason == .turnFailed ? "glyph-error" : "glyph-done",
                selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        Gtk.margins(glyph, top: 3)

        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.label(item.title, css: "row-title", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(titleRow), title)
        if item.isBlocking {
            gtk_box_append(ptr(titleRow), makePill(item.kindLabel.uppercased(), css: "pill-needs"))
        }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_box_append(ptr(column), titleRow)
        gtk_box_append(
            ptr(column),
            Gtk.label(
                "\(item.body) · \(StatusFacts.age(Date().timeIntervalSince(item.at))) ago",
                css: "row-detail", selectable: false))
        gtk_widget_set_hexpand(column, 1)

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 4, bottom: 4, leading: 4, trailing: 4)
        gtk_box_append(ptr(row), glyph)
        gtk_box_append(ptr(row), column)
        gtk_button_set_child(ptr(button), row)
        gtk_widget_set_hexpand(button, 1)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onOpen)
        return button
    }

    /// The heading over what was found, with the way back to the list. It names the query rather
    /// than saying "results", because the words that were searched for are the only thing that
    /// makes a result list readable a minute later.
    static func searchHeader(
        query: String, count: Int, running: Bool, onLeave: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let label = Gtk.label(
            running
                ? Localized.text("SEARCHING “%@”", query)
                : Localized.text("“%@” · %@", query, "\(count)"),
            css: "section-header", selectable: false)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(row), label)
        let leave = Gtk.button(Localized.text("back"), css: ["flat", "dim"], onClick: onLeave)
        gtk_widget_set_valign(leave, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(leave, Localized.text("Back to the chat list"))
        gtk_box_append(ptr(row), leave)
        return row
    }

    /// One conversation the words were found in: what it is, where it lives, and the places it
    /// said them — each quoted under the register it was in, so an answer, a thought and a shell
    /// command are told apart at a glance rather than read for.
    static func searchResult(
        _ result: TranscriptSearch.Row, onOpen: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "session-row")

        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.label(result.title, css: "row-title", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(titleRow), title)
        if result.isTitleOnly {
            gtk_box_append(ptr(titleRow), makePill(Localized.text("TITLE"), css: "pill-offline"))
        }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_box_append(ptr(column), titleRow)
        gtk_box_append(
            ptr(column),
            Gtk.label(
                [result.project, result.profileName].compactMap { $0 }.joined(separator: " · "),
                css: "row-detail", selectable: false))
        for match in result.matches.prefix(3) {
            let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
            let kind = Gtk.label(TranscriptSearch.label(for: match), css: "tool-name", selectable: false)
            gtk_label_set_ellipsize(op(kind), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_valign(kind, GTK_ALIGN_START)
            gtk_box_append(ptr(line), kind)
            let quote = Gtk.label(match.text, css: "row-detail", selectable: false)
            gtk_widget_set_hexpand(quote, 1)
            gtk_box_append(ptr(line), quote)
            gtk_box_append(ptr(column), line)
        }
        if result.total > result.matches.count {
            gtk_box_append(
                ptr(column),
                Gtk.label(
                    Localized.text("… %@ more in this chat", "\(result.total - result.matches.count)"),
                    css: "dim", selectable: false))
        }
        gtk_widget_set_hexpand(column, 1)

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 6, bottom: 6, leading: 4, trailing: 4)
        gtk_box_append(ptr(row), column)
        gtk_button_set_child(ptr(button), row)
        gtk_widget_set_hexpand(button, 1)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onOpen)
        return button
    }

    static func empty(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: "dim", wrap: true, selectable: false)
        Gtk.margins(label, top: 20, bottom: 20, leading: 12, trailing: 12)
        return label
    }

    /// One conversation, in the grammar `docs/session-list.md` sets for all three desks: a state
    /// column whose mark always means something, the title on a line of its own, a line of news
    /// only when there is news, and who, where and with what last.
    /// A right click hands back the row widget (as bits, for the sendable hop) and where inside it
    /// the click landed, so the caller can open a menu under the pointer. The row is also the
    /// handle a pointer picks the chat up by: it carries its own identity to whichever pane it is
    /// dragged onto.
    ///
    /// The mark lives in a button of its own beside the chat rather than inside it, because a
    /// press inside a `GtkButton` belongs to that button: a marker drawn into the row would open
    /// the conversation every time someone tried to select it.
    ///
    /// - Parameter section: the heading the row sits under, whose mark it need not wear again.
    /// - Parameter news: what the row has to say, decided by the list that holds it.
    static func make(
        _ model: SessionRowModel, focused: Bool, marked: Bool = false,
        vocabulary: ChatListVocabulary = .full, section: SessionSection? = nil,
        news: ChatRowNews? = nil,
        onOpen: @escaping @Sendable () -> Void,
        onMark: @escaping @Sendable (Bool) -> Void = { _ in },
        onAgents: (@Sendable () -> Void)? = nil,
        onMenu: @escaping @Sendable (UInt, Double, Double) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "session-row")
        if focused { Gtk.addClass(button, "row-focused") }
        if marked { Gtk.addClass(button, "row-marked") }
        if model.state == .offline { Gtk.addClass(button, "row-away") }

        let glyph = stateMark(model)
        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        Gtk.margins(glyph, top: 3)

        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.label(model.title, css: titleClass(model.emphasis), selectable: false)
        gtk_box_append(ptr(titleRow), title)
        let marks = model.titleMarks(under: section)
        for mark in marks { gtk_box_append(ptr(titleRow), flag(mark)) }
        if model.entry.session.expertID != nil { gtk_box_append(ptr(titleRow), masterFlag(model.entry)) }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_box_append(ptr(column), titleRow)
        if let news { gtk_box_append(ptr(column), newsLine(news)) }
        gtk_box_append(
            ptr(column), detailRow(model, vocabulary: vocabulary, onAgents: onAgents))
        gtk_widget_set_hexpand(column, 1)

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 4, bottom: 4, leading: 4, trailing: 4)
        gtk_box_append(ptr(row), glyph)
        gtk_box_append(ptr(row), column)
        gtk_button_set_child(ptr(button), row)
        gtk_widget_set_name(button, Words.button)
        tailscode_set_accessible_label(button, spoken(model, news: news, marks: marks))

        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onOpen)
        let buttonBits = UInt(bitPattern: button)
        Gtk.onRightClick(button) { x, y in onMenu(buttonBits, x, y) }
        Gtk.makeChatDragSource(
            button,
            payload: PaneDragPayload(
                profileID: model.entry.profileID, sessionID: model.entry.session.id).encoded)
        gtk_widget_set_hexpand(button, 1)

        let holder = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(holder, "session-row-holder")
        gtk_box_append(ptr(holder), makeMark(marked: marked, onMark: onMark))
        gtk_box_append(ptr(holder), button)
        return holder
    }

    /// The mark of the master a conversation is a task of, small after its title; a plain one
    /// until the shelf has read which master it is.
    static func masterFlag(_ entry: SessionEntry) -> UnsafeMutablePointer<GtkWidget> {
        let row = MasterDesk.shared.master(for: entry)
        let mark = row.map { MasterMarks.mark($0.master, size: .tiny) } ?? MasterMarks.mark("✦", hue: .gray, size: .tiny)
        Tip.set(mark, row.map { Localized.text("A task of %@", $0.master.name) } ?? MasterWords.title)
        return mark
    }

    /// A small mark after the title. This client is set in type, so a mark is a quiet word rather
    /// than a symbol somebody has to learn; the clock is the one glyph the list already uses.
    static func flag(_ mark: ChatRowInk.TitleMark) -> UnsafeMutablePointer<GtkWidget> {
        let word = mark == .scheduled ? mark.glyph : mark.spoken.lowercased()
        let flag = Gtk.label(word, css: "row-flag", selectable: false)
        gtk_label_set_ellipsize(op(flag), PANGO_ELLIPSIZE_NONE)
        Tip.set(flag, mark.spoken)
        return flag
    }

    /// What the state column draws: the state's own glyph, the unread dot on a row at rest, and
    /// nothing at all on a row that has been read, in a column that keeps its width either way so
    /// every title starts on one edge.
    private static func stateMark(_ model: SessionRowModel) -> UnsafeMutablePointer<GtkWidget> {
        let glyph: UnsafeMutablePointer<GtkWidget>
        switch model.columnMark {
        case .activity(let activity):
            glyph = Gtk.label(model.state.glyph.text, css: model.state.glyph.css, selectable: false)
            ActivityPulse.apply(activity.icon, to: glyph)
            Tip.set(glyph, activity.spoken)
        case .unread:
            glyph = Gtk.label("●", css: "unread-dot", selectable: false)
            Tip.set(glyph, Localized.text("Unread"))
        case .none:
            glyph = Gtk.label("", css: "glyph-pending", selectable: false)
        }
        Gtk.addClass(glyph, "row-state")
        gtk_label_set_ellipsize(op(glyph), PANGO_ELLIPSIZE_NONE)
        gtk_label_set_xalign(op(glyph), 0.5)
        return glyph
    }

    /// The title's face on the three rungs of ink.
    static func titleClass(_ emphasis: ChatRowInk.Emphasis) -> String {
        switch emphasis {
        case .strong: return "row-title-unread"
        case .plain: return "row-title"
        case .receded: return "row-title-read"
        }
    }

    /// The class a line of news wears, which is what gives it the tone of what it is.
    static func newsClass(_ voice: ChatRowNews.Voice) -> String {
        switch voice {
        case .asking: return "news-ask"
        case .working: return "news-live"
        case .failed: return "news-fail"
        case .said: return "news-said"
        case .away, .settled: return "news-quiet"
        }
    }

    /// The line of news under the title. A quoted answer and a question may take two lines; a
    /// status that is rewritten while the turn runs stays on one and is cut at its end, so a step
    /// that changes never changes the height of the row it is on.
    private static func newsLine(_ news: ChatRowNews) -> UnsafeMutablePointer<GtkWidget> {
        let lines = ChatRowInk.newsLines(news.voice, roomy: false)
        let words = [news.lead, news.object].compactMap { $0 }.filter { !$0.isEmpty }
        let label: UnsafeMutablePointer<GtkWidget>
        if let object = news.object, !object.isEmpty {
            label = Gtk.markupLabel(
                "\(PangoMarkdown.escape(news.lead)) <tt>\(PangoMarkdown.escape(object))</tt>",
                css: "row-news", wrap: lines > 1)
            gtk_label_set_selectable(op(label), 0)
        } else {
            label = Gtk.label(news.lead, css: "row-news", wrap: lines > 1, selectable: false)
        }
        Gtk.addClass(label, newsClass(news.voice))
        gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_END)
        gtk_label_set_lines(op(label), Int32(lines))
        gtk_label_set_xalign(op(label), 0)
        Tip.set(label, words.joined(separator: " "))
        gtk_widget_set_name(label, Words.news)
        return label
    }

    /// Everything a chat row draws except the words that move while its turn runs — the news
    /// line's text and the age. Two readings with the same face are the same widgets with other
    /// words in them, so the list sets the words (`patchWords`) instead of building the row again.
    struct Face: Equatable {
        let state: SessionRowState
        let column: ChatRowInk.ColumnMark
        let title: String
        let emphasis: ChatRowInk.Emphasis
        let marks: [ChatRowInk.TitleMark]
        let expert: String?
        let news: ChatRowNews.Voice?
        let newsObject: Bool
        let project: String?
        let origin: String?
        let chip: ModelChip?
        let agents: String?
        let focused: Bool
        let marked: Bool
    }

    static func face(
        _ model: SessionRowModel, focused: Bool, marked: Bool, vocabulary: ChatListVocabulary,
        section: SessionSection?, news: ChatRowNews?
    ) -> Face {
        let facets = model.facets(vocabulary)
        let count = model.entry.session.activeAgents ?? 0
        return Face(
            state: model.state, column: model.columnMark, title: model.title, emphasis: model.emphasis,
            marks: model.titleMarks(under: section), expert: model.entry.session.expertID,
            news: news?.voice, newsObject: !(news?.object ?? "").isEmpty, project: facets.project,
            origin: facets.origin, chip: ModelBadge.chip(for: model.entry),
            agents: count > 0 && (model.state == .live || model.state == .awaitingApproval)
                ? AgentsReading.agentsWords(count) : nil,
            focused: focused, marked: marked)
    }

    /// The names the moving parts of a row answer to, so a patch can find them again.
    enum Words {
        static let button = "row-open"
        static let news = "row-news-words"
        static let age = "row-age-words"
    }

    /// Sets the words of a row whose face has not changed: the news line, its tooltip, the age and
    /// what the row is called aloud. Says false when a part it needs is not where it was left, and
    /// the caller builds the row instead.
    static func patchWords(
        _ holder: UnsafeMutablePointer<GtkWidget>, model: SessionRowModel,
        vocabulary: ChatListVocabulary, section: SessionSection?, news: ChatRowNews?
    ) -> Bool {
        guard let button = Gtk.descendant(of: holder, named: Words.button),
            let age = Gtk.descendant(of: holder, named: Words.age)
        else { return false }
        let label = Gtk.descendant(of: holder, named: Words.news)
        guard (label != nil) == (news != nil) else { return false }
        if let news, let label {
            let words = [news.lead, news.object].compactMap { $0 }.filter { !$0.isEmpty }
            if let object = news.object, !object.isEmpty {
                gtk_label_set_markup(
                    op(label), "\(PangoMarkdown.escape(news.lead)) <tt>\(PangoMarkdown.escape(object))</tt>")
            } else {
                gtk_label_set_text(op(label), news.lead)
            }
            Tip.set(label, words.joined(separator: " "))
        }
        gtk_label_set_text(op(age), model.facets(vocabulary).age)
        tailscode_set_accessible_label(
            button, spoken(model, news: news, marks: model.titleMarks(under: section)))
        return true
    }

    /// What the row is called aloud: its name, what it is doing, what it has to say, and whether
    /// it is unread, in the order a person would say them.
    static func spoken(
        _ model: SessionRowModel, news: ChatRowNews?, marks: [ChatRowInk.TitleMark]
    ) -> String {
        var parts = [model.title]
        if let state = model.state.activity?.spoken { parts.append(state) }
        if let news, news.spoken != model.state.activity?.spoken { parts.append(news.spoken) }
        if model.unread { parts.append(Localized.text("Unread")) }
        parts.append(contentsOf: marks.map(\.spoken))
        return parts.joined(separator: ", ")
    }

    /// Several conversations held in one window, drawn as the one row they are. The names are the
    /// row's title, in the order the panes read; the shape and the count lead the detail line; and
    /// the state is the loudest pane's, because a split with a question waiting in it is a split
    /// that needs you.
    ///
    /// Each member also gets a line of its own under the row, because merging the rows must not
    /// take away the ability to open one chat: those are buttons, and a press inside a `GtkButton`
    /// belongs to that button, so the row's own button is a sibling of them rather than their
    /// parent.
    static func tab(
        _ model: SplitTabRow, focused: Bool, marked: Bool = false,
        onOpen: @escaping @Sendable () -> Void,
        onOpenMember: @escaping @Sendable (Int) -> Void,
        onMark: @escaping @Sendable (Bool) -> Void = { _ in },
        onMenu: @escaping @Sendable (UInt, Double, Double) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "session-row")
        Gtk.addClass(button, "split-tab-row")
        if focused { Gtk.addClass(button, "row-focused") }
        if marked { Gtk.addClass(button, "row-marked") }

        let state = model.state
        let glyph: UnsafeMutablePointer<GtkWidget>
        if let activity = state.activity {
            glyph = Gtk.label(state.glyph.text, css: state.glyph.css, selectable: false)
            ActivityPulse.apply(activity.icon, to: glyph)
            Tip.set(glyph, activity.spoken)
        } else if model.unread {
            glyph = Gtk.label("●", css: "unread-dot", selectable: false)
        } else {
            glyph = Gtk.label("", css: "glyph-pending", selectable: false)
        }
        Gtk.addClass(glyph, "row-state")
        gtk_label_set_ellipsize(op(glyph), PANGO_ELLIPSIZE_NONE)
        gtk_label_set_xalign(op(glyph), 0.5)
        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        Gtk.margins(glyph, top: 3)

        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let emphasis = ChatRowInk.emphasis(state: state, unread: model.unread)
        let title = Gtk.label(model.title, css: titleClass(emphasis), selectable: false)
        gtk_box_append(ptr(titleRow), title)
        if model.pinned { gtk_box_append(ptr(titleRow), flag(.pinned)) }

        let facets = model.facets()
        let detail = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let lead = Gtk.label(facets.project ?? "", css: "row-project", selectable: false)
        gtk_box_append(ptr(detail), lead)
        if let origin = facets.origin {
            let label = Gtk.label("· \(origin)", css: "row-detail", selectable: false)
            gtk_widget_set_hexpand(label, 1)
            gtk_box_append(ptr(detail), label)
        }
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(detail), spacer)
        let age = Gtk.label(facets.age, css: "row-age", selectable: false)
        gtk_label_set_ellipsize(op(age), PANGO_ELLIPSIZE_NONE)
        gtk_label_set_xalign(op(age), 1)
        gtk_widget_set_size_request(age, 30, -1)
        gtk_box_append(ptr(detail), age)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_box_append(ptr(column), titleRow)
        gtk_box_append(ptr(column), detail)
        gtk_widget_set_hexpand(column, 1)

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 4, bottom: 4, leading: 4, trailing: 4)
        gtk_box_append(ptr(row), glyph)
        gtk_box_append(ptr(row), column)
        gtk_button_set_child(ptr(button), row)
        gtk_widget_set_hexpand(button, 1)
        Tip.set(button, Localized.text("Open all of these as one split"))
        tailscode_set_accessible_label(button, model.accessibleLabel)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onOpen)
        let buttonBits = UInt(bitPattern: button)
        Gtk.onRightClick(button) { x, y in onMenu(buttonBits, x, y) }

        let top = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_box_append(ptr(top), makeMark(marked: marked, onMark: onMark))
        gtk_box_append(ptr(top), button)

        let holder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(holder, "session-row-holder")
        Gtk.addClass(holder, "split-tab-holder")
        gtk_box_append(ptr(holder), top)
        for (index, member) in model.members.enumerated() {
            gtk_box_append(ptr(holder), memberLine(member, index: index, onOpen: onOpenMember))
        }
        return holder
    }

    /// One conversation inside a remembered split, on a line of its own: pressing it opens that
    /// chat alone, the way its row would have before the split swallowed it.
    private static func memberLine(
        _ model: SessionRowModel, index: Int, onOpen: @escaping @Sendable (Int) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "split-tab-member")
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let glyph =
            model.state.activity == nil && model.unread
            ? Gtk.label("●", css: "unread-dot", selectable: false)
            : Gtk.label(model.state.glyph.text, css: model.state.glyph.css, selectable: false)
        gtk_label_set_ellipsize(op(glyph), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(line), glyph)
        let title = Gtk.label(
            model.title, css: model.unread ? "row-note" : "row-detail", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_label_set_xalign(op(title), 0)
        gtk_box_append(ptr(line), title)
        gtk_button_set_child(ptr(button), line)
        gtk_widget_set_hexpand(button, 1)
        Tip.set(button, Localized.text("Open just this chat"))
        tailscode_set_accessible_label(
            button, Localized.text("Open just %@", model.title))
        Gtk.makeChatDragSource(
            button,
            payload: PaneDragPayload(
                profileID: model.entry.profileID, sessionID: model.entry.session.id).encoded)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { onOpen(index) }
        return button
    }

    /// The accent moved, not the list: a row that is already on screen is re-marked in place. The
    /// row's own button is found by its class rather than by position, because a remembered split
    /// carries its members' lines under the same holder.
    static func setFocused(_ holder: UnsafeMutablePointer<GtkWidget>, _ focused: Bool) {
        guard gtk_widget_get_parent(holder) != nil, let button = rowButton(in: holder) else {
            return
        }
        if focused {
            gtk_widget_add_css_class(button, "row-focused")
        } else {
            gtk_widget_remove_css_class(button, "row-focused")
        }
    }

    private static func rowButton(_ depth: Int = 0, in widget: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget>?
    {
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if gtk_widget_has_css_class(current, "session-row") != 0 { return current }
            if depth < 2, let found = rowButton(depth + 1, in: current) { return found }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }

    private static func rowButton(in widget: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget>?
    {
        rowButton(0, in: widget)
    }

    /// The last line, read as three things rather than one: what the conversation is in and where
    /// it lives, what it runs on, and how long ago it moved. Who and where lead because the
    /// project is what a person recognises a chat by, and the model follows them a step back on a
    /// row at rest. The age is pinned to the trailing edge in monospace so it forms a straight
    /// column down the list — a staleness that has to be found at the end of a sentence of varying
    /// length is a fact nobody reads.
    private static func detailRow(
        _ model: SessionRowModel, vocabulary: ChatListVocabulary,
        onAgents: (@Sendable () -> Void)?
    ) -> UnsafeMutablePointer<GtkWidget> {
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let facets = model.facets(vocabulary)
        if let project = facets.project {
            gtk_box_append(ptr(line), Gtk.label(project, css: "row-project", selectable: false))
        }
        if let origin = facets.origin {
            let text = facets.project == nil ? origin : "· \(origin)"
            gtk_box_append(ptr(line), Gtk.label(text, css: "row-detail", selectable: false))
        }
        if let chip = ModelBadge.chip(for: model.entry) {
            let label = modelLabel(chip)
            if model.emphasis == .receded { Gtk.addClass(label, "row-model-read") }
            gtk_box_append(ptr(line), label)
        }
        if let agents = onAgents.flatMap({ agentsChip(model, onOpen: $0) }) {
            gtk_box_append(ptr(line), agents)
        }
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(line), spacer)
        let age = Gtk.label(facets.age, css: "row-age", selectable: false)
        gtk_widget_set_name(age, Words.age)
        gtk_label_set_ellipsize(op(age), PANGO_ELLIPSIZE_NONE)
        gtk_label_set_xalign(op(age), 1)
        gtk_widget_set_size_request(age, 30, -1)
        gtk_box_append(ptr(line), age)
        return line
    }

    /// The mark itself: quiet until the pointer is over the row or the chat is actually marked,
    /// so a list nobody is selecting in does not wear a column of empty boxes. It states which it
    /// is in its accessible name too — an opacity is not a label a screen reader can read. The
    /// handler is told whether shift was held, because the same press means two gestures: alone it
    /// marks the row, shifted it marks the whole span back to the anchored one.
    private static func makeMark(
        marked: Bool, onMark: @escaping @Sendable (Bool) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "row-mark")
        if marked { Gtk.addClass(button, "row-mark-on") }
        let glyph = Gtk.label(marked ? "☑" : "☐", css: "row-mark-glyph", selectable: false)
        gtk_label_set_ellipsize(op(glyph), PANGO_ELLIPSIZE_NONE)
        gtk_button_set_child(ptr(button), glyph)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        let label =
            marked
            ? Localized.text("Marked — click to unmark; shift-click marks the span to here")
            : Localized.text("Mark this chat — shift-click marks every chat back to it")
        Tip.set(button, label)
        tailscode_set_accessible_label(button, label)
        let buttonBits = UInt(bitPattern: button)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") {
            onMark(Gtk.shiftHeld(UnsafeMutablePointer<GtkWidget>(bitPattern: buttonBits)!))
        }
        return button
    }

    /// A pill is a word or it is nothing: three letters ellipsized to two and a dot say less than
    /// the state they stand for, so the pill keeps its whole width and the title — which ellipsizes
    /// gracefully and has room to spare — is what gives way when the list is narrow.
    private static func makePill(_ text: String, css: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: "pill", selectable: false)
        Gtk.addClass(label, css)
        gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        return label
    }

    /// The model wearing its family's hue and the effort wearing its heat, as the coloured words
    /// the detail line opens with. Typography, not chrome: pills on this list mean *state*, and a
    /// bordered box repeated down every row shouts over the titles it sits under — the identity
    /// is two emphasised words whose colour is the fact. Ultracode is not a heat, so its word is
    /// set letter by letter from the shared rainbow — the same stops the aura runs — held to the
    /// canvas's own contrast floor.
    static func modelLabel(_ chip: ModelChip) -> UnsafeMutablePointer<GtkWidget> {
        let palette = MatrixTheme.palette
        let family = ModelTint.identityHex(family: chip.family, name: chip.name, in: palette)
        var markup =
            "<span foreground=\"\(family)\" weight=\"600\">\(PangoMarkdown.escape(chip.name))</span>"
        if let effort = chip.effort {
            markup += " "
            if chip.isUltracode {
                let colors = ModelTint.rainbow(letters: effort.count, onCanvas: palette.canvas)
                markup += zip(effort, colors)
                    .map { "<span foreground=\"\($1)\" weight=\"600\">\($0)</span>" }
                    .joined()
            } else {
                let heat = ModelTint.effortHex(effort, in: palette) ?? palette.textDim
                markup +=
                    "<span foreground=\"\(heat)\" weight=\"600\">\(PangoMarkdown.escape(effort))</span>"
            }
        }
        let label = Gtk.markupLabel(markup, css: "row-model", wrap: false)
        gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_END)
        gtk_label_set_selectable(op(label), 0)
        return label
    }
}
