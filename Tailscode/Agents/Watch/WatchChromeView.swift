import TailscodeCore
import UIKit

/// The words that frame the wall: the situation in the largest type on the screen, what is watched
/// under it, the clock and the date, the caption over the hour ribbon, and the calm line when
/// nothing runs. Each sits in the rectangle Core's layout gave it.
@MainActor
final class WatchChromeView: UIView {
    let headline = WatchLabel()
    let watch = WatchLabel()
    let clock = WatchLabel()
    let date = WatchLabel()
    let caption = WatchLabel()
    let captionEnd = WatchLabel()
    let calm = WatchLabel()
    let rails = WatchRailView()

    private let timeFormat = DateFormatter()
    private let dateFormat = DateFormatter()
    private var lastLocale = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        timeFormat.timeStyle = .short
        timeFormat.dateStyle = .none
        for label in [headline, watch, clock, date, caption, captionEnd, calm, rails] { addSubview(label) }
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ context: WatchWordsContext) {
        applyHeadline(context)
        applyClock(context)
        applyRibbon(context)
        applyCalm(context)
        rails.frame = bounds
        rails.apply(context)
    }

    func tick(_ context: WatchWordsContext) {
        applyClock(context)
        applyRibbon(context)
        applyWatchLine(context)
    }

    private func applyHeadline(_ context: WatchWordsContext) {
        let layout = context.layout
        let wall = context.wall
        let ink = context.palette.mood(wall.mood, hasFailure: wall.hasFailure).color()
        let rect = layout.headline.cgRect
        let lines = max(1, layout.headlineLines)
        var size = context.scale.type(5.0, floor: 20)
        let floor: CGFloat = 17
        headline.set(wall.headline, font: WatchFont.text(size, .semibold), ink: ink, lines: 0)
        while size > floor {
            let height = headline.height(forWidth: rect.width)
            if height <= min(rect.height, CGFloat(lines) * headline.lineHeight) + 1 { break }
            size = max(floor, size * 0.92)
            headline.font = WatchFont.text(size, .semibold)
        }
        headline.numberOfLines = lines
        let used = min(rect.height, headline.height(forWidth: rect.width))
        headline.frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(used, headline.lineHeight)).rounded()
        applyWatchLine(context)
    }

    /// What is watched, and by whom. On a screen too narrow for all of it the machines and the
    /// sub-agents go first and "seen by this iPhone", which is what keeps the wall honest, never does.
    private func applyWatchLine(_ context: WatchWordsContext) {
        let layout = context.layout
        let wall = context.wall
        let seen = DeviceWord.isPad
            ? String(localized: "seen by this iPad") : String(localized: "seen by this iPhone")
        let battery = context.batteryHeld ? [String(localized: "screen may sleep: battery is low")] : []
        var full = [wall.watchLine]
        if let agents = wall.subagentsLine { full.append(agents) }
        let candidates = [full + [seen] + battery, [wall.watchLine, seen] + battery, [seen] + battery]
        let rect = layout.watchLine.cgRect
        let lines = max(1, layout.watchLines)
        let size = max(12, min(context.scale.type(1.75, floor: 12), rect.height / CGFloat(lines) / 1.2))
        let font = WatchFont.text(size)
        let ink = context.palette.dim.color()
        var chosen = candidates[candidates.count - 1]
        for candidate in candidates {
            watch.set(candidate.joined(separator: " · "), font: font, ink: ink, lines: 0)
            if watch.height(forWidth: rect.width) <= CGFloat(lines) * watch.lineHeight + 1 {
                chosen = candidate
                break
            }
        }
        watch.set(chosen.joined(separator: " · "), font: font, ink: ink, lines: lines)
        watch.frame = rect.rounded()
    }

    private func applyClock(_ context: WatchWordsContext) {
        let layout = context.layout
        let shows = context.style.showsClock && layout.clock.width > 0
        clock.isHidden = !shows
        date.isHidden = !shows
        guard shows else { return }
        let locale = Locale.current.identifier
        if locale != lastLocale {
            lastLocale = locale
            dateFormat.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        }
        let alignment: NSTextAlignment = layout.clockAlignment == .trailing ? .right : .left
        let clockRect = layout.clock.cgRect
        let clockSize = min(context.scale.type(7.2, floor: 28), clockRect.height / 1.18)
        clock.set(
            timeFormat.string(from: context.now), font: WatchFont.digits(clockSize, .light),
            ink: context.palette.text.color(), lines: 1, alignment: alignment)
        clock.frame = clockRect.rounded()
        let dateRect = layout.date.cgRect
        let dateSize = min(context.scale.type(1.75, floor: 12), max(11, dateRect.height / 1.25))
        date.set(
            dateFormat.string(from: context.now), font: WatchFont.text(dateSize),
            ink: context.palette.dim.color(), lines: 1, alignment: alignment)
        date.frame = dateRect.rounded()
    }

    private func applyRibbon(_ context: WatchWordsContext) {
        guard context.style.showsHour, let rect = context.layout.ribbon, rect.width > 0 else {
            caption.isHidden = true
            captionEnd.isHidden = true
            return
        }
        caption.isHidden = false
        captionEnd.isHidden = false
        let unit = CGFloat(context.layout.unit)
        let small = max(1.6 * unit, 9)
        let size = max(11, min(small, context.scale.type(1.5, floor: 11)))
        let font = WatchFont.text(size, .semibold)
        let device = DeviceWord.isPad
            ? String(localized: "seen by this iPad") : String(localized: "seen by this iPhone")
        let words = (String(localized: "The last hour") + " · " + device).uppercased()
        let height = max(small * 1.4, ceil(font.lineHeight))
        caption.set(words, font: font, ink: context.palette.dim.color(0.9))
        caption.frame = CGRect(x: rect.x, y: rect.y, width: rect.width * 0.8, height: height).rounded()
        captionEnd.set(
            String(localized: "now").uppercased(), font: font, ink: context.palette.working.color(),
            lines: 1, alignment: .right)
        captionEnd.frame = CGRect(x: rect.maxX - 88, y: rect.y, width: 80, height: height).rounded()
    }

    private func applyCalm(_ context: WatchWordsContext) {
        let wall = context.wall
        guard wall.tiles.isEmpty, let summary = wall.calm else {
            calm.isHidden = true
            return
        }
        calm.isHidden = false
        let device = DeviceWord.isPad
            ? String(localized: "seen by this iPad") : String(localized: "seen by this iPhone")
        let rect = context.layout.calmLine.cgRect
        let size = max(12, min(context.scale.type(2.4, floor: 13), rect.height / 1.4))
        calm.set(
            summary.line + " · " + device, font: WatchFont.text(size), ink: context.palette.dim.color(),
            lines: 2, alignment: .center)
        calm.frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(rect.height, size * 2.6)).rounded()
    }
}
