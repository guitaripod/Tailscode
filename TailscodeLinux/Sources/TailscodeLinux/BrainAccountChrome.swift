import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension BrainAccount {
    /// A canvas that paints through the account: the footer's key hints and the scroll thumb.
    static func paintCanvas(_ holder: PaintHolder) -> UnsafeMutablePointer<GtkWidget> {
        _ = Gtk.releaseInstalled
        return tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let holder = Unmanaged<PaintHolder>.fromOpaque(raw).takeUnretainedValue()
                holder.account?.paint(holder.kind, cr, width: Double(width), height: Double(height))
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<PaintHolder>.fromOpaque(raw).release()
            })!
    }

    final class PaintHolder: @unchecked Sendable {
        weak var account: BrainAccount?
        let kind: Int
        init(kind: Int) { self.kind = kind }
    }

    fileprivate func paint(_ kind: Int, _ cr: OpaquePointer, width: Double, height: Double) {
        guard !disposed, let view = ref.view, !view.disposed else { return }
        if kind == 0 {
            paintFooter(cr, width: width, height: height, inks: view.inks)
        } else {
            paintScrollbar(cr, width: width, height: height, inks: view.inks)
        }
    }

    private func paintFooter(_ cr: OpaquePointer, width: Double, height: Double, inks: BrainInks) {
        let rule = inks.rule
        cairo_set_source_rgba(cr, rule.red, rule.green, rule.blue, 1)
        cairo_set_line_width(cr, 1)
        cairo_new_path(cr)
        cairo_move_to(cr, 0, 0.5)
        cairo_line_to(cr, width, 0.5)
        cairo_stroke(cr)
        let mid = height / 2
        var x = Self.padLeft
        func hint(_ keys: [String], _ verb: String) {
            for key in keys { x += BrainDraw.keyCap(cr, key, x: x, midY: mid, fonts: fonts, inks: inks) + 3 }
            x += 3
            BrainDraw.line(
                cr, verb, font: fonts.status, lineHeight: fonts.lineHeight, x: x, top: 0, height: height,
                color: inks.dim)
            x += BrainDraw.measure(verb, fonts.status) + 14
        }
        hint(["s", "S"], BrainWords.saidVerb)
        hint(["a"], BrainWords.askVerb)
        hint(["\u{2191}", "\u{2193}"], BrainWords.itemsVerb)
        hint(["Enter"], BrainWords.detailVerb)
        if let began = beganClock {
            let size = BrainDraw.measure(began, fonts.count)
            BrainDraw.line(
                cr, began, font: fonts.count, lineHeight: fonts.lineHeight, x: width - Self.padRight - size, top: 0,
                height: height, color: inks.dim)
        }
    }

    var beganClock: String? {
        let model = owner.model
        guard let at = model.turn.startedAt ?? model.steps.compactMap(\.at).min() else { return nil }
        return NeuralReading.clock(at)
    }

    private func paintScrollbar(_ cr: OpaquePointer, width: Double, height: Double, inks: BrainInks) {
        guard maxScroll > 0, viewHeight > 0 else { return }
        let thumb = max(24, viewHeight * viewHeight / total)
        let travel = viewHeight - thumb
        let y = (maxScroll > 0 ? scroll / maxScroll : 0) * travel
        BrainDraw.fill(cr, inks.dim, 0.35)
        BrainDraw.roundedRect(cr, width - 5, y, 3, thumb, 1.5)
        cairo_fill(cr)
    }


    /// What the header and the pins say, again: the entity's header, the pill that offers the way
    /// back to a following account, and the pins above the story.
    func refreshChrome() {
        let model = owner.model
        let list = model.browseState.list
        let solo = list.filter.zones == [.say] && !list.filter.failedOnly && list.filter.query.isEmpty
        filterWord = solo ? BrainWords.whatItToldYou : (list.isFiltered ? BrainWords.filtered : nil)
        noteActivity()
        refreshEntityHeader()
        refreshPins()
        gtk_widget_set_visible(pill, list.showsFollowPill ? 1 : 0)
        gtk_widget_queue_draw(footer)
        tailscode_brain_row_invalidate(root)
    }

    /// Notes the moment the step in flight last said something, which is when silence is counted
    /// from: the client's own clock, because the transcript's times are the machine's.
    private func noteActivity() {
        guard let live = account.live else {
            lastActivityMark = ""
            lastActivityAt = nil
            return
        }
        let mark = "\(live.stepID)|\(live.tail.count)|\(live.lastLine ?? "")|\(account.header.stepCount)"
        if !lastActivityMark.isEmpty, mark != lastActivityMark { lastActivityAt = Date() }
        lastActivityMark = mark
    }

    /// Once a second while the turn runs: the Now line's "last output 4 s ago" and the header's
    /// words move on without anything arriving.
    func tickSecond(_ time: Double) {
        guard account.header.isRunning, time - lastSecond >= 1 else { return }
        lastSecond = time
        refreshEntityHeader()
        refreshPins()
    }

    /// Makes the pins again when what they say changed: the ask, the Now line and a running turn's
    /// plan, each in its place above the story.
    func refreshPins() {
        let model = owner.model
        let ask = account.askItem
        let askSig = ask.map { "\($0.id)|\($0.subject)|\($0.why?.text ?? "")|\(Int(boxWidth))|\(owner.inks.hex.warn)" } ?? ""
        setPin(&askPin, signature: askSig) { ask.map { self.buildAsk($0) } }
        let vitals = account.vitals(now: Date(), lastActivity: lastActivityAt)
        var nowSig = ""
        if ask == nil, let live = account.live {
            nowSig = "\(live.stepID)|\(live.title)|\(live.argument)|\(live.tail.map(\.text).joined(separator: "\n"))|\(vitals.isSilent)|\(vitals.lastOutputWords ?? "")|\(vitals.silentWords ?? "")|\(Int(boxWidth))|\(owner.inks.hex.accent)"
        }
        let live = account.live
        setPin(&nowPin, signature: nowSig) { live.map { self.buildNow($0, vitals: vitals) } }
        var planSig = ""
        var compact = false
        if account.header.isRunning, let plan = account.plan {
            compact = nowPin != nil && planNeedsCompaction(plan)
            let open = planOpenOverride ?? true
            planSig = "\(plan.items.map { "\($0.text)\($0.state)" }.joined(separator: "|"))|\(compact)|\(open)|\(Int(boxWidth))"
        }
        pinnedPlanCompact = compact
        let plan = account.plan
        let open = planOpenOverride ?? true
        setPin(&planPin, signature: planSig) { plan.map { self.buildPlan($0, entryID: nil, compact: compact, open: open) } }
        _ = model
    }

    /// Whether a running plan is too tall to be open beside the Now line: it then keeps its
    /// segments and the item in progress.
    private func planNeedsCompaction(_ plan: NeuralAccount.Plan) -> Bool {
        if let override = planOpenOverride { return !override }
        let available = (frameCache?.height ?? 560) - headerHeight - Self.footerHeight - askHeight - 150 - 160
        return Double(24 + plan.items.prefix(24).count * 24 + 16) > available
    }

    private func setPin(_ pin: inout Pin?, signature: String, build: () -> UnsafeMutablePointer<GtkWidget>?) {
        if let held = pin, held.signature == signature { return }
        if let held = pin {
            pin = nil
            releaseFocus(inside: held.widget)
            tailscode_brain_row_remove(root, held.widget)
        }
        guard !signature.isEmpty, let widget = build() else { return }
        let made = Pin(widget: widget, signature: signature)
        pin = made
        tailscode_brain_row_add(root, widget)
        made.height = measure(widget, width: pinWidth())
    }

    /// Takes every pin off the root, for a change of colours that makes them again.
    func dropPins() {
        for pin in [askPin, nowPin, planPin].compactMap({ $0 }) {
            releaseFocus(inside: pin.widget)
            tailscode_brain_row_remove(root, pin.widget)
        }
        askPin = nil
        nowPin = nil
        planPin = nil
    }

    /// One line of a role's type as the toolkit lays it out, with its own leading.
    static func lineHeight(_ css: String) -> Double {
        let label = BrainUI.label("Mg", css, wrap: true)
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(label, GTK_ORIENTATION_VERTICAL, 400, &minimum, &natural, nil, nil)
        return Double(max(natural, 1))
    }

    private func releaseFocus(inside widget: UnsafeMutablePointer<GtkWidget>) {
        guard let window = gtk_widget_get_root(root),
            let focused = gtk_root_get_focus(OpaquePointer(UnsafeMutableRawPointer(window)))
        else { return }
        guard focused == widget || gtk_widget_is_ancestor(focused, widget) != 0 else { return }
        gtk_widget_grab_focus(story)
    }

    private func measure(_ widget: UnsafeMutablePointer<GtkWidget>, width: Double) -> Double {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(widget, GTK_ORIENTATION_VERTICAL, Int32(max(width, 1)), &minimum, &natural, nil, nil)
        return Double(max(minimum, natural))
    }

    /// The header and the pins measured at the width they are laid out at, in the pass that places
    /// them: when any is not the height it was, the root asks to be laid out again, once.
    /// The width a pinned item is laid out at: the box once there is one, and until then the box
    /// the root's width will give it, so a pin is never measured in room it will not have.
    private func pinWidth(rootWidth: Double? = nil) -> Double {
        if boxWidth > 0 { return boxWidth }
        let available = rootWidth ?? Double(gtk_widget_get_width(self.root))
        guard available > 1 else { return 640 }
        return max(200, frame(width: available, height: max(viewHeight, 400)).boxWidth)
    }

    func measureChrome(width: Double) {
        var changed = false
        if (owner.currentMetrics.arrangement == .accordion) != headerWasNarrow { refreshEntityHeader() }
        let wanted = max(40, measure(header, width: width))
        if abs(wanted - headerHeight) > 0.5 {
            headerHeight = wanted
            changed = true
        }
        let box = pinWidth(rootWidth: width)
        for pin in [askPin, nowPin, planPin].compactMap({ $0 }) {
            let next = measure(pin.widget, width: box)
            if abs(next - pin.height) > 0.5 {
                pin.height = next
                changed = true
            }
        }
        if changed {
            Gtk.onMain { [weak self] in
                guard let self, !self.disposed else { return }
                tailscode_brain_row_invalidate(self.root)
                self.geometryChanged()
            }
        }
    }

    func retheme() {
        fonts = BrainListFonts()
        workFonts = WorkFonts()
        proseProbe = Self.probe()
        headerStamp = ""
        dropPins()
        readStamp = nil
        askedLine = Self.lineHeight("bn-asked-text")
        for (_, cell) in cells {
            cell.stale = true
            for rows in cell.rows { rows.retheme() }
        }
        heights = [:]
        refresh(immediate: true)
    }

    /// The prose role's line height and size, read from a label that wears it: one line of it
    /// measured as the toolkit lays it out, with the style sheet's own leading.
    static func probe() -> (line: Double, em: Double) {
        let label = BrainUI.label("Mg", "bn-said-text", wrap: true)
        let font = BrainUI.font(of: label)
        let size = font.split(separator: " ").last.flatMap { Double($0) } ?? 11.25
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(label, GTK_ORIENTATION_VERTICAL, 400, &minimum, &natural, nil, nil)
        return (Double(max(natural, 1)), size * 4 / 3)
    }


    func installInput() {
        let ref = self.ref
        Gtk.onScrollBubble(root) { [weak self] dy in
            guard let self else { return false }
            return self.wheel(dy)
        }
        Gtk.onKey(root) { keyval, state in
            ref.view?.accountKey(keyval: keyval, state: state) ?? false
        }
        let focus = Unmanaged.passRetained(FocusBox { entered in
            ref.view?.accountFocusChanged(entered)
        }).toOpaque()
        _ = Gtk.releaseInstalled
        tailscode_on_focus_change(
            root,
            { raw in
                guard let raw else { return }
                Unmanaged<FocusBox>.fromOpaque(raw).takeUnretainedValue().handler(true)
            },
            { raw in
                guard let raw else { return }
                Unmanaged<FocusBox>.fromOpaque(raw).takeUnretainedValue().handler(false)
            }, focus)
        Gtk.onPressCapture(root) { [weak self] _, _ in
            Gtk.onMain { [weak self] in self?.focusIfOutside() }
        }
    }

    final class FocusBox: @unchecked Sendable {
        let handler: (Bool) -> Void
        init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
    }

    /// Whether the keyboard is on the account or on something inside it.
    var hasFocus: Bool {
        guard let window = gtk_widget_get_root(root),
            let focused = gtk_root_get_focus(OpaquePointer(UnsafeMutableRawPointer(window)))
        else { return false }
        return focused == root || gtk_widget_is_ancestor(focused, root) != 0
    }

    /// Whether the keyboard is on a button, where Enter and Space are the button's.
    var focusIsButton: Bool {
        guard let window = gtk_widget_get_root(root),
            let focused = gtk_root_get_focus(OpaquePointer(UnsafeMutableRawPointer(window)))
        else { return false }
        let instance = UnsafeMutableRawPointer(focused).assumingMemoryBound(to: GTypeInstance.self)
        return g_type_check_instance_is_a(instance, gtk_button_get_type()) != 0
    }

    func focusIfOutside() {
        guard !disposed, !hasFocus else { return }
        gtk_widget_grab_focus(story)
    }

    func focus() {
        gtk_widget_grab_focus(story)
    }
}
