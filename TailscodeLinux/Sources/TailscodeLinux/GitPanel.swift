import CAdw
import CodingAgentKit
import Foundation
import TailscodeCore

extension GitTone {
    /// The class the panel's ink wears — Core names it, so the stylesheet, the band and the panel
    /// cannot drift into three vocabularies.
    var css: String { self == .neutral ? "git-neutral" : cssName }

    /// The same meaning as a colour, for the runs a band paints inside one label.
    var hex: String {
        let palette = MatrixTheme.palette
        switch self {
        case .added: return palette.accent
        case .removed: return palette.danger
        case .changed: return palette.info
        case .untracked: return palette.textDim
        case .conflict: return palette.warn
        case .neutral: return palette.text
        }
    }
}

/// What the repository behind this conversation is doing — read, never operated.
///
/// The band says which branch the work is landing on; this opens the whole of it: what the working
/// tree holds that no commit does, arranged in the order a person triages in, and one click from
/// any path to what actually changed in it. Nothing here writes: staging or committing from a
/// remote client is a change nobody reviewed on the machine that has to live with it.
enum GitPanel {
    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?, state: GitState, title: String,
        patch: @escaping @Sendable (GitRow) async -> String?,
        commit: @escaping @Sendable (GitCommitRow) async -> String?
    ) {
        let (window, content) = Dialogs.window(
            title: Localized.text("Repository"), parent: parent, width: 560)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
        gtk_box_append(ptr(column), header(state, title: title))
        for section in state.sections {
            gtk_box_append(ptr(column), files(section, parent: window, patch: patch))
        }
        if let note = note(state) {
            gtk_box_append(ptr(column), Gtk.label(note, css: "usage-source", wrap: true))
        }
        if !state.commits.isEmpty {
            gtk_box_append(ptr(column), commits(state, parent: window, commit: commit))
        }

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_max_content_height(op(scroller), 640)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_child(op(scroller), column)
        gtk_box_append(ptr(content), scroller)

        let windowBits = UInt(bitPattern: window)
        let dismiss = Gtk.button(Localized.text("Close"), css: ["suggested-action"]) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return }
            gtk_window_destroy(ptr(raw))
        }
        gtk_widget_set_halign(dismiss, GTK_ALIGN_END)
        Gtk.margins(dismiss, top: 4)
        gtk_box_append(ptr(content), dismiss)
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(dismiss)
    }

    /// The branch first, because it is the answer to "where is this landing"; then what it owes
    /// the upstream, then the working tree in one line — and, above all of it when the repository
    /// has stopped mid-merge, the line that says so.
    private static func header(_ state: GitState, title: String)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "usage-card")

        let name = Gtk.label(title, css: "usage-plan", selectable: false)
        gtk_label_set_ellipsize(op(name), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(op(name), 0)
        gtk_box_append(ptr(card), name)

        let branch = Gtk.label(state.title, css: "spend-total", selectable: false)
        gtk_label_set_ellipsize(op(branch), PANGO_ELLIPSIZE_MIDDLE)
        gtk_widget_set_halign(branch, GTK_ALIGN_START)
        gtk_box_append(ptr(card), branch)

        let sync = Gtk.label(state.sync, css: state.syncTone.css, selectable: false)
        gtk_label_set_xalign(op(sync), 0)
        gtk_box_append(ptr(card), sync)

        let summary = Gtk.markupLabel(
            state.summaryParts.map {
                "<span foreground='\($0.tone.hex)'>\(PangoMarkdown.escape($0.text))</span>"
            }.joined(separator: "<span alpha='45%'> · </span>"), css: "usage-detail-key",
            wrap: false)
        gtk_label_set_xalign(op(summary), 0)
        gtk_box_append(ptr(card), summary)

        if let alert = state.alert {
            let banner = Gtk.label(alert, css: "git-alert", wrap: true, selectable: false)
            gtk_label_set_xalign(op(banner), 0)
            gtk_widget_set_hexpand(banner, 1)
            gtk_box_append(ptr(card), banner)
        }

        for fact in state.facts {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
            let key = Gtk.label(fact.label, css: "usage-detail-key", selectable: false)
            gtk_label_set_xalign(op(key), 0)
            gtk_widget_set_hexpand(key, 1)
            gtk_box_append(ptr(row), key)
            let value = Gtk.label(
                fact.value, css: fact.tone == .neutral ? "usage-detail-value" : fact.tone.css,
                selectable: true)
            gtk_label_set_ellipsize(op(value), PANGO_ELLIPSIZE_MIDDLE)
            gtk_box_append(ptr(row), value)
            gtk_box_append(ptr(card), row)
        }
        return card
    }

    private static func files(
        _ section: GitSection, parent: UnsafeMutablePointer<GtkWidget>,
        patch: @escaping @Sendable (GitRow) async -> String?
    ) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        Gtk.addClass(card, "usage-card")
        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let title = Gtk.label(section.title, css: section.tone.css, selectable: false)
        gtk_label_set_xalign(op(title), 0)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(heading), title)
        let count = Gtk.label("\(section.rows.count)", css: "spend-caption", selectable: false)
        gtk_label_set_ellipsize(op(count), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(heading), count)
        gtk_box_append(ptr(card), heading)

        let parentBits = UInt(bitPattern: parent)
        for entry in section.rows {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            Gtk.addClass(row, "git-row")
            let glyph = Gtk.label(entry.kind.glyph, css: entry.tone.css, selectable: false)
            gtk_label_set_ellipsize(op(glyph), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_size_request(glyph, 14, -1)
            gtk_box_append(ptr(row), glyph)

            let path = Gtk.markupLabel(name(of: entry), css: "usage-gauge-label", wrap: false)
            gtk_label_set_ellipsize(op(path), PANGO_ELLIPSIZE_MIDDLE)
            gtk_label_set_xalign(op(path), 0)
            gtk_widget_set_hexpand(path, 1)
            gtk_widget_set_tooltip_text(row, entry.spoken)
            gtk_box_append(ptr(row), path)

            if !entry.detail.isEmpty {
                let counts = Gtk.markupLabel(countsMarkup(entry), css: "spend-caption", wrap: false)
                gtk_label_set_ellipsize(op(counts), PANGO_ELLIPSIZE_NONE)
                gtk_box_append(ptr(row), counts)
            }
            Gtk.onRelease(row) {
                Gtk.onMain {
                    guard let raw = UnsafeMutableRawPointer(bitPattern: parentBits) else { return }
                    GitDiffWindow.present(
                        parent: raw.assumingMemoryBound(to: GtkWidget.self), title: entry.name,
                        subtitle: entry.path, load: { await patch(entry) })
                }
            }
            gtk_box_append(ptr(card), row)
        }
        return card
    }

    private static func commits(
        _ state: GitState, parent: UnsafeMutablePointer<GtkWidget>,
        commit: @escaping @Sendable (GitCommitRow) async -> String?
    ) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        Gtk.addClass(card, "usage-card")
        let title = Gtk.label(Localized.text("RECENT COMMITS"), css: "git-neutral", selectable: false)
        gtk_label_set_xalign(op(title), 0)
        gtk_box_append(ptr(card), title)

        let parentBits = UInt(bitPattern: parent)
        for entry in state.commits.prefix(20) {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            Gtk.addClass(row, "git-row")
            let hash = Gtk.label(entry.short, css: entry.isHead ? "git-added" : "spend-caption", selectable: false)
            gtk_label_set_ellipsize(op(hash), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_size_request(hash, 66, -1)
            gtk_label_set_xalign(op(hash), 0)
            gtk_box_append(ptr(row), hash)
            let subject = Gtk.label(entry.subject, css: "usage-gauge-label", selectable: false)
            gtk_label_set_ellipsize(op(subject), PANGO_ELLIPSIZE_END)
            gtk_label_set_xalign(op(subject), 0)
            gtk_widget_set_hexpand(subject, 1)
            gtk_box_append(ptr(row), subject)
            let age = Gtk.label(entry.age, css: "spend-caption", selectable: false)
            gtk_label_set_ellipsize(op(age), PANGO_ELLIPSIZE_NONE)
            gtk_box_append(ptr(row), age)
            var tip = [entry.short, entry.author, entry.age]
            if !entry.refs.isEmpty { tip.append(entry.refs.joined(separator: ", ")) }
            gtk_widget_set_tooltip_text(row, tip.joined(separator: " · "))
            Gtk.onRelease(row) {
                Gtk.onMain {
                    guard let raw = UnsafeMutableRawPointer(bitPattern: parentBits) else { return }
                    GitDiffWindow.present(
                        parent: raw.assumingMemoryBound(to: GtkWidget.self), title: entry.subject,
                        subtitle: "\(entry.short) · \(entry.author) · \(entry.age)",
                        load: { await commit(entry) })
                }
            }
            gtk_box_append(ptr(card), row)
        }
        return card
    }

    private static func note(_ state: GitState) -> String? {
        if !state.isRepository {
            return Localized.text("This conversation is not working inside a git repository.")
        }
        if state.truncated, state.hiddenCount > 0 {
            return Localized.text("%d more changed paths are not listed.", state.hiddenCount)
        }
        if state.isClean {
            return Localized.text("Nothing has been touched since the last commit.")
        }
        return nil
    }

    /// The file, then where it lives — the name is what a reader scans for, so the directory it
    /// sits in follows it dimmed rather than leading and pushing every name out of alignment.
    private static func name(of row: GitRow) -> String {
        let name = PangoMarkdown.escape(row.name)
        if let original = row.original {
            return "\(name) <span alpha='55%'>← \(PangoMarkdown.escape(original))</span>"
        }
        guard !row.folder.isEmpty else { return name }
        return "\(name) <span alpha='55%'>\(PangoMarkdown.escape(row.folder))</span>"
    }

    private static func countsMarkup(_ row: GitRow) -> String {
        guard row.hasCounts else {
            return "<span alpha='60%'>\(PangoMarkdown.escape(row.detail))</span>"
        }
        var parts: [String] = []
        if row.insertions > 0 {
            parts.append(
                "<span foreground='\(MatrixTheme.palette.accent)'>+\(GitState.number(row.insertions))</span>")
        }
        if row.deletions > 0 {
            parts.append(
                "<span foreground='\(MatrixTheme.palette.danger)'>−\(GitState.number(row.deletions))</span>")
        }
        return parts.joined(separator: " ")
    }
}

