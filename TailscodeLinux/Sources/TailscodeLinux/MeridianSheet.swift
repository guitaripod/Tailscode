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
    let fonts: String

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
        fonts = "\(Preferences.scale(.chrome))/\(Preferences.scale(.mono))/\(Preferences.scale(.prose))/\(MatrixTheme.palette.name)"
    }
}

private final class MeridianCallback: @unchecked Sendable {
    let work: (Int32, Double) -> Void
    init(_ work: @escaping (Int32, Double) -> Void) { self.work = work }
}

/// Whether a lane's controls are showing: while the pointer is over the lane or keyboard focus is
/// anywhere inside it, so they can be found by the mouse and reached by Tab.
private final class LaneReveal: @unchecked Sendable {
    let cluster: Gtk.WeakWidget
    var hover = false
    var focus = false

    init(cluster: UnsafeMutablePointer<GtkWidget>) { self.cluster = Gtk.WeakWidget(cluster) }

    func apply() {
        guard let widget = cluster.widget else { return }
        gtk_widget_set_opacity(widget, hover || focus ? 1 : 0)
    }
}

/// Meridian: the sheet behind the clock chip. One day laid out as a line, a lane for every place the
/// person watches, a moment they can move along it with every desk reading that moment, what to
/// copy and what to be told about. Core's `MeridianBoard` decides every number and word; this
/// draws the lanes and the line, and decides only how the pointer and the keys move it.
///
/// It is a window of its own, single instance and not modal. Nothing in it has a width chosen for
/// one type size: a column is as wide as the widest thing in it, the lane track is the one thing
/// that flexes, text wraps rather than being cut, and the window opens at the size its content
/// asks for at the type size in force, clamped to the screen.
final class MeridianSheet: @unchecked Sendable {
    nonisolated(unsafe) static var current: MeridianSheet?

    static let floorWidth: Int32 = 780
    static let floorHeight: Int32 = 560
    private static let glideSeconds = 0.18
    private static let longLine: Int32 = 96

    private enum Space {
        static let hair: Int32 = 4
        static let small: Int32 = 8
        static let medium: Int32 = 16
        static let large: Int32 = 24
        static let margin: Int32 = 32
    }

    private enum CopyKind: Int, CaseIterable {
        case iso
        case utc
        case epoch

        var title: String {
            switch self {
            case .iso: return "COPY ISO"
            case .utc: return "COPY UTC"
            case .epoch: return "COPY EPOCH"
            }
        }
    }

    private struct LaneRefs {
        let id: String
        let time: UnsafeMutablePointer<GtkWidget>
        let day: UnsafeMutablePointer<GtkWidget>
        let glyph: UnsafeMutablePointer<GtkWidget>
    }

    private struct Segment {
        let style: ClockStyle
        let button: UnsafeMutablePointer<GtkWidget>
        let example: UnsafeMutablePointer<GtkWidget>
    }

