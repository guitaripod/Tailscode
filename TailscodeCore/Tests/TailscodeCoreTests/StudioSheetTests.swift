import Foundation
import Testing

@testable import TailscodeCore

@Suite("The Studio sheet")
struct StudioSheetTests {
    private func frame(_ width: Double, _ height: Double, _ titlebar: Double) -> StudioSheetFrame {
        StudioSheetGeometry.frame(windowWidth: width, windowHeight: height, titlebar: titlebar)
    }

    @Test("A 1440 by 900 window leaves the title bar and a seam above the sheet")
    func standardWindow() {
        let sheet = frame(1440, 900, 52)
        #expect(sheet.topInset == 60)
        #expect(sheet.y == 60)
        #expect(sheet.x == 24)
        #expect(sheet.width == 1392)
        #expect(sheet.height == 840)
        #expect(sheet.leftInset == 24 && sheet.rightInset == 24 && sheet.bottomInset == 0)
        #expect(sheet.cornerRadius == 14)
    }

    @Test("A window under 720 tall has no seam, so the stage keeps the points")
    func shortWindowHasNoGap() {
        let sheet = frame(1440, 700, 52)
        #expect(sheet.topInset == 52)
        #expect(sheet.height == 648)
        #expect(frame(1440, 720, 52).topInset == 60)
        #expect(frame(1440, 719, 52).topInset == 52)
    }

    @Test("The sheet never starts closer to the top than 36")
    func minimumTop() {
        #expect(frame(1000, 800, 10).topInset == 36)
        #expect(frame(1000, 600, 0).topInset == 36)
    }

    @Test("A 960 by 640 window keeps its sides and loses its seam")
    func smallWindow() {
        let sheet = frame(960, 640, 52)
        #expect(sheet.topInset == 52)
        #expect(sheet.x == 24)
        #expect(sheet.width == 912)
        #expect(sheet.height == 588)
    }

    @Test("Under 700 wide the sheet fills the window's width")
    func narrowWindow() {
        let sheet = frame(690, 600, 52)
        #expect(sheet.x == 0)
        #expect(sheet.leftInset == 0 && sheet.rightInset == 0)
        #expect(sheet.width == 690)
        #expect(frame(700, 600, 52).x == 24)
        #expect(frame(699.5, 600, 52).x == 0)
    }

    @Test("At 1800 the sheet still fills; past it, it caps at 1752 and centres")
    func wideWindows() {
        let edge = frame(1800, 1000, 52)
        #expect(edge.x == 24)
        #expect(edge.width == 1752)
        let wide = frame(2560, 1440, 52)
        #expect(wide.width == 1752)
        #expect(wide.x == 404)
        #expect(wide.leftInset == 404 && wide.rightInset == 404)
        #expect(wide.x + wide.width + wide.rightInset == 2560)
        #expect(frame(1920, 1080, 52).x == 84)
        #expect(frame(1801, 1000, 52).width == 1752)
    }

    @Test("A window shorter than the top inset gets no height and the function does not trap")
    func degenerate() {
        let sheet = frame(400, 30, 52)
        #expect(sheet.height == 0)
        #expect(sheet.width == 400)
        #expect(sheet.topInset == 52)
        #expect(frame(0, 0, 0).height == 0)
        #expect(frame(.nan, .infinity, -4).height == 0)
        #expect(frame(-10, -10, 52).width == 0)
    }

    @Test("The sheet always fits inside the window it is given")
    func staysInside() {
        for width in stride(from: 0.0, through: 3000, by: 137) {
            for height in stride(from: 0.0, through: 1600, by: 111) {
                let sheet = frame(width, height, 52)
                #expect(sheet.width >= 0 && sheet.height >= 0)
                #expect(sheet.x + sheet.width <= width + 0.0001)
                #expect(sheet.height == 0 || sheet.y + sheet.height == height)
            }
        }
    }

