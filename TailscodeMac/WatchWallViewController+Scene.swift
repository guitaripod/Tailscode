import AppKit
import QuartzCore
import TailscodeCore
import TailscodeMetal

extension WatchWallViewController {
    /// One frame, asked for by the Metal view with the clock the effects started on: the field and the
    /// dim stepped by the real time since the last frame, the scene Core builds for this layout, and
    /// while the wall is moving from one layout to the next, the mix of that scene with the one the
    /// person was looking at. Nothing here reads the board or measures a word.
    func provideScene(at t: TimeInterval) -> WallScene? {
        guard let layout, isActive || fixedWall != nil else { return nil }
        let now = Date()
        let dt = min(0.1, max(0, t - lastFrame))
        lastFrame = t
        stepMotes(dt: dt, layout: layout)
        dimmer.step(dt: dt, at: now, after: style.dimAfter, animated: animated)
        effects.prune(at: t)
        var scene = WallScene.build(sceneInput(layout, t: t, now: now))
        if let moving = tween {
            let progress = (t - moving.start) / WatchSceneBlend.duration
            if progress >= 1 {
                tween = nil
                words.settle()
            } else {
                scene = WatchSceneBlend.mixed(from: moving.from, to: scene, progress)
                words.glide(WatchSceneBlend.easeOut(progress))
            }
        }
        lastScene = scene
        let animating = scene.isAnimating || tween != nil || slideStart != nil
        if animating != lastAnimating {
            lastAnimating = animating
            DispatchQueue.main.async { [weak self] in MainThread.call { self?.applyCadence() } }
        }
        return scene
    }

    func sceneInput(_ layout: WallLayout, t: TimeInterval, now: Date) -> WallSceneInput {
        WallSceneInput(
            wall: wall, layout: layout, palette: palette, style: effectiveStyle, t: t, now: now,
            effects: effects.live, motes: motes, ribbon: ribbon, hold: holdValue(at: t),
            dim: dimmer.amount, peeking: isPeeking, animated: animated, beatSlide: beatSlide(at: t),
            departed: effects.departed(at: t))
    }

    func holdValue(at t: TimeInterval) -> WallHold? {
        guard hold.isHolding, let tile = hold.tile else { return nil }
        return WallHold(
            tile: tile, x: Double(hold.point.x), y: Double(hold.point.y), progress: hold.progress(at: t))
    }

    private func beatSlide(at t: TimeInterval) -> Double {
        guard let start = slideStart, animated else {
            slideStart = nil
            return 0
        }
        let progress = (t - start) / 0.45
        guard progress < 1 else {
            slideStart = nil
            return 0
        }
        return 1 - progress * progress * (3 - 2 * progress)
    }

    private func stepMotes(dt: Double, layout: WallLayout) {
        guard animated, WallCadence.fieldRuns(lowPower: lowPower, thermal: thermal, style: style) else { return }
        motes.step(
            dt: dt, mood: wall.mood, target: attentionPoint(layout), slow: 1 - 0.6 * dimmer.amount,
            aspect: Double(size.width / max(1, size.height)))
    }

    /// Where the first ask stands, as fractions of the wall, so the field leans toward it.
    func attentionPoint(_ layout: WallLayout) -> (x: Double, y: Double)? {
        guard let index = wall.tiles.firstIndex(where: { $0.state.isNeedsYou }), layout.tiles.indices.contains(index),
            layout.width > 1, layout.height > 1
        else { return nil }
        let rect = layout.tiles[index]
        return (rect.midX / layout.width, rect.midY / layout.height)
    }

    var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    var thermal: WallCadence.Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    var proMotion: Bool { (root.window?.screen?.maximumFramesPerSecond ?? 60) > 60 }

    /// Whether nobody can see the wall: its window is covered or off screen or minimised, or the app
    /// is hidden. The wall keeps drawing for a person who is working in another app on another
    /// screen, so an app that is merely not in front is not hidden.
    func isHiddenNow() -> Bool {
        if let hiddenProbe { return hiddenProbe() }
        guard let window = root.window else { return true }
        if DisplayGate.assumesVisible { return false }
        return !window.occlusionState.contains(.visible) || window.isMiniaturized || NSApp.isHidden
    }

    static func breathes(_ tile: WallTile) -> Bool {
        switch tile.state {
        case .working, .thinking, .needsYou, .retrying: return true
        case .background(let stuck): return !stuck
        case .quiet, .finished, .away: return false
        }
    }

    /// Whether the dim is still easing toward where it is going, which needs frames to get there.
    var isDimming: Bool {
        let target = dimmer.isDimmed(at: Date(), after: style.dimAfter) ? 1.0 : 0.0
        return dimmer.amount != target
    }

    /// The most frames a second the wall may draw now: Core's function, every client's cap.
    func frameCap(at t: TimeInterval = CACurrentMediaTime()) -> Int {
        let effectsLive =
            effects.isActive(at: t) || hold.isHolding || tween != nil || slideStart != nil || isDimming
        let fieldRuns = animated && WallCadence.fieldRuns(lowPower: lowPower, thermal: thermal, style: style)
        let breathing = animated && (fieldRuns || wall.tiles.isEmpty || wall.tiles.contains(where: Self.breathes))
        return WallCadence.cap(
            effectsLive: effectsLive, breathing: breathing, dimmedCalm: wall.isCalm && dimmer.amount >= 0.99,
            hidden: isHiddenNow(), lowPower: lowPower, thermal: thermal, proMotion: proMotion)
    }

    /// Gives the Metal view its rate. Called whenever something that decides it changes and once a
    /// second, so a window that is covered stops drawing and one that is uncovered starts again.
    func applyCadence() {
        let running = (isActive || fixedWall != nil) && isLive
        let wanted = running ? frameCap() : 0
        appliedCap = wanted
        metal?.framesPerSecond = wanted
        if running, thermal == .critical, !isHiddenNow() {
            if !drewCritical { metal?.drawOnce() }
            drewCritical = true
        } else {
            drewCritical = false
        }
    }
}
