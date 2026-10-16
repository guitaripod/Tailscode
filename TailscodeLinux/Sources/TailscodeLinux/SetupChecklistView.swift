import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A machine checklist drawn from Core's `SetupChecklist` and from nothing else: a headline with
/// its state glyph, one card per row (glyph, title, one line of facts, and the row's fix), and the
/// single primary button at the foot.
///
/// A row's fix is whichever of three things it is: a button for a job the machine does, which turns
/// into a determinate bar with its bytes and the time left and a Cancel the moment it runs; one
/// command in a monospace block with Copy and the reason it needs a person; or, when nothing can be
/// done from here, only the explanation. Every word is Core's and the view decides none of them.
///
/// It is rewritten in place. A download lands a new reading every second for minutes, and a list
/// rebuilt on each one would move the button under the pointer and drop a selected command: a row is
/// replaced only when its shape (state, fix, whether a bar is showing) changes, and otherwise its
/// labels and bar are updated where they stand.
final class SetupChecklistView: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    let footer: UnsafeMutablePointer<GtkWidget>

    var onPrimary: ((SetupAction) -> Void)?
    var onFix: ((SetupRowFix) -> Void)?
    var onCancel: (() -> Void)?
    var onChange: (() -> Void)?

    private let headlineGlyph = Gtk.label("·", selectable: false)
    private let nameLabel = Gtk.label("", css: "setup-name", selectable: false)
    private let headlineLabel = Gtk.label("", css: "preflight-headline", wrap: true, selectable: false)
    private let titleLine = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let rowsBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
    private let placeBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let placeLabel = Gtk.label("", css: "preview-row-detail", selectable: false)
    private var placeButton: UnsafeMutablePointer<GtkWidget>?
    private let primaryButton = gtk_button_new()!
    private let footerBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private var badge: BetaBadge?
    private var badgeFeature: BetaFeature?
    private var rowViews: [String: RowView] = [:]
    private var order: [String] = []
    private var checklist: SetupChecklist?
    private var copied = false
    private let reportLines: @Sendable () -> [String]

    private static let glyphTones = ActivityTone.allCases.map(\.glyphCSS)

    init(reportLines: @escaping @Sendable () -> [String] = { [] }) {
        self.reportLines = reportLines
        let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 16)
        widget = root
        footer = footerBox
        gtk_widget_set_halign(footerBox, GTK_ALIGN_END)

        gtk_widget_set_valign(headlineGlyph, GTK_ALIGN_START)
        gtk_widget_set_size_request(headlineGlyph, 20, -1)
        gtk_box_append(ptr(titleLine), nameLabel)
        let titles = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        gtk_widget_set_hexpand(titles, 1)
        gtk_box_append(ptr(titles), titleLine)
        gtk_box_append(ptr(titles), headlineLabel)
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_box_append(ptr(header), headlineGlyph)
        gtk_box_append(ptr(header), titles)
        gtk_box_append(ptr(root), header)

        gtk_widget_set_hexpand(placeLabel, 1)
        gtk_label_set_xalign(op(placeLabel), 0)
        gtk_box_append(ptr(placeBox), placeLabel)
        gtk_widget_set_visible(placeBox, 0)
        gtk_box_append(ptr(root), placeBox)

        gtk_box_append(ptr(root), rowsBox)

        Gtk.addClass(primaryButton, "suggested-action")
        Gtk.addClass(primaryButton, "pill")
        gtk_widget_set_visible(primaryButton, 0)
        Gtk.connect(UnsafeMutableRawPointer(primaryButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.pressPrimary() }
        }
        gtk_box_append(ptr(footerBox), primaryButton)
    }

    var primaryLabel: String {
        gtk_button_get_label(ptr(primaryButton)).map { String(cString: $0) } ?? ""
    }

    var primaryVisible: Bool { gtk_widget_get_visible(primaryButton) != 0 }

    var headlineText: String { gtk_label_get_text(op(headlineLabel)).map { String(cString: $0) } ?? "" }

    var rowCount: Int { order.count }

    func rowWidget(_ id: String) -> UnsafeMutablePointer<GtkWidget>? { rowViews[id]?.widget }

    func glyphOpacity(of id: String) -> Double? { rowViews[id].map { gtk_widget_get_opacity($0.glyphWidget) } }

    func jobFraction(of id: String) -> Double? {
        rowViews[id]?.barWidget.map { gtk_progress_bar_get_fraction(op($0)) }
    }

    func tearDown() { badge?.tearDown() }

    func apply(_ next: SetupChecklist) {
        checklist = next
        gtk_label_set_text(op(nameLabel), next.name)
        placeBadge(for: next)
        gtk_label_set_text(op(headlineGlyph), next.icon.glyph)
        Gtk.setTone(headlineGlyph, next.icon.tone.glyphCSS, from: Self.glyphTones)
        ActivityPulse.apply(next.icon, to: headlineGlyph)
        gtk_label_set_text(op(headlineLabel), next.headline)
        tailscode_set_accessible_label(widget, next.spoken)
        renderPlace(next.place)
        renderRows(next.rows)
        renderPrimary(next.primary)
    }

    private func renderPlace(_ place: SetupPlace?) {
        guard let place else {
            gtk_widget_set_visible(placeBox, 0)
            return
        }
        gtk_label_set_text(op(placeLabel), place.line)
        if let placeButton {
            gtk_button_set_label(ptr(placeButton), place.changeLabel)
        } else if onChange != nil {
            let button = Gtk.button(place.changeLabel, css: ["flat"]) { [weak self] in
                Gtk.onMain { [weak self] in self?.onChange?() }
            }
            gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(placeBox), button)
            placeButton = button
        }
        gtk_widget_set_visible(placeBox, 1)
    }

    var placeText: String? {
        gtk_widget_get_visible(placeBox) == 0 ? nil : gtk_label_get_text(op(placeLabel)).map { String(cString: $0) }
    }

    var offersChange: Bool { placeButton != nil && gtk_widget_get_visible(placeBox) != 0 }

    private func placeBadge(for next: SetupChecklist) {
        guard next.beta != badgeFeature else { return }
        if let badge {
            gtk_box_remove(ptr(titleLine), badge.widget)
            badge.tearDown()
            self.badge = nil
        }
        badgeFeature = next.beta
        guard let feature = next.beta else { return }
        let made = BetaBadge(feature: feature, reportLines: reportLines)
        gtk_box_append(ptr(titleLine), made.widget)
        badge = made
    }

    private func renderRows(_ rows: [SetupRow]) {
        let ids = rows.map(\.id)
        for stale in Set(rowViews.keys).subtracting(ids) { rowViews.removeValue(forKey: stale) }
        var changedOrder = ids != order
        for row in rows {
            if let existing = rowViews[row.id], existing.shape == RowView.shape(of: row) {
                existing.update(row)
            } else {
                rowViews[row.id] = RowView(row: row, view: self)
                changedOrder = true
            }
        }
        if changedOrder {
            Gtk.replaceChildren(of: rowsBox, with: ids.compactMap { rowViews[$0]?.widget })
            order = ids
        }
    }

    private func renderPrimary(_ action: SetupAction?) {
        guard let action else {
            gtk_widget_set_visible(primaryButton, 0)
            return
        }
        gtk_widget_set_visible(primaryButton, 1)
        gtk_button_set_label(ptr(primaryButton), copied && isCopy(action) ? DelegateSetup.copied : action.label)
        tailscode_set_accessible_label(primaryButton, action.label)
    }

    private func isCopy(_ action: SetupAction) -> Bool {
        if case .copy = action { return true }
        return false
    }

    private func pressPrimary() {
        guard let action = checklist?.primary else { return }
        if case .copy(let command, _) = action {
            Gtk.copyToClipboard(command)
            flashCopied()
        }
        onPrimary?(action)
    }

    private func flashCopied() {
        copied = true
        renderPrimary(checklist?.primary)
        Gtk.after(1500) { [weak self] in
            Gtk.onMain { [weak self] in
                self?.copied = false
                self?.renderPrimary(self?.checklist?.primary)
            }
        }
    }

    fileprivate func press(fix: SetupRowFix) { onFix?(fix) }

    fileprivate func pressCancel() { onCancel?() }

    var report: String {
        guard let checklist else { return "empty" }
        let rows = checklist.rows.map { "\($0.id)=\($0.state)" }.joined(separator: ",")
        return "status=\(checklist.status) headline=\"\(checklist.headline)\" primary=\(checklist.primary.map(\.label) ?? "none") rows=[\(rows)]"
    }

    fileprivate final class RowView: @unchecked Sendable {
        let widget: UnsafeMutablePointer<GtkWidget>
        let shape: String
        private let glyph: UnsafeMutablePointer<GtkWidget>
        private let titleLabel: UnsafeMutablePointer<GtkWidget>
        private let lineLabel: UnsafeMutablePointer<GtkWidget>
        private let failureLabel: UnsafeMutablePointer<GtkWidget>
        var glyphWidget: UnsafeMutablePointer<GtkWidget> { glyph }
        var barWidget: UnsafeMutablePointer<GtkWidget>? { bar }
        private var bar: UnsafeMutablePointer<GtkWidget>?
        private var jobLabel: UnsafeMutablePointer<GtkWidget>?
        private var copyButton: UnsafeMutablePointer<GtkWidget>?
        private var copyTimer = 0

        static func shape(of row: SetupRow) -> String {
            "\(row.id)|\(row.state)|\(row.fix?.id ?? "")|\(row.fix?.enabled ?? true)|\(row.fix?.command ?? "")|\(row.job != nil)|\(row.job?.fraction != nil)|\(row.failure != nil)"
        }

        init(row: SetupRow, view: SetupChecklistView) {
            shape = Self.shape(of: row)
            let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
            Gtk.addClass(line, "setup-row")
            widget = line
            glyph = Gtk.label(row.icon.glyph, selectable: false)
            gtk_widget_set_valign(glyph, GTK_ALIGN_START)
            gtk_widget_set_size_request(glyph, 18, -1)
            gtk_box_append(ptr(line), glyph)

            let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
            gtk_widget_set_hexpand(words, 1)
            titleLabel = Gtk.label(row.title, css: "preview-row-title", wrap: true, selectable: false)
            lineLabel = Gtk.label(row.line ?? "", css: "preview-row-detail", wrap: true, selectable: false)
            failureLabel = Gtk.label(row.failure ?? "", css: "setup-failure", wrap: true, selectable: false)
            for label in [titleLabel, lineLabel, failureLabel] {
                gtk_label_set_max_width_chars(op(label), 52)
            }
            if row.state == .done {
                let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
                gtk_widget_set_hexpand(lineLabel, 1)
                gtk_box_append(ptr(head), titleLabel)
                gtk_box_append(ptr(head), lineLabel)
                gtk_box_append(ptr(words), head)
            } else {
                gtk_box_append(ptr(words), titleLabel)
                gtk_box_append(ptr(words), lineLabel)
            }
            gtk_box_append(ptr(words), failureLabel)
            gtk_box_append(ptr(line), words)
            tailscode_set_accessible_label(line, row.spoken)

            let fixArea = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
            gtk_widget_set_margin_top(fixArea, 4)
            gtk_box_append(ptr(words), fixArea)
            if let job = row.job {
                buildJob(job, into: fixArea, view: view)
            } else if let fix = row.fix {
                buildFix(fix, row: row, into: fixArea, view: view)
            }
            gtk_widget_set_visible(fixArea, row.job == nil && row.fix == nil ? 0 : 1)
            paint(row)
        }

        private func buildJob(_ job: SetupRowJob, into area: UnsafeMutablePointer<GtkWidget>, view: SetupChecklistView) {
            let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
            if job.fraction != nil {
                let made = gtk_progress_bar_new()!
                Gtk.addClass(made, "setup-progress")
                gtk_widget_set_hexpand(made, 1)
                gtk_widget_set_valign(made, GTK_ALIGN_CENTER)
                bar = made
                gtk_box_append(ptr(line), made)
            }
            let measure = Gtk.label("", css: "preview-row-detail", wrap: true, selectable: false)
            gtk_widget_set_hexpand(measure, 1)
            gtk_label_set_max_width_chars(op(measure), 40)
            jobLabel = measure
            if job.fraction == nil { gtk_box_append(ptr(line), measure) }
            let cancel = Gtk.button(Localized.text("Cancel"), css: ["flat"]) { [weak view] in
                Gtk.onMain { [weak view] in view?.pressCancel() }
            }
            gtk_widget_set_valign(cancel, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(line), cancel)
            gtk_box_append(ptr(area), line)
            if job.fraction != nil { gtk_box_append(ptr(area), measure) }
        }

        private func buildFix(
            _ fix: SetupRowFix, row: SetupRow, into area: UnsafeMutablePointer<GtkWidget>, view: SetupChecklistView
        ) {
            switch fix.kind {
            case .job:
                let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
                let button = Gtk.button(row.state == .failed ? Localized.text("Try again") : fix.label, css: []) { [weak view] in
                    Gtk.onMain { [weak view] in view?.press(fix: fix) }
                }
                gtk_widget_set_sensitive(button, fix.enabled ? 1 : 0)
                gtk_box_append(ptr(line), button)
                if let cost = fix.cost {
                    let label = Gtk.label(cost, css: "preview-row-detail", selectable: false)
                    gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
                    gtk_box_append(ptr(line), label)
                }
                gtk_box_append(ptr(area), line)
            case .command:
                guard let command = fix.command else { return }
                let block = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
                Gtk.addClass(block, "setup-command")
                let text = Gtk.label(command, css: "setup-command-text", wrap: true, selectable: false)
                gtk_label_set_wrap_mode(op(text), PANGO_WRAP_CHAR)
                gtk_widget_set_hexpand(text, 1)
                gtk_label_set_max_width_chars(op(text), 46)
                gtk_box_append(ptr(block), text)
                let copy = Gtk.button(Localized.text("Copy"), css: ["flat"]) { [weak self] in
                    Gtk.copyToClipboard(command)
                    Gtk.onMain { [weak self] in self?.flashCopied() }
                }
                gtk_widget_set_valign(copy, GTK_ALIGN_START)
                copyButton = copy
                gtk_box_append(ptr(block), copy)
                gtk_box_append(ptr(area), block)
                if let reason = fix.reason {
                    let why = Gtk.label(reason, css: "preview-row-detail", wrap: true, selectable: false)
                    gtk_label_set_max_width_chars(op(why), 52)
                    gtk_box_append(ptr(area), why)
                }
            }
        }

        private func flashCopied() {
            guard let copyButton else { return }
            copyTimer += 1
            let mine = copyTimer
            gtk_button_set_label(ptr(copyButton), DelegateSetup.copied)
            Gtk.after(1500) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, self.copyTimer == mine, let button = self.copyButton else { return }
                    gtk_button_set_label(ptr(button), Localized.text("Copy"))
                }
            }
        }

        func update(_ row: SetupRow) {
            gtk_label_set_text(op(titleLabel), row.title)
            gtk_label_set_text(op(lineLabel), row.line ?? "")
            gtk_label_set_text(op(failureLabel), row.failure ?? "")
            tailscode_set_accessible_label(widget, row.spoken)
            paint(row)
        }

        private func paint(_ row: SetupRow) {
            gtk_label_set_text(op(glyph), row.icon.glyph)
            Gtk.setTone(glyph, row.icon.tone.glyphCSS, from: SetupChecklistView.glyphTones)
            ActivityPulse.apply(row.icon, to: glyph)
            gtk_widget_set_visible(lineLabel, (row.line ?? "").isEmpty ? 0 : 1)
            gtk_widget_set_visible(failureLabel, row.failure == nil ? 0 : 1)
            if let job = row.job {
                if let bar, let fraction = job.fraction { gtk_progress_bar_set_fraction(op(bar), min(1, max(0, fraction))) }
                let text = job.waiting ? Localized.text("Waiting for its turn") : (job.line ?? job.step ?? "")
                if let jobLabel {
                    gtk_label_set_text(op(jobLabel), text)
                    gtk_widget_set_visible(jobLabel, text.isEmpty ? 0 : 1)
                }
            }
            if row.state == .done {
                Gtk.addClass(widget, "setup-row-done")
            } else {
                gtk_widget_remove_css_class(widget, "setup-row-done")
            }
        }
    }
}