    private let window: UnsafeMutablePointer<GtkWidget>
    private let body = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let headTime = ClockUI.label("", "clock-head")
    private let delta = ClockUI.label("", "clock-delta")
    private let dateLine = ClockUI.label("", "clock-dim")
    private let ticks = tailscode_ticks_new()!
    private let lanesBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.small)
    private let lines = tailscode_lines_new()!
    private let scrubber: UnsafeMutablePointer<GtkWidget>
    private let labelColumn = gtk_size_group_new(GTK_SIZE_GROUP_HORIZONTAL)!
    private let controlsColumn = gtk_size_group_new(GTK_SIZE_GROUP_HORIZONTAL)!
    private let ghost = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.small)
    private let ghostHeader = gtk_button_new()!
    private let ghostInvitation = ClockUI.label("", "clock-name")
    private let ghostSummary = ClockUI.label("", "clock-dim")
    private let ghostPanel = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.small)
    private let searchEntry = gtk_entry_new()!
    private let results = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
    private let insightBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.small + 2)
    private let machinesRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium + 2)
    private let machinesBody = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.small)
    private let alarmsRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium + 2)
    private let alarmsBody = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.small)
    private let notify: UnsafeMutablePointer<GtkWidget>
    private var copyButtons: [(title: UnsafeMutablePointer<GtkWidget>, value: UnsafeMutablePointer<GtkWidget>, kind: CopyKind)] = []
    private var segments: [Segment] = []
    private var copyTickets: [CopyKind: Int] = [:]
    private var notifyTicket = 0

    private var laneRefs: [LaneRefs] = []
    private var structure: MeridianStructure?
    private var scrubMinute: Int?
    private var board: MeridianBoard
    private var token = 0
    private var scrubberCallback: Unmanaged<MeridianCallback>?
    private var markCallbacks: [Unmanaged<MeridianCallback>] = []
    private var laneReveals: [LaneReveal] = []
    private lazy var glide = RepeatingMotion(holding: false) { [weak self] in self?.glideStep() }
    private var glideOrigin = 0.0
    private var glideTarget = 0.0
    private var glideStart = 0.0
    private var glideFollows = false

    private var addOpen = false
    private var emptyDismissed = false
    private var highlighted = 0
    private var shownResults: [PlaceRow] = []
    private var placesMinute = -1

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
        window = gtk_window_new()!
        gtk_window_set_title(ptr(window), Localized.text("Meridian"))
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }
        Gtk.addClass(window, "meridian-sheet")
        addOpen = ClockWatch.shared.preferences.pins.isEmpty
        gtk_window_set_child(ptr(window), makeContent())
        installBehaviour()
        refresh(force: true)
        gtk_widget_realize(window)
        refresh(force: true)
        fitWindow(near: parent)
        token = ClockWatch.shared.observe { [weak self] in
            Gtk.onMain { [weak self] in self?.refresh(force: false) }
        }
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(scrubber)
    }

    private func fitWindow(near parent: UnsafeMutablePointer<GtkWidget>?) {
        let limit = FeatureWindow.size(near: parent, minimumWidth: Self.floorWidth, minimumHeight: Self.floorHeight)
        guard let content = gtk_window_get_child(ptr(window)) else { return }
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(content, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, nil, nil)
        let width = min(limit.width, max(Self.floorWidth, natural))
        var minimumHeight: Int32 = 0
        var naturalHeight: Int32 = 0
        gtk_widget_measure(content, GTK_ORIENTATION_VERTICAL, width, &minimumHeight, &naturalHeight, nil, nil)
        let height = min(limit.height, max(Self.floorHeight, naturalHeight))
        gtk_window_set_default_size(ptr(window), width, height)
    }

    private func makeContent() -> UnsafeMutablePointer<GtkWidget> {
        let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.margins(
            body, top: 0, bottom: Space.medium, leading: Space.margin, trailing: Space.margin)
        let header = makeHeader()
        Gtk.margins(
            header, top: Space.large, bottom: Space.small, leading: Space.margin, trailing: Space.margin)
        gtk_box_append(ptr(root), header)
        gtk_box_append(ptr(body), makeLanes())
        gtk_box_append(ptr(body), makeScrubberRow())
        gtk_box_append(ptr(body), makeAddPlace())
        gtk_widget_set_margin_top(insightBox, Space.medium)
        Gtk.addClass(insightBox, "clock-insight")
        gtk_box_append(ptr(body), insightBox)
        sectionRow(machinesRow, title: Localized.text("MACHINES"), body: machinesBody)
        gtk_widget_set_margin_top(machinesRow, Space.medium)
        gtk_box_append(ptr(body), machinesRow)
        sectionRow(alarmsRow, title: Localized.text("ALARMS"), body: alarmsBody)
        gtk_widget_set_margin_top(alarmsRow, Space.medium)
        gtk_box_append(ptr(body), alarmsRow)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_propagate_natural_width(op(scroller), 1)
        gtk_scrolled_window_set_min_content_height(op(scroller), 240)
        bodyScroller = scroller
        gtk_scrolled_window_set_child(op(scroller), body)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_box_append(ptr(root), scroller)
        gtk_box_append(ptr(root), makeFooter())
        return root
    }

    private func labelCell(_ widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget> {
        gtk_size_group_add_widget(labelColumn, widget)
        gtk_widget_set_hexpand(widget, 0)
        return widget
    }

    private func sectionRow(
        _ row: UnsafeMutablePointer<GtkWidget>, title: String, body content: UnsafeMutablePointer<GtkWidget>
    ) {
        let label = ClockUI.label(title, "clock-section")
        gtk_widget_set_valign(label, GTK_ALIGN_START)
        gtk_widget_set_margin_top(label, 3)
        gtk_box_append(ptr(row), labelCell(label))
        gtk_widget_set_hexpand(content, 1)
        gtk_box_append(ptr(row), content)
    }

    private func makeHeader() -> UnsafeMutablePointer<GtkWidget> {
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.large)
        let left = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.small)
        gtk_widget_set_hexpand(left, 1)
        gtk_widget_set_valign(left, GTK_ALIGN_START)
        let title = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.small + 4)
        gtk_box_append(ptr(title), ClockUI.glyph(TAILSCODE_GLYPH_GLOBE, size: 26, body: MatrixTheme.palette.accent))
        gtk_box_append(ptr(title), ClockUI.label(Localized.text("Meridian"), "clock-title"))
        gtk_box_append(ptr(left), title)
        gtk_label_set_wrap(op(dateLine), 1)
        gtk_box_append(ptr(left), dateLine)
        gtk_box_append(ptr(header), left)

        let right = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.hair)
        gtk_widget_set_halign(right, GTK_ALIGN_END)
        gtk_label_set_xalign(op(headTime), 1)
        gtk_label_set_xalign(op(delta), 1)
        gtk_widget_set_halign(headTime, GTK_ALIGN_END)
        gtk_widget_set_halign(delta, GTK_ALIGN_END)
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
        let section = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.small)
        gtk_widget_set_margin_top(section, Space.small)
        let tickRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium + 2)
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_box_append(ptr(tickRow), labelCell(spacer))
        gtk_widget_set_hexpand(ticks, 1)
        gtk_box_append(ptr(tickRow), ticks)
        gtk_box_append(ptr(section), tickRow)

        MeridianInk.apply(to: lines)
        MeridianInk.apply(to: ticks)
        MeridianInk.apply(to: scrubber)
        Gtk.addClass(ticks, "clock-ticks")
        Gtk.addClass(lines, "clock-lines")
        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(op(overlay), lanesBox)
        let lineHost = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium + 2)
        let lineSpacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_size_group_add_widget(labelColumn, lineSpacer)
        gtk_box_append(ptr(lineHost), lineSpacer)
        gtk_widget_set_hexpand(lines, 1)
        gtk_box_append(ptr(lineHost), lines)
        gtk_widget_set_can_target(lineHost, 0)
        gtk_overlay_add_overlay(op(overlay), lineHost)
        gtk_box_append(ptr(section), overlay)
        return section
    }

    private func makeScrubberRow() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium + 2)
        gtk_widget_set_margin_top(row, Space.small + 2)
        let hint = ClockUI.label(Localized.text("Drag to read every desk at that moment"), "clock-dim", wrap: true, chars: 26)
        gtk_widget_set_valign(hint, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(row), labelCell(hint))
        Gtk.addClass(scrubber, "clock-scrubber")
        gtk_widget_set_valign(scrubber, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(scrubber, 1)
        tailscode_set_accessible_label(scrubber, Localized.text("Scrub time"))
        gtk_box_append(ptr(row), scrubber)
        return row
    }

    private func makeAddPlace() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.addClass(ghost, "clock-ghost")
        gtk_widget_set_margin_top(ghost, Space.medium)

        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.small + 2)
        let tile = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(tile, "clock-lane-tile")
        gtk_widget_set_size_request(tile, 30, 30)
        gtk_widget_set_valign(tile, GTK_ALIGN_CENTER)
        let plus = ClockUI.label("+", "clock-plus")
        gtk_widget_set_halign(plus, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(plus, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(tile), plus)
        gtk_widget_set_hexpand(tile, 0)
        gtk_widget_set_halign(tile, GTK_ALIGN_START)
        tailscode_set_accessible_hidden(tile, 1)
        gtk_box_append(ptr(header), tile)
        gtk_widget_set_hexpand(ghostInvitation, 1)
        gtk_widget_set_valign(ghostInvitation, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(header), ghostInvitation)
        gtk_widget_set_valign(ghostSummary, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(header), ghostSummary)
        Gtk.addClass(ghostHeader, "flat")
        Gtk.addClass(ghostHeader, "clock-ghost-header")
        gtk_button_set_child(ptr(ghostHeader), header)
        gtk_widget_set_hexpand(ghostHeader, 1)
        Gtk.connect(UnsafeMutableRawPointer(ghostHeader), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.toggleAddPlace() }
        }
        gtk_box_append(ptr(ghost), ghostHeader)

        gtk_widget_set_hexpand(searchEntry, 1)
        Gtk.addClass(searchEntry, "clock-search")
        Gtk.margins(searchEntry, top: 0, bottom: 0, leading: Space.small, trailing: Space.small)
        gtk_box_append(ptr(ghostPanel), searchEntry)
        gtk_widget_set_margin_bottom(results, Space.small)
        Gtk.margins(results, top: 0, bottom: Space.small, leading: Space.small, trailing: Space.small)
        gtk_box_append(ptr(ghostPanel), results)
        gtk_box_append(ptr(ghost), ghostPanel)

        Gtk.onNotify(UnsafeMutableRawPointer(searchEntry), property: "text") { [weak self] in
            Gtk.onMain { [weak self] in
                self?.highlighted = 0
                self?.renderPlaces()
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(searchEntry), "activate") { [weak self] in
            Gtk.onMain { [weak self] in self?.pinHighlighted() }
        }
        Gtk.onKey(searchEntry) { [weak self] keyval, _ in
            guard keyval == 0xFF52 || keyval == 0xFF54 else { return false }
            Gtk.onMain { [weak self] in self?.moveHighlight(keyval == 0xFF54 ? 1 : -1) }
            return true
        }
        return ghost
    }

    private func makeFooter() -> UnsafeMutablePointer<GtkWidget> {
        let footer = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_box_append(ptr(footer), Gtk.hairline())
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium)
        Gtk.margins(
            row, top: Space.small + 2, bottom: Space.medium + 2, leading: Space.margin, trailing: Space.margin)

        var items: [UnsafeMutablePointer<GtkWidget>] = []
        for kind in CopyKind.allCases { items.append(makeCopyButton(kind)) }
        items.append(makeSegmented())
        let end = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium)
        gtk_widget_set_valign(end, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(end, GTK_ALIGN_END)
        gtk_widget_set_hexpand(end, 1)
        let esc = ClockUI.label(Localized.text("Esc closes"), "clock-dim")
        gtk_widget_set_valign(esc, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(end), esc)
        gtk_box_append(ptr(end), notify)
        items.append(end)
        let flow = Gtk.wrapRow(items, spacing: Space.small)
        gtk_widget_set_halign(flow, GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(flow, 1)
        gtk_box_append(ptr(row), flow)
        Gtk.connect(UnsafeMutableRawPointer(notify), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.addAlarm(at: nil, note: nil) }
        }
        gtk_box_append(ptr(footer), row)
        return footer
    }

    private func makeCopyButton(_ kind: CopyKind) -> UnsafeMutablePointer<GtkWidget> {
        let title = ClockUI.label(Localized.text(kind.title), "clock-copy-title")
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
        return button
    }

    private func makeSegmented() -> UnsafeMutablePointer<GtkWidget> {
        let accessible = tailscode_box_new_with_role(GTK_ORIENTATION_HORIZONTAL, 0, GTK_ACCESSIBLE_ROLE_GROUP)!
        tailscode_set_accessible_label(accessible, Localized.text("Time format"))
        Gtk.addClass(accessible, "clock-seg")
        gtk_widget_set_valign(accessible, GTK_ALIGN_CENTER)
        for style in ClockStyle.allCases {
            let title = ClockUI.label(style.title, "clock-seg-title")
            let example = ClockUI.label("", "clock-seg-example")
            let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
            gtk_box_append(ptr(lines), title)
            gtk_box_append(ptr(lines), example)
            let button = gtk_button_new()!
            Gtk.addClass(button, "flat")
            Gtk.addClass(button, "clock-seg-item")
            gtk_button_set_child(ptr(button), lines)
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked") {
                Gtk.onMain { ClockWatch.shared.updatePreferences { $0.style = style } }
            }
            gtk_box_append(ptr(accessible), button)
            segments.append(Segment(style: style, button: button, example: example))
        }
        return accessible
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
        Gtk.onKey(window) { [weak self] keyval, _ in
            guard keyval == Keymap.escape else { return false }
            Gtk.onMain { [weak self] in self?.escape() }
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

    var root: UnsafeMutablePointer<GtkWidget> { window }

    var summary: String {
        let lanes = board.lanes.map { "\($0.name)=\($0.time)" }.joined(separator: ",")
        let size = "\(gtk_widget_get_width(window))x\(gtk_widget_get_height(window))"
        return "head=\(board.head) delta=\(board.delta) following=\(scrubMinute == nil) lanes=\(board.lanes.count) [\(lanes)] alarms=\(board.alarms.count) golden=\(board.golden?.label ?? "-") size=\(size) add=\(addOpen ? "open" : "shut") results=\(shownResults.count)"
    }

    var placesReading: (open: Bool, rows: [PlaceRow], invitation: String, summary: String, sensitive: Bool) {
        (
            addOpen, shownResults,
            gtk_label_get_text(op(ghostInvitation)).map { String(cString: $0) } ?? "",
            gtk_label_get_text(op(ghostSummary)).map { String(cString: $0) } ?? "",
            gtk_widget_is_sensitive(ghostHeader) != 0
        )
    }

    var segmentReading: [(style: ClockStyle, selected: Bool, example: String)] {
        segments.map {
            (
                $0.style, gtk_widget_has_css_class($0.button, "clock-seg-on") != 0,
                gtk_label_get_text(op($0.example)).map { String(cString: $0) } ?? ""
            )
        }
    }

    func driveScrub(minute: Int) { land(on: minute) }

    func driveFollow() { followClock() }

    func driveNotify() { addAlarm(at: nil, note: nil) }

    func driveSearch(_ text: String) {
        if !addOpen { setAddOpen(true) }
        gtk_editable_set_text(op(searchEntry), text)
    }

    func driveAdd(open: Bool) { setAddOpen(open) }

    func driveKey(_ name: String) {
        switch name {
        case "down": moveHighlight(1)
        case "up": moveHighlight(-1)
        case "enter": pinHighlighted()
        default: escape()
        }
    }

    var controlsReading: [(id: String, up: Bool, down: Bool)] { controlStates }

    var searchText: String { Dialogs.entryText(searchEntry) }

    func driveStyle(_ style: ClockStyle) { ClockWatch.shared.updatePreferences { $0.style = style } }

    func driveSize(width: Int32, height: Int32) {
        gtk_window_set_default_size(ptr(window), width, height)
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
        laneReveals = []
        controlStates = []
        Gtk.removeChildren(of: lanesBox)
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
        var trackWidth: Int32 = 0
        var tickHeight: Int32 = 0
        tailscode_ticks_measure(ticks, &trackWidth, &tickHeight)
        trackFloor = trackWidth
        gtk_widget_set_size_request(ticks, trackWidth, tickHeight)
        gtk_widget_set_size_request(scrubber, trackWidth, -1)
        gtk_widget_set_size_request(lines, trackWidth, -1)
        let last = board.lanes.count - 1
        for (index, lane) in board.lanes.enumerated() {
            gtk_box_append(ptr(lanesBox), makeLane(lane, index: index, last: last))
        }
        renderInsight()
        renderMachines()
        renderAlarms()
        renderFormats()
        if ClockWatch.shared.preferences.pins.isEmpty {
            if !emptyDismissed, !addOpen { addOpen = true }
        } else {
            emptyDismissed = false
        }
        renderPlaces()
    }

    private var trackFloor: Int32 = 0
    private var controlStates: [(id: String, up: Bool, down: Bool)] = []
    private var bodyScroller: UnsafeMutablePointer<GtkWidget>?

    private func makeLane(_ lane: MeridianBoard.Lane, index: Int, last: Int) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium + 2)
        gtk_widget_set_size_request(row, -1, 44)

        let info = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.small + 2)
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

        let controls = makeControls(for: lane, index: index, last: last)
        gtk_size_group_add_widget(controlsColumn, controls.cluster)
        gtk_box_append(ptr(info), controls.cluster)
        if let reveal = controls.reveal {
            laneReveals.append(reveal)
            watchLane(row, reveal: reveal)
        }
        if lane.isRemovable {
            let rowHold = Gtk.WeakWidget(row)
            Gtk.onRightClick(row) { [weak self] x, y in
                Gtk.onMain { [weak self] in
                    guard let row = rowHold.widget else { return }
                    self?.laneMenu(for: lane, row: row, x: x, y: y)
                }
            }
        }
        gtk_box_append(ptr(row), labelCell(info))
        gtk_box_append(ptr(row), makeBar(lane))
        laneRefs.append(LaneRefs(id: lane.id, time: time, day: day, glyph: glyph))
        return row
    }

    private func watchLane(_ row: UnsafeMutablePointer<GtkWidget>, reveal: LaneReveal) {
        Gtk.onPointer(
            row,
            move: { _, _ in
                Gtk.onMain {
                    reveal.hover = true
                    reveal.apply()
                }
            },
            leave: {
                Gtk.onMain {
                    reveal.hover = false
                    reveal.apply()
                }
            })
        let focus = gtk_event_controller_focus_new()!
        gtk_widget_add_controller(row, focus)
        let address = Int(bitPattern: UnsafeMutableRawPointer(focus))
        Gtk.onNotify(UnsafeMutableRawPointer(focus), property: "contains-focus") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
            let inside = gtk_event_controller_focus_contains_focus(op(raw)) != 0
            Gtk.onMain {
                reveal.focus = inside
                reveal.apply()
            }
        }
    }

    private func makeControls(
        for lane: MeridianBoard.Lane, index: Int, last: Int
    ) -> (cluster: UnsafeMutablePointer<GtkWidget>, reveal: LaneReveal?) {
        let cluster = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
        gtk_widget_set_valign(cluster, GTK_ALIGN_CENTER)
        guard lane.isRemovable else {
            gtk_widget_set_opacity(cluster, 0)
            gtk_widget_set_can_target(cluster, 0)
            return (cluster, nil)
        }
        let id = lane.id
        controlStates.append((id, index > 1, index < last))
        func button(
            _ glyph: String, _ label: String, enabled: Bool, _ act: @escaping @Sendable () -> Void
        ) -> UnsafeMutablePointer<GtkWidget> {
            let item = Gtk.button(glyph, css: ["flat", "clock-lane-control"]) { Gtk.onMain(act) }
            tailscode_set_accessible_label(item, label)
            gtk_widget_set_tooltip_text(item, label)
            gtk_widget_set_sensitive(item, enabled ? 1 : 0)
            return item
        }
        gtk_box_append(
            ptr(cluster),
            button("\u{2191}", Localized.text("Move up"), enabled: index > 1) {
                ClockWatch.shared.updatePreferences { $0.move(id, by: -1) }
            })
        gtk_box_append(
            ptr(cluster),
            button("\u{2193}", Localized.text("Move down"), enabled: index < last) {
                ClockWatch.shared.updatePreferences { $0.move(id, by: 1) }
            })
        gtk_box_append(
            ptr(cluster),
            button("\u{00D7}", String(format: Localized.text("Remove %@"), lane.name), enabled: true) {
                ClockWatch.shared.updatePreferences { $0.unpin(id) }
            })
        let reveal = LaneReveal(cluster: cluster)
        reveal.apply()
        return (cluster, reveal)
    }

    private func makeBar(_ lane: MeridianBoard.Lane) -> UnsafeMutablePointer<GtkWidget> {
        let strip = tailscode_strip_new(40, 0, 13)!
        gtk_widget_set_valign(strip, GTK_ALIGN_FILL)
        gtk_widget_set_vexpand(strip, 1)
        let hours = max(1, Int((Double(board.minutes) / 60).rounded()))
        MeridianInk.paint(strip: strip, bar: lane.bar, hairline: 0.06, grid: hours, noon: true)
        Gtk.addClass(strip, "clock-strip")
        tailscode_set_accessible_label(strip, lane.name)
        gtk_widget_set_size_request(strip, trackFloor, -1)
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
        let note = reset.map { String(format: Localized.text("%@ window reopens"), $0.provider) }
        addAlarm(at: mark.instant, note: note)
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
        let glyph = ClockUI.glyph(TAILSCODE_GLYPH_INFO, size: 15, body: MatrixTheme.palette.info)
        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        gtk_widget_set_margin_top(glyph, 2)
        gtk_box_append(ptr(insightBox), glyph)
        let label = ClockUI.label(insight, "clock-insight-text", wrap: true, chars: Self.longLine)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(insightBox), label)
    }

    private func renderMachines() {
        Gtk.removeChildren(of: machinesBody)
        guard !board.machines.isEmpty else {
            gtk_widget_set_visible(machinesRow, 0)
            return
        }
        gtk_widget_set_visible(machinesRow, 1)
        var items: [UnsafeMutablePointer<GtkWidget>] = []
        for machine in board.machines {
            let item = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.small - 2)
            Gtk.addClass(item, "clock-machine")
            gtk_box_append(ptr(item), ClockUI.dot(machine.tone))
            gtk_box_append(ptr(item), ClockUI.label(machine.name, "clock-name"))
            gtk_box_append(ptr(item), ClockUI.label(machine.status, "clock-status \(ClockUI.tone(machine.tone))"))
            if let time = machine.time {
                gtk_box_append(ptr(item), ClockUI.label(time, "clock-stamp clock-dim"))
            }
            items.append(item)
        }
        gtk_box_append(ptr(machinesBody), Gtk.wrapRow(items, spacing: Space.medium))
        if let warning = board.skewWarning {
            gtk_box_append(
                ptr(machinesBody), ClockUI.label(warning, "clock-status clock-warn", wrap: true, chars: Self.longLine))
        }
    }

    private func renderAlarms() {
        Gtk.removeChildren(of: alarmsBody)
        guard !board.alarms.isEmpty else {
            gtk_widget_set_visible(alarmsRow, 0)
            return
        }
        gtk_widget_set_visible(alarmsRow, 1)
        var pills: [UnsafeMutablePointer<GtkWidget>] = []
        for alarm in board.alarms {
            let pill = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.small - 2)
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
        gtk_box_append(ptr(alarmsBody), Gtk.wrapRow(pills, spacing: Space.small))
    }

    private func renderFormats() {
        let now = ClockWatch.shared.now
        let zone = TimeZone.current
        let current = ClockWatch.shared.preferences.style
        for segment in segments {
            let text =
                segment.style == .system
                ? ClockStyle.systemDescription() : segment.style.example(at: now, in: zone)
            gtk_label_set_text(op(segment.example), text)
            if segment.style == current {
                gtk_widget_add_css_class(segment.button, "clock-seg-on")
                tailscode_set_accessible_pressed(segment.button, 1)
            } else {
                gtk_widget_remove_css_class(segment.button, "clock-seg-on")
                tailscode_set_accessible_pressed(segment.button, 0)
            }
        }
    }

    private func toggleAddPlace() {
        if !addOpen { setAddOpen(true) } else { setAddOpen(false) }
    }

    private func setAddOpen(_ open: Bool) {
        addOpen = open
        if !open, ClockWatch.shared.preferences.pins.isEmpty { emptyDismissed = true }
        if !open { gtk_editable_set_text(op(searchEntry), "") }
        renderPlaces()
        if open {
            gtk_widget_grab_focus(searchEntry)
            revealPlaces()
        } else {
            gtk_widget_grab_focus(ghostHeader)
        }
    }

    private func revealPlaces() {
        let scrollerHold = bodyScroller.map { Gtk.WeakWidget($0) }
        let ghostHold = Gtk.WeakWidget(ghost)
        let bodyHold = Gtk.WeakWidget(body)
        Gtk.betweenFrames(of: window) {
            guard let scroller = scrollerHold?.widget, let ghost = ghostHold.widget, let body = bodyHold.widget,
                let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
            else { return }
            var bounds = graphene_rect_t()
            guard gtk_widget_compute_bounds(ghost, body, &bounds) != 0 else { return }
            let bottom = Double(bounds.origin.y + bounds.size.height) + 16
            let page = gtk_adjustment_get_page_size(adjustment)
            let target = min(gtk_adjustment_get_upper(adjustment) - page, max(gtk_adjustment_get_value(adjustment), bottom - page))
            gtk_adjustment_set_value(adjustment, target)
        }
    }

    private func escape() {
        guard addOpen else {
            MeridianSheet.close()
            return
        }
        if !Dialogs.entryText(searchEntry).isEmpty {
            gtk_editable_set_text(op(searchEntry), "")
        } else {
            setAddOpen(false)
        }
    }

    private func moveHighlight(_ step: Int) {
        guard !shownResults.isEmpty else { return }
        highlighted = (highlighted + step + shownResults.count) % shownResults.count
        renderPlaces()
    }

    private func pinHighlighted() {
        guard shownResults.indices.contains(highlighted) else { return }
        pin(shownResults[highlighted].id)
    }

    private func pin(_ id: String) {
        gtk_editable_set_text(op(searchEntry), "")
        addOpen = false
        ClockWatch.shared.updatePreferences { $0.pin(id) }
        renderPlaces()
        gtk_widget_grab_focus(scrubber)
    }

    private func renderPlaces() {
        let preferences = ClockWatch.shared.preferences
        let status = MeridianPlaces.status(preferences)
        gtk_label_set_text(op(ghostInvitation), status.invitation)
        gtk_label_set_text(op(ghostSummary), status.summary)
        gtk_widget_set_sensitive(ghostHeader, status.isFull ? 0 : 1)
        tailscode_set_accessible_label(ghostHeader, "\(status.invitation), \(status.summary)")
        gtk_entry_set_placeholder_text(ptr(searchEntry), status.placeholder)
        let open = addOpen && !status.isFull
        gtk_widget_set_visible(ghostPanel, open ? 1 : 0)
        if open { Gtk.addClass(ghost, "clock-ghost-open") } else { gtk_widget_remove_css_class(ghost, "clock-ghost-open") }
        Gtk.removeChildren(of: results)
        shownResults = []
        guard open else { return }
        let query = Dialogs.entryText(searchEntry)
        let now = ClockWatch.shared.now
        placesMinute = Int(now.timeIntervalSince1970 / 60)
        if query.isEmpty {
            shownResults = MeridianPlaces.suggestions(preferences: preferences, viewer: .current, now: now)
            if !shownResults.isEmpty {
                let heading = ClockUI.label(Localized.text("Popular"), "clock-section")
                gtk_widget_set_margin_top(heading, Space.hair)
                gtk_box_append(ptr(results), heading)
            }
        } else {
            shownResults = MeridianPlaces.results(
                for: query, preferences: preferences, viewer: .current, now: now)
            if shownResults.isEmpty {
                gtk_box_append(
                    ptr(results), ClockUI.label(MeridianPlaces.emptyResult(for: query), "clock-dim", wrap: true, chars: 60))
            }
        }
        highlighted = min(highlighted, max(0, shownResults.count - 1))
        for (index, place) in shownResults.enumerated() {
            gtk_box_append(ptr(results), makeResult(place, on: index == highlighted))
        }
    }

    private func makeResult(_ place: PlaceRow, on: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let item = gtk_button_new()!
        Gtk.addClass(item, "flat")
        Gtk.addClass(item, "clock-result")
        if on { Gtk.addClass(item, "clock-result-on") }
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium)
        let names = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(names, 1)
        gtk_widget_set_valign(names, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(names), ClockUI.label(place.name, "clock-name"))
        gtk_box_append(ptr(names), ClockUI.label(place.detail, "clock-dim"))
        let when = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_valign(when, GTK_ALIGN_CENTER)
        let time = ClockUI.label(place.time, "clock-lane-time")
        let away = ClockUI.label("\(place.offset) \u{00B7} \(place.dayWord)", "clock-dim")
        gtk_label_set_xalign(op(time), 1)
        gtk_label_set_xalign(op(away), 1)
        gtk_box_append(ptr(when), time)
        gtk_box_append(ptr(when), away)
        gtk_box_append(ptr(line), names)
        gtk_box_append(ptr(line), when)
        gtk_button_set_child(ptr(item), line)
        tailscode_set_accessible_label(item, place.spoken)
        let id = place.id
        Gtk.connect(UnsafeMutableRawPointer(item), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.pin(id) }
        }
        return item
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
        renderFormats()
        if addOpen, placesMinute != Int(ClockWatch.shared.now.timeIntervalSince1970 / 60) { renderPlaces() }
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
        gtk_label_set_text(op(entry.title), Localized.text("Copied"))
        Gtk.addClass(entry.title, "clock-copied")
        let ticket = (copyTickets[kind] ?? 0) + 1
        copyTickets[kind] = ticket
        let titleHold = Gtk.WeakWidget(entry.title)
        Gtk.after(1200) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.copyTickets[kind] == ticket, let raw = titleHold.widget else { return }
                gtk_label_set_text(op(raw), Localized.text(kind.title))
                gtk_widget_remove_css_class(raw, "clock-copied")
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
        let notifyHold = Gtk.WeakWidget(notify)
        Gtk.after(1200) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.notifyTicket == ticket, let raw = notifyHold.widget else { return }
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
