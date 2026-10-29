import AppKit
import QuartzCore
import TailscodeCore

extension WatchWallViewController {
    static let handBackAfter: TimeInterval = 2.6
    static let idleHides: TimeInterval = 3

    func setActive(_ on: Bool) {
        isActive = on
        refreshRunning()
        if on { reread(now: Date()) }
    }

    func setLive(_ on: Bool) {
        isLive = on
        refreshRunning()
    }

    /// Starts and stops everything that costs: the second's clock, the power assertion, the frames.
    /// The wall only runs while it is the lens in use and its window can be seen.
    func refreshRunning() {
        let running = (isActive || fixedWall != nil) && isLive
        if running, ticker == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainThread.call { self?.tick() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
            lastFrame = CACurrentMediaTime()
            reread(now: Date())
            fetchHourIfDue(Date())
        } else if !running, ticker != nil {
            ticker?.invalidate()
            ticker = nil
            cancelHold()
            restoreChrome()
        }
        keepAwake.hold(running && WatchKeepAwake.allows(style))
        applyCadence()
    }

    func tick() {
        let now = Date()
        updateDrift(now)
        palette = Self.palette(for: style, at: now)
        reread(now: now)
        keepAwake.hold(WatchKeepAwake.allows(style))
        fetchHourIfDue(now)
        hideChromeIfIdle(now)
        applyCadence()
    }

