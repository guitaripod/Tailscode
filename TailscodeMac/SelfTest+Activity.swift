import AgentTestSupport
import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// Every clock in this client that moves on its own, read for the one property a picture of the
    /// window cannot carry: the rate.
    ///
    /// A mark drawn at a hundred and twenty and the same mark drawn at thirty are the same
    /// screenshot, so the tempo is proved off the objects themselves — the range every clock this
    /// app drives by hand asks its display for, the two laps the render server keeps for the aura,
    /// the shader the orb is drawn by, and the transcript's one indeterminate bar, which is this
    /// client's own rather than AppKit's exactly so that there is a rate to read at all.
    static func checkActivityTempo() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("activity tempo case failed: \(label)") }
            checks += 1
        }
        let tempo = CAFrameRateRange.activityTempo
        try expect(
            tempo.preferred == Float(ActivityTuning.frameRate)
                && tempo.maximum == Float(ActivityTuning.frameRate)
                && tempo.minimum == Float(ActivityTuning.minimumFrameRate),
            "the tempo is the vocabulary's rate and floor, never a number this client chose")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        let moving = ActivityPulse.motionAllowed

        let bar = ActivitySweepBar(tint: MacTheme.Color.accent)
        bar.frame = NSRect(x: 0, y: 0, width: 320, height: 4)
        window.contentView?.addSubview(bar)
        try expect(
            (bar.travel != nil) == moving,
            "the transcript's one bar travels, and holds perfectly still under reduced motion")
        try expect(
            bar.travel.map { $0.preferredFrameRateRange == tempo } ?? true,
            "at the tempo, rather than at whatever AppKit draws its own indeterminate bar at")
        bar.removeFromSuperview()

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 44))
        window.contentView?.addSubview(host)
        let aura = UltracodeAura(around: host, cornerRadius: 10)
        aura.setActive(true)
        try expect(
            aura.laps.count == (moving ? 2 : 0),
            "the aura turns and breathes while the power is on, and does neither when motion is off")
        try expect(
            aura.laps.allSatisfy { $0.preferredFrameRateRange == tempo },
            "both laps at the tempo, because a lap the render server keeps is still this app moving")
        aura.setActive(false)

        try expect(
            PresenceOrbView().frameRate == Int(ActivityTuning.frameRate),
            "and the creature at the foot of the sidebar is drawn at it, not at the panel's rate")

        let badge = ActivityBadgeView(pointSize: 11)
        badge.frame = NSRect(x: 0, y: 60, width: 16, height: 16)
        window.contentView?.addSubview(badge)
        badge.show(ActivityIcon(symbol: "terminal", glyph: "•", tone: .live, motion: .working), spoken: nil)
        let breath = badge.symbolLayer?.animation(forKey: "pulse.light")
        try expect(
            (breath != nil) == moving && breath.map { $0.preferredFrameRateRange == tempo } ?? true,
            "a breathing badge's light is a lap the render server keeps, at the tempo")
        badge.show(ActivityIcon(symbol: "gearshape", glyph: "◐", tone: .live, motion: .turning), spoken: nil)
        try expect(
            (badge.symbolLayer?.animation(forKey: "pulse.turn") != nil) == moving
                && badge.symbolLayer?.animation(forKey: "pulse.light") == nil,
            "a sweeping badge turns its symbol's layer rather than drawing it again every frame")
        try expect(
            badge.symbolLayer.map { $0.anchorPoint == CGPoint(x: 0.5, y: 0.5) } ?? false,
            "about its centre, so the symbol turns in place rather than orbiting its corner")
        badge.show(ActivityIcon(symbol: "checkmark", glyph: "✓", tone: .quiet, motion: .still), spoken: nil)
        try expect(!badge.isMoving, "and a settled badge carries nothing that moves")
        badge.removeFromSuperview()

        let card = PendingCards.compacting(startedAt: Date(), waiting: false) { _ in }
        guard let carried = sweepBar(in: card) else {
            throw SelfTestFailure(
                "activity tempo case failed: the compacting card carries this client's own bar")
        }
        try expect(
            carried.intrinsicContentSize.height > 0,
            "the compacting card's bar is a body rather than a line nobody can see")
        try expect(
            systemIndicator(in: card) == nil,
            "and is the only bar on it, because AppKit's own is drawn at a tempo nothing can read")
        try expect(
            SessionRowState.background(tasks: 1).activity == .inBackground(tasks: 1)
                && SessionRowState.background(tasks: 1).isInFlight
                && ActivityKind.inBackground(tasks: 1).icon.motion.isAnimated,
            "work a process carries between turns reads as work, sits with the live rows, and breathes")
        try expect(
            SessionRowState.stalled(tasks: 1).activity == .stalled(tasks: 1)
                && SessionRowState.stalled(tasks: 1).isInFlight
                && SessionRowState.stalled(tasks: 1).carriesBackgroundWork
                && ActivityKind.stalled(tasks: 1).icon.tone == .attention
                && !ActivityKind.stalled(tasks: 1).icon.motion.isAnimated,
            "work the server found stuck stays with the live rows, wears attention, and holds still")
        return checks
    }

    /// Every motion in this client that never ends on its own, proved to ask the desk again rather
    /// than only once.
    ///
    /// A guard read where an animation is created answers the question at that instant and never
    /// afterwards, and the question stays open for exactly as long as the lap does — which is the
    /// whole defect: a ring lit when a tier was picked turns for the rest of the conversation under
    /// a preference changed a minute later, and a desk that allows movement back is never given it.
    /// So the claim is made the only way a running app can make it. The laps are stripped off the
    /// layers by hand, `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` is posted,
    /// and nothing but an observer could have put them back.
    ///
    /// The road itself is proved first, because two callers agreeing means nothing if what they
    /// agree through is wrong: `setRepeatingMotion` lays a lap on exactly when the desk allows
    /// movement, at the vocabulary's tempo, never stacks a second on the first, and refuses a
    /// meaning the vocabulary calls still whatever the desk allows.
    static func checkRepeatingMotion() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else {
                throw SelfTestFailure("repeating motion case failed: \(label)")
            }
            checks += 1
        }
        let moving = ActivityPulse.motionAllowed
        let tempo = CAFrameRateRange.activityTempo
        func mindChanged() {
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
        func lap() -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 0.4
            animation.duration = 1
            animation.repeatCount = .infinity
            return animation
        }

        let layer = CALayer()
        layer.setRepeatingMotion(lap(), forKey: "lap")
        try expect(
            (layer.animation(forKey: "lap") != nil) == moving,
            "the road lays a lap on when the desk allows movement, and none when it does not")
        try expect(
            layer.animation(forKey: "lap").map { $0.preferredFrameRateRange == tempo } ?? true,
            "at the vocabulary's tempo rather than at whatever the panel happens to offer")
        layer.setRepeatingMotion(lap(), forKey: "lap")
        try expect(
            (layer.animationKeys() ?? []).filter { $0 == "lap" }.count == (moving ? 1 : 0),
            "and asked twice it replaces the lap rather than stacking a second on top of it")
        layer.setRepeatingMotion(lap(), forKey: "lap", meaning: .still)
        try expect(
            layer.animation(forKey: "lap") == nil,
            "a meaning the vocabulary calls still never moves, whatever the desk allows")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 44))
        window.contentView?.addSubview(host)
        let aura = UltracodeAura(around: host, cornerRadius: 10)
        aura.setActive(true)
        try expect(
            aura.laps.count == (moving ? 2 : 0),
            "the aura's two laps are on while the power is, and off while the desk asks for less")
        stripLaps(from: host)
        try expect(aura.laps.isEmpty, "stripped by hand there is nothing left turning")
        mindChanged()
        try expect(
            aura.laps.count == (moving ? 2 : 0),
            "and a desk changing its mind lays them again — the ring asks for a whole conversation")
        aura.setActive(false)
        stripLaps(from: host)
        mindChanged()
        try expect(
            aura.laps.isEmpty,
            "an aura whose power is off stays dark through the change, having no fact to draw")
        host.removeFromSuperview()

        let bar = ActivitySweepBar(tint: MacTheme.Color.accent)
        bar.frame = NSRect(x: 0, y: 0, width: 320, height: 4)
        window.contentView?.addSubview(bar)
        try expect(
            (bar.travel != nil) == moving,
            "the transcript's one bar travels while the step it sits under is still running")
        stripLaps(from: bar)
        try expect(bar.travel == nil, "stripped by hand it holds perfectly still")
        mindChanged()
        try expect(
            (bar.travel != nil) == moving,
            "and the same change lays the travel again over a summarize that has minutes to go")
        bar.removeFromSuperview()

        let orb = PresenceOrbView()
        orb.frame = NSRect(x: 0, y: 0, width: 44, height: 44)
        window.contentView?.addSubview(orb)
        orb.setEnabled(false)
        orb.isHidden = false
        try expect(
            !orb.isDrawing,
            "a creature standing in the sidebar with its clock stopped is exactly what a settled"
                + " frame under reduced motion leaves behind")
        mindChanged()
        try expect(
            orb.isDrawing,
            "and a desk changing its mind starts it again, so allowing movement back gets a body"
                + " that breathes rather than one frozen mid-breath")
        orb.setEnabled(false)
        mindChanged()
        try expect(
            !orb.isDrawing,
            "while the same change never wakes a creature the setting itself switched off")
        orb.removeFromSuperview()
        return checks
    }

    /// Takes every lap off a view's whole layer tree, mask included, so that a claim about
    /// something putting one back is a claim about the road that lays it rather than about the lap
    /// that was already there. Nothing in the app removes an animation from outside the view that
    /// owns it; this is the harness taking the picture apart to prove it can be rebuilt.
    private static func stripLaps(from view: NSView) {
        func strip(_ layer: CALayer) {
            layer.removeAllAnimations()
            if let mask = layer.mask { strip(mask) }
            for sublayer in layer.sublayers ?? [] { strip(sublayer) }
        }
        if let layer = view.layer { strip(layer) }
        for child in view.subviews { stripLaps(from: child) }
    }

    private static func sweepBar(in view: NSView) -> ActivitySweepBar? {
        if let bar = view as? ActivitySweepBar { return bar }
        for child in view.subviews {
            if let found = sweepBar(in: child) { return found }
        }
        return nil
    }

    static func markLabel(in view: NSView) -> ActivityMarkLabel? {
        if let label = view as? ActivityMarkLabel { return label }
        guard let row = view as? DisclosureRow, let header = row.headerView else { return nil }
        return header.subviews.compactMap { $0 as? ActivityMarkLabel }.first
    }
}
