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

final class MeridianCallback: @unchecked Sendable {
    let work: (Int32, Double) -> Void
    init(_ work: @escaping (Int32, Double) -> Void) { self.work = work }
}

/// Whether a lane's controls are showing: while the pointer is over the lane or keyboard focus is
/// anywhere inside it, so they can be found by the mouse and reached by Tab.
final class LaneReveal: @unchecked Sendable {
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
    static let glideSeconds = 0.18
    static let longLine: Int32 = 96

    enum Space {
        static let hair: Int32 = 4
        static let small: Int32 = 8
        static let medium: Int32 = 16
        static let large: Int32 = 24
        static let margin: Int32 = 32
    }

    enum CopyKind: Int, CaseIterable {
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

    struct LaneRefs {
        let id: String
        let time: UnsafeMutablePointer<GtkWidget>
        let day: UnsafeMutablePointer<GtkWidget>
        let glyph: UnsafeMutablePointer<GtkWidget>
    }

    struct Segment {
        let style: ClockStyle
        let button: UnsafeMutablePointer<GtkWidget>
        let example: UnsafeMutablePointer<GtkWidget>
    }

    let window: UnsafeMutablePointer<GtkWidget>
    let body = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    let headTime = ClockUI.label("", "clock-head")
    let delta = ClockUI.label("", "clock-delta")
    let dateLine = ClockUI.label("", "clock-dim")
    let ticks = tailscode_ticks_new()!
    let lanesBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.small)
    let lines = tailscode_lines_new()!
    let scrubber: UnsafeMutablePointer<GtkWidget>
    let labelColumn = gtk_size_group_new(GTK_SIZE_GROUP_HORIZONTAL)!
    let controlsColumn = gtk_size_group_new(GTK_SIZE_GROUP_HORIZONTAL)!
    let ghost = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.small)
    let ghostHeader = gtk_button_new()!
    let ghostInvitation = ClockUI.label("", "clock-name")
    let ghostSummary = ClockUI.label("", "clock-dim")
    let ghostPanel = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.small)
    let searchEntry = gtk_entry_new()!
    let results = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
    let insightBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.small + 2)
    let machinesRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium + 2)
    let machinesBody = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.small)
    let alarmsRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Space.medium + 2)
    let alarmsBody = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Space.small)
    let notify: UnsafeMutablePointer<GtkWidget>
    var copyButtons: [(title: UnsafeMutablePointer<GtkWidget>, value: UnsafeMutablePointer<GtkWidget>, kind: CopyKind)] = []
    var segments: [Segment] = []
    var copyTickets: [CopyKind: Int] = [:]
    var notifyTicket = 0

    var laneRefs: [LaneRefs] = []
    var structure: MeridianStructure?
    var scrubMinute: Int?
    var board: MeridianBoard
    var token = 0
    var scrubberCallback: Unmanaged<MeridianCallback>?
    var markCallbacks: [Unmanaged<MeridianCallback>] = []
    var laneReveals: [LaneReveal] = []
    lazy var glide = RepeatingMotion(holding: false) { [weak self] in self?.glideStep() }
    var glideOrigin = 0.0
    var glideTarget = 0.0
    var glideStart = 0.0
    var glideFollows = false

    var addOpen = false
    var emptyDismissed = false
    var highlighted = 0
    var shownResults: [PlaceRow] = []
    var placesMinute = -1

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

    init(parent: UnsafeMutablePointer<GtkWidget>?) {
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

    var trackFloor: Int32 = 0
    var controlStates: [(id: String, up: Bool, down: Bool)] = []
    var bodyScroller: UnsafeMutablePointer<GtkWidget>?
}
