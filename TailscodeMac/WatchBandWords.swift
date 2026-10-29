import AppKit
import TailscodeCore

/// The words that are not a tile's: the situation in the largest type on the screen, what is being
/// watched under it, the time and the date, the caption over the hour's ribbon and the calm screen's
/// one line. Their rectangles are the layout's; this chooses the size the words can be set at in them.
@MainActor
final class WatchBandWords {
    static let headlineSizes = [6.4, 5.4, 4.6, 3.8, 3.2, 2.6]

    let headline = WatchLabel(wrap: .words, lines: 2)
    let watchLine = WatchLabel()
    let clock = WatchLabel()
    let date = WatchLabel()
    let caption = WatchLabel()
    let calm = WatchLabel(wrap: .words, lines: 2)
    private let timeFormat = DateFormatter()
    private let dateFormat = DateFormatter()

    init() {
        timeFormat.timeStyle = .short
        timeFormat.dateStyle = .none
        dateFormat.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
    }

    var labels: [String: WatchLabel] {
        ["headline": headline, "watch": watchLine, "clock": clock, "date": date, "caption": caption, "calm": calm]
    }

    static func hasFailure(_ wall: AgentWall) -> Bool {
        wall.tiles.contains { tile in
            if case .finished(.failed) = tile.state { return true }
            return false
        }
    }

    /// The text of the watch line: Core's, with the count of sub-agents under the tiles.
    static func watchWords(_ wall: AgentWall) -> String {
        ([wall.watchLine] + [wall.subagentsLine].compactMap { $0 }).filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    static func calmWords(_ wall: AgentWall) -> String {
        guard let calm = wall.calm else { return "" }
        return calm.line + " · " + Localized.text("seen by this Mac")
    }

    func apply(_ wall: AgentWall, layout: WallLayout, face: WatchFace, now: Date) -> [String: CGRect] {
        let type = face.type
        let palette = face.palette
        var frames: [String: CGRect] = [:]
        let tone = palette.mood(wall.mood, hasFailure: Self.hasFailure(wall))

        let rect = layout.headline.watchFrame
        headline.configure(wrap: .words, lines: max(1, layout.headlineLines))
        var chosen = Self.headlineSizes.last ?? 3
        for units in Self.headlineSizes {
            let font = type.prose(units, weight: .semibold)
            headline.show(wall.headline, font: font, ink: tone.watchColor())
            let lines = headline.naturalLines(forWidth: rect.width)
            if lines <= max(1, layout.headlineLines), headline.height(forWidth: rect.width) <= rect.height + 1 {
                chosen = units
                break
            }
        }
        headline.show(wall.headline, font: type.prose(chosen, weight: .semibold), ink: tone.watchColor())
        frames["headline"] = rect

        watchLine.show(
            Self.watchWords(wall), font: type.prose(1.75), ink: palette.dim.watchColor())
        frames["watch"] = layout.watchLine.watchFrame

        let showsClock = face.style.showsClock && !layout.clock.isEmpty
        if showsClock {
            let align: NSTextAlignment = layout.clockAlignment == .trailing ? .right : .left
            clock.show(
                timeFormat.string(from: now),
                font: .monospacedDigitSystemFont(ofSize: type.size(6.6, floor: 30), weight: .semibold),
                ink: palette.text.watchColor(), align: align)
            date.show(
                dateFormat.string(from: now), font: type.prose(1.75), ink: palette.dim.watchColor(),
                align: align)
            frames["clock"] = layout.clock.watchFrame
            frames["date"] = layout.date.watchFrame
        }

        if let ribbon = layout.ribbon, face.style.showsHour {
            let small = max(1.6 * layout.unit, 9)
            caption.show(
                Localized.text("The last hour · seen by this Mac"), font: type.prose(1.6, weight: .medium),
                ink: palette.dim.watchColor())
            frames["caption"] = CGRect(x: ribbon.x, y: ribbon.y, width: ribbon.width, height: small * 1.4)
        }

        if wall.tiles.isEmpty, wall.calm != nil {
            calm.show(
                Self.calmWords(wall), font: type.prose(2.4, weight: .medium), ink: palette.dim.watchColor(),
                align: .center)
            frames["calm"] = layout.calmLine.watchFrame
        }
        return frames
    }
}
