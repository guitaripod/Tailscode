import Foundation

extension WallLayout {
    /// The numbers every mode shares, and one function per mode that lays the chrome out in the
    /// safe frame. The grid is returned empty of tiles; `place` fills the cells.
    struct Ground {
        let frame: WallRect
        let unit: Double
        let style: WallStyle
        let drift: (x: Double, y: Double)
        let roomy: Bool
        let fold: WallFold?

        var pad: Double { max(2.2 * unit, 14) }
        var gap: Double { max(1.6 * unit, 9) }
        var ribbonHeight: Double { (roomy ? 14.0 : 8.8) * unit }
        var railHeight: Double { 4.4 * unit }
        var compact: Bool { unit < 6.4 }

        var headSize: Double { max(4.6 * unit, compact ? 20 : 24) }
        var watchSize: Double { max(1.75 * unit, 12) }
        var clockSize: Double { max(6.6 * unit, 30) }
        var dateSize: Double { max(1.75 * unit, 12) }

        func empty(_ x: Double, _ y: Double) -> WallRect { WallRect(x: x, y: y, width: 0, height: 0) }

        func square(centreX: Double, centreY: Double, radius: Double) -> WallRect {
            WallRect(x: centreX - radius, y: centreY - radius, width: 2 * radius, height: 2 * radius)
        }

        func assemble(
            mode: Mode, headline: WallRect, headlineLines: Int, watch: WallRect, watchLines: Int,
            clock: WallRect, alignment: Alignment, date: WallRect, grid: WallRect, gutter: Double,
            ribbon: WallRect?, recent: WallRect?, listed: WallRect?, controls: WallRect?, centre: WallRect,
            calmLine: WallRect, pages: [WallRect] = []
        ) -> WallLayout {
            WallLayout(
                mode: mode, width: 0, height: 0, unit: unit, headline: headline,
                headlineLines: headlineLines, watchLine: watch, watchLines: watchLines, clock: clock,
                clockAlignment: alignment, date: date, grid: grid, tiles: [], squads: [], ribbon: ribbon,
                recentRail: recent, listedRail: listed, controls: controls, centre: centre,
                calmLine: calmLine, pages: pages, gutter: gutter)
        }

        func stack() -> WallLayout {
            let u = unit
            let fw = frame.width
            let portrait = frame.height > fw
            let margin = 3.0 * u
            let showsClock = style.showsClock
            let clockWidth = showsClock ? (portrait ? 27.0 : 30.0) * u : 0
            let topY = frame.y + 2.4 * u + drift.y
            let band = (portrait ? 19.0 : 14.0) * u
            let headlineWidth = max(10 * u, fw - 2 * margin - (showsClock ? clockWidth + 2 * u : 0))
            let left = frame.x + margin + drift.x
            let headline = WallRect(x: left, y: topY, width: headlineWidth, height: band - 4.2 * u)
            let watch = WallRect(x: left, y: headline.maxY + 0.2 * u, width: headlineWidth, height: 3.0 * u)
            let clockX = frame.maxX - margin - clockWidth + drift.x
            let clock = showsClock ? WallRect(x: clockX, y: topY, width: clockWidth, height: 8.4 * u) : empty(clockX, topY)
            let date =
                showsClock
                ? WallRect(x: clockX, y: clock.maxY + 0.2 * u, width: clockWidth, height: 3.0 * u)
                : empty(clockX, topY)

            let bottom = frame.maxY - 1.8 * u + drift.y
            let railsOn = style.showsRails
            let rail = WallRect(
                x: left, y: bottom - railHeight, width: fw - 2 * margin, height: railHeight)
            let ribbonBottom = railsOn ? rail.y - 0.8 * u : bottom
            let ribbon =
                style.showsHour
                ? WallRect(x: left, y: ribbonBottom - ribbonHeight, width: fw - 2 * margin, height: ribbonHeight)
                : nil
            let leftWidth = rail.width * 0.56
            let recent =
                railsOn ? WallRect(x: rail.x, y: rail.y, width: leftWidth - u, height: rail.height) : nil
            let listed =
                railsOn
                ? WallRect(x: rail.x + leftWidth, y: rail.y, width: rail.width - leftWidth, height: rail.height)
                : nil

            let gridTop = max(watch.maxY, date.maxY) + 1.6 * u
            let gridBottom = (ribbon?.y ?? ribbonBottom) - 1.4 * u
            let grid = WallRect(
                x: frame.x + margin, y: gridTop, width: fw - 2 * margin, height: gridBottom - gridTop)
            let side = min(grid.width, grid.height) * 0.62
            let centre = WallRect(
                x: grid.x + (grid.width - side) / 2, y: grid.y + (grid.height - side) / 2, width: side,
                height: side)
            let calmLine = WallRect(x: grid.x, y: centre.maxY - 1.4 * u, width: grid.width, height: 4 * u)
            return assemble(
                mode: .stack, headline: headline, headlineLines: portrait ? 2 : 1, watch: watch,
                watchLines: 1, clock: clock, alignment: .trailing, date: date, grid: grid,
                gutter: 1.2 * u, ribbon: ribbon, recent: recent, listed: listed, controls: nil,
                centre: centre, calmLine: calmLine)
        }

