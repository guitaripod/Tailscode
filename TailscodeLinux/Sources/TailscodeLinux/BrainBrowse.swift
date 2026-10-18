import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What keys and the pointer do to the brain, on this desk: every event is mapped to one of
/// Core's `NeuralBrowse.Action`s, the model runs the reducer, and the effects that come back are
/// the only things this file performs (scroll the list, copy to the clipboard, move the keyboard,
/// show the legend or a menu, ring a node). The key table, the mouse rules and the order Esc
/// undoes things in exist once, in Core.
extension BrainView {
    /// Runs an action through the model and performs what it asks for. `grabFocus` is false for
    /// events that did not come from the list itself (a filter's click, the search field's typing,
    /// a wheel), which must not take the keyboard from where the person put it.
    func browse(
        _ action: NeuralBrowse.Action, grabFocus: Bool = true, menuAt: (Double, Double)? = nil,
        menuParent: UnsafeMutablePointer<GtkWidget>? = nil
    ) {
        guard !disposed, stage != nil else { return }
        let effects = model.browse(action)
        applyBrowse(effects, grabFocus: grabFocus, menuAt: menuAt, menuParent: menuParent)
    }

    func applyBrowse(
        _ effects: [NeuralBrowse.Effect], grabFocus: Bool = true, menuAt: (Double, Double)? = nil,
        menuParent: UnsafeMutablePointer<GtkWidget>? = nil
    ) {
        for effect in effects {
            switch effect {
            case .scrollTo(let id):
                list?.scrollTo(id)
            case .copySubject(let id):
                copyText(id) { NeuralBrowse.subjectText(of: $0) }
            case .copyOutput(let id):
                copyText(id) { NeuralBrowse.outputText(of: $0) }
            case .copyMarkdown(let id):
                copyText(id) { NeuralBrowse.markdown(of: $0) }
            case .focusReadout:
                if grabFocus { focusReadoutOrAccount() }
            case .focusList:
                if grabFocus { focusList() }
            case .focusSearch:
                focusSearch()
            case .expandOutputToggle:
                if account?.toggleCardOutput() != true { readout?.toggleOutput() }
            case .showLegend:
                presentLegend()
            case .hideLegend:
                dismissLegend()
            case .collapseBrain:
                host?.setOpen(false, turnID: turnID)
            case .ring:
                break
            case .dim:
                refreshDimming()
            case .announce(let words):
                announce(words)
            case .showMenu(let id, let items):
                presentMenu(for: id, items: items, at: menuAt, parent: menuParent)
            case .showInRows(let id):
                showInRows(id)
            }
        }
        drainAccountEffects()
        afterBrowse()
    }

    /// Everything a changed cursor, hover or filter redraws.
    private func afterBrowse() {
        list?.modelChanged()
        filters?.invalidate()
        refreshAccordion()
        afterSelection()
        relayout()
    }

    func announce(_ words: String) {
        guard let list else { return }
        tailscode_accessible_announce(list.canvas, words, 0)
    }

    private func copyText(_ id: String, _ text: (NeuralStep) -> String) {
        guard let step = model.step(id: id) else { return }
        let value = text(step)
        guard !value.isEmpty else {
            announce(NeuralBrowse.noRelatedWords)
            return
        }
        Gtk.copyToClipboard(value)
        list?.flashCopied(id)
        announce(BrainWords.copied)
    }

    func copyStep(_ id: String) {
        copyText(id) { NeuralBrowse.subjectText(of: $0) }
    }

    // MARK: hover

    /// The pointer is on a list row: the readout previews it and the head rings its node, and
    /// the cursor stays where it is. A narrow row has no readout beside it, so it only rings.
    func hoverStep(_ id: String) {
        routeHover(id, delay: NeuralHoverGrace.intentDelay)
    }

    func hoverLeftStep() {
        routeHover(nil, delay: 0)
    }

    /// The least time between two hovers the brain acts on. A pointer moving over the strip, the
    /// rows and the head reports a thousand positions a second, and each one that changed what is
    /// under it would rebuild a reading of the turn: the first is acted on at once, the ones that
    /// follow within this time are folded into the newest, which is acted on when it has passed.
    static let hoverSpacing = 0.012

