import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The readout beside an open head: whatever is hovered, focused or pinned read out in full, the
/// turn's digest when nothing is, the step that is happening while the turn runs, a zone's steps
/// after a dive, the replay's log.
///
/// It is one component with several subjects, built entirely from `NeuralReadout`'s plain values,
/// and it never moves: it is allocated a rectangle and keeps it, its header and its footer facts
/// are pinned, and what lies between them scrolls. A new subject is built into the page that is
/// not showing and cross-faded in over 90 ms; the same subject arriving again is not rebuilt, and
/// a running turn's tail is updated in place so a selection made in it survives the stream.
/// A brain's view held without keeping it alive, which a closure on one of its own widgets must.
final class WeakBrainView: @unchecked Sendable {
    private weak var held: BrainView?
    init(_ view: BrainView) { held = view }

    /// The view, or nil once it is gone or its widget is being disposed: a hop that arrives after
    /// that has nothing left to act on.
    var view: BrainView? {
        guard let held, !held.disposed else { return nil }
        return held
    }
}

final class BrainReadout: @unchecked Sendable {
    unowned let owner: BrainView
    let ref: WeakBrainView
    let widget: UnsafeMutablePointer<GtkWidget>
    private let stack: UnsafeMutablePointer<GtkWidget>
    private var pages: [Page] = []
    private var current = 0
    private(set) var shown: NeuralReadout?
    private var stamp = Stamp()
    private(set) var announced = ""
    private var changes = 0

    struct Stamp: Equatable {
        var look = ""
        var lines = 8
    }

    /// One of the two faces the cross-fade swaps between.
    final class Page {
        let root: UnsafeMutablePointer<GtkWidget>
        let header: UnsafeMutablePointer<GtkWidget>
        let overlay: UnsafeMutablePointer<GtkWidget>
        let scroller: UnsafeMutablePointer<GtkWidget>
        let body: UnsafeMutablePointer<GtkWidget>
        let fade: UnsafeMutablePointer<GtkWidget>
        let foot: UnsafeMutablePointer<GtkWidget>
        var now: NowParts?
        var subject: SubjectParts?

        init() {
            root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
            scroller = gtk_scrolled_window_new()!
            body = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            overlay = gtk_overlay_new()!
            fade = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            foot = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
            Gtk.addClass(root, "bn-page")
            Gtk.addClass(header, "bn-ro-head")
            Gtk.addClass(body, "bn-ro-body")
            Gtk.addClass(fade, "bn-ro-fade")
            Gtk.addClass(foot, "bn-ro-foot")
            gtk_widget_set_size_request(header, -1, Int32(NeuralStageMetrics.readoutHeaderHeight))
            gtk_widget_set_size_request(foot, -1, Int32(NeuralStageMetrics.readoutFooterHeight))
            gtk_widget_set_vexpand(overlay, 1)
            gtk_widget_set_hexpand(overlay, 1)
            gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
            gtk_scrolled_window_set_min_content_height(op(scroller), 0)
            gtk_scrolled_window_set_propagate_natural_height(op(scroller), 0)
            gtk_scrolled_window_set_has_frame(op(scroller), 0)
            gtk_scrolled_window_set_child(op(scroller), body)
            gtk_widget_set_vexpand(scroller, 1)
            gtk_overlay_set_child(op(overlay), scroller)
            gtk_widget_set_valign(fade, GTK_ALIGN_END)
            gtk_widget_set_size_request(fade, -1, Int32(NeuralStageMetrics.readoutFade))
            gtk_widget_set_can_target(fade, 0)
            gtk_widget_set_visible(fade, 0)
            gtk_overlay_add_overlay(op(overlay), fade)
            gtk_box_append(ptr(root), header)
            gtk_box_append(ptr(root), overlay)
            gtk_box_append(ptr(root), foot)
            gtk_widget_set_hexpand(root, 1)
            gtk_widget_set_vexpand(root, 1)
        }

        var pulses: [UnsafeMutablePointer<GtkWidget>] = []
        var counterLabel: UnsafeMutablePointer<GtkWidget>?
        var factsLeft: UnsafeMutablePointer<GtkWidget>?
        var factsRight: UnsafeMutablePointer<GtkWidget>?

        var adjustment: UnsafeMutablePointer<GtkAdjustment>? {
            gtk_scrolled_window_get_vadjustment(op(scroller))
        }