    @Test("The durations, travel, scrim and edge are the design's")
    func constants() {
        #expect(StudioSheetMotion.openDuration == 0.320)
        #expect(StudioSheetMotion.closeDuration == 0.220)
        #expect(StudioSheetMotion.reducedDuration == 0.120)
        #expect(StudioSheetMotion.travelFraction == 0.28)
        #expect(StudioSheetMotion.scrimAlpha(for: .dark) == 0.38)
        #expect(StudioSheetMotion.scrimAlpha(for: .light) == 0.26)
        #expect(StudioSheetMotion.edgeHairlineWidth == 1)
        #expect(StudioSheetMotion.edgeShadowBlur == 24)
        #expect(StudioSheetMotion.edgeShadowAlpha == 0.30)
        #expect(StudioSheetMetrics.toolbarHeight == 44)
        #expect(StudioSheetMotion.duration(opening: true, reduced: false) == 0.320)
        #expect(StudioSheetMotion.duration(opening: false, reduced: false) == 0.220)
        #expect(StudioSheetMotion.duration(opening: true, reduced: true) == 0.120)
        #expect(StudioSheetMotion.duration(opening: false, reduced: true) == 0.120)
    }

    @Test("Easing runs 0 to 1 in both directions, monotonic and clamped")
    func easing() {
        for opening in [true, false] {
            #expect(StudioSheetMotion.eased(0, opening: opening) == 0)
            #expect(StudioSheetMotion.eased(1, opening: opening) == 1)
            #expect(StudioSheetMotion.eased(-3, opening: opening) == 0)
            #expect(StudioSheetMotion.eased(7, opening: opening) == 1)
            #expect(StudioSheetMotion.eased(.nan, opening: opening) == 0)
            var last = -1.0
            for step in 0...100 {
                let value = StudioSheetMotion.eased(Double(step) / 100, opening: opening)
                #expect(value >= last)
                last = value
            }
        }
        #expect(StudioSheetMotion.eased(0.5, opening: true) == 0.75)
        #expect(StudioSheetMotion.eased(0.5, opening: false) == 0.25)
    }

    @Test("Opening is ease-out-quad: well short of cubic's 91 percent at 176 ms")
    func openingDoesNotFrontLoad() {
        let covered = StudioSheetMotion.eased(0.176 / 0.320, opening: true)
        #expect(covered < 0.80)
        #expect(covered > 0.75)
    }

    @Test("Presence rises from 0 to 1 opening and falls from 1 to 0 closing")
    func presence() {
        #expect(StudioSheetMotion.progress(elapsed: 0, opening: true, reduced: false) == 0)
        #expect(StudioSheetMotion.progress(elapsed: 0.320, opening: true, reduced: false) == 1)
        #expect(StudioSheetMotion.progress(elapsed: 5, opening: true, reduced: false) == 1)
        #expect(StudioSheetMotion.progress(elapsed: 0, opening: false, reduced: false) == 1)
        #expect(StudioSheetMotion.progress(elapsed: 0.220, opening: false, reduced: false) == 0)
        #expect(StudioSheetMotion.progress(elapsed: 0.120, opening: true, reduced: true) == 1)
        var last = 2.0
        for step in 0...22 {
            let value = StudioSheetMotion.progress(
                elapsed: Double(step) * 0.01, opening: false, reduced: false)
            #expect(value <= last)
            last = value
        }
    }

    @Test("The sheet travels from 28 percent of its height below rest, and not at all when reduced")
    func translation() {
        #expect(StudioSheetMotion.translation(progress: 0, sheetHeight: 840, reduced: false) == 840 * 0.28)
        #expect(StudioSheetMotion.translation(progress: 1, sheetHeight: 840, reduced: false) == 0)
        #expect(StudioSheetMotion.translation(progress: 0.5, sheetHeight: 840, reduced: false) == 840 * 0.14)
        #expect(StudioSheetMotion.translation(progress: -1, sheetHeight: 840, reduced: false) == 840 * 0.28)
        #expect(StudioSheetMotion.translation(progress: 2, sheetHeight: 840, reduced: false) == 0)
        #expect(StudioSheetMotion.translation(progress: 0, sheetHeight: -5, reduced: false) == 0)
        for progress in [0.0, 0.3, 1.0] {
            #expect(StudioSheetMotion.translation(progress: progress, sheetHeight: 840, reduced: true) == 0)
        }
    }