    /// The static chrome moves a few points on a ten-minute loop, so no pixel is lit for days.
    private func updateDrift(_ now: Date) {
        guard animated else {
            drift = (0, 0)
            return
        }
        let loop = 600.0
        let phase = 2 * Double.pi * now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: loop) / loop
        drift = ((6 * sin(phase)).rounded(), (6 * cos(phase * 2)).rounded())
    }

    func fetchHourIfDue(_ now: Date) {
        guard now.timeIntervalSince(hourFetchedAt) >= 30, !hourFetching, let fetchHour, fixedWall == nil else { return }
        hourFetching = true
        hourFetchedAt = now
        Task { @MainActor [weak self] in
            let fetched = await fetchHour()
            self?.hourFetching = false
            self?.apply(hour: fetched)
        }
    }

    func windowChanged() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
        guard let window = root.window else { return }
        window.collectionBehavior.insert(.fullScreenPrimary)
        let center = NotificationCenter.default
        for name in [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification,
            NSWindow.didEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ] {
            observe(center, name, window)
        }
        for name in [
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange,
            ThemeSelection.didChange, MacWatchStyleStore.didChange,
        ] {
            observe(center, name, nil)
        }
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainThread.call { self?.environmentChanged(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) }
            })
        refreshRunning()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ object: Any?) {
        observers.append(
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] note in
                let name = note.name
                MainThread.call { self?.environmentChanged(name) }
            })
    }

    /// Something that decides how the wall looks or how fast it may draw has changed.
    func environmentChanged(_ name: Notification.Name) {
        switch name {
        case NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification:
            restoreChrome()
            sizeChanged()
        case NSWindow.didEnterFullScreenNotification:
            lastActivity = Date()
            sizeChanged()
        case ThemeSelection.didChange:
            palette = Self.palette(for: style, at: Date())
            reread(now: Date())
        case MacWatchStyleStore.didChange:
            let stored = MacWatchStyleStore.current
            if stored != style { apply(style: stored) }
        default:
            break
        }
        refreshRunning()
    }

    func apply(style next: WallStyle) {
        guard next != style else { return }
        style = next
        MacWatchStyleStore.save(next)
        palette = Self.palette(for: next, at: Date())
        reread(now: Date())
        refreshRunning()
    }

    func noteActivity() {
        lastActivity = Date()
        dimmer.wake(at: lastActivity)
        if chromeHidden { restoreChrome() }
        if dimmer.amount > 0 { applyCadence() }
    }

    func hideChromeIfIdle(_ now: Date) {
        guard let window = root.window, window.styleMask.contains(.fullScreen), isActive else {
            restoreChrome()
            return
        }
        guard !chromeHidden, !isPeeking, stylePopover?.isShown != true,
            now.timeIntervalSince(lastActivity) >= Self.idleHides
        else { return }
        chromeHidden = true
        window.toolbar?.isVisible = false
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func restoreChrome() {
        guard chromeHidden else { return }
        chromeHidden = false
        root.window?.toolbar?.isVisible = true
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard flags.isEmpty else { return false }
        if event.keyCode == 53 {
            escape()
            return true
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "1", "2", "3", "4", "5", "6": peek(index: (Int(key) ?? 1) - 1)
        case "d": toggleDim()
        case "s": showStyle()
        case "f": root.window?.toggleFullScreen(nil)
        default: return false
        }
        return true
    }

    /// Esc leaves full screen first, and when the wall is not in full screen it closes the peek.
    func escape() {
        if let window = root.window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            onClosePeek?()
        }
    }

    func peek(index: Int) {
        guard wall.tiles.indices.contains(index) else {
            NSSound.beep()
            return
        }
        onPeek?(wall.tiles[index].id)
    }

    func toggleDim() {
        dimmer.toggle(at: Date(), after: style.dimAfter)
        applyCadence()
        if appliedCap <= 1 { metal?.drawOnce() }
    }

    /// A press that lands on a tile, a worker or the `+N`: that session's peek. A press on the ground
    /// is nothing but a sign that somebody is there.
    func clicked(at point: CGPoint) {
        guard let layout else { return }
        let x = Double(point.x)
        let y = Double(point.y)
        func inside(_ rect: WallRect) -> Bool { x >= rect.x && x <= rect.maxX && y >= rect.y && y <= rect.maxY }
        for (index, tile) in wall.tiles.enumerated() where index < layout.tiles.count {
            if let squad = index < layout.squads.count ? layout.squads[index] : nil,
                inside(squad.parent) || squad.slots.contains(where: inside) || squad.more.map(inside) == true
            {
                onPeek?(tile.id)
                return
            }
            if inside(layout.tiles[index]) {
                onPeek?(tile.id)
                return
            }
        }
    }

    func showStyle(from anchor: NSView? = nil) {
        if let stylePopover, stylePopover.isShown {
            stylePopover.close()
            return
        }
        let controller = WatchStylePopover(style: style)
        controller.onChange = { [weak self] next in self?.apply(style: next) }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        stylePopover = popover
        if let anchor {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else {
            let corner = CGRect(x: root.bounds.maxX - 52, y: root.bounds.minY, width: 32, height: 4)
            popover.show(relativeTo: corner, of: root, preferredEdge: .maxY)
        }
    }

    func deny(_ key: String) {
        guard let ask = wall.tiles.first(where: { $0.id == key })?.ask else { return }
        noteActivity()
        actions?.decide(key, ask: ask, allow: false)
    }

    func beginHold(_ view: WatchTileWordsView, _ event: NSEvent) {
        guard let tile = view.tile, tile.ask?.isApproval == true, !hold.isHolding else { return }
        noteActivity()
        hold.begin(tile: tile.id, at: root.convert(event.locationInWindow, from: nil), now: CACurrentMediaTime())
        setPress(.holding, for: tile.id)
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainThread.call { self?.holdStep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
        applyCadence()
    }

    func holdStep() {
        guard hold.advance(to: CACurrentMediaTime()), let id = hold.tile else { return }
        holdTimer?.invalidate()
        holdTimer = nil
        guard let ask = wall.tiles.first(where: { $0.id == id })?.ask else { return }
        actions?.decide(id, ask: ask, allow: true)
    }

    func endHold(_ view: WatchTileWordsView, inside: Bool) {
        let id = view.key
        holdTimer?.invalidate()
        holdTimer = nil
        switch hold.release(at: CACurrentMediaTime()) {
        case .tap, .cancelled:
            setPress(.early, for: id)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.handBackAfter) { [weak self] in
                MainThread.call {
                    guard let self, self.presses[id] == .early else { return }
                    self.setPress(.rest, for: id)
                }
            }
        case .after, .none:
            setPress(.rest, for: id)
        }
        applyCadence()
    }

    func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        if let id = hold.tile { setPress(.rest, for: id) }
        hold.cancel()
    }

    private func setPress(_ press: WatchTileWordsView.Press, for id: String) {
        presses[id] = press == .rest ? nil : press
        words.tileView(id)?.press = press
    }
}
