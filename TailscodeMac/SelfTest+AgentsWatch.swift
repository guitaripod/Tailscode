import AppKit
import CodingAgentKit
import QuartzCore
import TailscodeCore

/// What `--selftest` holds the Watch wall to with no server: the Metal view exists and a scene builds
/// on every fictional wall, every tile and worker has words inside its own cell and nothing in them
/// leaves the tile, a command is shown whole with its answers, the frame cap is nothing when the
/// window is covered, a style survives the preferences, and a hold, a dim and a gesture behave as
/// Core and the design say.
extension AgentsChecks {
    static func theWatchWallDraws(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        let controller = AgentsFixtures.controller(feed, mode: .watch)
        controller.startWatching()
        await AgentsFixtures.settle(controller)
        let wall = controller.wall
        try expect(controller.mode == .watch, "the window opens on the wall")
        try expect(wall.isActive && wall.isLive, "and the wall is the lens in use")
        try expect(wall.metal != nil, "the Metal view exists")
        try expect(wall.size.width > 400, "the wall fills the content")
        let faults = AgentsFixtures.problems(in: wall.root, label: "wall")
        try expect(faults.isEmpty, "the wall's words leave nothing ambiguous: \(faults.prefix(3))")
        wall.metal?.drawOnce()
        try expect(wall.lastScene != nil, "the Metal view asks for a scene when it draws")
        for (name, scene) in AgentDemo.wallScenes(now: Date()) {
            wall.show(demo: scene)
            guard let layout = wall.layout else { throw SelfTestFailure("agents: \(name) has a layout") }
            try expect(wall.provideScene(at: CACurrentMediaTime()) != nil, "\(name): a scene builds")
            try expect(layout.tiles.count == wall.wall.tiles.count, "\(name): a cell for each tile")
            for (index, tile) in wall.wall.tiles.enumerated() {
                guard let view = wall.words.tileView(tile.id) else {
                    throw SelfTestFailure("agents: \(name) has words for \(tile.title)")
                }
                let cell = layout.tiles[index].watchFrame.insetBy(dx: -0.5, dy: -0.5)
                try expect(!view.isHidden && cell.contains(view.frame), "\(name): \(tile.title)'s words lie in its cell")
                try expect(!view.titleLabel.text.isEmpty, "\(name): \(tile.title) says its title")
                for sub in view.subviews where !sub.isHidden {
                    try expect(
                        view.bounds.insetBy(dx: -1.5, dy: -1.5).contains(sub.frame),
                        "\(name): \(tile.title): \(type(of: sub)) at \(sub.frame) stays in a tile of \(view.bounds.size)")
                }
                if let squad = index < layout.squads.count ? layout.squads[index] : nil {
                    for (slot, rect) in squad.slots.enumerated() where slot < tile.workers.count {
                        let worker = wall.words.workers[tile.workers[slot].id]
                        try expect(
                            worker.map { rect.watchFrame.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) } == true,
                            "\(name): a sub-agent of \(tile.title) lies in its slot")
                    }
                }
            }
        }
        controller.stopWatching()
    }

    static func theWallGlidesToANewSize(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        let controller = AgentsFixtures.controller(feed, mode: .watch)
        controller.startWatching()
        await AgentsFixtures.settle(controller)
        let wall = controller.wall
        guard wall.animated else { return }
        let busy = AgentDemo.wallScenes(now: Date()).first { $0.name == "busy" }?.wall
        wall.show(demo: busy)
        let t = CACurrentMediaTime()
        _ = wall.provideScene(at: t)
        controller.window?.setContentSize(NSSize(width: 1000, height: 700))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        wall.reread(now: Date())
        try expect(wall.tween != nil && wall.words.isGliding, "a new size starts the wall gliding")
        guard let start = wall.tween?.start else { throw SelfTestFailure("agents: the glide has a start") }
        _ = wall.provideScene(at: start + 0.1)
        try expect(wall.tween != nil, "and it is still under way a tenth of a second in")
        _ = wall.provideScene(at: start + WatchSceneBlend.duration + 0.05)
        try expect(wall.tween == nil && !wall.words.isGliding, "and over when the time is")
        guard let layout = wall.layout else { throw SelfTestFailure("agents: the wall has a layout") }
        for (index, tile) in wall.wall.tiles.enumerated() {
            let cell = layout.tiles[index].watchFrame.insetBy(dx: -0.5, dy: -0.5)
            let view = wall.words.tileView(tile.id)
            try expect(view.map { cell.contains($0.frame) } == true, "every tile's words end in its new cell")
        }
        try expect(
            WatchSceneBlend.easeOut(0) == 0 && WatchSceneBlend.easeOut(1) == 1 && WatchSceneBlend.easeOut(0.5) > 0.5,
            "the glide eases out")
        controller.stopWatching()
    }

    static func anAskKeepsItsWholeCommandAndItsAnswers(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        let controller = AgentsFixtures.controller(feed, mode: .watch)
        controller.startWatching()
        await AgentsFixtures.settle(controller)
        let wall = controller.wall
        guard
            let scene = AgentDemo.wallScenes(now: Date()).first(where: { $0.name == "attention" })?.wall,
            let ask = scene.tiles.first(where: { $0.state.isNeedsYou && $0.ask?.isApproval == true })
        else { throw SelfTestFailure("agents: the attention wall has an approval") }
        wall.show(demo: scene)
        guard let view = wall.words.tileView(ask.id) else { throw SelfTestFailure("agents: the ask has words") }
        try expect(view.answers == .holdAndDeny, "an approval answers with a hold and a deny")
        try expect(!view.approve.isHidden && !view.deny.isHidden && view.chat.isHidden, "and shows exactly those")
        try expect(view.detailLabel.text == ask.detail, "the command is said word for word")
        try expect(!view.isTruncated, "and is never cut")
        try expect(view.wordsLabel.text == ask.words, "led by Core's own words")
        let holdWords = view.approve.label.text
        view.press = .early
        try expect(view.approve.label.text == Localized.text("Hold to approve"), "a hold let go too soon says how to hold")
        view.press = .rest
        try expect(view.approve.label.text == holdWords, "and goes back to Approve")
        wall.apply(style: wall.style.with { $0.approvals = .openChat })
        guard let sent = wall.words.tileView(ask.id) else { throw SelfTestFailure("agents: the ask still has words") }
        try expect(sent.answers == .openChat && !sent.chat.isHidden && sent.approve.isHidden, "Open chat replaces the hold when the style says so")
        wall.apply(style: WallStyle.studio)
        controller.stopWatching()
    }

    static func theWallObeysItsCadenceAndKeepsItsStyle(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        let controller = AgentsFixtures.controller(feed, mode: .watch)
        controller.startWatching()
        await AgentsFixtures.settle(controller)
        let wall = controller.wall
        DisplayGate.assumesVisible = false
        let covered = wall.frameCap()
        DisplayGate.assumesVisible = true
        let seen = wall.frameCap()
        try expect(covered == 0, "a covered window draws nothing")
        try expect(seen > 0, "and an uncovered one does")
        wall.hiddenProbe = { true }
        try expect(wall.frameCap() == 0, "a hidden app draws nothing")
        wall.hiddenProbe = nil

        let key = MacWatchStyleStore.key
        let prior = UserDefaults.standard.string(forKey: key)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let custom = WallStyle.showcase.with {
            $0.still = true
            $0.dimAfter = 1800
            $0.moves.steps = false
        }
        MacWatchStyleStore.save(custom)
        try expect(UserDefaults.standard.string(forKey: key) == custom.encoded(), "a style is kept as the Core JSON under agentsWatchStyle")
        try expect(MacWatchStyleStore.current == custom, "and reads back whole")
        try expect(custom.preset == .custom, "a change by hand makes the preset custom")
        UserDefaults.standard.set("{not json", forKey: key)
        try expect(MacWatchStyleStore.current == .studio, "garbage is the Studio style")
        MacWatchStyleStore.save(.nightDesk)
        wall.apply(style: custom)
        try expect(wall.style == custom && MacWatchStyleStore.current == custom, "the wall applies a style live and saves it")

        let popover = WatchStylePopover(style: custom)
        popover.view.layoutSubtreeIfNeeded()
        popover.view.setFrameSize(popover.view.fittingSize)
        popover.view.layoutSubtreeIfNeeded()
        var heard: WallStyle?
        popover.onChange = { heard = $0 }
        popover.refresh(.showcase)
        try expect(popover.style == .showcase && heard == nil, "the Style popover shows a style without announcing it")
        let popoverFaults = AgentsFixtures.problems(in: popover.view, label: "style")
        try expect(popoverFaults.isEmpty, "and is whole: \(popoverFaults.prefix(3))")
        wall.apply(style: .studio)
        controller.stopWatching()
    }

    static func aHoldDimAndGestureBehave(_ expect: (Bool, String) throws -> Void) async throws {
        var gauge = WatchHoldGauge()
        gauge.begin(tile: "a", at: .zero, now: 10)
        try expect(abs(gauge.progress(at: 10.4) - 0.5) < 0.001, "a hold is half full at 0.4 s")
        try expect(!gauge.advance(to: 10.79), "and not yet held at 0.79 s")
        try expect(gauge.advance(to: 10.8) && !gauge.advance(to: 10.9), "held at 0.8 s, once")
        try expect(gauge.release(at: 11) == .after, "and let go after it fired")
        gauge.begin(tile: "a", at: .zero, now: 20)
        try expect(gauge.release(at: 20.2) == .tap, "a quick press is a tap")
        gauge.begin(tile: "a", at: .zero, now: 30)
        try expect(gauge.release(at: 30.6) == .cancelled && !gauge.isHolding, "a hold let go at 0.6 s is cancelled")

        let start = Date(timeIntervalSince1970: 1_000_000)
        var dimmer = WatchDimmer()
        dimmer.observe(.calm, at: start)
        try expect(!dimmer.isDimmed(at: start.addingTimeInterval(599), after: 600), "a wall dims after the time the style says, not before")
        try expect(dimmer.isDimmed(at: start.addingTimeInterval(600), after: 600), "and dims then")
        try expect(!dimmer.isDimmed(at: start.addingTimeInterval(9_999), after: nil), "a style that never dims never does")
        dimmer.wake(at: start.addingTimeInterval(500))
        try expect(!dimmer.isDimmed(at: start.addingTimeInterval(700), after: 600), "a key starts the calm again")
        dimmer.observe(.busy, at: start.addingTimeInterval(800))
        dimmer.toggle(at: start.addingTimeInterval(801), after: 600)
        try expect(!dimmer.isDimmed(at: start.addingTimeInterval(802), after: 600), "a wall with something running is never dimmed")

        var queue = WallEffectQueue()
        queue.add([WallEvent(kind: .asked, tile: "t")], at: 1, style: .studio)
        let driver = WatchEffectsDriver()
        let first = AgentDemo.wallScenes(now: Date()).first { $0.name == "busy" }?.wall ?? .empty
        try expect(driver.observe(from: nil, to: first, previousLayout: nil, style: .studio, at: 1).isEmpty, "a first read says nothing happened")
        try expect(!queue.live.isEmpty && queue.live.allSatisfy { $0.kind == .knock }, "an ask plays its two knocks")
        try expect(!WatchKeepAwake.allows(WallStyle.studio.with { $0.keepAwake = .never }), "never keeps the screen on for no one")
        try expect(WatchKeepAwake.allows(WallStyle.studio.with { $0.keepAwake = .always }), "always keeps it on")

        let keep = WatchKeepAwake()
        keep.hold(true)
        try expect(keep.isHeld, "the wall holds the display awake while it is up")
        keep.hold(false)
        try expect(!keep.isHeld, "and lets go when it leaves")
    }

    static func theWallPeeksAndLeaves(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        let controller = AgentsFixtures.controller(feed, mode: .watch)
        controller.startWatching()
        await AgentsFixtures.settle(controller)
        guard let key = controller.wall.wall.tiles.first?.id else { throw SelfTestFailure("agents: the wall has a tile") }
        controller.toggleInspector()
        controller.peekFromWall(key)
        try expect(controller.selectedKey == key && controller.wall.isPeeking, "a press on a tile peeks at it, with the inspector open")
        controller.closeWallPeek()
        try expect(controller.selectedKey == nil && !controller.wall.isPeeking, "Esc closes the peek")
        controller.setMode(.now)
        try expect(!controller.wall.isActive && controller.wall.ticker == nil, "the wall stops its clock when another lens is up")
        controller.setMode(.watch)
        try expect(controller.wall.isActive && controller.wall.ticker != nil, "and starts it again when it returns")
        controller.stopWatching()
        try expect(controller.wall.ticker == nil && !controller.wall.keepAwake.isHeld, "a closed window holds nothing")
    }
}
