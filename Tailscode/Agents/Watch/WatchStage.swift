import QuartzCore
import TailscodeCore
import UIKit

/// Where the wall is drawn and what the screen keeps for itself: the size, the insets and the fold,
/// read fresh on every layout pass.
struct WatchGeometry: Equatable {
    var size: CGSize
    var safe: WallInsets
    var fold: WallFold?

    var isUsable: Bool { size.width >= 8 && size.height >= 8 }
}

/// Everything the wall draws that is not words: the layout it has now and the one it came from while
/// the tiles morph, the effects and the field, the hold under a finger, how dim it is, and the one
/// scene a frame is made from. Nothing here allocates per frame beyond the scene's own arrays.
@MainActor
final class WatchStage {
    static let morphLasts: TimeInterval = 0.6
    static let holdLasts: TimeInterval = 0.8
    static let wakeLasts: TimeInterval = 1
    static let sleepLasts: TimeInterval = 3
    static let departedLasts: TimeInterval = 1.5
    static let slideLasts: TimeInterval = 0.45

    struct Morph {
        let wall: AgentWall
        let layout: WallLayout
        let start: TimeInterval
    }

    struct Dimming {
        var from = 0.0
        var to = 0.0
        var start: TimeInterval = -100
        var lasts: TimeInterval = 1
    }

    struct Held {
        var tile: String
        var point: CGPoint
        var start: TimeInterval
    }

    var effects: () -> [WallEffect] = { [] }
    var beatShiftedAt: () -> TimeInterval = { -100 }
    var peeking = false
    var animated = true

    private(set) var style: WallStyle
    private(set) var palette: WallPalette
    private(set) var wall = AgentWall.empty
    private(set) var layout: WallLayout
    private(set) var geometry: WatchGeometry?
    private(set) var ribbon: WallRibbon?
    private(set) var held: Held?
    private(set) var morph: Morph?
    private(set) var lastActivity = Date()

    private var motes: WallMotes
    private var lastFrame: TimeInterval?
    private var departed: [String: (rect: WallRect, until: TimeInterval)] = [:]
    private var dimming = Dimming()
    private var calmSince: Date?
    private var forcedDim = false

    init(style: WallStyle) {
        self.style = style
        palette = WallPalette.current(theme: ThemeSelection.theme)
        layout = WallLayout.make(
            width: 1, height: 1, safe: .zero, fold: nil, wall: .empty, style: style)
        motes = WallMotes(width: 1, height: 1, seed: 7_041_977)
    }

    func apply(style next: WallStyle, now: Date) {
        style = next
        refreshPalette(now: now)
    }

    func refreshPalette(now: Date) {
        let base = WallPalette.current(theme: ThemeSelection.theme)
        palette = style.isNight(at: now) ? base.night() : base
    }

    func apply(hour: AgentHour?, now: Date) {
        ribbon = style.showsHour ? WallRibbon.read(hour, now: now) : nil
    }

    func shape(for geometry: WatchGeometry) -> WatchShape {
        let reading = WallLayout.reading(
            width: Double(geometry.size.width), height: Double(geometry.size.height), safe: geometry.safe,
            fold: geometry.fold, style: style)
        return WatchShape(aspect: reading.aspect, gridAspect: reading.gridAspect, pages: reading.pages)
    }

    /// The burn-in drift of the static chrome: up to six points round a ten-minute loop, still when
    /// nothing may move.
    private func drift(at now: Date) -> (x: Double, y: Double) {
        guard animated, !style.still else { return (0, 0) }
        let phase = 2 * Double.pi * now.timeIntervalSince1970.truncatingRemainder(dividingBy: 600) / 600
        return ((sin(phase) * 6 * 4).rounded() / 4, (cos(phase) * 6 * 4).rounded() / 4)
    }