    /// Every hover goes through here: a hover of what is already shown is nothing, and the rest
    /// are rate-limited, newest wins.
    func routeHover(_ id: String?, delay: Double) {
        guard !disposed else { return }
        if id == hoverApplied, !hoverFlushScheduled { return }
        pendingHover = (id, delay)
        if !hoverFlushScheduled, BrainClock.now - lastHoverApply >= Self.hoverSpacing {
            flushHover()
            return
        }
        guard !hoverFlushScheduled else { return }
        hoverFlushScheduled = true
        Gtk.after(UInt32(Self.hoverSpacing * 1000)) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.disposed else { return }
                self.hoverFlushScheduled = false
                self.flushHover()
            }
        }
    }

    private func flushHover() {
        guard let (id, delay) = pendingHover, stage != nil else {
            pendingHover = nil
            return
        }
        pendingHover = nil
        lastHoverApply = BrainClock.now
        hoverApplied = id
        if let id {
            model.pointer(over: id, at: BrainClock.now - delay)
            browse(.hover(id), grabFocus: false)
        } else {
            model.pointer(over: nil, at: BrainClock.now)
            browse(.hoverLeft, grabFocus: false)
        }
    }

    /// A node of the head was clicked: a "+7" node picks its first failed member and solos the
    /// zone, any other node is a row clicked.
    func nodeClicked(_ id: String, double: Bool) {
        browse(.clickNode(id, double: double))
    }

    // MARK: focus

    func focusList() {
        guard let list, !disposed, list.canvas != nil else { return }
        gtk_widget_grab_focus(list.canvas)
    }

    private func returnFocusToList() {
        model.setBrowseFocus(.list)
        focusList()
    }

    func focusSearch() {
        guard let list else { return }
        gtk_widget_set_visible(list.entry, 1)
        relayout()
        Gtk.onMain { [weak self] in
            guard let self, !self.disposed, let list = self.list else { return }
            gtk_widget_grab_focus(list.entry)
            gtk_editable_set_position(op(list.entry), -1)
        }
    }

    func openSearch() {
        model.setBrowseSearchOpen(true)
        model.setBrowseFocus(.search)
        list?.modelChanged()
        relayout()
        focusSearch()
    }

    func clearAllFilters() {
        browse(.searchText(""), grabFocus: false)
        if model.stepList.filter.isActive {
            while model.stepList.filter.isActive {
                let before = model.stepList.filter
                browse(.key(.escape))
                if before == model.stepList.filter { break }
            }
        }
    }

    func listFocusChanged(_ entered: Bool) {
        if entered {
            if model.browseFocus != .list { model.setBrowseFocus(.list) }
        }
        list?.invalidate()
        stage?.invalidate()
        redrawNow()
    }

    func searchFocusChanged(_ entered: Bool) {
        if entered {
            model.setBrowseFocus(.search)
            model.setBrowseSearchOpen(true)
        } else if model.browseFocus == .search {
            model.setBrowseFocus(.list)
            if model.stepList.filter.query.isEmpty {
                model.setBrowseSearchOpen(false)
                list?.modelChanged()
                relayout()
            }
        }
    }

    func readoutFocusChanged(_ entered: Bool) {
        if entered {
            model.setBrowseFocus(.readout)
        } else if model.browseFocus == .readout {
            model.setBrowseFocus(.list)
        }
    }

    /// Moves the keyboard to the row itself before any part that holds it is removed, so no
    /// widget with focus is ever unparented.
    func returnFocusFromBrain() {
        guard let root = gtk_widget_get_root(widget),
            let focused = gtk_root_get_focus(OpaquePointer(UnsafeMutableRawPointer(root)))
        else { return }
        guard focused != widget, gtk_widget_is_ancestor(focused, widget) != 0 else { return }
        gtk_widget_set_focusable(widget, 1)
        gtk_widget_set_can_focus(widget, 1)
        gtk_widget_grab_focus(widget)
    }

    func listAnimationChanged() {
        updateClock()
    }

    /// Whether the keyboard is in the brain: on the list, the head or the readout. The search
    /// field is not, because it takes text, and nothing else in the window is.
    var hasBrainFocus: Bool {
        guard let root = gtk_widget_get_root(widget), !disposed else { return false }
        guard let focused = gtk_root_get_focus(OpaquePointer(UnsafeMutableRawPointer(root))) else { return false }
        func within(_ ancestor: UnsafeMutablePointer<GtkWidget>?) -> Bool {
            guard let ancestor else { return false }
            return focused == ancestor || gtk_widget_is_ancestor(focused, ancestor) != 0
        }
        return within(list?.canvas) || within(stage?.hit) || within(readout?.widget) || within(account?.root)
    }

    // MARK: keys

    /// A key the list, the head or the readout has: mapped to the reducer's vocabulary, never
    /// when the person is typing in the search field or holds a chord that belongs to the window.
    func brainKey(keyval: UInt32, state: UInt32) -> Bool {
        guard !disposed, phase == .open, stage != nil else { return false }
        let reserved = GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue
        guard state & reserved == 0 else { return false }
        guard let key = Self.browseKey(keyval) else { return false }
        if key == .escape, stage?.diveZone != nil, !model.stepList.filter.isActive, model.pinnedStep == nil {
            stage?.dive(into: nil)
            return true
        }
        if key == .tab { return false }
        var modifiers: NeuralBrowse.Modifiers = []
        if state & GDK_SHIFT_MASK.rawValue != 0 { modifiers.insert(.shift) }
        let hadCursor = model.pinnedStep != nil
        browse(.key(key, modifiers))
        if key == .escape, hadCursor, model.pinnedStep == nil {
            hoverApplied = nil
            pendingHover = nil
            model.pointer(over: nil, at: BrainClock.now - 10)
            afterSelection()
        }
        return true
    }

    /// Keys in the search field: leaving it, taking the first match, and walking the matches.
    func searchKey(keyval: UInt32, state: UInt32) -> Bool {
        guard !disposed else { return false }
        let reserved = GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue
        guard state & reserved == 0, let key = Self.browseKey(keyval) else { return false }
        switch key {
        case .enter, .escape, .up, .down:
            model.setBrowseFocus(.search)
            browse(.key(key))
            return true
        default:
            return false
        }
    }

    static func browseKey(_ keyval: UInt32) -> NeuralBrowse.Key? {
        switch Int32(truncatingIfNeeded: keyval) {
        case GDK_KEY_Up, GDK_KEY_KP_Up: return .up
        case GDK_KEY_Down, GDK_KEY_KP_Down: return .down
        case GDK_KEY_Page_Up, GDK_KEY_KP_Page_Up: return .pageUp
        case GDK_KEY_Page_Down, GDK_KEY_KP_Page_Down: return .pageDown
        case GDK_KEY_Home, GDK_KEY_KP_Home: return .home
        case GDK_KEY_End, GDK_KEY_KP_End: return .end
        case GDK_KEY_Left, GDK_KEY_KP_Left: return .left
        case GDK_KEY_Right, GDK_KEY_KP_Right: return .right
        case GDK_KEY_Return, GDK_KEY_KP_Enter: return .enter
        case GDK_KEY_space: return .space
        case GDK_KEY_Escape: return .escape
        case GDK_KEY_Tab, GDK_KEY_ISO_Left_Tab: return .tab
        default:
            let scalar = gdk_keyval_to_unicode(guint(keyval))
            guard scalar >= 0x21, scalar < 0x7F, let unicode = Unicode.Scalar(scalar) else { return nil }
            return .character(Character(unicode))
        }
    }

    // MARK: dimming and the accordion

    /// The nodes the filters hide: a node dims when its step and every step it stands for are
    /// hidden, so a "+7" node stays lit while any member shows.
    func refreshDimming() {
        let list = model.browseState.list
        guard list.isFiltered else {
            if !dimmedNodes.isEmpty {
                dimmedNodes = []
                stage?.invalidate()
            }
            return
        }
        let hidden = list.hiddenIDs
        var nodes = Set<String>()
        for id in hidden {
            let node = list.nodeID(of: id)
            guard hidden.contains(node) else { continue }
            let members = list.ganglionMembers(of: node)
            if members.allSatisfy({ hidden.contains($0) }) { nodes.insert(node) }
        }
        guard nodes != dimmedNodes else { return }
        dimmedNodes = nodes
        stage?.invalidate()
    }

    /// A narrow brain has no list to open a row of: its account is the list. The step list's
    /// expanded row stays closed in every layout.
    func refreshAccordion() {
        list?.setExpanded(nil, contentHeight: 0)
    }

    // MARK: legend and menu

    func toggleLegend() {
        browse(.key(.character("?")))
    }

    func presentLegend() {
        dismissLegend()
        let narrow = currentMetrics.arrangement == .accordion
        guard let anchor = narrow ? account?.root : list?.canvas else { return }
        let popover = gtk_popover_new()!
        gtk_widget_set_parent(popover, anchor)
        gtk_popover_set_has_arrow(ptr(popover), 0)
        gtk_popover_set_autohide(ptr(popover), 0)
        let m = currentMetrics
        var rect = GdkRectangle(
            x: gint((narrow ? m.width : m.list.width) / 2), y: gint(NeuralStageMetrics.listHeaderHeight + 24),
            width: 1, height: 1)
        gtk_popover_set_pointing_to(ptr(popover), &rect)
        gtk_popover_set_position(ptr(popover), GTK_POS_BOTTOM)
        Gtk.addClass(popover, "bn-legend")
        let grid = gtk_grid_new()!
        gtk_grid_set_column_spacing(ptr(grid), 18)
        gtk_grid_set_row_spacing(ptr(grid), 7)
        let entries = NeuralBrowse.legend
        let perColumn = (entries.count + 1) / 2
        for (index, entry) in entries.enumerated() {
            let column = Int32(index / perColumn) * 2
            let rowIndex = Int32(index % perColumn)
            let keys = BrainUI.label(entry.keys, "bn-legend-keys")
            gtk_widget_set_halign(keys, GTK_ALIGN_START)
            let does = BrainUI.label(entry.does, "bn-legend-does")
            gtk_widget_set_halign(does, GTK_ALIGN_START)
            gtk_grid_attach(ptr(grid), keys, column, rowIndex, 1, 1)
            gtk_grid_attach(ptr(grid), does, column + 1, rowIndex, 1, 1)
        }
        gtk_popover_set_child(ptr(popover), grid)
        tailscode_set_accessible_label(popover, BrainWords.keyLegend)
        let hold = Gtk.WeakWidget(popover)
        let ref = WeakBrainView(self)
        Gtk.connect(UnsafeMutableRawPointer(popover), "closed") {
            Gtk.onMain {
                ref.view?.model.setBrowseLegend(false)
                ref.view?.legendPopover = nil
                guard let held = hold.widget, gtk_widget_get_parent(held) != nil else { return }
                gtk_widget_unparent(held)
            }
        }
        Gtk.onKey(popover) { keyval, _ in
            if keyval == 0x3F || keyval == Keymap.escape {
                ref.view?.dismissLegend()
                return true
            }
            return false
        }
        legendPopover = Gtk.WeakWidget(popover)
        gtk_popover_popup(ptr(popover))
    }

    /// Takes the legend and a menu off the widgets they hang on, before those widgets go: a popover
    /// left as a child is a warning at the widget's end and a dangling pointer for its signals.
    func dropPopovers() {
        for held in [legendPopover, menuPopover] {
            guard let popover = held?.widget, gtk_widget_get_parent(popover) != nil else { continue }
            gtk_popover_popdown(ptr(popover))
            gtk_widget_unparent(popover)
        }
        legendPopover = nil
        menuPopover = nil
    }

    func dismissLegend() {
        guard let held = legendPopover?.widget else { return }
        gtk_popover_popdown(ptr(held))
    }

    /// Whether the key legend is up, so a press elsewhere in the brain can put it away.
    func dismissLegendOnPress() {
        guard model.browseState.legend else { return }
        browse(.key(.escape), grabFocus: false)
    }

    func presentMenu(
        for id: String, items: [NeuralBrowse.MenuItem], at point: (Double, Double)?, holding: Bool = false,
        parent: UnsafeMutablePointer<GtkWidget>? = nil
    ) {
        guard let list, let row = model.browseState.list.row(id: id) else { return }
        let popover = gtk_popover_new()!
        gtk_widget_set_parent(popover, parent ?? list.canvas)
        gtk_popover_set_has_arrow(ptr(popover), 0)
        let at = point ?? (120, 60)
        var rect = GdkRectangle(x: gint(at.0), y: gint(at.1), width: 1, height: 1)
        gtk_popover_set_pointing_to(ptr(popover), &rect)
        gtk_popover_set_position(ptr(popover), GTK_POS_BOTTOM)
        if holding { gtk_popover_set_autohide(ptr(popover), 0) }
        Gtk.addClass(popover, "bn-menu")
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        let hold = Gtk.WeakWidget(popover)
        let ref = WeakBrainView(self)
        for item in items {
            let button = gtk_button_new()!
            Gtk.addClass(button, "flat")
            Gtk.addClass(button, "bn-menu-item")
            let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 18)
            let title = BrainUI.label(NeuralBrowse.title(of: item), "bn-menu-title")
            gtk_widget_set_hexpand(title, 1)
            gtk_widget_set_halign(title, GTK_ALIGN_START)
            gtk_box_append(ptr(line), title)
            if let key = BrainWords.menuKey(item, zone: row.zone) {
                gtk_box_append(ptr(line), BrainUI.label(key, "bn-menu-key"))
            }
            gtk_button_set_child(ptr(button), line)
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked") {
                Gtk.onMain {
                    if let held = hold.widget { gtk_popover_popdown(ptr(held)) }
                    ref.view?.browse(.menu(item, id), grabFocus: true)
                }
            }
            gtk_box_append(ptr(column), button)
        }
        gtk_popover_set_child(ptr(popover), column)
        Gtk.connect(UnsafeMutableRawPointer(popover), "closed") {
            Gtk.onMain {
                guard let held = hold.widget, gtk_widget_get_parent(held) != nil else { return }
                gtk_widget_unparent(held)
            }
        }
        menuPopover = hold
        gtk_popover_popup(ptr(popover))
    }

    /// "Show in Rows": the step's own card, which the Rows toggle lists in the transcript.
    private func showInRows(_ id: String) {
        guard let host else { return }
        if !host.rowsShown.contains(turnID) { host.toggleRows(turnID: turnID) }
        announce(NeuralBrowse.title(of: .showInRows))
    }
}
