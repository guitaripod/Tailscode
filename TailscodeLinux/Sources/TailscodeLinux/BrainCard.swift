import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A collapsed turn: one card whose picture is the head itself, lit where the turn worked, and
/// whose words are what the turn came to. The card is made of a few widgets the row places
/// directly: a surface that paints the card's own ground and edge, the picture, the column of
/// words, and Replay and Rows. The column's chips and sentences are made the first time the card
/// is drawn, so a conversation of three hundred turns builds three hundred shells and the
/// handful of cards in view.
final class BrainCard: @unchecked Sendable {
    unowned let owner: BrainView
    private let viewRef: WeakBrainView
    let surface: UnsafeMutablePointer<GtkWidget>
    let picture: UnsafeMutablePointer<GtkWidget>
    let text: UnsafeMutablePointer<GtkWidget>
    let buttons: UnsafeMutablePointer<GtkWidget>
    private let replay: UnsafeMutablePointer<GtkWidget>
    private let rows: UnsafeMutablePointer<GtkWidget>

    private(set) var card: NeuralBrainCard
    private var layout = NeuralStageMetrics.CardLayout.wide
    private(set) var hovered = false
    private(set) var hasContent = false
    private var contentTicket = 0
    private var contentSignature = ""
    private var builtDensity = ChatDensity.comfortable
    private var width = 0.0
    private var picturePending = false
    private var restPicture: BrainPicture?
    private var restKey: BrainPictures.Key?
    private var pictureRect = NeuralRect.zero
    private var sized = (width: 0.0, height: 0.0, scale: 0)

    private var chipRow: UnsafeMutablePointer<GtkWidget>?
    private var chipWidgets: [UnsafeMutablePointer<GtkWidget>] = []
    private var digestLabel: UnsafeMutablePointer<GtkWidget>?
    private var digestFitted = ""

    /// The words a card drew, for the harness: the headline, the chips, the digest.
    private(set) var drawn = (headline: "", chips: [String](), digest: "")

    init(owner: BrainView) {
        self.owner = owner
        let ref = WeakBrainView(owner)
        viewRef = ref
        card = owner.model.brainCard(now: Date())
        let surfaceHolder = Holder()
        let pictureHolder = Holder()
        surface = surfaceHolder.make(kind: .surface)
        picture = pictureHolder.make(kind: .picture)
        text = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        replay = Gtk.button(NeuralReading.replayLabel, css: ["brain-pill", "bn-card-button"]) {
            Gtk.onMain { ref.view?.toggleReplay() }
        }
        rows = Gtk.button(NeuralReading.rowsLabel, css: ["brain-pill", "bn-card-button"]) {
            Gtk.onMain { ref.view?.toggleRows() }
        }
        surfaceHolder.card = self
        pictureHolder.card = self
        build()
    }

    private final class Holder: @unchecked Sendable {
        enum Kind { case surface, picture }
        weak var card: BrainCard?
        var kind = Kind.surface

        func make(kind: Kind) -> UnsafeMutablePointer<GtkWidget> {
            _ = Gtk.releaseInstalled
            self.kind = kind
            return tailscode_canvas_new(
                { cr, width, height, raw in
                    guard let cr, let raw else { return }
                    let holder = Unmanaged<Holder>.fromOpaque(raw).takeUnretainedValue()
                    guard let card = holder.card else { return }
                    switch holder.kind {
                    case .surface: card.paintSurface(cr, width: Double(width), height: Double(height))
                    case .picture: card.paintPicture(cr, width: Double(width), height: Double(height))
                    }
                }, Unmanaged.passRetained(self).toOpaque(),
                { raw in
                    guard let raw else { return }
                    Unmanaged<Holder>.fromOpaque(raw).release()
                })!
        }
    }

