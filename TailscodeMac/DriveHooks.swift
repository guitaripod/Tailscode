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