        /// Whether more of the body lies below what the scroller shows.
        func updateFade() {
            guard let adjustment else { return }
            let more = gtk_adjustment_get_value(adjustment) + gtk_adjustment_get_page_size(adjustment)
                < gtk_adjustment_get_upper(adjustment) - 1
            gtk_widget_set_visible(fade, more ? 1 : 0)
        }

        func watchFade() {
            guard let adjustment else { return }
            let hold = Gtk.WeakWidget(root)
            let reader: @Sendable () -> Void = {
                Gtk.onMain {
                    guard let rootWidget = hold.widget else { return }
                    guard let held = g_object_get_data(ptr(rootWidget), "bn-page") else { return }
                    Unmanaged<Page>.fromOpaque(held).takeUnretainedValue().updateFade()
                }
            }
            Gtk.connect(UnsafeMutableRawPointer(adjustment), "changed", reader)
            Gtk.connect(UnsafeMutableRawPointer(adjustment), "value-changed", reader)
        }
    }

    /// What a running turn's panel keeps to update in place.
    struct NowParts {
        let stepID: String?
        let counter: UnsafeMutablePointer<GtkWidget>?
        let chip: UnsafeMutablePointer<GtkWidget>?
        let tail: UnsafeMutablePointer<GtkWidget>?
        let tailLabel: UnsafeMutablePointer<GtkWidget>?
        let soFar: UnsafeMutablePointer<GtkWidget>?
        let factsLeft: UnsafeMutablePointer<GtkWidget>?
        let factsRight: UnsafeMutablePointer<GtkWidget>?
    }

    /// What a step's panel keeps so a button can change a part of it in place.
    struct SubjectParts {
        let stepID: String
        var copyText: String?
        var toggleOutput: (() -> Void)?
    }