    private func build() {
        for widget in [surface, picture] {
            gtk_widget_set_can_target(widget, 0)
            gtk_widget_set_can_focus(widget, 0)
            tailscode_set_accessible_hidden(widget, 1)
        }
        gtk_widget_set_can_target(text, 0)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        gtk_widget_set_overflow(text, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_valign(buttons, GTK_ALIGN_START)
        gtk_widget_set_halign(buttons, GTK_ALIGN_END)
        for button in [replay, rows] {
            gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
            gtk_widget_set_cursor_from_name(button, "pointer")
            gtk_box_append(ptr(buttons), button)
        }
        tailscode_set_accessible_label(replay, NeuralReading.replayLabel)
        tailscode_set_accessible_label(rows, NeuralReading.rowsLabel)
    }

    /// The widgets the row stacks for a card, bottom to top.
    var widgets: [UnsafeMutablePointer<GtkWidget>] { [surface, picture, text, buttons] }

    // MARK: state

    func refresh() {
        card = owner.model.brainCard(now: Date())
        let signature = Self.signature(of: card)
        if hasContent, signature != contentSignature { buildContent() }
        let running = owner.model.turn.outcome == .running
        gtk_widget_set_sensitive(replay, running || owner.model.steps.count <= 1 ? 0 : 1)
        gtk_widget_remove_css_class(rows, "on")
        if owner.row.showRows { gtk_widget_add_css_class(rows, "on") }
        tailscode_set_accessible_pressed(rows, owner.row.showRows ? 1 : 0)
        let replaying = owner.model.isReplaying
        gtk_button_set_label(ptr(replay), replaying ? Localized.text("Stop") : NeuralReading.replayLabel)
        requestPicture()
        redraw()
    }

    func redraw() {
        gtk_widget_queue_draw(surface)
        gtk_widget_queue_draw(picture)
    }

    func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        redraw()
    }

    private static func signature(of card: NeuralBrainCard) -> String {
        card.headline.pieces.map(\.text).joined(separator: "|")
            + "#" + card.chips.map { "\($0.zone)\($0.count)\($0.tone)" }.joined(separator: ",")
            + "#" + card.digest
    }

    func retheme() {
        restPicture = nil
        restKey = nil
        contentSignature = ""
        if hasContent { buildContent() }
        requestPicture()
        redraw()
    }

    // MARK: layout

    /// The card laid out for a row `width` points wide: the metrics decide the picture's place and
    /// the layout class; the zone strip and the digest follow `fit`.
    func configure(metrics: NeuralStageMetrics) {
        let next = metrics.card.layout
        let widthChanged = abs(metrics.width - width) > 0.5
        width = metrics.width
        pictureRect = metrics.card.picture
        if next != layout || owner.density != builtDensity {
            layout = next
            if hasContent { buildContent() }
        } else if hasContent, widthChanged {
            fitContent()
        }
        requestPicture()
    }

    var layoutClass: NeuralStageMetrics.CardLayout { layout }

    /// What a card of this width shows: Core's reading of the width, limited to what the narrow
    /// composition has room for.
    var parts: Set<NeuralBrainCard.Part> {
        var shown = card.fit(width: width)
        if layout == .narrow {
            shown.remove(.zoneStrip)
            shown.remove(.digest)
        }
        if owner.density == .compact { shown.remove(.digest) }
        return shown
    }

    // MARK: the picture

    private func requestPicture() {
        guard pictureRect.width > 1, NeuralAssetFiles.isAvailable, BrainBudget.stageAllowed else { return }
        let scale = max(1, Int(gtk_widget_get_scale_factor(owner.widget)))
        let table = NeuralToneTable(palette: MatrixTheme.palette, face: owner.model.face)
        let frame = owner.model.frame(time: 0, reduceMotion: true)
        let wholeWidth = pictureRect.width * NeuralDesign.width / NeuralStageMetrics.designWidth
        let key = BrainPictures.Key(
            table: table, frame: frame, width: Int((wholeWidth * Double(scale)).rounded()),
            height: Int((pictureRect.height * Double(scale)).rounded()))
        if restKey == key, restPicture != nil { return }
        guard !picturePending || restKey != key else { return }
        restKey = key
        picturePending = true
        BrainPictures.picture(
            frame: frame, table: table, width: wholeWidth, height: pictureRect.height, scale: scale
        ) { [weak self] made in
            guard let self else { return }
            self.picturePending = false
            guard self.restKey == key else { return }
            self.restPicture = made
            gtk_widget_queue_draw(self.picture)
            self.owner.cardPictureReady()
        }
    }

