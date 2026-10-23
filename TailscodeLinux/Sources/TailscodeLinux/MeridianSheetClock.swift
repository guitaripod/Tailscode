import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension MeridianSheet {
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

    func scrubbed(kind: Int32, fraction: Double) {
        let minute = board.minute(atFraction: fraction)
        if kind == 0 {
            glideTo(minute)
        } else {
            land(on: minute)
        }
    }

    func nudge(_ minutes: Int) {
        land(on: min(max(board.scrubMinute + minutes, 0), board.minutes - 1))
    }

    func land(on minute: Int) {
        endGlide()
        scrubMinute = min(max(minute, 0), board.minutes - 1)
        refresh(force: false)
    }

    func followClock() {
        glide(to: board.nowMinute, thenFollow: true)
    }

    func glideTo(_ minute: Int) {
        glide(to: minute, thenFollow: false)
    }

    func glide(to minute: Int, thenFollow: Bool) {
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

    func glideStep() {
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

    func finishGlide() {
        glide.lift()
        scrubMinute = glideFollows ? nil : Int(glideTarget)
        refresh(force: false)
    }

    func endGlide() {
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

    func rebuild() {
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
}