    init(owner: BrainView) {
        self.owner = owner
        ref = WeakBrainView(owner)
        stack = gtk_stack_new()!
        widget = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(widget, "bn-readout")
        gtk_widget_set_hexpand(stack, 1)
        gtk_widget_set_vexpand(stack, 1)
        gtk_stack_set_transition_type(op(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_set_transition_duration(op(stack), UInt32(NeuralTransition.contentFadeDuration * 1000))
        gtk_stack_set_hhomogeneous(op(stack), 1)
        gtk_stack_set_vhomogeneous(op(stack), 1)
        gtk_box_append(ptr(widget), stack)
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)
        for name in ["a", "b"] {
            let page = Page()
            pages.append(page)
            gtk_stack_add_named(op(stack), page.root, name)
            let retained = Unmanaged.passRetained(page).toOpaque()
            g_object_set_data_full(
                ptr(page.root), "bn-page", retained,
                { raw in
                    guard let raw else { return }
                    Unmanaged<Page>.fromOpaque(raw).release()
                })
            page.watchFade()
        }
        gtk_stack_set_visible_child_name(op(stack), "a")
        tailscode_set_accessible_label(widget, BrainWords.readoutLabel)
        Gtk.onPointer(
            widget,
            move: { [ref] _, _ in ref.view?.readoutPointer(inside: true) },
            leave: { [ref] in ref.view?.readoutPointer(inside: false) })
        let focus = Unmanaged.passRetained(FocusBox { [ref] entered in
            ref.view?.readoutFocusChanged(entered)
        }).toOpaque()
        _ = Gtk.releaseInstalled
        tailscode_on_focus_change(
            widget,
            { raw in
                guard let raw else { return }
                Unmanaged<FocusBox>.fromOpaque(raw).takeUnretainedValue().handler(true)
            },
            { raw in
                guard let raw else { return }
                Unmanaged<FocusBox>.fromOpaque(raw).takeUnretainedValue().handler(false)
            }, focus)
    }

    private final class FocusBox: @unchecked Sendable {
        let handler: (Bool) -> Void
        init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
    }

    private var fitted: (width: Int, height: Int, x: Int, y: Int, inline: Bool)?

    /// Sets the panel's size and its place in the clip that holds it: a split gives it the whole
    /// clip, an accordion the cursor row's content, inside the row's own zone edge.
    func fit(width: Double, height: Double, at origin: (Double, Double), inline: Bool) {
        let next = (
            width: Int(width.rounded()), height: Int(height.rounded()), x: Int(origin.0.rounded()),
            y: Int(origin.1.rounded()), inline: inline
        )
        if let fitted, fitted == next { return }
        fitted = next
        gtk_widget_set_size_request(widget, Int32(next.width), Int32(next.height))
        if let parent = gtk_widget_get_parent(widget) {
            gtk_fixed_move(ptr(parent), widget, Double(next.x), Double(next.y))
        }
        if inline {
            gtk_widget_add_css_class(widget, "bn-readout-inline")
        } else {
            gtk_widget_remove_css_class(widget, "bn-readout-inline")
        }
    }

    /// Moves the keyboard to the first button the panel offers; false when it offers none.
    func focusFirstControl() -> Bool {
        guard let page else { return false }
        func find(_ node: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget>? {
            if gtk_widget_get_visible(node) == 0 || gtk_widget_get_child_visible(node) == 0 { return nil }
            let instance = UnsafeMutableRawPointer(node).assumingMemoryBound(to: GTypeInstance.self)
            if g_type_check_instance_is_a(instance, gtk_button_get_type()) != 0,
                gtk_widget_get_can_focus(node) != 0
            {
                return node
            }
            var child = gtk_widget_get_first_child(node)
            while let held = child {
                if let found = find(held) { return found }
                child = gtk_widget_get_next_sibling(held)
            }
            return nil
        }
        guard let button = find(page.root) else { return false }
        gtk_widget_grab_focus(button)
        return true
    }

    /// Folds or unfolds the long output or diff of the step shown.
    func toggleOutput() {
        page?.subject?.toggleOutput?()
    }

    /// How tall the panel's content wants to be at `width`: its header, its body and its foot.
    func naturalHeight(width: Double) -> Double? {
        guard let page, shown != nil else { return nil }
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(page.body, GTK_ORIENTATION_VERTICAL, Int32(max(width, 1)), &minimum, &natural, nil, nil)
        return NeuralStageMetrics.readoutHeaderHeight + Double(natural) + NeuralStageMetrics.readoutFooterHeight
    }

    var page: Page? { pages.isEmpty ? nil : pages[current] }

    /// How visible the body and the facts are, for the first content landing after a move.
    func setBodyAlpha(_ alpha: Double) {
        guard let page else { return }
        gtk_widget_set_opacity(page.overlay, alpha)
        gtk_widget_set_opacity(page.foot, alpha)
    }

    /// The words the panel is about, for the harness.
    var reading: String {
        guard let shown else { return "empty" }
        switch shown.body {
        case .step(let step): return "step \(step.header.number) \(step.header.label) \(step.header.chip.word)"
        case .digest(let digest): return "digest steps=\(digest.ticks.count) failures=\(digest.failures.count)"
        case .now(let now): return "now \(now.step?.header.number ?? 0)"
        case .zone(let list): return "zone \(list.label) rows=\(list.rows.count)"
        case .replay(let replay): return "replay \(replay.current?.header.number ?? 0) log=\(replay.log.count)"
        case .ask(let ask): return "ask \(ask.step.header.number)"
        }
    }

    /// The text of every label in the showing page, for the harness to read what is said.
    var visibleText: String {
        var words: [String] = []
        func walk(_ widget: UnsafeMutablePointer<GtkWidget>) {
            if gtk_widget_get_visible(widget) == 0 { return }
            let instance = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self)
            if g_type_check_instance_is_a(instance, gtk_label_get_type()) != 0,
                let raw = gtk_label_get_text(op(widget))
            {
                words.append(String(cString: raw))
            }
            var child = gtk_widget_get_first_child(widget)
            while let held = child {
                walk(held)
                child = gtk_widget_get_next_sibling(held)
            }
        }
        if let page { walk(page.root) }
        return words.joined(separator: "\n")
    }

    /// Every widget in the showing page wider than the panel, with its own minimum and natural
    /// width, for the harness to find what pushes the panel out.
    var overflowReading: String { overflowReading(limit: Int(gtk_widget_get_width(widget))) }

    func overflowReading(limit bound: Int) -> String {
        guard let page else { return "none" }
        let limit = Int32(bound)
        var lines: [String] = []
        func walk(_ node: UnsafeMutablePointer<GtkWidget>, depth: Int) {
            if gtk_widget_get_visible(node) == 0 { return }
            var minimum: Int32 = 0
            var natural: Int32 = 0
            gtk_widget_measure(node, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, nil, nil)
            let allocated = gtk_widget_get_width(node)
            if allocated > limit || minimum > limit {
                let name = String(cString: gtk_widget_get_css_name(node))
                var classes = ""
                if let list = gtk_widget_get_css_classes(node) {
                    var index = 0
                    while let item = list[index] {
                        classes += String(cString: item) + "."
                        index += 1
                    }
                    g_strfreev(list)
                }
                lines.append("\(String(repeating: " ", count: depth))\(name).\(classes) alloc=\(allocated) min=\(minimum) nat=\(natural)")
            }
            var child = gtk_widget_get_first_child(node)
            while let held = child {
                walk(held, depth: depth + 1)
                child = gtk_widget_get_next_sibling(held)
            }
        }
        walk(page.root, depth: 0)
        return "panel=\(limit) " + lines.joined(separator: " ; ")
    }

    /// The part of the panel the harness measures: its showing page's own widgets.
    var bodyHeight: Int { page.map { Int(gtk_widget_get_height($0.scroller)) } ?? 0 }
    var bodyContentHeight: Int {
        guard let adjustment = page?.adjustment else { return 0 }
        return Int(gtk_adjustment_get_upper(adjustment))
    }
    var fadeVisible: Bool { page.map { gtk_widget_get_visible($0.fade) != 0 } ?? false }

    var pageSwaps: Int { changes }

    func show(_ next: NeuralReadout, stamp nextStamp: Stamp, animate: Bool) {
        if let shown, shown == next, stamp == nextStamp {
            swapDeferred = false
            return
        }
        if let shown, stamp == nextStamp, updatesInPlace(from: shown, to: next) {
            swapDeferred = false
            self.shown = next
            applyNow(next)
            return
        }
        guard !isFading else {
            deferSwap()
            return
        }
        swapDeferred = false
        let previousStep = shown?.step?.stepID
        let target = 1 - current
        let incoming = pages[target]
        clear(incoming)
        build(incoming, next, stamp: nextStamp)
        self.shown = next
        stamp = nextStamp
        current = target
        let reduce = BrainBudget.reduceMotion || !animate || shownOnce == false
        gtk_stack_set_transition_type(
            op(stack), reduce ? GTK_STACK_TRANSITION_TYPE_NONE : GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_set_visible_child_name(op(stack), target == 0 ? "a" : "b")
        shownOnce = true
        changes += 1
        let said = next.announcement
        if said != announced, previousStep != next.step?.stepID || previousStep == nil {
            announced = said
            tailscode_accessible_announce(widget, said, 0)
        }
        incoming.updateFade()
    }

    private var shownOnce = false

    private var swapDeferred = false

    /// Whether the cross-fade between the two pages is running.
    var isFading: Bool { gtk_stack_get_transition_running(op(stack)) != 0 }

    /// Whether the page that is not showing still holds its widgets, for the harness.
    var idlePageIsBuilt: Bool {
        guard pages.count == 2 else { return false }
        return gtk_widget_get_first_child(pages[1 - current].body) != nil
    }

    /// A subject that arrives while the cross-fade runs waits for it to end. The page it would be
    /// built into is the one still fading out under the pointer, and a hover or a press is
    /// delivered from that page's own widgets: emptying it there deletes the widget whose event
    /// is being handled, and the toolkit's pointer bookkeeping then dereferences it. Nothing is
    /// queued but the fact that something is owed; when the fade has ended the brain is asked
    /// again for what the model says by then, so what finally shows is never stale.
    private func deferSwap() {
        guard !swapDeferred else { return }
        swapDeferred = true
        awaitFade(held: Gtk.WeakWidget(stack), attempt: 0)
    }

    private func awaitFade(held: Gtk.WeakWidget, attempt: Int) {
        Gtk.after(24) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.swapDeferred, held.widget != nil else { return }
                if self.isFading, attempt < 50 {
                    self.awaitFade(held: held, attempt: attempt + 1)
                    return
                }
                self.swapDeferred = false
                guard let view = self.ref.view, !view.isSuspended else { return }
                view.refreshReadout(animate: true)
            }
        }
    }