    /// Takes a new reading and the screen it is laid out on. Answers whether the tiles are moving
    /// from where they were to somewhere else, which starts the morph.
    @discardableResult
    func adopt(_ read: WatchRead, geometry next: WatchGeometry, now: Date, at t: TimeInterval) -> Bool {
        let old = (wall: wall, layout: layout)
        let had = geometry != nil
        let made = WallLayout.make(
            width: Double(next.size.width), height: Double(next.size.height), safe: next.safe,
            fold: next.fold, wall: read.wall, style: style, drift: drift(at: now))
        for event in read.events where event.kind == .left {
            guard let index = old.wall.tiles.firstIndex(where: { $0.id == event.tile }),
                index < old.layout.tiles.count
            else { continue }
            departed[event.tile] = (old.layout.tiles[index], t + Self.departedLasts)
        }
        var began = false
        if had, animated, !style.still, Self.moved(from: (old.wall, old.layout), to: (read.wall, made)) {
            morph = Morph(wall: old.wall, layout: old.layout, start: t)
            began = true
        }
        wall = read.wall
        layout = made
        geometry = next
        if motes.count != WallMotes.count(width: made.width, height: made.height) {
            motes = WallMotes(width: made.width, height: made.height, seed: 7_041_977)
        }
        if !read.events.isEmpty { noteActivity(at: t) }
        refreshDim(now: now, at: t)
        return began
    }

    private static func moved(
        from old: (wall: AgentWall, layout: WallLayout), to next: (wall: AgentWall, layout: WallLayout)
    ) -> Bool {
        for (index, tile) in next.wall.tiles.enumerated() where index < next.layout.tiles.count {
            guard let before = old.wall.tiles.firstIndex(where: { $0.id == tile.id }),
                before < old.layout.tiles.count
            else { continue }
            let a = old.layout.tiles[before]
            let b = next.layout.tiles[index]
            if abs(a.x - b.x) > 1 || abs(a.y - b.y) > 1 || abs(a.width - b.width) > 1
                || abs(a.height - b.height) > 1
            {
                return true
            }
        }
        return false
    }

    func isMorphing(at t: TimeInterval) -> Bool {
        guard let morph else { return false }
        return t - morph.start < Self.morphLasts
    }

    func dim(at t: TimeInterval) -> Double {
        let progress = dimming.lasts > 0 ? min(1, max(0, (t - dimming.start) / dimming.lasts)) : 1
        let eased = progress * progress * (3 - 2 * progress)
        return dimming.from + (dimming.to - dimming.from) * eased
    }

    func isDimming(at t: TimeInterval) -> Bool { t - dimming.start < dimming.lasts }

    var dimTarget: Double { dimming.to }

    private func setDim(_ target: Double, at t: TimeInterval) {
        guard dimming.to != target else { return }
        dimming = Dimming(
            from: dim(at: t), to: target, start: t,
            lasts: target > dimming.to ? Self.sleepLasts : Self.wakeLasts)
    }

    func noteActivity(at t: TimeInterval) {
        forcedDim = false
        lastActivity = Date()
        calmSince = wall.isCalm ? (calmSince ?? lastActivity) : nil
        setDim(0, at: t)
    }

    /// Dims once the wall has been calm for as long as the style waits, and wakes the moment it is
    /// not calm.
    func refreshDim(now: Date, at t: TimeInterval) {
        if forcedDim {
            setDim(1, at: t)
            return
        }
        guard wall.isCalm, let after = style.dimAfter else {
            calmSince = nil
            setDim(0, at: t)
            return
        }
        let since = calmSince ?? now
        calmSince = since
        if now.timeIntervalSince(max(since, lastActivity)) >= after { setDim(1, at: t) }
    }

    func dimNow(at t: TimeInterval) {
        forcedDim = true
        setDim(1, at: t)
    }

    var dimLasts: TimeInterval { dimming.lasts }

    func isDimmedCalm(at t: TimeInterval) -> Bool { dim(at: t) >= 0.99 && wall.isCalm }

    /// Where the words' brightness is heading: the ground's own dimming, and lower under a peek.
    var wordsTarget: CGFloat { CGFloat((1 - 0.6 * dimTarget) * (peeking ? 0.45 : 1)) }

