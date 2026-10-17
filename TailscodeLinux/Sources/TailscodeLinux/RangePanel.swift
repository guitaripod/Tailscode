import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The sheet behind the context chip, the wall chip and the cold-cache chip: one answer to *will I
/// make it?* The verdict first, then the tanks that govern this chat as pace bars, the prompt
/// cache, what is in the window and the three largest things in it, how the window has filled turn
/// by turn, and the one thing to do about it.
///
/// Every number and every word is ``RangeBoard``'s; this file decides only how wide a slice of the
/// stacked bar is and how tall a bar of the chart. The panel reads again while it is open, because
/// a countdown and a cache that stopped being warm must stay true.
final class RangePanel: @unchecked Sendable {
    struct Reading {
        let board: RangeBoard
        let fill: ContextFill?
    }

    private static let windowWidth: Int32 = 500
    private static let trackWidth = 410
    private static let chartHeight: Int32 = 72
    private static let reread: UInt32 = 15_000
    private static let burst: UInt32 = 2_000

    /// A class-backed dialog presented from a local is dead on arrival — released while shown, its
    /// buttons do nothing — so the panel holds itself here until its window goes.
    private nonisolated(unsafe) static var open: RangePanel?

    private let read: () -> Reading?
    private let goTo: (@Sendable (String) -> Void)?
    private let windowBits: UInt
    private let columnBits: UInt
    private var dismissBits: UInt = 0
    private var showsBilling = false
    private var closed = false
    private var burstPending = false
    private var readAt = Date.distantPast

    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?, title: String,
        compact: (@Sendable () -> Void)?, goTo: (@Sendable (String) -> Void)?,
        read: @escaping () -> Reading?
    ) {
        if let open, let raw = UnsafeMutableRawPointer(bitPattern: open.windowBits) {
            gtk_window_present(ptr(raw))
            return
        }
        let panel = RangePanel(
            parent: parent, title: title, compact: compact, goTo: goTo, read: read)
        open = panel
        panel.render()
        panel.show()
        panel.startClock()
    }

    static var isOpen: Bool { open != nil }

    /// Closes the open sheet, if there is one.
    static func dismiss() {
        guard let open, let raw = UnsafeMutableRawPointer(bitPattern: open.windowBits) else { return }
        gtk_window_destroy(ptr(raw))
        open.release()
    }

    /// Lets go of the sheet once its window is gone, and only if it is still the one held — a
    /// sheet opened since is not this one's to close.
    private func release() {
        closed = true
        if RangePanel.open === self { RangePanel.open = nil }
    }

    /// A conversation emitted a new state: the open panel reads again, at most once in a burst.
    static func transcriptChanged() {
        guard let panel = open, !panel.closed, !panel.burstPending else { return }
        panel.burstPending = true
        Gtk.after(burst) {
            Gtk.onMain { [weak panel] in
                guard let panel else { return }
                panel.burstPending = false
                panel.render()
            }
        }
    }

    private init(
        parent: UnsafeMutablePointer<GtkWidget>?, title: String,
        compact: (@Sendable () -> Void)?, goTo: (@Sendable (String) -> Void)?,
        read: @escaping () -> Reading?
    ) {
        self.read = read
        self.goTo = goTo
        let (window, content, actions) = Dialogs.windowWithActions(
            title: RangeSheetWords.title(chat: title), parent: parent, width: Self.windowWidth)
        windowBits = UInt(bitPattern: window)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
        columnBits = UInt(bitPattern: column)
        gtk_box_append(ptr(content), column)

        let closing = windowBits
        if let compact {
            let button = Gtk.button(Localized.text("Compact…"), css: ["suggested-action"]) {
                if let raw = UnsafeMutableRawPointer(bitPattern: closing) {
                    gtk_window_destroy(ptr(raw))
                }
                compact()
            }
            gtk_box_append(ptr(actions), button)
        }
        let dismiss = Gtk.button(Localized.text("Close"), css: compact == nil ? ["suggested-action"] : []) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: closing) else { return }
            gtk_window_destroy(ptr(raw))
        }
        gtk_box_append(ptr(actions), dismiss)
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") {
            Gtk.onMain { [weak self] in self?.release() }
        }
        dismissBits = UInt(bitPattern: dismiss)
    }

    /// Presented only once the sheet holds its rows: a window mapped empty is sized to nothing and
    /// keeps that height when the rows arrive.
    private func show() {
        guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return }
        gtk_window_present(ptr(raw))
        if let dismiss = UnsafeMutableRawPointer(bitPattern: dismissBits) {
            gtk_widget_grab_focus(ptr(dismiss))
        }
    }

    private func startClock() {
        Gtk.after(Self.reread) {
            Gtk.onMain { [weak self] in
                guard let self, !self.closed else { return }
                self.render()
                self.startClock()
            }
        }
    }

    private var column: UnsafeMutablePointer<GtkWidget>? {
        UnsafeMutableRawPointer(bitPattern: columnBits).map { ptr($0) }
    }

    private func render() {
        guard let column, !closed else { return }
        readAt = Date()
        Gtk.removeChildren(of: column)
        guard let reading = read() else {
            gtk_box_append(
                ptr(column),
                Gtk.label(
                    RangeSheetWords.nothingYet, css: "dim", selectable: false))
            return
        }
        let board = reading.board
        gtk_box_append(ptr(column), verdict(board.verdict))
        if !board.rows.isEmpty || !board.elsewhere.isEmpty {
            gtk_box_append(ptr(column), section(RangeSheetWords.tanks))
            gtk_box_append(ptr(column), tanks(board))
        }
        if let cache = board.cache {
            gtk_box_append(ptr(column), section(RangeSheetWords.cache))
            gtk_box_append(ptr(column), cacheCard(cache))
        }
        if let composition = board.composition {
            gtk_box_append(ptr(column), section(RangeSheetWords.window))
            gtk_box_append(ptr(column), compositionCard(composition, fill: reading.fill))
        }
        if let footprint = board.footprint {
            gtk_box_append(ptr(column), section(RangeSheetWords.footprint))
            gtk_box_append(ptr(column), footprintCard(footprint))
        }
        if let source = board.source {
            gtk_box_append(ptr(column), Gtk.label(source, css: "usage-source", wrap: true, selectable: false))
        }
    }

    private func section(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        Gtk.label(text.uppercased(), css: "range-section", selectable: false)
    }

    private func card(spacing: Int32 = 8) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: spacing)
        Gtk.addClass(card, "usage-card")
        return card
    }

    private func verdict(_ verdict: RangeBoard.Verdict) -> UnsafeMutablePointer<GtkWidget> {
        let card = card(spacing: 6)
        let headline = Gtk.label(verdict.headline, css: "range-verdict", wrap: true, selectable: false)
        switch verdict.tone {
        case .quiet: break
        case .attention: Gtk.addClass(headline, "range-verdict-attention")
        case .danger: Gtk.addClass(headline, "range-verdict-danger")
        }
        gtk_box_append(ptr(card), headline)
        if let detail = verdict.detail {
            gtk_box_append(
                ptr(card), Gtk.label(detail, css: "context-summary", wrap: true, selectable: false))
        }
        return card
    }

    private func tanks(_ board: RangeBoard) -> UnsafeMutablePointer<GtkWidget> {
        let card = card(spacing: 10)
        let rows = board.rows + board.elsewhere
        for (index, row) in rows.enumerated() {
            if index > 0 { gtk_box_append(ptr(card), rule()) }
            gtk_box_append(ptr(card), PaceBar.row(row))
        }
        return card
    }

    private func rule() -> UnsafeMutablePointer<GtkWidget> {
        let rule = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(rule, "usage-rule")
        return rule
    }

    private func cacheCard(_ cache: CacheRow) -> UnsafeMutablePointer<GtkWidget> {
        let card = card(spacing: 6)
        let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(
            ptr(head), Gtk.label(cache.title, css: "usage-gauge-label", selectable: false))
        let detail = Gtk.label(cache.detail, css: "usage-plan", wrap: true, selectable: false)
        gtk_widget_set_hexpand(detail, 1)
        gtk_box_append(ptr(head), detail)
        let trailing = Gtk.label(
            cache.trailing, css: cache.isCold ? "usage-plan" : "usage-detail-value",
            selectable: false)
        gtk_label_set_ellipsize(op(trailing), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(head), trailing)
        gtk_box_append(ptr(card), head)

        let meter = tailscode_meter_new()!
        gtk_widget_set_hexpand(meter, 1)
        let ink = PresenceRGB(hex: MatrixTheme.palette.info) ?? PresenceRGB(red: 0.5, green: 0.5, blue: 0.5)
        [ink.red, ink.green, ink.blue].withUnsafeBufferPointer {
            tailscode_meter_set(meter, cache.isCold ? 0 : cache.fractionLeft, $0.baseAddress, 0.12, 4)
        }
        gtk_box_append(ptr(card), meter)
        if let sentence = cache.sentence {
            gtk_box_append(
                ptr(card), Gtk.label(sentence, css: "gauge-reset", wrap: true, selectable: false))
        }
        return card
    }

    private func compositionCard(_ composition: ContextComposition, fill: ContextFill?)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let card = card(spacing: 8)
        let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let caption = Gtk.label(
            RangeSheetWords.compositionTotal(StatusFacts.tokens(composition.total)),
            css: "spend-caption", wrap: true, selectable: false)
        gtk_widget_set_hexpand(caption, 1)
        gtk_box_append(ptr(head), caption)
        if let fill, !fill.slices.isEmpty { gtk_box_append(ptr(head), switcher()) }
        gtk_box_append(ptr(card), head)

        if showsBilling, let fill, !fill.slices.isEmpty {
            appendBilling(fill, to: card)
        } else {
            appendContent(composition, to: card)
        }
        return card
    }

    /// The Content | Billing switch: two linked buttons, the one showing lit.
    private func switcher() -> UnsafeMutablePointer<GtkWidget> {
        let box = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(box, "linked")
        Gtk.addClass(box, "range-switch")
        for (title, billing) in [(RangeSheetWords.content, false), (RangeSheetWords.billing, true)] {
            let button = Gtk.button(title, css: showsBilling == billing ? ["suggested-action"] : []) {
                [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, self.showsBilling != billing else { return }
                    self.showsBilling = billing
                    self.render()
                }
            }
            gtk_box_append(ptr(box), button)
        }
        return box
    }

    private func appendContent(
        _ composition: ContextComposition, to card: UnsafeMutablePointer<GtkWidget>
    ) {
        gtk_box_append(
            ptr(card),
            stackedBar(composition.slices.map { ($0.id, $0.label, $0.share, $0.tokens) }, prefix: "range-slice-"))
        for slice in composition.slices {
            gtk_box_append(
                ptr(card),
                legend(
                    slice.label, share: slice.share, tokens: slice.tokens,
                    css: "range-slice-\(slice.id)"))
        }
        for item in composition.items {
            gtk_box_append(ptr(card), itemRow(item))
        }
    }

    private func appendBilling(_ fill: ContextFill, to card: UnsafeMutablePointer<GtkWidget>) {
        gtk_box_append(
            ptr(card),
            stackedBar(fill.slices.map { ($0.id, $0.label, $0.share, $0.tokens) }, prefix: "context-band-"))
        for slice in fill.slices {
            gtk_box_append(
                ptr(card),
                legend(
                    slice.label, share: slice.share, tokens: slice.tokens,
                    css: "context-band-\(slice.id)"))
        }
    }

    private func stackedBar(
        _ slices: [(id: String, label: String, share: Double, tokens: Int)], prefix: String
    ) -> UnsafeMutablePointer<GtkWidget> {
        let track = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 1)
        Gtk.addClass(track, "context-track")
        gtk_widget_set_size_request(track, Int32(Self.trackWidth), 10)
        gtk_widget_set_halign(track, GTK_ALIGN_START)
        gtk_widget_set_overflow(track, GTK_OVERFLOW_HIDDEN)
        for slice in slices {
            let band = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            Gtk.addClass(band, prefix + slice.id)
            let width = max(2, Int(Double(Self.trackWidth) * min(max(slice.share, 0), 1)))
            gtk_widget_set_size_request(band, Int32(width), 10)
            gtk_widget_set_tooltip_text(band, "\(slice.label) · \(StatusFacts.tokens(slice.tokens))")
            gtk_box_append(ptr(track), band)
        }
        return track
    }

    private func legend(_ label: String, share: Double, tokens: Int, css: String)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let swatch = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(swatch, "context-swatch")
        Gtk.addClass(swatch, css)
        gtk_widget_set_size_request(swatch, 10, 10)
        gtk_widget_set_valign(swatch, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(row), swatch)
        let name = Gtk.label(label, css: "usage-gauge-label", selectable: false)
        gtk_label_set_ellipsize(op(name), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_hexpand(name, 1)
        gtk_box_append(ptr(row), name)
        for (text, css) in [(StatusFacts.share(share), "spend-caption"), (StatusFacts.tokens(tokens), "usage-detail-value")] {
            let figure = Gtk.label(text, css: css, selectable: false)
            gtk_label_set_ellipsize(op(figure), PANGO_ELLIPSIZE_NONE)
            gtk_box_append(ptr(row), figure)
        }
        return row
    }

    /// One of the largest things in the window. Pressing it closes the sheet and takes the
    /// transcript to the message that holds it.
    private func itemRow(_ item: ContextComposition.Item) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "range-item")
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_widget_set_hexpand(words, 1)
        let title = [item.tool, item.detail].compactMap { $0 }.joined(separator: " ")
        gtk_box_append(ptr(words), Gtk.label(title, css: "usage-gauge-label", selectable: false))
        gtk_box_append(
            ptr(words),
            Gtk.label(
                RangeSheetWords.turn(item.turn, size: StatusFacts.tokens(item.tokens)),
                css: "spend-caption", selectable: false))
        gtk_box_append(ptr(row), words)
        let share = Gtk.label(StatusFacts.share(item.share), css: "usage-detail-value", selectable: false)
        gtk_label_set_ellipsize(op(share), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_valign(share, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(row), share)
        gtk_button_set_child(ptr(button), row)
        let messageID = item.messageID
        let closing = windowBits
        let goTo = self.goTo
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") {
            if let raw = UnsafeMutableRawPointer(bitPattern: closing) {
                gtk_window_destroy(ptr(raw))
            }
            goTo?(messageID)
        }
        return button
    }

    private func footprintCard(_ footprint: RangeFootprint) -> UnsafeMutablePointer<GtkWidget> {
        let card = card(spacing: 6)
        let overlay = gtk_overlay_new()!
        let bars = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
        gtk_box_set_homogeneous(ptr(bars), 1)
        gtk_widget_set_size_request(bars, -1, Self.chartHeight)
        for bar in footprint.bars {
            let mark = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            gtk_widget_set_valign(mark, GTK_ALIGN_END)
            let height = max(2, Int32((Double(Self.chartHeight) * min(max(bar.height, 0), 1)).rounded()))
            switch bar.kind {
            case .turn:
                Gtk.addClass(mark, "range-bar-turn")
                gtk_widget_set_size_request(mark, -1, height)
            case .projected:
                Gtk.addClass(mark, "range-bar-projected")
                gtk_widget_set_size_request(mark, -1, height)
            case .refill:
                Gtk.addClass(mark, "range-bar-refill")
                gtk_widget_set_halign(mark, GTK_ALIGN_CENTER)
                gtk_widget_set_size_request(mark, 1, Self.chartHeight)
            }
            gtk_box_append(ptr(bars), mark)
        }
        gtk_overlay_set_child(op(overlay), bars)
        if let line = footprint.dangerLine {
            let offset = Int32((Double(Self.chartHeight) * (1 - min(max(line, 0), 1))).rounded())
            let rule = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            Gtk.addClass(rule, "range-danger-line")
            gtk_widget_set_valign(rule, GTK_ALIGN_START)
            Gtk.margins(rule, top: offset)
            gtk_widget_set_can_target(rule, 0)
            gtk_overlay_add_overlay(op(overlay), rule)
        }
        gtk_box_append(ptr(card), overlay)
        gtk_box_append(
            ptr(card),
            Gtk.label(footprint.captions.joined(separator: " "), css: "spend-caption", wrap: true, selectable: false))
        return card
    }

}