    var hasPicture: Bool { restPicture != nil }

    private func paintPicture(_ cr: OpaquePointer, width: Double, height: Double) {
        let inks = owner.inks
        let rect = NeuralRect(x: 0, y: 0, width: width, height: height)
        cairo_save(cr)
        BrainPainter.round(cr, 0, 0, width, height, 8)
        cairo_clip(cr)
        cairo_set_source_rgba(cr, inks.canvas.red, inks.canvas.green, inks.canvas.blue, 1)
        cairo_paint(cr)
        if let restPicture {
            BrainCardPainter.head(cr, picture: restPicture, rect: rect)
        } else {
            let glyph = owner.model.glyph(dim: false)
            let side = min(width, height) * 0.86
            cairo_translate(cr, (width - side) / 2, (height - side) / 2)
            BrainPainter.glyph(
                cr, glyph: glyph, width: side, height: side * 368 / 566, inks: inks, time: 0,
                reduceMotion: true)
        }
        let crop = NeuralStageMetrics.designCrop
        let mapping = BrainCardPainter.Mapping(x: 0, y: 0, scale: width / crop.width)
        cairo_restore(cr)
        cairo_save(cr)
        BrainPainter.round(cr, 0, 0, width, height, 8)
        cairo_clip(cr)
        if restPicture != nil {
            BrainCardPainter.lights(cr, card: card, mapping: mapping, inks: inks, hovered: hovered)
            BrainCardPainter.rings(cr, card: card, mapping: mapping, inks: inks)
        }
        cairo_restore(cr)
    }

    private func paintSurface(_ cr: OpaquePointer, width: Double, height: Double) {
        let inks = owner.inks
        let tone = inks.corrected(card.edgeTone)
        let raised = inks.card
        let rule = inks.corrected(.quiet)
        _ = rule
        let outline = BrainInks.mix(inks.rule2, tone, hovered ? 0.55 : 0)
        BrainPainter.round(cr, 0.5, 0.5, width - 1, height - 1, 12)
        cairo_set_source_rgba(cr, raised.red, raised.green, raised.blue, 1)
        cairo_fill_preserve(cr)
        let line = hovered ? outline : inks.rule2
        cairo_set_source_rgba(cr, line.red, line.green, line.blue, hovered ? 1 : 0.9)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        cairo_save(cr)
        BrainPainter.round(cr, 0.5, 0.5, width - 1, height - 1, 12)
        cairo_clip(cr)
        cairo_set_source_rgba(cr, tone.red, tone.green, tone.blue, 1)
        if card.edge == .stopped {
            var y = 0.0
            while y < height {
                cairo_rectangle(cr, 0, y, 3, min(6, height - y))
                y += 10
            }
            cairo_fill(cr)
        } else {
            cairo_rectangle(cr, 0, 0, 3, height)
            cairo_fill(cr)
        }
        cairo_restore(cr)
        if !hasContent, contentTicket == 0, owner.isVisible { scheduleContent() }
    }

    // MARK: the words

    private func scheduleContent() {
        contentTicket += 1
        let ticket = contentTicket
        Gtk.onMain { [weak self] in
            guard let self, self.viewRef.view != nil, self.contentTicket == ticket, !self.hasContent else { return }
            self.buildContent()
        }
    }

    /// Makes the column of words now, for a harness or a card that is about to be drawn.
    func ensureContent() {
        if !hasContent { buildContent() }
    }

    private func pieces() -> (number: String, unit: String) {
        let count = card.headline.count
        let number = String(card.headline.number)
        guard count.hasPrefix(number) else { return (count, "") }
        let rest = count.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        return (number, rest)
    }

