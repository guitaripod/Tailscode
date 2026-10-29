import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension AgentsWindow {
    func build(parent: UnsafeMutablePointer<GtkWidget>?) {
        gtk_window_set_title(ptr(window), Localized.text("Agents"))
        let size = AgentsWindowSize.initial(parent: parent)
        openedSize = (size.width, size.height)
        gtk_window_set_default_size(ptr(window), size.width, size.height)
        gtk_widget_set_size_request(window, AgentsWindowSize.floor.width, AgentsWindowSize.floor.height)
        Gtk.addClass(window, "agents-window")
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }
        let toolbar = adw_toolbar_view_new()!
        let toolbarHandle = OpaquePointer(toolbar)
        let bar = buildHeader()
        header = bar
        adw_toolbar_view_add_top_bar(toolbarHandle, bar)
        adw_toolbar_view_set_content(toolbarHandle, buildBody())
        adw_window_set_content(ptr(window), toolbar)
        controls = WatchControls(window: window, toolbar: toolbarHandle, clock: watchView.context.clock)
        adw_header_bar_pack_end(op(UnsafeMutableRawPointer(bar)), controls.fullscreenButton)
        adw_header_bar_pack_end(op(UnsafeMutableRawPointer(bar)), controls.awakeButton)
        adw_header_bar_pack_end(op(UnsafeMutableRawPointer(bar)), styleButton)
        tailscode_set_accessible_label(styleButton, Localized.text("Style"))
        gtk_widget_set_tooltip_text(styleButton, Localized.text("How the wall looks and moves"))
        gtk_widget_set_focus_on_click(styleButton, 0)
        let openStyle = hooks.openStyle
        Gtk.connect(UnsafeMutableRawPointer(styleButton), "clicked") { openStyle() }
        wireControls()
        applyLens()
        Gtk.onKey(window) { [weak self] keyval, state in
            self?.handleKey(keyval: keyval, state: state) ?? false
        }
        Gtk.onPointer(
            window, move: { [weak self] _, _ in Gtk.onMain { [weak self] in self?.inputSeen() } },
            leave: {})
        Gtk.onPressCapture(window) { [weak self] _, _ in Gtk.onMain { [weak self] in self?.inputSeen() } }
        Gtk.onNotify(UnsafeMutableRawPointer(window), property: "suspended") { [weak self] in
            Gtk.onMain { [weak self] in self?.windowSuspended() }
        }
        Gtk.observe(UnsafeMutableRawPointer(window), "close-request") { [weak self] in
            self?.rememberSize()
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [weak self] in
            guard let self else { return }
            Self.destroyed(self)
        }
    }

    private func buildHeader() -> UnsafeMutablePointer<GtkWidget> {
        let bar = adw_header_bar_new()!
        let switcher = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(switcher, "linked")
        gtk_toggle_button_set_group(ptr(nowButton), ptr(watchButton))
        gtk_toggle_button_set_group(ptr(hourButton), ptr(watchButton))
        gtk_toggle_button_set_active(ptr(watchButton), 1)
        for (button, words, lens) in [
            (watchButton, Localized.text("Watch"), Mode.watch), (nowButton, Localized.text("Now"), .now),
            (hourButton, Localized.text("Hour"), .hour),
        ] {
            gtk_box_append(ptr(switcher), button)
            tailscode_set_accessible_label(button, words)
            Gtk.connect(UnsafeMutableRawPointer(button), "toggled") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, !self.isDestroyed, gtk_toggle_button_get_active(ptr(self.lensButton(lens))) != 0 else { return }
                    self.show(lens)
                }
            }
        }
        adw_header_bar_set_title_widget(op(UnsafeMutableRawPointer(bar)), switcher)
        return bar
    }

    private func buildBody() -> UnsafeMutablePointer<GtkWidget> {
        let hourPage = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.margins(hourHeader, top: 14, bottom: 0, leading: 22, trailing: 22)
        gtk_box_append(ptr(hourPage), hourHeader)
        gtk_box_append(ptr(hourPage), hourView.widget)
        gtk_stack_add_named(op(stack), watchView.widget, "watch")
        gtk_stack_add_named(op(stack), boardView.widget, "now")
        gtk_stack_add_named(op(stack), hourPage, "hour")
        gtk_widget_set_hexpand(stack, 1)
        gtk_widget_set_vexpand(stack, 1)

        let inspector = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(inspector, "agents-inspector")
        gtk_widget_set_size_request(peek.widget, 380, -1)
        gtk_box_append(ptr(inspector), peek.widget)
        gtk_revealer_set_child(op(revealer), inspector)
        gtk_revealer_set_transition_type(op(revealer), GTK_REVEALER_TRANSITION_TYPE_SLIDE_LEFT)
        gtk_revealer_set_reveal_child(op(revealer), 0)

        let body = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_box_append(ptr(body), stack)
        gtk_box_append(ptr(body), revealer)
        adw_toast_overlay_set_child(op(UnsafeMutableRawPointer(toasts)), body)
        return toasts
    }

    func wireControls() {
        controls.lens = { [weak self] in self?.mode ?? .watch }
        controls.canInhibit = { [weak self] in
            guard let self else { return false }
            return self.isLive && !self.isDestroyed && self.watchView.isVisible
        }
        controls.noted = { [weak self] in self?.watchView.userTouched() }
        controls.hidePointer = { [weak self] hidden in self?.watchView.setPointerHidden(hidden) }
    }

    func wireWatch() {
        watchView.peekRequest = { [weak self] key in
            Gtk.onMain { [weak self] in self?.select(key: key) }
        }
        watchView.peekLayer.onDismiss = { [weak self] in self?.deselect() }
        watchView.onPeekExpired = { [weak self] in self?.deselect() }
        watchView.onHourWanted = { [weak self] in self?.fetchHour() }
    }

    func watchVisibility() {
        let box = Unmanaged.passRetained(Gtk.Box({ [weak self] in
            Gtk.onMain { [weak self] in self?.visibilityChanged() }
        })).toOpaque()
        tailscode_window_watch_visibility(
            window,
            { _, raw in
                guard let raw else { return }
                Unmanaged<Gtk.Box>.fromOpaque(raw).takeUnretainedValue().work()
            }, box)
    }

    func visibilityChanged() {
        guard !isDestroyed else { return }
        watchView.setVisible(tailscode_window_is_visible(window) != 0)
        controls.syncInhibit()
    }

    func inputSeen() {
        controls.noteInput()
        watchView.peekLayer.touch()
    }

    func show(_ next: Mode) {
        if next != mode {
            deselect()
            mode = next
        }
        applyLens()
        if next != .now { fetchHour() }
    }

    func lensButton(_ lens: Mode) -> UnsafeMutablePointer<GtkWidget> {
        switch lens {
        case .watch: return watchButton
        case .now: return nowButton
        case .hour: return hourButton
        }
    }

    func applyLens() {
        let name: String
        switch mode {
        case .watch: name = "watch"
        case .now: name = "now"
        case .hour: name = "hour"
        }
        gtk_stack_set_visible_child_name(op(stack), name)
        gtk_toggle_button_set_active(ptr(lensButton(mode)), 1)
        let wall = mode == .watch
        gtk_widget_set_visible(styleButton, wall ? 1 : 0)
        gtk_widget_set_visible(revealer, !wall && selectedKey != nil ? 1 : 0)
        AgentsParts.setClass(window, "agents-wall-window", wall)
        if let header { AgentsParts.setClass(header, "agents-wall-bar", wall) }
        if wall { WatchStyle.install(watchView.context.palette) }
        controls?.applyChrome()
    }

    /// The size the person left the window at, remembered once they have changed it: a window
    /// that was only opened keeps following the window it comes from.
    func rememberSize() {
        guard !isDestroyed, controls != nil, !controls.isFullscreen else { return }
        guard gtk_window_is_maximized(ptr(window)) == 0 else { return }
        let width = gtk_widget_get_width(window)
        let height = gtk_widget_get_height(window)
        guard abs(width - openedSize.width) > 2 || abs(height - openedSize.height) > 2 else { return }
        Preferences.setAgentsWindowSize(width: width, height: height)
    }

    var windowSize: (width: Int32, height: Int32) {
        (gtk_widget_get_width(window), gtk_widget_get_height(window))
    }
}