        func side() -> WallLayout {
            let u = unit
            let x0 = frame.x + pad
            let y0 = frame.y + pad
            let x1 = frame.maxX - pad
            let y1 = frame.maxY - pad
            let span = max(0, x1 - x0)
            let column = min(max((span) * 0.33, 170), 330, span * 0.5)
            let clockText = max(clockSize * 1.3, 40)
            let showsClock = style.showsClock
            let clock = showsClock ? WallRect(x: x0, y: y0, width: column, height: clockText * 1.05) : empty(x0, y0)
            let date =
                showsClock
                ? WallRect(x: x0, y: clock.maxY, width: column, height: dateSize * 1.5) : empty(x0, y0)
            let headlineY = showsClock ? date.maxY + gap : y0
            let headText = max(headSize * 0.85, 18)
            let headline = WallRect(x: x0, y: headlineY, width: column, height: headText * 1.1 * 3)
            let watch = WallRect(x: x0, y: headline.maxY, width: column, height: watchSize * 1.4 * 2)
            let ribbon =
                style.showsHour
                ? WallRect(x: x0, y: y1 - ribbonHeight, width: column, height: ribbonHeight) : nil
            let grid = WallRect(
                x: x0 + column + 2 * gap, y: y0, width: x1 - x0 - column - 2 * gap, height: y1 - y0)
            let centre = square(
                centreX: grid.midX, centreY: grid.y + grid.height * 0.42,
                radius: min(grid.width, grid.height) * 0.22)
            let calmLine = WallRect(x: grid.x, y: grid.y + grid.height * 0.78, width: grid.width, height: 4 * u)
            return assemble(
                mode: .side, headline: headline, headlineLines: 3, watch: watch, watchLines: 2,
                clock: clock, alignment: .leading, date: date, grid: grid, gutter: gap, ribbon: ribbon,
                recent: nil, listed: nil, controls: nil, centre: centre, calmLine: calmLine)
        }