    /// Moves the keyboard out of a page that is about to be emptied, to the list, so no widget
    /// that has focus is ever removed.
    private func releaseFocus(in page: Page) {
        guard let root = gtk_widget_get_root(widget),
            let focused = gtk_root_get_focus(OpaquePointer(UnsafeMutableRawPointer(root)))
        else { return }
        guard focused == page.root || gtk_widget_is_ancestor(focused, page.root) != 0 else { return }
        owner.focusList()
    }

    private func clear(_ page: Page) {
        releaseFocus(in: page)
        Gtk.removeChildren(of: page.header)
        Gtk.removeChildren(of: page.body)
        Gtk.removeChildren(of: page.foot)
        page.now = nil
        page.subject = nil
        page.pulses = []
        gtk_widget_set_opacity(page.overlay, 1)
        gtk_widget_set_opacity(page.foot, 1)
        for name in ["bn-z-think", "bn-z-sense", "bn-z-act", "bn-z-shell", "bn-z-delegate", "bn-z-say"] {
            gtk_widget_remove_css_class(page.root, name)
        }
        if let adjustment = page.adjustment { gtk_adjustment_set_value(adjustment, 0) }
    }

    /// Whether the new reading is the same running step as the one showing, differing only in
    /// what streams: the tail of its output, the count under it, the clock.
    private func updatesInPlace(from old: NeuralReadout, to new: NeuralReadout) -> Bool {
        guard case .now(let before) = old.body, case .now(let after) = new.body,
            before.step?.stepID == after.step?.stepID, before.step?.subject == after.step?.subject,
            before.step?.why == after.step?.why, before.label == after.label,
            page?.now != nil
        else { return false }
        return true
    }

