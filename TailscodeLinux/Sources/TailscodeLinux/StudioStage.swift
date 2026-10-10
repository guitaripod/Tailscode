import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// One verb on the stage's capsule.
struct StudioVerb: Sendable {
    let id: String
    let glyph: String
    let title: String
    let hint: String
    var isDestructive = false
    var isPrimary = false
    let perform: @Sendable () -> Void
}

/// The room a picture or a clip is shown in, shared by the image studio and the forge so the two
/// are the same stage: an opaque canvas with the content aspect-fit inside a 24-point margin, the
/// words for the state across its top, the progress line on its bottom edge, and — floating over
/// the canvas at the bottom and never over the picture — the verbs the finished work offers.
///
/// The stage never changes size while a job runs. The margin that holds the verbs is reserved
/// whether they are showing or not, so a render landing is a picture arriving into the rectangle
/// its sketch already used and nothing else on screen moves.
final class StudioStageShell: @unchecked Sendable {
    let root = gtk_overlay_new()!
    let content = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let stateRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let stateDot = Gtk.label("●", css: "studio-dot", selectable: false)
    private let stateLabel = Gtk.label("", css: "studio-state", selectable: false)
    private let stateDetail = Gtk.label("", css: "studio-state", selectable: false)
    private let progress = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 4)
    private var bars: [UnsafeMutablePointer<GtkWidget>] = []
    private let verbBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
    private var verbIDs: [String] = []
    private var verbButtons: [UnsafeMutablePointer<GtkWidget>] = []
    private var compact = false
    private var lastVerbs: [StudioVerb] = []
    private let cards = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let lowerCard = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private var dotTone: ActivityTone?
    private let metrics: StudioMetrics
    private let probe = gtk_drawing_area_new()!
    /// Told the stage's own size when it changes, for what the stage shows that depends on it.
    var onResize: (@Sendable (Double, Double) -> Void)?

    init(metrics: StudioMetrics = .pane) {
        self.metrics = metrics
        Gtk.addClass(root, "studio-stage")
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)
        gtk_widget_set_overflow(root, GTK_OVERFLOW_HIDDEN)

        let margin = Int32(metrics.stageMargin)
        Gtk.margins(
            content, top: margin, bottom: margin + Int32(metrics.verbsBand), leading: margin,
            trailing: margin)
        gtk_widget_set_hexpand(content, 1)
        gtk_widget_set_vexpand(content, 1)
        gtk_overlay_set_child(op(root), content)

        gtk_widget_set_halign(stateRow, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(stateRow, GTK_ALIGN_START)
        gtk_widget_set_margin_top(stateRow, 4)
        gtk_widget_set_can_target(stateRow, 0)
        gtk_label_set_ellipsize(op(stateLabel), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(op(stateLabel), 160)
        gtk_label_set_ellipsize(op(stateDetail), PANGO_ELLIPSIZE_NONE)
        Gtk.setHidden(stateDot, true)
        gtk_box_append(ptr(stateRow), stateDot)
        gtk_box_append(ptr(stateRow), stateLabel)
        gtk_box_append(ptr(stateRow), stateDetail)
        gtk_widget_set_visible(stateRow, 0)
        gtk_overlay_add_overlay(op(root), stateRow)

        gtk_widget_set_halign(cards, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(cards, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(cards, 0)
        gtk_overlay_add_overlay(op(root), cards)

        gtk_widget_set_halign(lowerCard, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(lowerCard, GTK_ALIGN_END)
        Gtk.margins(lowerCard, bottom: Int32(metrics.verbsBand) + 8, leading: margin, trailing: margin)
        gtk_widget_set_visible(lowerCard, 0)
        gtk_overlay_add_overlay(op(root), lowerCard)

        Gtk.addClass(verbBox, "studio-verbs")
        gtk_widget_set_halign(verbBox, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(verbBox, GTK_ALIGN_END)
        gtk_widget_set_margin_bottom(verbBox, 14)
        gtk_widget_set_opacity(verbBox, 0)
        gtk_widget_set_can_target(verbBox, 0)
        gtk_overlay_add_overlay(op(root), verbBox)

        gtk_widget_set_hexpand(probe, 1)
        gtk_widget_set_vexpand(probe, 1)
        gtk_widget_set_can_target(probe, 0)
        gtk_widget_set_can_focus(probe, 0)
        Gtk.setHidden(probe, true)
        gtk_overlay_add_overlay(op(root), probe)
        gtk_overlay_set_measure_overlay(op(root), probe, 0)
        Gtk.onResize(probe) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.onResize?(
                    Double(gtk_widget_get_width(self.probe)), Double(gtk_widget_get_height(self.probe)))
            }
        }

        gtk_widget_set_valign(progress, GTK_ALIGN_END)
        gtk_widget_set_hexpand(progress, 1)
        gtk_widget_set_can_target(progress, 0)
        gtk_widget_set_visible(progress, 0)
        gtk_overlay_add_overlay(op(root), progress)
    }

    /// The words for the state, across the top of the canvas, on a dot that breathes only while
    /// the machine is working. A state with nothing to say hides the line rather than leaving an
    /// empty one.
    func setState(
        _ sentence: String?, detail: String? = nil, tone: ActivityTone?, breathing: Bool
    ) {
        guard let sentence, !sentence.isEmpty else {
            gtk_widget_set_visible(stateRow, 0)
            ActivityPulse.apply(nil, to: stateDot)
            return
        }
        gtk_widget_set_visible(stateRow, 1)
        gtk_label_set_text(op(stateLabel), sentence)
        gtk_label_set_text(op(stateDetail), detail.map { " · " + $0 } ?? "")
        gtk_widget_set_visible(stateDetail, detail == nil ? 0 : 1)
        gtk_widget_set_tooltip_text(stateRow, [sentence, detail].compactMap { $0 }.joined(separator: " · "))
        gtk_widget_set_visible(stateDot, tone == nil ? 0 : 1)
        if let tone, tone != dotTone {
            dotTone = tone
            Gtk.setTone(stateDot, tone.glyphCSS, from: ActivityTone.allCases.map(\.glyphCSS))
        }
        ActivityPulse.apply(breathing ? ActivityKind.working.icon : nil, to: stateDot)
    }

    /// The progress line along the stage's bottom edge: hidden while there is no count to draw it
    /// from — never a bar sitting at zero — and one segment per pass when the graph has passes.
    func setProgress(_ segments: [Double]?) {
        guard let segments, !segments.isEmpty else {
            gtk_widget_set_visible(progress, 0)
            return
        }
        while bars.count < segments.count {
            let bar = gtk_progress_bar_new()!
            Gtk.addClass(bar, "studio-progress")
            gtk_widget_set_hexpand(bar, 1)
            gtk_box_append(ptr(progress), bar)
            bars.append(bar)
        }
        for (index, bar) in bars.enumerated() {
            gtk_widget_set_visible(bar, index < segments.count ? 1 : 0)
            if index < segments.count {
                gtk_progress_bar_set_fraction(op(bar), min(1, max(0, segments[index])))
            }
        }
        gtk_widget_set_visible(progress, 1)
    }

    var progressSummary: String {
        guard gtk_widget_get_visible(progress) != 0 else { return "hidden" }
        let shown = bars.filter { gtk_widget_get_visible($0) != 0 }
        let fractions = shown.map { String(format: "%.2f", gtk_progress_bar_get_fraction(op($0))) }
        return "line=\(fractions.joined(separator: "/"))"
    }

    /// The capsule of verbs a finished piece of work offers. While there is nothing to act on —
    /// the render is still out — it keeps its room, invisible and untouchable, so the stage does
    /// not change shape when the picture lands.
    func setVerbs(_ verbs: [StudioVerb], visible: Bool) {
        let ids = verbs.map(\.id)
        if ids != verbIDs || compact != lastCompact {
            rebuildVerbs(verbs)
        }
        lastVerbs = verbs
        gtk_widget_set_opacity(verbBox, visible && !verbs.isEmpty ? 1 : 0)
        gtk_widget_set_can_target(verbBox, visible && !verbs.isEmpty ? 1 : 0)
    }

    private var lastCompact = false

    /// A narrow stage shows each verb as its glyph and keeps the word in its tooltip and for the
    /// screen reader: seven labelled buttons do not fit a pane a third of a screen wide.
    func setCompact(_ narrow: Bool) {
        guard narrow != compact else { return }
        compact = narrow
        if !lastVerbs.isEmpty { rebuildVerbs(lastVerbs) }
    }

    private func rebuildVerbs(_ verbs: [StudioVerb]) {
        Gtk.removeChildren(of: verbBox)
        verbButtons = []
        lastCompact = compact
        verbIDs = verbs.map(\.id)
        for verb in verbs {
            if verb.isDestructive {
                let rule = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
                Gtk.addClass(rule, "studio-verbs-rule")
                gtk_box_append(ptr(verbBox), rule)
            }
            let action = verb.perform
            let button = Gtk.button(
                compact ? verb.glyph : "\(verb.glyph)  \(verb.title)",
                css: ["flat", "studio-verb"] + (verb.isDestructive ? ["danger"] : [])
                    + (verb.isPrimary ? ["studio-verb-lead"] : [])
            ) { Gtk.onMain { action() } }
            gtk_widget_set_tooltip_text(button, verb.hint)
            tailscode_set_accessible_label(button, verb.title)
            gtk_box_append(ptr(verbBox), button)
            verbButtons.append(button)
        }
    }

    var verbSummary: String {
        let shown = gtk_widget_get_opacity(verbBox) > 0.5 ? "shown" : "reserved"
        return "\(shown) [\(verbIDs.joined(separator: ","))]"
    }

    /// A card over the middle of the stage — the failure's one honest sentence and its remedy.
    func setCard(_ card: UnsafeMutablePointer<GtkWidget>?) {
        Gtk.removeChildren(of: cards)
        if let card {
            gtk_box_append(ptr(cards), card)
            gtk_widget_set_visible(cards, 1)
        } else {
            gtk_widget_set_visible(cards, 0)
        }
    }

    /// A card that rises out of the dock over the stage's lower third — the rewrite — without
    /// moving the stage, because it is an overlay and takes no room.
    func setLowerCard(_ card: UnsafeMutablePointer<GtkWidget>?) {
        Gtk.removeChildren(of: lowerCard)
        if let card {
            let clamp = adw_clamp_new()!
            adw_clamp_set_maximum_size(op(clamp), 640)
            adw_clamp_set_tightening_threshold(op(clamp), 520)
            adw_clamp_set_child(op(clamp), card)
            gtk_box_append(ptr(lowerCard), clamp)
        }
    }

    func showLowerCard(_ shown: Bool) {
        gtk_widget_set_visible(lowerCard, shown ? 1 : 0)
    }

    /// What a screen reader reads for the stage: the state in words.
    func describe(_ words: String) {
        tailscode_set_accessible_label(root, words)
    }
}

/// The failure's card: one honest sentence in the failure tone, what was and was not sent, and
/// the remedies that follow from it. Holds perfectly still — a settled state never moves.
enum StudioFailureCard {
    static func make(
        sentence: String, note: String?, remedies: [(title: String, primary: Bool, perform: @Sendable () -> Void)]
    ) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        Gtk.addClass(card, "studio-card")
        let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        let mark = Gtk.label("!", css: "studio-card-mark", selectable: false)
        gtk_widget_set_valign(mark, GTK_ALIGN_START)
        gtk_box_append(ptr(head), mark)
        let words = Gtk.label(sentence, css: "studio-card-sentence", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(words), 46)
        gtk_box_append(ptr(head), words)
        gtk_box_append(ptr(card), head)
        if let note {
            let line = Gtk.label(note, css: "draw-toggle-detail", wrap: true, selectable: false)
            gtk_label_set_max_width_chars(op(line), 52)
            gtk_widget_set_margin_start(line, 40)
            gtk_box_append(ptr(card), line)
        }
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_margin_start(row, 40)
        for remedy in remedies {
            let action = remedy.perform
            let button = Gtk.button(
                remedy.title, css: remedy.primary ? ["draw-action", "draw-action-lead"] : ["draw-action"]
            ) { Gtk.onMain { action() } }
            gtk_box_append(ptr(row), button)
        }
        gtk_box_append(ptr(card), row)
        return card
    }
}