    /// The brightness the words are drawn at, the same the scene multiplies the ground by.
    func wordsAlpha(at t: TimeInterval) -> CGFloat {
        CGFloat((1 - 0.6 * dim(at: t)) * (peeking ? 0.45 : 1))
    }

    var breathes: Bool {
        wall.tiles.contains { tile in
            switch tile.state {
            case .finished, .away: return false
            default: return true
            }
        }
    }

    func beginHold(tile: String, at point: CGPoint, t: TimeInterval) {
        held = Held(tile: tile, point: point, start: t)
    }

    func moveHold(to point: CGPoint) { held?.point = point }

    func endHold() { held = nil }

    func holdProgress(at t: TimeInterval) -> Double? {
        guard let held else { return nil }
        return min(1, max(0, (t - held.start) / Self.holdLasts))
    }

    private func wallHold(at t: TimeInterval) -> WallHold? {
        guard let held, let progress = holdProgress(at: t) else { return nil }
        return WallHold(tile: held.tile, x: held.point.x, y: held.point.y, progress: progress)
    }

    private func needsTarget() -> (x: Double, y: Double)? {
        guard let index = wall.tiles.firstIndex(where: { $0.state.isNeedsYou }),
            index < layout.tiles.count, layout.width > 0, layout.height > 0
        else { return nil }
        let rect = layout.tiles[index]
        return (rect.midX / layout.width, rect.midY / layout.height)
    }

    private func advance(_ t: TimeInterval) {
        defer { lastFrame = t }
        guard let lastFrame else { return }
        let dt = min(0.25, max(0, t - lastFrame))
        let info = ProcessInfo.processInfo
        let thermal = WatchPower.thermal(info.thermalState)
        guard WallCadence.fieldRuns(lowPower: info.isLowPowerModeEnabled, thermal: thermal, style: style),
            animated
        else { return }
        let aspect = layout.height > 0 ? layout.width / layout.height : 1
        motes.step(
            dt: dt, mood: wall.mood, target: needsTarget(), slow: 1 - 0.5 * dim(at: t), aspect: aspect)
    }

    private func slide(at t: TimeInterval) -> Double {
        let since = t - beatShiftedAt()
        guard since >= 0, since < Self.slideLasts else { return 0 }
        let x = since / Self.slideLasts
        return 1 - x * x * (3 - 2 * x)
    }

    private func input(
        _ wall: AgentWall, _ layout: WallLayout, t: TimeInterval, now: Date
    ) -> WallSceneInput {
        WallSceneInput(
            wall: wall, layout: layout, palette: palette, style: style, t: t, now: now, effects: effects(),
            motes: motes, ribbon: ribbon, hold: wallHold(at: t), dim: dim(at: t), peeking: peeking,
            animated: animated && !style.still, beatSlide: slide(at: t),
            departed: departed.mapValues { $0.rect })
    }

    /// One frame. While tiles move, the layout it is drawn from is Core's in-between of the one the
    /// tiles came from and the one they are going to, so a glass plate, its glyph, its light and
    /// the effects on it all travel together on an ease-out.
    func scene(at t: TimeInterval) -> WallScene? {
        guard geometry != nil else { return nil }
        advance(t)
        departed = departed.filter { $0.value.until > t }
        let now = Date()
        guard let morph else { return WallScene.build(input(wall, layout, t: t, now: now)) }
        let progress = (t - morph.start) / Self.morphLasts
        guard progress < 1 else {
            self.morph = nil
            return WallScene.build(input(wall, layout, t: t, now: now))
        }
        let eased = 1 - pow(1 - max(0, progress), 3)
        let between = layout.morphed(
            from: morph.layout, oldIDs: morph.wall.tiles.map(\.id), newIDs: wall.tiles.map(\.id),
            progress: eased)
        return WallScene.build(input(wall, between, t: t, now: now))
    }
}