    @Test("The sheet is opaque from its first frame unless motion is reduced")
    func opacity() {
        for progress in [0.0, 0.01, 0.5, 1.0] {
            #expect(StudioSheetMotion.sheetOpacity(progress: progress, reduced: false) == 1)
        }
        #expect(StudioSheetMotion.sheetOpacity(progress: 0, reduced: true) == 0)
        #expect(StudioSheetMotion.sheetOpacity(progress: 0.4, reduced: true) == 0.4)
        #expect(StudioSheetMotion.sheetOpacity(progress: 3, reduced: true) == 1)
    }

    @Test("The scrim fades to its face's alpha with the sheet")
    func scrim() {
        #expect(StudioSheetMotion.scrimOpacity(progress: 0, appearance: .dark) == 0)
        #expect(StudioSheetMotion.scrimOpacity(progress: 1, appearance: .dark) == 0.38)
        #expect(StudioSheetMotion.scrimOpacity(progress: 1, appearance: .light) == 0.26)
        #expect(StudioSheetMotion.scrimOpacity(progress: 0.5, appearance: .dark) == 0.19)
        #expect(StudioSheetMotion.scrimOpacity(progress: 9, appearance: .light) == 0.26)
        #expect(StudioSheetMotion.scrimOpacity(progress: -9, appearance: .light) == 0)
    }

    @Test("Opening takes the spring where there is one and ease-out-quad elsewhere; leaving is ease-in-quad")
    func curves() {
        #expect(StudioSheetMotion.curve(opening: true, hasSpring: true) == .springCriticallyDamped)
        #expect(StudioSheetMotion.curve(opening: true, hasSpring: false) == .easeOutQuad)
        #expect(StudioSheetMotion.curve(opening: false, hasSpring: true) == .easeInQuad)
        #expect(StudioSheetMotion.curve(opening: false, hasSpring: false) == .easeInQuad)
    }

    @Test("Every state meets every event as the table says")
    func table() {
        typealias Row = (StudioSheetState, StudioSheetEvent, StudioSheetState, StudioSheetEffect)
        let rows: [Row] = [
            (.closed, .show(lane: .image), .opening, .animateIn(.image)),
            (.closed, .show(lane: .video), .opening, .animateIn(.video)),
            (.closed, .dismiss, .closed, .none),
            (.closed, .finished, .closed, .none),
            (.opening, .show(lane: .image), .opening, .changeLane(.image)),
            (.opening, .show(lane: .video), .opening, .changeLane(.video)),
            (.opening, .dismiss, .closing, .animateOut),
            (.opening, .finished, .open, .none),
            (.open, .show(lane: .image), .open, .changeLane(.image)),
            (.open, .show(lane: .video), .open, .changeLane(.video)),
            (.open, .dismiss, .closing, .animateOut),
            (.open, .finished, .open, .none),
            (.closing, .show(lane: .image), .opening, .animateIn(.image)),
            (.closing, .show(lane: .video), .opening, .animateIn(.video)),
            (.closing, .dismiss, .closing, .none),
            (.closing, .finished, .closed, .none),
        ]
        for (state, event, next, effect) in rows {
            let result = state.reduced(by: event)
            #expect(result.state == next, "\(state) + \(event)")
            #expect(result.effect == effect, "\(state) + \(event)")
        }
        let states: [StudioSheetState] = [.closed, .opening, .open, .closing]
        let events: [StudioSheetEvent] =
            StudioLaneKind.allCases.map { .show(lane: $0) } + [.dismiss, .finished]
        #expect(rows.count == states.count * events.count)
    }

    @Test("A full life of the sheet walks closed, opening, open, closing, closed")
    func lifecycle() {
        var state = StudioSheetState.closed
        for event in [StudioSheetEvent.show(lane: .image), .finished, .dismiss, .finished] {
            state = state.reduced(by: event).state
        }
        #expect(state == .closed)
    }

