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
#endif