        func book() -> WallLayout {
            let u = unit
            let fold = self.fold ?? WallFold(axis: .vertical, from: frame.midX, to: frame.midX)
            let x0 = frame.x + pad
            let y0 = frame.y + pad
            let x1 = frame.maxX - pad
            let y1 = frame.maxY - pad
            let left = WallRect(x: x0, y: y0, width: fold.from - gap - x0, height: y1 - y0)
            let right = WallRect(x: fold.to + gap, y: y0, width: x1 - fold.to - gap, height: y1 - y0)
            let headText = headSize * 0.86
            let headline = WallRect(x: left.x, y: y0, width: left.width, height: headText * 2.2)
            let watch = WallRect(x: left.x, y: headline.maxY, width: left.width, height: watchSize * 1.6)
            let clockText = clockSize * 0.9
            let clockWidth = min(right.width, clockText * 3.4)
            let showsClock = style.showsClock
            let clock =
                showsClock
                ? WallRect(x: right.maxX - clockWidth, y: right.y, width: clockWidth, height: clockText * 1.05)
                : empty(right.maxX, right.y)
            let date =
                showsClock
                ? WallRect(x: clock.x, y: clock.maxY, width: clockWidth, height: dateSize * 1.5)
                : empty(right.maxX, right.y)
            let ribbon =
                style.showsHour
                ? WallRect(x: left.x, y: y1 - ribbonHeight, width: left.width, height: ribbonHeight) : nil
            let recent =
                style.showsRails
                ? WallRect(x: right.x, y: y1 - railHeight, width: right.width, height: railHeight) : nil
            let top = max(watch.maxY, date.maxY) + gap
            let cut = max(
                ribbon == nil ? 0 : ribbonHeight + gap * 1.2, recent == nil ? 0 : railHeight + gap * 1.2)
            let grid = WallRect(x: left.x, y: top, width: right.maxX - left.x, height: y1 - cut - top)
            let centre = square(
                centreX: left.midX, centreY: top + grid.height * 0.45,
                radius: min(left.width, grid.height) * 0.22)
            let calmLine = WallRect(x: right.x, y: centre.midY - 2 * u, width: right.width, height: 4 * u)
            return assemble(
                mode: .book, headline: headline, headlineLines: 2, watch: watch, watchLines: 1,
                clock: clock, alignment: .trailing, date: date, grid: grid, gutter: gap, ribbon: ribbon,
                recent: recent, listed: nil, controls: nil, centre: centre, calmLine: calmLine,
                pages: [left, right])
        }

        func laptop() -> WallLayout {
            let u = unit
            let fold = self.fold ?? WallFold(axis: .horizontal, from: frame.midY, to: frame.midY)
            let x0 = frame.x + pad
            let y0 = frame.y + pad
            let x1 = frame.maxX - pad
            let y1 = frame.maxY - pad
            let upper = WallRect(x: x0, y: y0, width: x1 - x0, height: fold.from - gap - y0)
            let base = WallRect(x: x0, y: fold.to + gap, width: x1 - x0, height: y1 - fold.to - gap)
            let half = base.width * 0.5
            let showsClock = style.showsClock
            let clockText = clockSize * 1.7
            let clock =
                showsClock
                ? WallRect(x: base.x, y: base.y + gap, width: half - gap, height: clockText * 1.15)
                : empty(base.x, base.y + gap)
            let date =
                showsClock
                ? WallRect(x: base.x, y: clock.maxY, width: half - gap, height: dateSize * 1.6)
                : empty(base.x, base.y + gap)
            let headX = showsClock ? base.x + half : base.x
            let headWidth = showsClock ? half : base.width
            let headText = headSize * 0.8
            let headline = WallRect(
                x: headX, y: base.y + gap + clockSize * 0.2, width: headWidth, height: headText * 2.2)
            let watch = WallRect(x: headX, y: headline.maxY, width: headWidth, height: watchSize * 1.4 * 2)
            let belowClock = base.y + gap + clockText * 1.25 + dateSize * 1.6 + gap * 2.2
            let railsY = max(belowClock, watch.maxY + gap)
            let ribbon =
                style.showsHour ? WallRect(x: base.x, y: railsY, width: base.width, height: ribbonHeight) : nil
            let recentY = railsY + (ribbon == nil ? 0 : ribbonHeight + gap * 1.4)
            let recent =
                style.showsRails
                ? WallRect(x: base.x, y: recentY, width: base.width, height: railHeight) : nil
            let stackEnd = recentY + (recent == nil ? 0 : railHeight) + gap * 2
            let controls = WallRect(x: base.x, y: max(stackEnd, y1 - 52), width: base.width, height: 48)
            let centre = square(
                centreX: upper.midX, centreY: upper.y + upper.height * 0.42,
                radius: min(upper.width, upper.height) * 0.2)
            let calmLine = WallRect(x: upper.x, y: upper.y + upper.height * 0.78, width: upper.width, height: 4 * u)
            return assemble(
                mode: .laptop, headline: headline, headlineLines: 2, watch: watch, watchLines: 2,
                clock: clock, alignment: .leading, date: date, grid: upper, gutter: gap, ribbon: ribbon,
                recent: recent, listed: nil, controls: controls, centre: centre, calmLine: calmLine)
        }
    }
}
