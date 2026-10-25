import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What a person does to the wall: fullscreen, keeping the screen awake, dimming it by hand, and
/// the header and pointer that go away after three idle seconds in fullscreen and come back with
/// the first movement. The keys are the window's own and work in this window only.
final class WatchControls: @unchecked Sendable {
    static let idleAfter: TimeInterval = 3

    let window: UnsafeMutablePointer<GtkWidget>
    let toolbar: OpaquePointer
    let fullscreenButton: UnsafeMutablePointer<GtkWidget>
    let awakeButton: UnsafeMutablePointer<GtkWidget>
    var inhibitor: WatchInhibiting = GtkInhibitor()
    let clock: WatchClock
    private(set) var isFullscreen = false
    private(set) var keepAwakeOverride: Bool?
    private(set) var cookie: UInt32 = 0
    private(set) var acquired = 0
    private(set) var released = 0
    private(set) var chromeShown = true
    private(set) var pointerHidden = false
    private var lastMotion: Date
    private var syncing = false
    private var closed = false
    var lens: () -> AgentsWindow.Mode = { .watch }
    var hidePointer: (Bool) -> Void = { _ in }
    var canInhibit: () -> Bool = { true }
    var noted: () -> Void = {}

    init(window: UnsafeMutablePointer<GtkWidget>, toolbar: OpaquePointer, clock: WatchClock) {
        self.window = window
        self.toolbar = toolbar
        self.clock = clock
        lastMotion = clock.now
        fullscreenButton = gtk_toggle_button_new()!
        awakeButton = gtk_toggle_button_new()!
        configure(fullscreenButton, icon: "view-fullscreen-symbolic", words: Localized.text("Fullscreen"))
        configure(awakeButton, icon: "display-brightness-symbolic", words: Localized.text("Keep the screen awake"))
        Gtk.connect(UnsafeMutableRawPointer(fullscreenButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.closed else { return }
                let on = gtk_toggle_button_get_active(ptr(self.fullscreenButton)) != 0
                if on != self.isFullscreen { self.setFullscreen(on) }
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(awakeButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.closed, !self.syncing else { return }
                let on = gtk_toggle_button_get_active(ptr(self.awakeButton)) != 0
                if on != self.keepAwake { self.setKeepAwake(on) }
            }
        }
        Gtk.onNotify(UnsafeMutableRawPointer(window), property: "fullscreened") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.closed else { return }
                let actual = gtk_window_is_fullscreen(ptr(self.window)) != 0
                if actual != self.isFullscreen { self.setFullscreen(actual, ask: false) }
            }
        }
    }

    private func configure(_ button: UnsafeMutablePointer<GtkWidget>, icon: String, words: String) {
        gtk_button_set_icon_name(ptr(button), icon)
        gtk_widget_set_tooltip_text(button, words)
        tailscode_set_accessible_label(button, words)
        gtk_widget_set_focus_on_click(button, 0)
    }

    var keepAwake: Bool { keepAwakeOverride ?? isFullscreen }

    func setFullscreen(_ on: Bool, ask: Bool = true) {
        guard on != isFullscreen else { return }
        isFullscreen = on
        keepAwakeOverride = nil
        if ask {
            if on { gtk_window_fullscreen(ptr(window)) } else { gtk_window_unfullscreen(ptr(window)) }
        }
        syncing = true
        gtk_toggle_button_set_active(ptr(fullscreenButton), on ? 1 : 0)
        gtk_toggle_button_set_active(ptr(awakeButton), keepAwake ? 1 : 0)
        syncing = false
        lastMotion = clock.now
        applyChrome()
        syncInhibit()
    }

    func toggleFullscreen() { setFullscreen(!isFullscreen) }

    func setKeepAwake(_ on: Bool) {
        keepAwakeOverride = on
        syncing = true
        gtk_toggle_button_set_active(ptr(awakeButton), on ? 1 : 0)
        syncing = false
        syncInhibit()
    }

    func toggleKeepAwake() { setKeepAwake(!keepAwake) }

    /// The idle inhibit is held while the wall wants the screen awake and is on screen, and let
    /// go the moment it does not: leaving fullscreen, minimising, closing.
    func syncInhibit() {
        let wanted = keepAwake && canInhibit()
        if wanted, cookie == 0 {
            cookie = inhibitor.acquire(reason: Localized.text("The agents wall is on screen"))
            acquired += 1
        } else if !wanted, acquired > released {
            inhibitor.release(cookie)
            cookie = 0
            released += 1
        }
    }

    var isInhibiting: Bool { acquired > released }

    func releaseAll() {
        closed = true
        keepAwakeOverride = false
        canInhibit = { false }
        syncInhibit()
    }

    func noteInput() {
        lastMotion = clock.now
        noted()
        if !chromeShown || pointerHidden { applyChrome() }
    }

    func evaluateIdle(now: Date) {
        applyChrome(now: now)
    }

    var wantsQuietChrome: Bool { isFullscreen && lens() == .watch }

    func applyChrome(now: Date? = nil) {
        let at = now ?? clock.now
        let quiet = wantsQuietChrome
        let idle = quiet && at.timeIntervalSince(lastMotion) >= Self.idleAfter
        adw_toolbar_view_set_extend_content_to_top_edge(toolbar, quiet ? 1 : 0)
        adw_toolbar_view_set_reveal_top_bars(toolbar, idle ? 0 : 1)
        chromeShown = !idle
        if idle != pointerHidden {
            pointerHidden = idle
            hidePointer(idle)
        }
    }

    func handle(keyval: UInt32, state: UInt32, watch: AgentsWatchView) -> Bool {
        let mods = state & (KeyChord.controlMask | KeyChord.altMask)
        noteInput()
        if keyval == Keymap.functionKey(11), mods == 0 {
            toggleFullscreen()
            return true
        }
        guard lens() == .watch, mods == 0, !Gtk.focusTakesText(window) else { return false }
        if let digit = Keymap.digit(keyval), (1...AgentWall.maxTiles).contains(digit) {
            let keys = watch.orderedKeys
            if keys.indices.contains(digit - 1) { watch.context.openPeek(keys[digit - 1]) }
            return true
        }
        switch keyval {
        case Keymap.tab: watch.moveFocus(1)
        case Keymap.shiftTab: watch.moveFocus(-1)
        case Keymap.enter, Keymap.keypadEnter:
            guard let key = watch.focusedKey ?? watch.orderedKeys.first else { return true }
            watch.context.openPeek(key)
        case 0x64, 0x44: watch.toggleDim()
        case 0x6B, 0x4B: toggleKeepAwake()
        default: return false
        }
        return true
    }
}
