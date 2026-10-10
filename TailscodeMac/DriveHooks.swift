#if DEBUG
    import AppKit
    import Darwin
    import Foundation
    import TailscodeCore

    /// `TAILSCODE_DRIVE="2000:stall=4000;9000:level;12000:flight=8;13000:kill"` — the seatbelts'
    /// verbs on a timer from launch, in the same `delay:verb=argument` shape the Linux harness
    /// reads, so a run over ssh can prove a stall is recorded and shed without anyone at the Mac.
    ///
    /// - `stall=<ms>` blocks the main thread (the watchdog's record, then level 4 on resume)
    /// - `spin=<ms>` keeps the main thread busy instead, so the record says it was running
    /// - `pressure=<nominal|strained|critical|auto>` replaces what the kernel says
    /// - `shed=<0…4|auto>` pins the level
    /// - `level` prints the level and why; `flight[=n]` prints the newest records of the ring
    /// - `split=<n>` opens the first chats as one tiling; `restore` prints what the safe restore
    ///   holds; `resume=all|one` presses the banner's buttons
    /// - `sopen[=state]` raises the Studio; `skey=<cmd-return|esc|cmd-e|cmd-shift-e|cmd-shift-r|cmd-1|
    ///   cmd-2|cmd-s|left|right|space>` presses that key through the real event path into the
    ///   Studio's window; `sstate` prints what the Studio is holding; `sanimate` presses Animate this
    ///   on the picture on the Image lane's stage; `smachineshot=<path>` writes the Video lane's
    ///   machine sheet to a PNG, since a popover is not part of the window's own picture; `sdemo=<state>` stages a Video lane state while the
    ///   Studio is up, so a render landing can be watched; `sfocus` gives the stage the keyboard, which is
    ///   where Space plays a clip and the arrows walk the shelf
    /// - `quit` quits the ordinary way; `kill` sends this process SIGKILL, the crash a ring must survive
    @MainActor
    enum DriveHooks {
        private static weak var main: MainWindowController?

        static func install(
            main: MainWindowController?,
            script: String? = ProcessInfo.processInfo.environment["TAILSCODE_DRIVE"]
        ) {
            guard let script else { return }
            self.main = main
            for step in script.split(separator: ";") {
                let parts = step.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let delay = Int(parts[0]) else { continue }
                let action = String(parts[1])
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) {
                    MainActor.assumeIsolated { perform(action, at: delay) }
                }
            }
        }

        /// The pane verbs as the menu bar lists them: each submenu of the View menu that Core's
        /// groups name, its items with the keys they wear and whether they are enabled now.
        private static func paneMenuReport() -> String {
            let names = Set(SplitMenu.groups.map(\.title))
            guard
                let view = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?
                    .submenu
            else { return "MENU no View menu" }
            view.update()
            let groups = view.items.compactMap { holder -> String? in
                guard let menu = holder.submenu, names.contains(menu.title) else { return nil }
                menu.update()
                let rows = menu.items.filter { !$0.isSeparatorItem }.map { item in
                    let text =
                        item.attributedTitle?.string.replacingOccurrences(of: "\t", with: " ")
                        ?? item.title
                    return "\(text)\(item.state == .on ? " *" : "")\(item.isEnabled ? "" : " (off)")"
                }
                return "\(menu.title): " + rows.joined(separator: " | ")
            }
            return "MENU " + groups.joined(separator: " || ")
        }

        private static func say(_ line: String) {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }

        static func perform(_ action: String, at delay: Int) {
            say("DRIVE \(delay) \(action)")
            let pieces = action.split(separator: "=", maxSplits: 1)
            let verb = String(pieces.first ?? "")
            let argument = pieces.count > 1 ? String(pieces[1]) : ""
            let seatbelts = Seatbelts.shared
            switch verb {
            case "stall":
                Thread.sleep(forTimeInterval: Double(Int(argument) ?? 4000) / 1000)
            case "spin":
                let until = MachClock.now() + Double(Int(argument) ?? 4000) / 1000
                while MachClock.now() < until {}
            case "pressure":
                let named = HostPressure.allCases.first {
                    $0.code == argument || String(describing: $0) == argument
                }
                seatbelts.pressure.inject(named)
                seatbelts.sample()
            case "shed":
                seatbelts.force(Int(argument).flatMap(ShedLevel.init(rawValue:)))
            case "level":
                let reasons = seatbelts.decision?.reasons.map(\.code).joined(separator: ",") ?? ""
                say(
                    "LEVEL \(seatbelts.level.rawValue) \(seatbelts.level.code) reasons=\(reasons) "
                        + "cascade=\(MotionBudget.cascadeAllowed) animation=\(MotionBudget.animationAllowed)")
            case "flight":
                seatbelts.writer?.drain()
                let records = seatbelts.writer.map { FlightRing.read(url: $0.url, last: Int(argument) ?? 10) } ?? []
                say(FlightFormatter.format(records))
            case "split":
                main?.driveSplit(Int(argument) ?? 5)
            case "chord":
                say(main?.driveChord(argument) ?? "CHORD no window")
            case "order":
                say(main?.splitPanes.driveOrder("ORDER") ?? "ORDER no window")
            case "geom":
                say(main?.splitPanes.driveGeometry() ?? "GEOM no window")
            case "divinfo":
                say(main?.splitPanes.driveDividers() ?? "DIVIDERS no window")
            case "divkey":
                let fields = argument.split(separator: ",").map(String.init)
                let index = Int(fields.first ?? "") ?? 0
                let word = fields.count > 1 ? fields[1] : "right"
                let key: DividerKey =
                    switch word {
                    case "left", "up": .back(large: false)
                    case "shift+left", "shift+up": .back(large: true)
                    case "right", "down": .forward(large: false)
                    case "shift+right", "shift+down": .forward(large: true)
                    case "home": .lowest
                    default: .highest
                    }
                let moved = main?.splitPanes.driveDivider(index, key: key) ?? false
                say("DIVKEY \(index) \(word) moved=\(moved)")
            case "menu":
                say(paneMenuReport())
            case "pdrag":
                let fields = argument.split(separator: ",").map(String.init)
                let target = Int(fields.first ?? "") ?? 0
                let u = Double(fields.count > 1 ? fields[1] : "0.5") ?? 0.5
                let v = Double(fields.count > 2 ? fields[2] : "0.5") ?? 0.5
                let source = Int(fields.count > 3 ? fields[3] : "0") ?? 0
                say(
                    main?.splitPanes.drivePaneHover(target: target, u: u, v: v, source: source)
                        ?? "PDRAG no window")
            case "pdrop":
                let fields = argument.split(separator: ",").map(String.init)
                let target = Int(fields.first ?? "") ?? 0
                let u = Double(fields.count > 1 ? fields[1] : "0.5") ?? 0.5
                let v = Double(fields.count > 2 ? fields[2] : "0.5") ?? 0.5
                let source = Int(fields.count > 3 ? fields[3] : "0") ?? 0
                say(
                    main?.splitPanes.drivePaneDrop(target: target, u: u, v: v, source: source)
                        ?? "PDROP no window")
            case "sopen":
                main?.openSurface(named: argument.isEmpty ? "studio" : "studio:\(argument)")
            case "skey":
                say(StudioDrive.press(argument))
            case "sstate":
                say(StudioDrive.state())
            case "stoolbar":
                say(StudioDrive.toolbar())
            case "smachineshot":
                let sheet = StudioVideoMachineSheet(runner: .shared) {}
                sheet.loadViewIfNeeded()
                sheet.view.layoutSubtreeIfNeeded()
                sheet.view.appearance = MacTheme.Chrome.appearance
                if let rep = sheet.view.bitmapImageRepForCachingDisplay(in: sheet.view.bounds) {
                    sheet.view.cacheDisplay(in: sheet.view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: argument))
                    say("SMACHINESHOT \(argument) \(Int(sheet.view.bounds.width))x\(Int(sheet.view.bounds.height))")
                }
            case "sdemo":
                StudioVideoDemo.apply(argument)
            case "sfocus":
                if let panel = StudioWindowController.shared.panel,
                    let stage = StudioWindowController.shared.activeLane?.stage
                {
                    panel.makeFirstResponder(stage)
                }
            case "sanimate":
                StudioWindowController.shared.image.animateStaged()
            case "smachine":
                if let panel = StudioWindowController.shared.panel, let content = panel.contentView {
                    StudioWindowController.shared.activeLane?.presentMachine(from: content)
                }
            case "sdraw":
                say(StudioDrive.draws(main))
            case "restore":
                say(main?.driveRestoreReport() ?? "RESTORE no window")
            case "resume":
                main?.driveResume(argument)
            case "quit":
                NSApp.terminate(nil)
            case "kill":
                kill(getpid(), SIGKILL)
            default:
                say("DRIVE unknown verb \(verb)")
            }
        }
    }

    /// The Studio's keys, pressed the way a hand presses them: a real key event handed to the
    /// application, so it passes the Studio's key monitor and the menu bar exactly as typing would.
    @MainActor
    enum StudioDrive {
        private static let keys: [String: (code: UInt16, characters: String, flags: NSEvent.ModifierFlags)] = [
            "cmd-return": (36, "\r", [.command]),
            "esc": (53, "\u{1B}", []),
            "cmd-e": (14, "e", [.command]),
            "cmd-shift-e": (14, "E", [.command, .shift]),
            "cmd-shift-r": (15, "R", [.command, .shift]),
            "cmd-1": (18, "1", [.command]),
            "cmd-2": (19, "2", [.command]),
            "cmd-s": (1, "s", [.command]),
            "left": (123, "\u{F702}", [.function]),
            "right": (124, "\u{F703}", [.function]),
            "space": (49, " ", []),
        ]

        static func press(_ name: String) -> String {
            guard let panel = StudioWindowController.shared.panel, let key = keys[name] else {
                return "SKEY \(name) no window or no such key"
            }
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: key.flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, characters: key.characters,
                    charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code)
            else { return "SKEY \(name) could not be made" }
            NSApp.sendEvent(event)
            return "SKEY \(name) sent"
        }

        /// Where the toolbar's items stand in the window, which the content view's own picture cannot
        /// show: the lane switch, the machine pill, the queue and Done, with the pill's words.
        static func toolbar() -> String {
            guard let panel = StudioWindowController.shared.panel, let toolbar = panel.toolbar else {
                return "STOOLBAR no window"
            }
            let height = panel.frame.height
            let rows = toolbar.items.map { item -> String in
                guard let view = item.view, view.window != nil else { return "\(item.itemIdentifier.rawValue) (no view)" }
                let frame = view.convert(view.bounds, to: nil)
                return String(
                    format: "%@ x=%.0f y=%.0f w=%.0f h=%.0f", item.itemIdentifier.rawValue, frame.minX,
                    height - frame.maxY, frame.width, frame.height)
            }
            let machine = StudioWindowController.shared.activeLane?.machine
            return "STOOLBAR window=\(Int(panel.frame.width))x\(Int(height)) " + rows.joined(separator: " | ")
                + " machine=[\(machine?.spoken ?? "-")] tone=\(String(describing: machine?.tone))"
        }

        /// A layout that held a draw slot, written and read back and rebuilt: which panes paint, on
        /// which machine, before and after the round trip a relaunch makes.
        static func draws(_ main: MainWindowController?) -> String {
            guard let main else { return "SDRAW no window" }
            let snapshot = main.splitPanes.snapshot()
            let before = main.splitPanes.panes.values.compactMap { $0.drawEndpoint?.address }
            guard let encoded = snapshot.encoded, let decoded = SplitSnapshot.decode(encoded) else {
                return "SDRAW snapshot did not round-trip"
            }
            _ = main.splitPanes.restore(decoded)
            let after = main.splitPanes.panes.values.compactMap { $0.drawEndpoint?.address }
            return "SDRAW draws=\(snapshot.draws.count) before=\(before) restored=\(after)"
        }

        static func state() -> String {
            let controller = StudioWindowController.shared
            if controller.current == .video { return "SSTATE lane=video " + controller.video.driveState }
            let studio = controller.image.studio
            let phase: String
            switch studio.slot.phase {
            case .asking: phase = "asking"
            case .composing: phase = "composing"
            case .painting: phase = "painting"
            case .failed(_, let reason): phase = "failed(\(reason))"
            }
            let shelf = controller.image.shelf
            return
                "SSTATE lane=\(controller.current) phase=\(phase) painting=\(studio.isPainting) "
                + "tiles=\(shelf.count) selected=\(controller.image.selectedTile ?? "-") "
                + "pictures=\(studio.slot.pictures.count) words=\(studio.slot.promptDraft.prefix(24))"
        }
    }
#endif
