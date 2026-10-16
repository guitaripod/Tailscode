import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What of a board redraws the lanes rather than only moves the line: the places, their days, what
/// is marked on them, who is awake together, the machines and the alarms. While the person drags
/// the line none of it changes, so a drag repaints the numbers and the lines and builds nothing.
struct MeridianStructure: Equatable {
    struct LaneShape: Equatable {
        let id: String
        let name: String
        let subtitle: String
        let removable: Bool
        let bar: DaylightBar
        let marks: [MeridianBoard.Mark]
    }

    let lanes: [LaneShape]
    let ticks: [MeridianBoard.Tick]
    let golden: MeridianBoard.Golden?
    let insight: String?
    let machines: [MachineClockReading]
    let skewWarning: String?
    let alarms: [MeridianBoard.AlarmRow]
    let style: ClockStyle
    let dayStart: Date
    let minutes: Int

    init(_ board: MeridianBoard) {
        lanes = board.lanes.map {
            LaneShape(
                id: $0.id, name: $0.name, subtitle: $0.subtitle, removable: $0.isRemovable,
                bar: $0.bar, marks: $0.marks)
        }
        ticks = board.ticks
        golden = board.golden
        insight = board.insight
        machines = board.machines
        skewWarning = board.skewWarning
        alarms = board.alarms
        style = board.style
        dayStart = board.axis.start
        minutes = board.minutes
    }
}

private func widgetFrom(_ bits: UInt) -> UnsafeMutablePointer<GtkWidget>? {
    UnsafeMutableRawPointer(bitPattern: bits).map { ptr($0) }
}

private final class MeridianCallback: @unchecked Sendable {
    let work: (Int32, Double) -> Void
    init(_ work: @escaping (Int32, Double) -> Void) { self.work = work }
}

/// Meridian: the sheet behind the clock chip. One day laid out as a line, a lane for every place the
/// person watches, a moment they can move along it with every desk reading that moment, what to
/// copy and what to be told about. Core's `MeridianBoard` decides every number and word; this
/// draws the lanes and the line, and decides only how the pointer and the keys move it.
///
/// It is a window of its own, single instance and not modal: the clock is something to glance at
/// beside the work, and a modal sheet would hold the conversation hostage to a time zone.
final class MeridianSheet: @unchecked Sendable {
    nonisolated(unsafe) static var current: MeridianSheet?

    static let labelWidth: Int32 = 264
    static let gap: Int32 = 18
    private static let glideSeconds = 0.18

    private let window: UnsafeMutablePointer<GtkWidget>
    private let body = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let headTime = Gtk.label("", css: "clock-head", selectable: false)
    private let delta = Gtk.label("", css: "clock-delta", selectable: false)
    private let dateLine = Gtk.label("", css: "clock-dim", selectable: false)
    private let ticks = tailscode_ticks_new()!
    private let lanesBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
    private let lines = tailscode_lines_new()!
    private let scrubber: UnsafeMutablePointer<GtkWidget>
    private let searchEntry = gtk_entry_new()!
    private let results = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
    private let insightBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
    private let machinesBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
    private let alarmsBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private let notify: UnsafeMutablePointer<GtkWidget>
    private let styleMenu: UnsafeMutablePointer<GtkWidget>
    private var copyButtons: [(title: UnsafeMutablePointer<GtkWidget>, value: UnsafeMutablePointer<GtkWidget>, kind: CopyKind)] = []
    private var copyTickets: [CopyKind: Int] = [:]
    private var notifyTicket = 0

    private var laneRefs: [LaneRefs] = []
    private var structure: MeridianStructure?
    private var scrubMinute: Int?
    private var board: MeridianBoard
    private var token = 0
    private var scrubberCallback: Unmanaged<MeridianCallback>?
    private var markCallbacks: [Unmanaged<MeridianCallback>] = []
    private lazy var glide = RepeatingMotion(holding: false) { [weak self] in self?.glideStep() }
    private var glideOrigin = 0.0
    private var glideTarget = 0.0
    private var glideStart = 0.0
    private var glideFollows = false

    private enum CopyKind: Int {
        case iso
        case utc
        case epoch
    }

    private struct LaneRefs {
        let id: String
        let time: UnsafeMutablePointer<GtkWidget>
        let day: UnsafeMutablePointer<GtkWidget>
        let glyph: UnsafeMutablePointer<GtkWidget>
    }