/// One file's change, or one commit's, in the colours a reviewer expects and with the line numbers
/// they need to find it again. The whole patch is one Pango label: four thousand widgets to draw a
/// diff is four thousand widgets GTK has to lay out every time the window resizes.
enum GitDiffWindow {
    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?, title: String, subtitle: String,
        load: @escaping @Sendable () async -> String?
    ) {
        let (window, content) = Dialogs.window(title: title, parent: parent, width: 760)
        let caption = Gtk.label(subtitle, css: "usage-plan", selectable: true)
        gtk_label_set_ellipsize(op(caption), PANGO_ELLIPSIZE_MIDDLE)
        gtk_label_set_xalign(op(caption), 0)
        gtk_box_append(ptr(content), caption)

        let body = Gtk.markupLabel("", css: "git-diff", wrap: false)
        gtk_label_set_xalign(op(body), 0)
        gtk_label_set_yalign(op(body), 0)
        gtk_label_set_selectable(op(body), 1)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_min_content_height(op(scroller), 420)
        gtk_scrolled_window_set_max_content_height(op(scroller), 620)
        gtk_scrolled_window_set_child(op(scroller), body)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_box_append(ptr(content), scroller)

        let windowBits = UInt(bitPattern: window)
        let dismiss = Gtk.button(Localized.text("Close"), css: ["suggested-action"]) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return }
            gtk_window_destroy(ptr(raw))
        }
        gtk_widget_set_halign(dismiss, GTK_ALIGN_END)
        gtk_box_append(ptr(content), dismiss)
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(dismiss)

        let bodyBits = UInt(bitPattern: body)
        Task {
            let patch = await load()
            let markup = patch.map(Self.markup) ?? Localized.text("This server could not produce a diff for that.")
            Gtk.onMain {
                guard let raw = UnsafeMutableRawPointer(bitPattern: bodyBits) else { return }
                gtk_label_set_markup(op(raw.assumingMemoryBound(to: GtkWidget.self)), markup)
            }
        }
    }

    static func markup(_ patch: String) -> String {
        let palette = MatrixTheme.palette
        var lines: [String] = []
        for line in GitPatchReader.lines(patch) {
            let text = PangoMarkdown.escape(line.text)
            let gutter = line.kind == .deletion ? line.oldLine : line.newLine
            let number = gutter.map { String(format: "%5d", $0) } ?? "     "
            let stamp = "<span alpha='40%'>\(number)</span> "
            switch line.kind {
            case .addition:
                lines.append("\(stamp)<span foreground='\(palette.accent)'>+ \(text)</span>")
            case .deletion:
                lines.append("\(stamp)<span foreground='\(palette.danger)'>− \(text)</span>")
            case .hunk:
                lines.append("<span foreground='\(palette.info)'>\(text)</span>")
            case .meta:
                lines.append("<span alpha='45%'>\(text)</span>")
            case .context:
                lines.append("\(stamp)  <span alpha='75%'>\(text)</span>")
            }
        }
        return lines.isEmpty ? Localized.text("No textual change to show.") : lines.joined(separator: "\n")
    }
}
