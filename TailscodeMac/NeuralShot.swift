#if DEBUG
    import AppKit
    import CodingAgentKit
    import Foundation
    import TailscodeCore

    /// `TailscodeMac --neural-shot <state> <out.bgra>` draws the head offscreen through the Metal
    /// renderer at 768 by 504 and writes `<out>-interior.bgra` and `<out>-front.bgra`, the same
    /// premultiplied BGRA bytes `NeuralCompositor` writes on the CPU, so the two can be compared
    /// pixel for pixel. `<state>` is a state's name (`working`, `thinking`, `approval`, `idle`,
    /// `settled`, …) or `all` with a directory in place of the file, which writes every state under
    /// the names the Core golden test uses. `--neural-bench` times the GPU instead.
    ///
    /// The theme is the usual launch environment (`TAILSCODE_THEME`, `TAILSCODE_APPEARANCE`) and
    /// phosphor dark when neither is set, which is the golden's palette; `TAILSCODE_NEURAL_DIR`
    /// reads the container files from a folder instead of the bundle.
    @MainActor
    enum NeuralShot {
        static var isRequested: Bool {
            let arguments = CommandLine.arguments
            return arguments.contains("--neural-shot") || arguments.contains("--neural-bench")
                || arguments.contains("--neural-view") || arguments.contains("--neural-quad")
        }

        static let width = 768
        static let height = 504

        private struct Named {
            let name: String
            let state: NeuralState
            let time: Double
        }

        static func run() -> Never {
            let arguments = CommandLine.arguments
            if arguments.contains("--neural-view") { viewCheck() }
            if arguments.contains("--neural-quad") { quadCheck() }
            let mismatches = NeuralUniforms.layoutMismatches()
            print("neural layout: \(mismatches.isEmpty ? "ok" : mismatches.joined(separator: "; "))")
            guard mismatches.isEmpty else { exit(1) }
            guard let context = NeuralMetalContext.shared, context.isSupported,
                let renderer = NeuralHeadRenderer(context: context)
            else { fail("no Metal device with ASTC and the neural shaders") }
            if let folder = ProcessInfo.processInfo.environment["TAILSCODE_NEURAL_DIR"] {
                context.setAssetDirectory(URL(fileURLWithPath: folder))
            }
            context.retain()
            awaitTextures(context)
            if arguments.contains("--neural-bench") {
                bench(renderer, context: context)
                exit(0)
            }
            guard let flag = arguments.firstIndex(of: "--neural-shot"), flag + 2 < arguments.count
            else { fail("usage: TailscodeMac --neural-shot <state|all> <out.bgra|directory>") }
            shoot(
                arguments[flag + 1], into: arguments[flag + 2], renderer: renderer)
            exit(0)
        }

        private static func fail(_ message: String) -> Never {
            print("neural: \(message)")
            exit(1)
        }

        private static func awaitTextures(_ context: NeuralMetalContext) {
            let deadline = Date().addingTimeInterval(30)
            while context.currentTextures() == nil && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard context.currentTextures() != nil else { fail("the textures did not load") }
            print(
                "neural textures: \(context.residentBytes) bytes (\(String(format: "%.2f", Double(context.residentBytes) / 1_048_576)) MB)"
            )
        }

        /// `--neural-quad` draws a listening head's ear twice through two detached layers, the
        /// second time as an eye-only frame, and compares the front the renderer retained with a
        /// full offscreen render of the second frame. They must be the same bytes.
        private static func quadCheck() -> Never {
            guard let context = NeuralMetalContext.shared, context.isSupported,
                let renderer = NeuralHeadRenderer(context: context)
            else { fail("no Metal device with ASTC and the neural shaders") }
            context.retain()
            awaitTextures(context)
            let table = NeuralToneTable(palette: palette, face: face)
            let meters = NeuralMeters(contextFill: 0.62, call: .listening)
            func frame(_ time: Double) -> NeuralFrame {
                NeuralFrame.at(
                    time: time, state: .settled, face: face, meters: meters, reduceMotion: false)
            }
            let first = frame(0)
            let second = frame(0.5)
            print("quad: only eye, ear, ribs differ \(NeuralFrameDelta.changesOnlyEyeEarRibs(from: first, to: second))")
            let interior = CAMetalLayer()
            let front = CAMetalLayer()
            for layer in [interior, front] {
                layer.device = context.device
                layer.pixelFormat = NeuralHeadRenderer.pixelFormat
                layer.drawableSize = CGSize(width: width, height: height)
            }
            let drewFirst = renderer.draw(
                frame: first, table: table, time: 0, retainFront: true, interior: interior,
                front: front)
            Thread.sleep(forTimeInterval: 0.2)
            let drewSecond = renderer.draw(
                frame: second, table: table, time: 0.5, scope: .eyeOnly, retainFront: true,
                interior: interior, front: front)
            Thread.sleep(forTimeInterval: 0.2)
            print("quad: drew full \(drewFirst) eye-only \(drewSecond) was eye-only \(renderer.lastDrawWasEyeOnly)")
            guard let retained = renderer.debugReadRetainedFront(),
                let full = renderer.snapshot(
                    frame: second, table: table, time: 0.5, width: width, height: height)
            else { fail("nothing to compare") }
            var differing = 0
            var worst = 0
            for index in retained.bytes.indices {
                let delta = abs(Int(retained.bytes[index]) - Int(full.front.bytes[index]))
                if delta > 0 { differing += 1 }
                worst = max(worst, delta)
            }
            print("quad: front bytes differing \(differing) of \(retained.bytes.count), worst \(worst)")
            exit(worst <= 1 ? 0 : 1)
        }

        private static func pause(_ seconds: Double) async {
            try? await Task.sleep(for: .seconds(seconds))
        }

        private static func brain(_ context: NeuralBrainContext, running: Bool) -> NeuralBrainModel {
            let turns = NeuralTurns.partition(
                messages: NeuralDemo.turn(answer: !running), running: running)
            return NeuralBrainModel(turn: turns[0], context: context)
        }

        private final class ViewCheckDelegate: NSObject, NSApplicationDelegate {
            func applicationDidFinishLaunching(_ notification: Notification) {
                Task { @MainActor in
                    await NeuralShot.viewSequence()
                    exit(0)
                }
            }
        }

        private static let viewDelegate = ViewCheckDelegate()

        /// `--neural-view` puts a real `NeuralHeadView` in a window and reports what its clock and
        /// its drawing did across the cases the discipline is about: a working head ticks and
        /// draws, a settled one draws once and runs no clock, reduced motion and a suspended
        /// view hold still, a call's ear alone redraws only the ear, and a resize draws once. It
        /// needs a window server, so it is launched through `open` on the Mac's own session.
        private static func viewCheck() -> Never {
            guard NeuralHeadView.isSupported else { fail("the head cannot be drawn on this Mac") }
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            app.delegate = viewDelegate
            app.run()
            exit(0)
        }

        private static func viewSequence() async {
            let app = NSApplication.shared
            NeuralHeadView.forcesActive = true
            app.activate(ignoringOtherApps: true)
            let window = NSWindow(
                contentRect: NSRect(x: 80, y: 80, width: 640, height: 420), styleMask: [.titled],
                backing: .buffered, defer: false)
            let view = NeuralHeadView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
            window.contentView = view
            window.orderFrontRegardless()
            await pause(2)
            print(
                "view: window visible \(window.occlusionState.contains(.visible)) isVisible \(window.isVisible) occlusion \(window.occlusionState.rawValue) app active \(app.isActive) screens \(NSScreen.screens.count) asleep \(CGDisplayIsAsleep(CGMainDisplayID())) session \(String(describing: CGSessionCopyCurrentDictionary() as? [String: Any]))"
            )
            var ticks = 0
            view.onTick = { _ in ticks += 1 }
            var ready = false
            view.onReady = { ready = true }
            let palette = AppTheme.phosphor.dark
            let working = brain(
                NeuralBrainContext(activity: .usingTool(name: "Bash", kind: .shell)), running: true)

            func report(_ name: String) {
                print(
                    "view: \(name): ticks \(ticks) frames \(view.framesDrawn) eyeOnly \(view.eyeOnlyFrames) clock \(view.isClockRunning) ready \(ready) holds \(NeuralMetalContext.shared?.retainCount ?? -1) resident \(NeuralMetalContext.shared?.residentBytes ?? 0)"
                )
            }

            view.apply(model: working, palette: palette)
            await pause(3)
            report("working 3 s")

            view.apply(model: brain(.none, running: false), palette: palette)
            await pause(0.4)
            let settledFrames = view.framesDrawn
            report("settled after 0.4 s")
            await pause(1.5)
            print(
                "view: settled held \(view.framesDrawn == settledFrames ? "yes" : "NO") frames \(view.framesDrawn - settledFrames) more clock \(view.isClockRunning)"
            )

            let before = view.framesDrawn
            view.setFrameSize(NSSize(width: 520, height: 380))
            await pause(0.4)
            print("view: resize drew \(view.framesDrawn - before) frame(s) clock \(view.isClockRunning)")

            view.apply(
                model: brain(NeuralBrainContext(call: .listening), running: false), palette: palette)
            await pause(2)
            report("settled with a listening ear 2 s")

            view.apply(model: working, palette: palette, reduceMotion: true)
            await pause(0.5)
            report("working under reduced motion")

            view.apply(model: working, palette: palette)
            await pause(0.5)
            view.isSuspended = true
            await pause(0.2)
            print("view: suspended clock \(view.isClockRunning)")
            view.isSuspended = false
            await pause(0.5)
            print("view: resumed clock \(view.isClockRunning)")

            window.contentView = nil
            await pause(0.3)
            report("removed from window")
        }

        private static var palette: Palette {
            let environment = ProcessInfo.processInfo.environment
            let theme = environment["TAILSCODE_THEME"].map { AppTheme.named($0) } ?? .phosphor
            let dark = environment["TAILSCODE_APPEARANCE"] != "light"
            return theme.palette(dark: dark)
        }

        private static let face = NeuralFace(family: .opus)

        private static func states() -> [Named] {
            var all = ActivityKind.everyState.enumerated().map { entry -> Named in
                let state = NeuralState.make(activity: entry.element)
                return Named(name: "\(entry.offset)-\(state.label)", state: state, time: 0.128)
            }
            all.append(Named(name: "settled", state: .settled, time: 0))
            all.append(Named(name: "idle", state: .idle, time: 0))
            return all
        }

        private static func frame(for entry: Named) -> NeuralFrame {
            NeuralFrame.at(
                time: entry.time, state: entry.state, face: face,
                meters: NeuralMeters(contextFill: 0.62), reduceMotion: false)
        }

        private static func shoot(_ wanted: String, into output: String, renderer: NeuralHeadRenderer) {
            let table = NeuralToneTable(palette: palette, face: face)
            let everything = states()
            let chosen: [Named]
            if wanted == "all" {
                chosen = everything
                try? FileManager.default.createDirectory(
                    atPath: output, withIntermediateDirectories: true)
            } else {
                chosen = everything.filter { entry in
                    entry.name == wanted || entry.state.label == wanted
                }
                guard !chosen.isEmpty else {
                    fail("unknown state \(wanted); known: \(everything.map(\.name).joined(separator: " "))")
                }
            }
            for entry in chosen {
                guard
                    let pair = renderer.snapshot(
                        frame: frame(for: entry), table: table, time: entry.time, width: width,
                        height: height)
                else { fail("\(entry.name) did not render") }
                let base: String
                if wanted == "all" {
                    base = (output as NSString).appendingPathComponent(entry.name)
                } else {
                    base = output.hasSuffix(".bgra") ? String(output.dropLast(5)) : output
                }
                do {
                    try Data(pair.interior.bytes).write(to: URL(fileURLWithPath: base + "-interior.bgra"))
                    try Data(pair.front.bytes).write(to: URL(fileURLWithPath: base + "-front.bgra"))
                } catch {
                    fail("could not write \(base): \(error.localizedDescription)")
                }
                print("neural shot \(entry.name) -> \(base)-{interior,front}.bgra")
            }
        }

        private static func bench(_ renderer: NeuralHeadRenderer, context: NeuralMetalContext) {
            let table = NeuralToneTable(palette: palette, face: face)
            let frames = 120
            let sizes = [(width: 1280, height: 840), (width: 2560, height: 1680)]
            let cases: [(String, NeuralState)] = [
                ("working", NeuralState.make(activity: .usingTool(name: "Bash", kind: .shell))),
                ("compacting", NeuralState.make(activity: .compacting)),
                ("approval", NeuralState.make(activity: .needsApproval)),
                ("settled", .settled),
            ]
            print("device: \(context.device.name)")
            for size in sizes {
                for (name, state) in cases {
                    let seconds = renderer.measure(
                        frames: frames, width: size.width, height: size.height, table: table
                    ) { index in
                        let time = Double(index) / ActivityTuning.frameRate
                        return (
                            NeuralFrame.at(
                                time: time, state: state, face: face,
                                meters: NeuralMeters(contextFill: 0.62), reduceMotion: false),
                            time
                        )
                    }
                    guard let seconds, !seconds.isEmpty else { fail("\(name) did not measure") }
                    let mean = seconds.reduce(0, +) / Double(seconds.count)
                    let sorted = seconds.sorted()
                    print(
                        String(
                            format: "neural bench %4dx%-4d %-10@ frames %d mean %.1f us median %.1f us min %.1f us max %.1f us",
                            size.width, size.height, name as NSString, seconds.count, mean * 1e6,
                            sorted[sorted.count / 2] * 1e6, sorted[0] * 1e6, sorted[sorted.count - 1] * 1e6))
                }
            }
            print("neural resident textures: \(context.residentBytes) bytes")
        }
    }
#endif