    private func applyNow(_ readout: NeuralReadout) {
        guard case .now(let now) = readout.body, let page, let parts = page.now else { return }
        if let step = now.step {
            if let counter = parts.counter { gtk_label_set_text(op(counter), step.header.counter) }
            if let chip = parts.chip { gtk_label_set_text(op(chip), step.header.chip.word) }
            if let left = parts.factsLeft { gtk_label_set_text(op(left), Self.factsLeft(step.facts)) }
        }
        if let label = parts.tailLabel {
            gtk_label_set_markup(op(label), tailMarkup(now.tail.lines.map { ($0.text, $0.tone) }, caret: true))
        }
        if let soFar = parts.soFar { rebuildSoFar(soFar, headline: now.soFar.headline, chips: now.soFar.chips) }
        page.updateFade()
    }

    static func factsLeft(_ facts: NeuralReadout.Facts) -> String {
        [facts.message, facts.clock].compactMap { $0 }.joined(separator: "  ")
    }

    var inks: BrainInks { owner.inks }

    func retheme() {
        shown = nil
        stamp = Stamp()
    }

    // MARK: header and footer

    private func build(_ page: Page, _ readout: NeuralReadout, stamp: Stamp) {
        switch readout.body {
        case .step(let step):
            applyZone(step.header.zone, to: page)
            header(for: step.header, to: page)
            buildStep(StepParts(step), in: page)
            footFacts(step.facts, in: page)
        case .digest(let digest):
            digestHeader(digest, in: page)
            buildDigest(digest, in: page)
            digestFoot(digest, in: page)
        case .now(let now):
            buildNow(now, in: page)
        case .ask(let ask):
            buildAsk(ask, in: page)
        case .zone(let list):
            applyZone(list.zone, to: page)
            buildZone(list, in: page)
        case .replay(let replay):
            buildReplay(replay, in: page)
        }
        gtk_widget_set_visible(page.fade, 0)
    }

    func applyZone(_ zone: NeuralZone, to page: Page) {
        Gtk.addClass(page.root, "bn-z-\(BrainUI.zoneName(zone))")
    }

    private func statusChip(_ chip: NeuralReadout.Chip) -> UnsafeMutablePointer<GtkWidget> {
        let widget = BrainUI.label(chip.word, "bn-chip", Self.toneClass(chip.tone))
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        return widget
    }

    static func toneClass(_ tone: NeuralTone) -> String {
        switch tone {
        case .live, .identity: return "bn-chip-live"
        case .attention: return "bn-chip-attention"
        case .danger: return "bn-chip-danger"
        case .quiet: return "bn-chip-quiet"
        }
    }

    func header(for header: NeuralReadout.Header, to page: Page, lead: UnsafeMutablePointer<GtkWidget>? = nil) {
        let zone = header.zone
        let inks = self.inks
        if let lead { gtk_box_append(ptr(page.header), lead) }
        gtk_box_append(ptr(page.header), BrainUI.shapeGlyph(zone, size: 18) { inks.corrected(zone) })
        let name = BrainUI.label(header.label, "bn-zone", "bn-tone-text")
        gtk_widget_set_valign(name, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(page.header), name)
        gtk_box_append(ptr(page.header), statusChip(header.chip))
        if header.isPinned {
            let pin = BrainUI.label("\u{25CF} " + BrainWords.pinned, "bn-pin")
            gtk_widget_set_valign(pin, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(page.header), pin)
        }
        let counter = BrainUI.label(header.counter, "bn-counter", ellipsize: true)
        gtk_widget_set_halign(counter, GTK_ALIGN_END)
        gtk_widget_set_hexpand(counter, 1)
        gtk_widget_set_valign(counter, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(page.header), counter)
        page.counterLabel = counter
        tailscode_set_accessible_label(page.header, header.counter)
    }