    @Test("The sheet holds the keyboard while it rises and stays, and gives the chat its chords back as it leaves")
    func keyOwnership() {
        #expect(StudioSheetState.closed.capturesKeys == false)
        #expect(StudioSheetState.opening.capturesKeys)
        #expect(StudioSheetState.open.capturesKeys)
        #expect(StudioSheetState.closing.capturesKeys == false)
        #expect(StudioSheetState.closed.conversationChordsEnabled)
        #expect(StudioSheetState.opening.conversationChordsEnabled == false)
        #expect(StudioSheetState.open.conversationChordsEnabled == false)
        #expect(StudioSheetState.closing.conversationChordsEnabled)
    }

    @Test("Esc stops a render that is out and closes the sheet otherwise")
    func escapeRule() {
        #expect(StudioSheetKeys.escape(renderIsOut: true) == .stopRender)
        #expect(StudioSheetKeys.escape(renderIsOut: false) == .closeSheet)
    }

    @Test("Ctrl+W and Command+W close the sheet; plain w, shifted and Alt chords do not")
    func closeChords() throws {
        let w = UInt32(UnicodeScalar("w").value)
        let q = UInt32(UnicodeScalar("q").value)
        let ctrlW = try #require(KeyChord.canonical(keyval: w, state: KeyChord.controlMask))
        let plain = try #require(KeyChord.canonical(keyval: w, state: 0))
        let shifted = try #require(
            KeyChord.canonical(keyval: w, state: KeyChord.controlMask | KeyChord.shiftMask))
        let alt = try #require(
            KeyChord.canonical(keyval: w, state: KeyChord.controlMask | KeyChord.altMask))
        let other = try #require(KeyChord.canonical(keyval: q, state: KeyChord.controlMask))
        let plainOther = try #require(KeyChord.canonical(keyval: q, state: 0))
        let shiftedPlain = try #require(KeyChord.canonical(keyval: w, state: KeyChord.shiftMask))

        #expect(StudioSheetKeys.closes(ctrlW))
        #expect(StudioSheetKeys.closes(plain) == false)
        #expect(StudioSheetKeys.closes(shifted) == false)
        #expect(StudioSheetKeys.closes(alt) == false)
        #expect(StudioSheetKeys.closes(other) == false)

        #expect(StudioSheetKeys.closes(plain, command: true))
        #expect(StudioSheetKeys.closes(ctrlW, command: true) == false)
        #expect(StudioSheetKeys.closes(shiftedPlain, command: true) == false)
        #expect(StudioSheetKeys.closes(plainOther, command: true) == false)

        let parsed = try #require(KeySpec.parse("ctrl+w")?.chords.first)
        #expect(StudioSheetKeys.closes(parsed))
    }

    @Test("The sheet's words are written")
    func words() {
        #expect(!StudioSheetWords.dialogName.isEmpty)
        #expect(!StudioSheetWords.closeLabel.isEmpty)
        #expect(!StudioSheetWords.escapeHint.isEmpty)
    }

    @Test func aSheetOverASheetSitsFurtherInOnTheTopAndBothSides() {
        let rest = StudioSheetGeometry.frame(windowWidth: 1440, windowHeight: 900, titlebar: 52)
        let over = StudioSheetGeometry.frame(windowWidth: 1440, windowHeight: 900, titlebar: 52, depth: 1)
        #expect(over.y == rest.y + StudioSheetMetrics.stackInset)
        #expect(over.x == rest.x + StudioSheetMetrics.stackInset)
        #expect(over.width == rest.width - 2 * StudioSheetMetrics.stackInset)
        #expect(over.height == rest.height - StudioSheetMetrics.stackInset)
        #expect(over.bottomInset == 0)
        let deeper = StudioSheetGeometry.frame(windowWidth: 1440, windowHeight: 900, titlebar: 52, depth: 9)
        #expect(deeper == over, "depth never passes the stack's maximum")
        let negative = StudioSheetGeometry.frame(windowWidth: 1440, windowHeight: 900, titlebar: 52, depth: -3)
        #expect(negative == rest)
    }
}