    static func present(parent: UnsafeMutablePointer<GtkWidget>?) {
        if let current {
            gtk_window_present(ptr(current.window))
            return
        }
        current = MeridianSheet(parent: parent)
    }

    static func close() {
        guard let current else { return }
        gtk_window_destroy(ptr(current.window))
    }

    private init(parent: UnsafeMutablePointer<GtkWidget>?) {
        board = ClockWatch.shared.board(scrubMinute: nil)
        scrubber = tailscode_scrubber_new(nil, nil)
        notify = Gtk.button("", css: ["suggested-action", "clock-notify"]) {}
        styleMenu = gtk_menu_button_new()!
        window = gtk_window_new()!
        gtk_window_set_title(ptr(window), Localized.text("Meridian"))
        let size = FeatureWindow.size(near: parent, minimumWidth: 760, minimumHeight: 520)
        gtk_window_set_default_size(ptr(window), min(1040, size.width), min(700, size.height))
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }
        Gtk.addClass(window, "meridian-sheet")
        gtk_window_set_child(ptr(window), makeContent())
        installBehaviour()
        refresh(force: true)
        token = ClockWatch.shared.observe { [weak self] in
            Gtk.onMain { [weak self] in self?.refresh(force: false) }
        }
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(scrubber)
    }

    private func makeContent() -> UnsafeMutablePointer<GtkWidget> {
        let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.margins(body, top: 26, bottom: 8, leading: 32, trailing: 32)
        gtk_box_append(ptr(body), makeHeader())
        gtk_box_append(ptr(body), makeLanes())
        gtk_box_append(ptr(body), makeScrubberRow())
        gtk_box_append(ptr(body), makeAddCity())
        gtk_widget_set_margin_top(insightBox, 14)
        Gtk.addClass(insightBox, "clock-insight")
        gtk_box_append(ptr(body), insightBox)
        gtk_widget_set_margin_top(machinesBox, 12)
        gtk_box_append(ptr(body), machinesBox)
        gtk_widget_set_margin_top(alarmsBox, 12)
        gtk_box_append(ptr(body), alarmsBox)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(scroller), body)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_box_append(ptr(root), scroller)
        gtk_box_append(ptr(root), makeFooter())
        return root
    }

    private func makeHeader() -> UnsafeMutablePointer<GtkWidget> {
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 22)
        let left = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_widget_set_hexpand(left, 1)
        let title = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_box_append(ptr(title), ClockUI.glyph(TAILSCODE_GLYPH_GLOBE, size: 26, body: MatrixTheme.palette.accent))
        gtk_box_append(ptr(title), ClockUI.label(Localized.text("Meridian"), "clock-title"))
        gtk_box_append(ptr(left), title)
        gtk_box_append(ptr(left), dateLine)
        gtk_box_append(ptr(header), left)

        let right = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_widget_set_halign(right, GTK_ALIGN_END)
        gtk_label_set_xalign(op(headTime), 1)
        gtk_label_set_xalign(op(delta), 1)
        gtk_widget_set_halign(headTime, GTK_ALIGN_END)
        gtk_widget_set_halign(delta, GTK_ALIGN_END)
        gtk_label_set_ellipsize(op(headTime), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(right), headTime)
        gtk_box_append(ptr(right), delta)
        gtk_box_append(ptr(header), right)

        let now = Gtk.button(Localized.text("Now"), css: ["clock-now"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.followClock() }
        }
        gtk_widget_set_valign(now, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(header), now)
        return header
    }

    private func makeLanes() -> UnsafeMutablePointer<GtkWidget> {
        let section = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        gtk_widget_set_margin_top(section, 26)
        let tickRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Self.gap)
        gtk_box_append(ptr(tickRow), column(width: Self.labelWidth))
        gtk_box_append(ptr(tickRow), ticks)
        gtk_box_append(ptr(section), tickRow)

        MeridianInk.apply(to: lines)
        MeridianInk.apply(to: ticks)
        MeridianInk.apply(to: scrubber)
        Gtk.addClass(ticks, "clock-ticks")
        Gtk.addClass(lines, "clock-lines")
        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(op(overlay), lanesBox)
        gtk_widget_set_margin_start(lines, Self.labelWidth + Self.gap)
        gtk_overlay_add_overlay(op(overlay), lines)
        gtk_box_append(ptr(section), overlay)
        return section
    }

    private func column(width: Int32) -> UnsafeMutablePointer<GtkWidget> {
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_size_request(spacer, width, -1)
        return spacer
    }

    private func makeScrubberRow() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Self.gap)
        gtk_widget_set_margin_top(row, 10)
        let hint = ClockUI.label(Localized.text("Drag to read every desk at that moment"), "clock-dim", wrap: true)
        gtk_widget_set_size_request(hint, Self.labelWidth, -1)
        gtk_label_set_max_width_chars(op(hint), 28)
        gtk_widget_set_valign(hint, GTK_ALIGN_CENTER)
        Gtk.addClass(scrubber, "clock-scrubber")
        gtk_widget_set_valign(scrubber, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(scrubber, Localized.text("Scrub time"))
        gtk_box_append(ptr(row), hint)
        gtk_box_append(ptr(row), scrubber)
        return row
    }

    private func makeAddCity() -> UnsafeMutablePointer<GtkWidget> {
        let section = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        gtk_widget_set_margin_top(section, 14)
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Self.gap)
        let label = ClockUI.label(Localized.text("Add city"), "clock-section")
        gtk_widget_set_size_request(label, Self.labelWidth, -1)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        gtk_entry_set_placeholder_text(ptr(searchEntry), Localized.text("Search a city or country"))
        gtk_widget_set_hexpand(searchEntry, 1)
        Gtk.addClass(searchEntry, "clock-search")
        tailscode_set_accessible_label(searchEntry, Localized.text("Add city"))
        gtk_box_append(ptr(row), label)
        gtk_box_append(ptr(row), searchEntry)
        gtk_box_append(ptr(section), row)
        let indented = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Self.gap)
        gtk_box_append(ptr(indented), column(width: Self.labelWidth))
        gtk_widget_set_hexpand(results, 1)
        gtk_box_append(ptr(indented), results)
        gtk_box_append(ptr(section), indented)
        Gtk.onNotify(UnsafeMutableRawPointer(searchEntry), property: "text") { [weak self] in
            Gtk.onMain { [weak self] in self?.searchChanged() }
        }
        Gtk.connect(UnsafeMutableRawPointer(searchEntry), "activate") { [weak self] in
            Gtk.onMain { [weak self] in self?.pinFirstResult() }
        }
        return section
    }

    private func makeFooter() -> UnsafeMutablePointer<GtkWidget> {
        let footer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(footer, "clock-footer-bar")
        Gtk.margins(footer, top: 10, bottom: 18, leading: 32, trailing: 32)
        for kind in [CopyKind.iso, .utc, .epoch] { appendCopy(kind, to: footer) }
        configureStyleMenu()
        gtk_box_append(ptr(footer), styleMenu)
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(footer), spacer)
        gtk_box_append(ptr(footer), ClockUI.label(Localized.text("Esc closes"), "clock-dim"))
        gtk_box_append(ptr(footer), notify)
        Gtk.connect(UnsafeMutableRawPointer(notify), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.addAlarm(at: nil, note: nil) }
        }
        return footer
    }

    private func configureStyleMenu() {
        gtk_menu_button_set_label(op(styleMenu), board.style.title)
        gtk_menu_button_set_can_shrink(op(styleMenu), 1)
        Gtk.addClass(styleMenu, "clock-style")
        gtk_widget_set_valign(styleMenu, GTK_ALIGN_CENTER)
        let popover = gtk_popover_new()!
        gtk_menu_button_set_popover(op(styleMenu), popover)
        let bits = UInt(bitPattern: popover)
        Gtk.connect(UnsafeMutableRawPointer(popover), "map") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
            let current = ClockWatch.shared.preferences.style
            for style in ClockStyle.allCases {
                let item = gtk_button_new()!
                Gtk.addClass(item, "flat")
                let mark = style == current ? "\u{2713} " : "    "
                gtk_button_set_child(
                    ptr(item), Gtk.label(mark + style.title, css: "row-title", selectable: false))
                Gtk.connect(UnsafeMutableRawPointer(item), "clicked") {
                    if let popover = widgetFrom(bits) { gtk_popover_popdown(ptr(UnsafeMutableRawPointer(popover))) }
                    ClockWatch.shared.updatePreferences { $0.style = style }
                }
                gtk_box_append(ptr(column), item)
            }
            gtk_popover_set_child(ptr(raw), column)
        }
    }

    private func appendCopy(_ kind: CopyKind, to footer: UnsafeMutablePointer<GtkWidget>) {
        let titles = [CopyKind.iso: "COPY ISO", .utc: "COPY UTC", .epoch: "COPY EPOCH"]
        let title = ClockUI.label(Localized.text(titles[kind] ?? ""), "clock-copy-title")
        let value = ClockUI.label("", "clock-copy-value")
        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_box_append(ptr(lines), title)
        gtk_box_append(ptr(lines), value)
        let button = gtk_button_new()!
        Gtk.addClass(button, "clock-copy")
        gtk_button_set_child(ptr(button), lines)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.copy(kind) }
        }
        copyButtons.append((title, value, kind))
        gtk_box_append(ptr(footer), button)
    }

    private func installBehaviour() {
        let retained = Unmanaged.passRetained(
            MeridianCallback { [weak self] kind, value in
                Gtk.onMain { [weak self] in self?.scrubbed(kind: kind, fraction: value) }
            })
        scrubberCallback = retained
        tailscode_scrubber_set_handler(
            scrubber,
            { raw, kind, value in
                guard let raw else { return }
                Unmanaged<MeridianCallback>.fromOpaque(raw).takeUnretainedValue().work(kind, value)
            }, retained.toOpaque())
        Gtk.onKey(scrubber) { [weak self] keyval, state in
            guard let self else { return false }
            let step = state & Keymap.shift != 0 ? 15 : 1
            switch keyval {
            case 0xFF51: Gtk.onMain { [weak self] in self?.nudge(-step) }
            case 0xFF53: Gtk.onMain { [weak self] in self?.nudge(step) }
            case 0xFF50: Gtk.onMain { [weak self] in self?.land(on: 0) }
            case 0xFF57: Gtk.onMain { [weak self] in self?.land(on: (self?.board.minutes ?? 1) - 1) }
            default: return false
            }
            return true
        }
        Gtk.onKey(window) { keyval, _ in
            guard keyval == Keymap.escape else { return false }
            Gtk.onMain { MeridianSheet.close() }
            return true
        }
        RepeatingMotion.watch(scrubber) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !RepeatingMotion.allowed, self.glide.isTurning else { return }
                self.finishGlide()
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [weak self] in
            self?.windowGone()
        }
    }

    private func windowGone() {
        glide.lift()
        ClockWatch.shared.stopObserving(token)
        scrubberCallback?.release()
        scrubberCallback = nil
        releaseMarkCallbacks()
        MeridianSheet.current = nil
    }

    private func releaseMarkCallbacks() {
        for callback in markCallbacks { callback.release() }
        markCallbacks = []
    }

    var summary: String {
        let lanes = board.lanes.map { "\($0.name)=\($0.time)" }.joined(separator: ",")
        return "head=\(board.head) delta=\(board.delta) following=\(scrubMinute == nil) lanes=\(board.lanes.count) [\(lanes)] alarms=\(board.alarms.count) golden=\(board.golden?.label ?? "-")"
    }

    func driveScrub(minute: Int) { land(on: minute) }

    func driveFollow() { followClock() }

    func driveNotify() { addAlarm(at: nil, note: nil) }

    func driveSearch(_ text: String) {
        gtk_editable_set_text(op(searchEntry), text)
    }

    func driveCopy(_ name: String) {
        switch name {
        case "iso": copy(.iso)
        case "utc": copy(.utc)
        default: copy(.epoch)
        }
    }

    private func scrubbed(kind: Int32, fraction: Double) {
        let minute = board.minute(atFraction: fraction)
        if kind == 0 {
            glideTo(minute)
        } else {
            land(on: minute)
        }
    }

    private func nudge(_ minutes: Int) {
        land(on: min(max(board.scrubMinute + minutes, 0), board.minutes - 1))
    }

    private func land(on minute: Int) {
        endGlide()
        scrubMinute = min(max(minute, 0), board.minutes - 1)
        refresh(force: false)
    }

    private func followClock() {
        glide(to: board.nowMinute, thenFollow: true)
    }

    private func glideTo(_ minute: Int) {
        glide(to: minute, thenFollow: false)
    }

    private func glide(to minute: Int, thenFollow: Bool) {
        endGlide()
        let target = min(max(minute, 0), board.minutes - 1)
        guard RepeatingMotion.allowed, target != board.scrubMinute else {
            scrubMinute = thenFollow ? nil : target
            refresh(force: false)
            return
        }
        glideOrigin = Double(board.scrubMinute)
        glideTarget = Double(target)
        glideFollows = thenFollow
        glideStart = Double(g_get_monotonic_time()) / 1_000_000
        if !glide.lay(on: scrubber, meaning: .working) {
            scrubMinute = thenFollow ? nil : target
            refresh(force: false)
        }
    }

    private func glideStep() {
        let elapsed = Double(g_get_monotonic_time()) / 1_000_000 - glideStart
        let progress = min(1, elapsed / Self.glideSeconds)
        guard progress < 1 else {
            finishGlide()
            return
        }
        let eased = 1 - pow(1 - progress, 3)
        scrubMinute = Int((glideOrigin + (glideTarget - glideOrigin) * eased).rounded())
        refresh(force: false)
    }

    private func finishGlide() {
        glide.lift()
        scrubMinute = glideFollows ? nil : Int(glideTarget)
        refresh(force: false)
    }

    private func endGlide() {
        guard glide.isTurning else { return }
        glide.lift()
    }

    func refresh(force: Bool) {
        var fresh = ClockWatch.shared.board(scrubMinute: scrubMinute)
        if let last = structure, last.dayStart != fresh.axis.start {
            scrubMinute = nil
            fresh = ClockWatch.shared.board(scrubMinute: nil)
        }
        board = fresh
        let shape = MeridianStructure(board)
        if force || shape != structure || laneRefs.map(\.id) != board.lanes.map(\.id) {
            structure = shape
            rebuild()
        }
        paintMoment()
    }

    private func rebuild() {
        releaseMarkCallbacks()
        laneRefs = []
        Gtk.removeChildren(of: lanesBox)
        for lane in board.lanes { gtk_box_append(ptr(lanesBox), makeLane(lane)) }
        let positions = board.ticks.map(\.position)
        let labels = board.ticks.map(\.label)
        withCStrings(labels) { pointers in
            positions.withUnsafeBufferPointer {
                tailscode_ticks_set(ticks, Int32(positions.count), $0.baseAddress, pointers)
            }
        }
        MeridianInk.apply(to: ticks)
        MeridianInk.apply(to: lines)
        MeridianInk.apply(to: scrubber)
        renderInsight()
        renderMachines()
        renderAlarms()
        gtk_menu_button_set_label(op(styleMenu), board.style.title)
        renderSearch()
        let count = Double(board.lanes.count)
        gtk_widget_set_size_request(lanesBox, -1, Int32(count * 44 + max(0, count - 1) * 10))
    }

    private func makeLane(_ lane: MeridianBoard.Lane) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Self.gap)
        gtk_widget_set_size_request(row, -1, 44)

        let info = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_widget_set_hexpand(info, 1)
        let tile = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(tile, "clock-lane-tile")
        gtk_widget_set_size_request(tile, 30, 30)
        gtk_widget_set_valign(tile, GTK_ALIGN_CENTER)
        let glyph = tailscode_glyph_new(16)!
        tailscode_set_accessible_hidden(glyph, 1)
        gtk_box_append(ptr(tile), glyph)
        gtk_box_append(ptr(info), tile)

        let names = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(names, 1)
        gtk_widget_set_valign(names, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(names), ClockUI.label(lane.name, "clock-lane-name"))
        gtk_box_append(ptr(names), ClockUI.label(lane.subtitle, "clock-dim"))
        gtk_box_append(ptr(info), names)

        let when = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_valign(when, GTK_ALIGN_CENTER)
        let time = ClockUI.label(lane.time, "clock-lane-time")
        let day = ClockUI.label(lane.dayWord, "clock-dim")
        gtk_label_set_xalign(op(time), 1)
        gtk_label_set_xalign(op(day), 1)
        gtk_box_append(ptr(when), time)
        gtk_box_append(ptr(when), day)
        gtk_box_append(ptr(info), when)

        if lane.isRemovable {
            let id = lane.id
            let button = Gtk.button("\u{00D7}", css: ["flat", "clock-remove"]) {
                ClockWatch.shared.updatePreferences { $0.unpin(id) }
            }
            tailscode_set_accessible_label(button, String(format: Localized.text("Remove %@"), lane.name))
            gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
            gtk_widget_set_opacity(button, 0)
            gtk_box_append(ptr(info), button)
            let buttonBits = UInt(bitPattern: button)
            let rowBits = UInt(bitPattern: row)
            Gtk.onPointer(
                row,
                move: { _, _ in Gtk.onMain { widgetFrom(buttonBits).map { gtk_widget_set_opacity($0, 1) } } },
                leave: { Gtk.onMain { widgetFrom(buttonBits).map { gtk_widget_set_opacity($0, 0) } } })
            Gtk.onRightClick(row) { [weak self] x, y in
                Gtk.onMain { [weak self] in
                    guard let row = widgetFrom(rowBits) else { return }
                    self?.laneMenu(for: lane, row: row, x: x, y: y)
                }
            }
        }
        if !lane.isRemovable {
            let spacer = Gtk.button("\u{00D7}", css: ["flat", "clock-remove"]) {}
            gtk_widget_set_opacity(spacer, 0)
            gtk_widget_set_can_target(spacer, 0)
            gtk_widget_set_focusable(spacer, 0)
            tailscode_set_accessible_hidden(spacer, 1)
            gtk_box_append(ptr(info), spacer)
        }
        let frame = Gtk.shrinkable(info)
        gtk_widget_set_size_request(frame, Self.labelWidth, -1)
        gtk_widget_set_hexpand(frame, 0)
        gtk_box_append(ptr(row), frame)
        gtk_box_append(ptr(row), makeBar(lane))
        laneRefs.append(LaneRefs(id: lane.id, time: time, day: day, glyph: glyph))
        return row
    }

    private func makeBar(_ lane: MeridianBoard.Lane) -> UnsafeMutablePointer<GtkWidget> {
        let strip = tailscode_strip_new(40, 40, 13)!
        gtk_widget_set_valign(strip, GTK_ALIGN_CENTER)
        let hours = max(1, Int((Double(board.minutes) / 60).rounded()))
        MeridianInk.paint(strip: strip, bar: lane.bar, hairline: 0.06, grid: hours, noon: true)
        Gtk.addClass(strip, "clock-strip")
        tailscode_set_accessible_label(strip, lane.name)
        guard !lane.marks.isEmpty else { return strip }
        let kinds = lane.marks.map { $0.kind == .reset ? Int32(0) : Int32(1) }
        let positions = lane.marks.map(\.position)
        withCStrings(lane.marks.map(\.label)) { labels in
            kinds.withUnsafeBufferPointer { kindPointer in
                positions.withUnsafeBufferPointer { positionPointer in
                    tailscode_strip_set_marks(
                        strip, Int32(lane.marks.count), kindPointer.baseAddress,
                        positionPointer.baseAddress, labels)
                }
            }
        }
        let marks = lane.marks
        let callback = Unmanaged.passRetained(
            MeridianCallback { [weak self] _, value in
                Gtk.onMain { [weak self] in self?.markPressed(marks, index: Int(value)) }
            })
        markCallbacks.append(callback)
        tailscode_strip_set_handler(
            strip,
            { raw, kind, value in
                guard let raw else { return }
                Unmanaged<MeridianCallback>.fromOpaque(raw).takeUnretainedValue().work(kind, value)
            }, callback.toOpaque())
        return strip
    }

    private func markPressed(_ marks: [MeridianBoard.Mark], index: Int) {
        guard marks.indices.contains(index), marks[index].kind == .reset else { return }
        let mark = marks[index]
        let reset = ClockResets.upcoming(
            holdings: ClockWatch.shared.currentHoldings, now: ClockWatch.shared.now, limit: 4
        ).first { $0.instant == mark.instant }
        addAlarm(at: mark.instant, note: reset?.alarmNote)
    }

    private func laneMenu(
        for lane: MeridianBoard.Lane, row: UnsafeMutablePointer<GtkWidget>, x: Double, y: Double
    ) {
        var anchorX = 0.0
        var anchorY = 0.0
        guard gtk_widget_translate_coordinates(row, lanesBox, x, y, &anchorX, &anchorY) != 0 else { return }
        let id = lane.id
        Gtk.contextMenu(
            on: lanesBox, x: anchorX, y: anchorY,
            rows: [
                (Localized.text("Remove"), nil, { ClockWatch.shared.updatePreferences { $0.unpin(id) } }),
                (Localized.text("Move up"), nil, { ClockWatch.shared.updatePreferences { $0.move(id, by: -1) } }),
                (Localized.text("Move down"), nil, { ClockWatch.shared.updatePreferences { $0.move(id, by: 1) } }),
            ])
    }

    private func renderInsight() {
        Gtk.removeChildren(of: insightBox)
        guard let insight = board.insight else {
            gtk_widget_set_visible(insightBox, 0)
            return
        }
        gtk_widget_set_visible(insightBox, 1)
        gtk_box_append(ptr(insightBox), ClockUI.glyph(TAILSCODE_GLYPH_INFO, size: 15, body: MatrixTheme.palette.info))
        let label = ClockUI.label(insight, "clock-insight-text", wrap: true)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(insightBox), label)
    }

    private func renderMachines() {
        Gtk.removeChildren(of: machinesBox)
        guard !board.machines.isEmpty else {
            gtk_widget_set_visible(machinesBox, 0)
            return
        }
        gtk_widget_set_visible(machinesBox, 1)
        gtk_box_append(ptr(machinesBox), ClockUI.label(Localized.text("MACHINES"), "clock-section"))
        for machine in board.machines {
            let item = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
            gtk_box_append(ptr(item), ClockUI.dot(machine.tone))
            gtk_box_append(ptr(item), ClockUI.label(machine.name, "clock-name"))
            gtk_box_append(ptr(item), ClockUI.label(machine.status, "clock-status \(ClockUI.tone(machine.tone))"))
            gtk_box_append(ptr(machinesBox), item)
        }
        if let warning = board.skewWarning {
            let label = ClockUI.label(warning, "clock-status clock-warn")
            gtk_widget_set_hexpand(label, 1)
            gtk_label_set_xalign(op(label), 1)
            gtk_box_append(ptr(machinesBox), label)
        }
    }

    private func renderAlarms() {
        Gtk.removeChildren(of: alarmsBox)
        guard !board.alarms.isEmpty else {
            gtk_widget_set_visible(alarmsBox, 0)
            return
        }
        gtk_widget_set_visible(alarmsBox, 1)
        gtk_box_append(ptr(alarmsBox), ClockUI.label(Localized.text("ALARMS"), "clock-section"))
        var pills: [UnsafeMutablePointer<GtkWidget>] = []
        for alarm in board.alarms {
            let pill = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
            Gtk.addClass(pill, "clock-alarm")
            gtk_box_append(ptr(pill), ClockUI.label(alarm.title, "clock-stamp"))
            gtk_box_append(ptr(pill), ClockUI.label(alarm.detail, "clock-dim"))
            let id = alarm.id
            let remove = Gtk.button("\u{00D7}", css: ["flat", "clock-remove"]) {
                ClockAlarmStore.update { $0.remove(id) }
            }
            tailscode_set_accessible_label(remove, String(format: Localized.text("Remove %@"), alarm.title))
            gtk_box_append(ptr(pill), remove)
            pills.append(pill)
        }
        gtk_box_append(ptr(alarmsBox), Gtk.wrapRow(pills, spacing: 8))
    }

    private func searchChanged() {
        renderSearch()
    }

    private func searchQuery() -> String { Dialogs.entryText(searchEntry) }

    private func renderSearch() {
        Gtk.removeChildren(of: results)
        let full = ClockWatch.shared.preferences.pins.count >= WorldClockPreferences.maxPins
        gtk_widget_set_sensitive(searchEntry, full ? 0 : 1)
        gtk_entry_set_placeholder_text(
            ptr(searchEntry),
            full ? Localized.text("Remove a city to add another") : Localized.text("Search a city or country"))
        let query = searchQuery()
        guard !query.isEmpty, !full else { return }
        let matches = WorldCities.search(
            query, excluding: Set(ClockWatch.shared.preferences.pins), limit: 6)
        for city in matches {
            let id = city.id
            let item = gtk_button_new()!
            Gtk.addClass(item, "flat")
            Gtk.addClass(item, "clock-result")
            let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
            gtk_box_append(ptr(line), ClockUI.label(city.name, "clock-name"))
            gtk_box_append(ptr(line), ClockUI.label(city.country, "clock-dim"))
            gtk_button_set_child(ptr(item), line)
            Gtk.connect(UnsafeMutableRawPointer(item), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in self?.pin(id) }
            }
            gtk_box_append(ptr(results), item)
        }
    }

    private func pinFirstResult() {
        let query = searchQuery()
        guard !query.isEmpty else { return }
        let matches = WorldCities.search(
            query, excluding: Set(ClockWatch.shared.preferences.pins), limit: 6)
        if let first = matches.first { pin(first.id) }
    }

    private func pin(_ id: String) {
        gtk_editable_set_text(op(searchEntry), "")
        ClockWatch.shared.updatePreferences { $0.pin(id) }
        renderSearch()
    }

    private func paintMoment() {
        gtk_label_set_text(op(headTime), board.head)
        gtk_label_set_text(op(dateLine), board.dateLine)
        gtk_label_set_text(op(delta), board.delta)
        let atNow = board.scrubMinute == board.nowMinute
        Gtk.setTone(delta, atNow ? "clock-ok" : "clock-warn", from: ["clock-ok", "clock-warn"])
        for (ref, lane) in zip(laneRefs, board.lanes) {
            gtk_label_set_text(op(ref.time), lane.time)
            gtk_label_set_text(op(ref.day), lane.dayWord)
            switch lane.isUp {
            case true?:
                gtk_widget_set_visible(ref.glyph, 1)
                MeridianInk.glyph(ref.glyph, kind: TAILSCODE_GLYPH_SUN, body: MeridianInk.rgb(MatrixTheme.palette.warn))
            case false?:
                gtk_widget_set_visible(ref.glyph, 1)
                MeridianInk.glyph(ref.glyph, kind: TAILSCODE_GLYPH_MOON, body: MeridianInk.rgb(MeridianInk.pale))
            case nil:
                gtk_widget_set_visible(ref.glyph, 0)
            }
        }
        let golden = board.golden
        tailscode_lines_set(
            lines, golden?.start ?? -1, golden?.end ?? -1, golden?.label, board.nowPosition,
            board.linePosition)
        let thumb = board.minutes > 1 ? Double(board.scrubMinute) / Double(board.minutes - 1) : 0
        tailscode_scrubber_set(scrubber, thumb)
        for entry in copyButtons {
            let text: String
            switch entry.kind {
            case .iso: text = board.copy.iso
            case .utc: text = board.copy.utc
            case .epoch: text = board.copy.epoch
            }
            gtk_label_set_text(op(entry.value), text)
        }
        gtk_button_set_label(ptr(notify), board.notifyLabel)
        gtk_widget_set_sensitive(notify, board.canNotify ? 1 : 0)
    }

    private func copy(_ kind: CopyKind) {
        let text: String
        switch kind {
        case .iso: text = board.copy.iso
        case .utc: text = board.copy.utc
        case .epoch: text = board.copy.epoch
        }
        Gtk.copyToClipboard(text)
        guard let entry = copyButtons.first(where: { $0.kind == kind }) else { return }
        let titles = [CopyKind.iso: "COPY ISO", .utc: "COPY UTC", .epoch: "COPY EPOCH"]
        gtk_label_set_text(op(entry.title), Localized.text("Copied"))
        Gtk.addClass(entry.title, "clock-copied")
        let ticket = (copyTickets[kind] ?? 0) + 1
        copyTickets[kind] = ticket
        let title = entry.title
        let bits = UInt(bitPattern: title)
        Gtk.after(1200) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.copyTickets[kind] == ticket,
                    let raw = UnsafeMutableRawPointer(bitPattern: bits)
                else { return }
                gtk_label_set_text(op(raw), Localized.text(titles[kind] ?? ""))
                gtk_widget_remove_css_class(ptr(raw), "clock-copied")
            }
        }
    }

    private func addAlarm(at instant: Date?, note: String?) {
        let when = instant ?? board.scrubInstant
        let added = ClockAlarmStore.add(
            at: when, zoneID: TimeZone.current.identifier, note: note, now: ClockWatch.shared.now)
        guard added == nil else { return }
        notifyTicket += 1
        let ticket = notifyTicket
        gtk_button_set_label(ptr(notify), Localized.text("Already set"))
        let bits = UInt(bitPattern: notify)
        Gtk.after(1200) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.notifyTicket == ticket,
                    let raw = UnsafeMutableRawPointer(bitPattern: bits)
                else { return }
                        gtk_button_set_label(ptr(raw), self.board.notifyLabel)
            }
        }
    }

    private func withCStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> T) -> T {
        let duplicated = strings.map { strdup($0) }
        defer { duplicated.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = duplicated.map { $0.map { UnsafePointer($0) } }
        return pointers.withUnsafeMutableBufferPointer { body(UnsafePointer($0.baseAddress!)) }
    }
}