    /// The footer's facts: where the step stands, at the left, and when the turn began, at the
    /// right, which is the one fact left out when the panel is too narrow for both whole.
    func footFacts(_ facts: NeuralReadout.Facts, in page: Page, right: String? = nil) {
        let left = BrainUI.label(Self.factsLeft(facts), "bn-fact", ellipsize: true)
        let end = BrainUI.label(right ?? facts.turnBegan ?? "", "bn-fact")
        gtk_label_set_xalign(op(end), 1)
        let width = Double(owner.currentMetrics.readoutContentWidth)
        func natural(_ widget: UnsafeMutablePointer<GtkWidget>) -> Double {
            var value: Int32 = 0
            gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, nil, &value, nil, nil)
            return Double(value)
        }
        let fits = natural(left) + natural(end) + 12 + 32 + 8 <= width
        if !fits { gtk_widget_set_visible(end, 0) }
        BrainUI.add(page.foot, left, BrainUI.spacer(), end)
        page.factsLeft = left
        page.factsRight = end
    }

    /// The dot a running panel wears: breathing for work, knocking twice for a step that waits on
    /// the person, still when motion is off. It reads absolute time, so every dot on screen swells
    /// as one hand.
    func pulse(attention: Bool, in page: Page) -> UnsafeMutablePointer<GtkWidget> {
        let box = Unmanaged.passRetained(PulseBox(attention: attention, ref: ref)).toOpaque()
        _ = Gtk.releaseInstalled
        let dot = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let pulse = Unmanaged<PulseBox>.fromOpaque(raw).takeUnretainedValue()
                guard let view = pulse.ref.view else { return }
                let still = BrainBudget.reduceMotion
                let motion: NeuralMotion = pulse.attention ? .heartbeat : .breath
                let level = still ? 1 : motion.level(at: BrainClock.now)
                let floor = pulse.attention ? 0.42 : 0.34
                let swing = still ? 1 : (level - floor) / (1 - floor)
                let color = pulse.attention ? view.inks.warn : view.inks.accent
                cairo_new_path(cr)
                cairo_arc(
                    cr, Double(width) / 2, Double(height) / 2, 3.2 * (0.9 + 0.25 * swing), 0, 2 * .pi)
                cairo_set_source_rgba(cr, color.red, color.green, color.blue, still ? 1 : level)
                cairo_fill(cr)
            }, box,
            { raw in
                guard let raw else { return }
                Unmanaged<PulseBox>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(dot, 10, 10)
        gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(dot, 0)
        tailscode_set_accessible_hidden(dot, 1)
        page.pulses.append(dot)
        return dot
    }

    private final class PulseBox: @unchecked Sendable {
        let attention: Bool
        let ref: WeakBrainView
        init(attention: Bool, ref: WeakBrainView) {
            self.attention = attention
            self.ref = ref
        }
    }

    /// Asks the showing page's dots for their next frame.
    func tickPulses() {
        guard let page else { return }
        for dot in page.pulses { gtk_widget_queue_draw(dot) }
    }

    func tailMarkup(_ lines: [BodyLine], caret: Bool) -> String {
        var markup = outputMarkup(lines, failed: false)
        if caret { markup += "\n<span background=\"\(inks.hex.accent)\"> </span>" }
        return markup
    }

    func outputMarkup(_ lines: [BodyLine], failed: Bool) -> String {
        let hex = inks.hex
        let danger = Contrast.blend(hex.dim, hex.danger, 0.72) ?? hex.danger
        return lines.map { line in
            let text = BrainUI.escape(line.text.isEmpty ? " " : line.text)
            switch line.tone {
            case .dim: return "<span foreground=\"\(failed ? danger : hex.dim)\">\(text)</span>"
            case .danger: return "<span foreground=\"\(danger)\">\(text)</span>"
            case .emphasis: return "<span foreground=\"\(hex.text)\" weight=\"bold\">\(text)</span>"
            }
        }.joined(separator: "\n")
    }
}

