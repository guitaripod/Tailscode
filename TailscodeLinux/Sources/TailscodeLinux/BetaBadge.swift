import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The mark a feature wears while it is in beta, on GTK: a capsule beside the feature's title.
/// Resting the pointer on it is enough to read why, because the card stays while the pointer is on
/// the capsule or the card and leaves when it is on neither, and a click or Enter does the same for
/// a touchpad or a screen reader. Every word is the catalog's.
///
/// A mark nobody has opened, or whose card has something newer than the version it was last opened
/// at, is announced once by a single pass of light across the capsule and then holds perfectly
/// still. The pass is drawn from the widget's own frame clock as absolute time, at most once per
/// process per feature, and the clock comes off the moment the pass ends.
final class BetaBadge: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    private let feature: BetaFeature
    private let reportLines: @Sendable () -> [String]
    private let capsule: UnsafeMutablePointer<GtkWidget>
    private let sheen = tailscode_sheen_new()!
    private let popover: UnsafeMutablePointer<GtkWidget>
    private var card: BetaCardView?
    private var generation = 0
    private var pointerOnCard = false
    private var passStart = 0.0
    private lazy var lap = RepeatingMotion(holding: false) { [weak self] in self?.step() }

    nonisolated(unsafe) private static var announced: Set<BetaFeature> = []

    init(feature: BetaFeature, reportLines: @escaping @Sendable () -> [String]) {
        self.feature = feature
        self.reportLines = reportLines
        capsule = tailscode_box_new_with_role(GTK_ORIENTATION_HORIZONTAL, 0, GTK_ACCESSIBLE_ROLE_BUTTON)!
        Gtk.addClass(capsule, "beta-badge")
        gtk_widget_set_valign(capsule, GTK_ALIGN_CENTER)
        gtk_widget_set_cursor_from_name(capsule, "pointer")
        gtk_widget_set_focusable(capsule, 1)
        gtk_widget_set_hexpand(capsule, 0)
        tailscode_set_accessible_label(capsule, feature.card.spoken)
        let label = Gtk.label(BetaWords.badge, selectable: false)
        gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(capsule), label)

        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(op(overlay), capsule)
        gtk_overlay_add_overlay(op(overlay), sheen)
        gtk_widget_set_valign(overlay, GTK_ALIGN_CENTER)
        widget = overlay

        popover = gtk_popover_new()!
        gtk_widget_set_parent(popover, capsule)
        gtk_popover_set_autohide(ptr(popover), 0)
        gtk_popover_set_position(ptr(popover), GTK_POS_BOTTOM)

        watchPointer(on: capsule) { [weak self] inside in
            if inside { self?.show(focusing: false) } else { self?.scheduleHide() }
        }
        Gtk.onRelease(capsule) { [weak self] in
            Gtk.onMain { [weak self] in self?.show(focusing: true) }
        }
        Gtk.onKey(capsule) { [weak self] keyval, _ in
            guard keyval == Keymap.enter || keyval == Keymap.keypadEnter || keyval == 0x20 else {
                return false
            }
            Gtk.onMain { [weak self] in self?.show(focusing: true) }
            return true
        }
        Gtk.onKey(popover) { [weak self] keyval, _ in
            guard keyval == Keymap.escape else { return false }
            Gtk.onMain { [weak self] in self?.hide() }
            return true
        }
        Gtk.connect(UnsafeMutableRawPointer(capsule), "map") { [weak self] in
            Gtk.onMain { [weak self] in self?.announceIfFresh() }
        }
        RepeatingMotion.watch(sheen) { [weak self] in
            Gtk.onMain { [weak self] in self?.motionPreferenceChanged() }
        }
    }

    /// Calls `changed` on the main loop whenever the pointer comes onto or leaves `widget` or
    /// anything inside it. The property is read rather than the enter and leave signals, which a
    /// crossing between a surface and a popup answers with a leave straight after the enter.
    private func watchPointer(
        on widget: UnsafeMutablePointer<GtkWidget>, _ changed: @escaping @Sendable (Bool) -> Void
    ) {
        let motion = gtk_event_controller_motion_new()!
        gtk_widget_add_controller(widget, motion)
        let address = Int(bitPattern: UnsafeMutableRawPointer(motion))
        Gtk.onNotify(UnsafeMutableRawPointer(motion), property: "contains-pointer") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
            let inside = gtk_event_controller_motion_contains_pointer(op(raw)) != 0
            Gtk.onMain { changed(inside) }
        }
    }

    private var isShown: Bool { gtk_widget_get_visible(popover) != 0 }

    /// This app, as the seen-store compares it: the version its install reads, which is what the
    /// update surface calls current too.
    static let appVersion: SoftwareVersion =
        LinuxAppInstall.read().version.flatMap(SoftwareVersion.init)
        ?? SoftwareVersion(TailscodeVersion.current) ?? SoftwareVersion("0")!

    static func freshness(of feature: BetaFeature) -> BetaFreshness {
        BetaSeenStore.freshness(feature, current: appVersion)
    }

    /// Whether a mark is announced by light: only a fresh one, only the first time this process
    /// draws it, and never where the desk asked for less motion.
    static func announces(_ freshness: BetaFreshness, already: Bool, reducedMotion: Bool) -> Bool {
        freshness.isFresh && !already && !reducedMotion
    }

    private func show(focusing: Bool) {
        generation += 1
        guard !isShown else {
            if focusing, let card { gtk_widget_grab_focus(card.gotIt) }
            return
        }
        let freshness = Self.freshness(of: feature)
        let view = BetaCardView(
            card: feature.card, freshness: freshness,
            onCopy: { [weak self] in Gtk.onMain { [weak self] in self?.copyReport() } },
            onClose: { [weak self] in Gtk.onMain { [weak self] in self?.hide() } })
        card = view
        gtk_popover_set_child(ptr(popover), view.widget)
        watchPointer(on: view.widget) { [weak self] inside in
            self?.pointerOnCard = inside
            if !inside { self?.scheduleHide() }
        }
        gtk_popover_popup(ptr(popover))
        if focusing { gtk_widget_grab_focus(view.gotIt) }
        markSeen()
    }

    private func markSeen() {
        BetaSeenStore.markSeen(feature, at: Self.appVersion)
        SettingsFile.capture()
        endPass()
    }

    /// The block Copy report puts on the pasteboard.
    func report() -> String {
        BetaReport.compose(
            feature: feature, app: "Tailscode \(Self.appVersion.raw)", system: BetaSystem.line,
            lines: reportLines())
    }

    private func copyReport() {
        Gtk.copyToClipboard(report())
        card?.markCopied()
    }

    /// The pointer crossing from the capsule to the card is a leave and an enter a few pixels
    /// apart, so a leave only hides the card once it has gone unanswered for a moment.
    private func scheduleHide() {
        generation += 1
        let mine = generation
        Gtk.after(250) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.generation == mine, !self.pointerOnCard else { return }
                self.hide()
            }
        }
    }

    private func hide() {
        generation += 1
        pointerOnCard = false
        guard isShown else { return }
        gtk_popover_popdown(ptr(popover))
    }

    private func announceIfFresh() {
        guard
            Self.announces(
                Self.freshness(of: feature), already: Self.announced.contains(feature),
                reducedMotion: !RepeatingMotion.allowed)
        else { return }
        Self.announced.insert(feature)
        passStart = Self.now
        guard lap.lay(on: sheen, meaning: .working) else { return }
        step()
    }

    private static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    private func step() {
        guard
            let progress = BetaSheen.progress(
                elapsed: Self.now - passStart, reducedMotion: !RepeatingMotion.allowed)
        else {
            endPass()
            return
        }
        paint(progress)
    }

    private func endPass() {
        guard lap.isTurning || lastPainted >= 0 else { return }
        lap.lift()
        paint(-1)
    }

    private var lastPainted = -1.0

    private func paint(_ progress: Double) {
        lastPainted = progress
        let ink = PresenceRGB(hex: MatrixTheme.palette.special) ?? PresenceRGB(red: 0.5, green: 0.4, blue: 0.8)
        let rgb = [ink.red, ink.green, ink.blue]
        rgb.withUnsafeBufferPointer { tailscode_sheen_set(sheen, progress, $0.baseAddress, 0.4) }
    }

    /// The desk changed its mind about movement mid-pass: a light that is still crossing stops where
    /// it is rather than finishing a motion nobody wants.
    private func motionPreferenceChanged() {
        guard lap.isTurning, !RepeatingMotion.allowed else { return }
        endPass()
    }

    /// The popover is parented on the capsule rather than owned by the window, so a window that is
    /// destroyed hands it back itself.
    func tearDown() {
        lap.lift()
        hide()
        gtk_widget_unparent(popover)
    }

    /// What the mark is doing, for a harness that has to prove a claim about it: whether the light
    /// is crossing, whether this process has already announced the feature and whether the card is
    /// open.
    var reading: (sheenTurning: Bool, announced: Bool, cardOpen: Bool) {
        (lap.isTurning, Self.announced.contains(feature), isShown)
    }

    var cardText: String? { card?.text }

    var line: String {
        let state = reading
        return "\(feature.rawValue) freshness=\(Self.freshness(of: feature)) sheenTurning=\(state.sheenTurning)"
            + " announced=\(state.announced) card=\(state.cardOpen ? "open" : "shut")"
    }

    /// Opens the card as a click would, for the driver and the harness.
    func open() { show(focusing: false) }

    func close() { hide() }

    static func forgetAnnouncement(of feature: BetaFeature) {
        announced.remove(feature)
    }
}

/// The system line a beta report carries: the distribution and the toolkit this desk draws with,
/// which are the two facts a bug on Linux most often turns on.
enum BetaSystem {
    static var line: String {
        let toolkit = "gtk \(gtk_get_major_version()).\(gtk_get_minor_version())"
        return "\(distribution) · \(toolkit) · \(session)"
    }

    private static var distribution: String {
        guard let text = try? String(contentsOfFile: "/etc/os-release", encoding: .utf8) else { return "Linux" }
        for line in text.split(separator: "\n") where line.hasPrefix("PRETTY_NAME=") {
            let value = line.dropFirst("PRETTY_NAME=".count)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return "Linux"
    }

    private static var session: String {
        ProcessInfo.processInfo.environment["XDG_SESSION_TYPE"] ?? "unknown session"
    }
}