    private func buildContent() {
        hasContent = true
        builtDensity = owner.density
        contentSignature = Self.signature(of: card)
        Gtk.removeChildren(of: text)
        chipWidgets = []
        chipRow = nil
        digestLabel = nil
        digestFitted = ""
        let inks = owner.inks
        let split = pieces()
        func head(clauses wide: Bool) -> UnsafeMutablePointer<GtkWidget> {
            let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let number = BrainUI.label(split.number, "bn-count")
            gtk_box_append(ptr(row), number)
            if !split.unit.isEmpty { gtk_box_append(ptr(row), BrainUI.label(split.unit, "bn-unit")) }
            if let duration = card.headline.piece(.duration) {
                gtk_box_append(ptr(row), BrainUI.label(duration.text, "bn-dur"))
            }
            if wide { gtk_box_append(ptr(row), clauses(inks: inks)) }
            for child in children(of: row) { gtk_widget_set_valign(child, GTK_ALIGN_BASELINE_FILL) }
            gtk_widget_set_valign(row, GTK_ALIGN_START)
            return row
        }
        let wide = layout == .wide
        gtk_box_append(ptr(text), head(clauses: wide))
        if !wide {
            let sub = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            gtk_box_append(ptr(sub), clauses(inks: inks))
            gtk_box_append(ptr(text), sub)
        }
        if wide {
            let strip = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6, "bn-zone-strip")
            gtk_widget_set_overflow(strip, GTK_OVERFLOW_HIDDEN)
            for chip in card.chips {
                let zone = chip.zone
                let ref = WeakBrainView(owner)
                let button = BrainUI.zoneChip(chip, inks: inks, compact: owner.density == .compact) {
                    ref.view?.openDiving(into: zone)
                }
                gtk_box_append(ptr(strip), button)
                chipWidgets.append(button)
            }
            chipRow = strip
            gtk_box_append(ptr(text), strip)
            let digest = BrainUI.label(card.digest, "bn-digest")
            gtk_widget_set_hexpand(digest, 1)
            digestLabel = digest
            gtk_box_append(ptr(text), digest)
        }
        drawn = (
            card.headline.pieces.map(\.text).joined(separator: " "),
            card.chips.map { "\($0.label) \($0.count)" }, card.digest)
        let spoken = card.spoken
        tailscode_set_accessible_label(owner.widget, spoken)
        fitContent()
    }

    private func children(of box: UnsafeMutablePointer<GtkWidget>) -> [UnsafeMutablePointer<GtkWidget>] {
        var out: [UnsafeMutablePointer<GtkWidget>] = []
        var child = gtk_widget_get_first_child(box)
        while let held = child {
            out.append(held)
            child = gtk_widget_get_next_sibling(held)
        }
        return out
    }

    /// The tally in its two colours and the failure or state clause in its tone.
    private func clauses(inks: BrainInks) -> UnsafeMutablePointer<GtkWidget> {
        let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8, "bn-clauses")
        let hex = inks.hex
        if let tally = card.headline.piece(.tally) {
            let parts = tally.text.split(separator: " ", maxSplits: 1).map(String.init)
            let added = parts.first ?? ""
            let removed = parts.count > 1 ? parts[1] : ""
            let label = BrainUI.markup(
                "<span foreground=\"\(hex.accent)\">\(BrainUI.escape(added))</span> <span foreground=\"\(hex.danger)\">\(BrainUI.escape(removed))</span>",
                "bn-tally", wrap: false)
            gtk_widget_set_hexpand(label, 0)
            gtk_box_append(ptr(row), label)
        }
        for kind in [NeuralBrainCard.Piece.Kind.failure, .state] {
            guard let piece = card.headline.piece(kind) else { continue }
            let label = BrainUI.label(piece.text, "bn-clause")
            switch piece.tone {
            case .danger?: Gtk.addClass(label, "bn-tone-danger")
            case .attention?: Gtk.addClass(label, "bn-tone-attention")
            case .quiet?: Gtk.addClass(label, "bn-tone-quiet")
            default: break
            }
            gtk_box_append(ptr(row), label)
        }
        for child in children(of: row) { gtk_widget_set_valign(child, GTK_ALIGN_BASELINE_FILL) }
        return row
    }

    /// Shows the zone chips that fit whole and the digest cut by whole clauses, which is all a
    /// narrower card gives up before its picture, its headline, Replay and Rows.
    func fitContent() {
        guard hasContent, layout == .wide else { return }
        let textWidth = max(0, width - Self.textInset(for: layout) - 12)
        let shown = parts
        var room = textWidth
        var visibleChips = 0
        for chip in chipWidgets {
            let need = Double(naturalWidth(chip)) + 6
            let allowed = shown.contains(.zoneStrip) && need <= room + 6
            gtk_widget_set_visible(chip, allowed ? 1 : 0)
            if allowed {
                room -= need
                visibleChips += 1
            } else {
                room = -1
            }
        }
        if let chipRow { gtk_widget_set_visible(chipRow, visibleChips > 0 ? 1 : 0) }
        guard let digest = digestLabel else { return }
        gtk_widget_set_visible(digest, shown.contains(.digest) ? 1 : 0)
        let fitted = fittedDigest(width: textWidth, label: digest)
        if fitted != digestFitted {
            digestFitted = fitted
            gtk_label_set_text(op(digest), fitted)
        }
    }

    /// The card's digest cut by whole clauses to what the line can say.
    private func fittedDigest(width: Double, label: UnsafeMutablePointer<GtkWidget>) -> String {
        guard width > 0, !card.digestClauses.isEmpty else { return card.digest }
        var best = card.digest(fitting: 0)
        var characters = 24
        let limit = card.digest.count
        while characters <= limit + 24 {
            let candidate = card.digest(fitting: characters)
            if measure(candidate, in: label) <= width {
                best = candidate
                if candidate == card.digest { break }
            } else {
                break
            }
            characters += 6
        }
        return best
    }

    private func measure(_ string: String, in label: UnsafeMutablePointer<GtkWidget>) -> Double {
        guard let layout = gtk_widget_create_pango_layout(label, string) else { return 0 }
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        var measured: Int32 = 0
        pango_layout_get_pixel_size(layout, &measured, nil)
        return Double(measured)
    }

    private func naturalWidth(_ widget: UnsafeMutablePointer<GtkWidget>) -> Int32 {
        var natural: Int32 = 0
        gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, nil, &natural, nil, nil)
        return natural
    }

    /// Where the column of words begins: past the edge, the inset, the picture and the inset.
    static func textInset(for layout: NeuralStageMetrics.CardLayout) -> Double {
        layout == .wide ? 3 + 12 + 132 + 12 + 2 : 3 + 10 + 100 + 10 + 2
    }

    /// What the harness reads: the card's layout class and what it shows.
    var reading: String {
        let chips = chipWidgets.filter { gtk_widget_get_visible($0) != 0 }.count
        let digest = digestLabel.map { gtk_widget_get_visible($0) != 0 } ?? false
        return "card layout=\(layout) width=\(Int(width)) content=\(hasContent) chips=\(chips)/\(chipWidgets.count) digest=\(digest) picture=\(restPicture != nil) hovered=\(hovered)"
    }

    var visibleChipCount: Int { chipWidgets.filter { gtk_widget_get_visible($0) != 0 }.count }
    var digestVisible: Bool { digestLabel.map { gtk_widget_get_visible($0) != 0 } ?? false }
    var digestText: String {
        digestLabel.flatMap { gtk_label_get_text(op($0)).map { String(cString: $0) } } ?? ""
    }
    var chipCount: Int { chipWidgets.count }
    var replayButton: UnsafeMutablePointer<GtkWidget> { replay }
    var rowsButton: UnsafeMutablePointer<GtkWidget> { rows }
    var chipButtons: [UnsafeMutablePointer<GtkWidget>] { chipWidgets }
}

