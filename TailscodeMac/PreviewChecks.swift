import AppKit
import CodingAgentKit
import TailscodeCore

/// The preview pane drawn from hand-built states, checked headlessly from `--selftest`: every face
/// it can wear, the picture decoded from real JPEG bytes and drawn at its own shape, the address
/// the driver reads, and the promise that a pane which is parked or shut down owns no clock and no
/// stream. The faces are looked at with `--open preview[:state]`.
@MainActor
enum PreviewCheck {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }
        faces(expect)
        commands(expect)
        addresses(expect)
        ownership(expect)
        return failures
    }

    private static func fixture(_ name: String) -> PreviewState {
        PreviewDemo.state(name) ?? PreviewState()
    }

    private static func pane(runs: Bool = false, host: String? = nil) -> PreviewSlotView {
        let target = PreviewTarget(host: PreviewDemo.host, project: PreviewDemo.project)
        return PreviewSlotView(
            target: target, fixedHost: host, runs: runs, secrets: PreviewMemorySecrets())
    }

    private static func faces(_ expect: (Bool, String) -> Void) {
        let asking = PreviewSlotView(target: nil, runs: false, secrets: PreviewMemorySecrets())
        expect(asking.summary == "asking" && asking.isAsking, "a pane with no target asks")
        expect(asking.hostFieldShown && !asking.passwordShown, "asking offers a host and hides the password")
        expect(!asking.hasLink && asking.lifetimeCount == 0, "asking owns no clock and no stream")
        let fixed = PreviewSlotView(
            target: nil, fixedHost: "mac.local", runs: false, secrets: PreviewMemorySecrets())
        expect(!fixed.hostFieldShown, "a Mac the chooser already chose is not asked for again")

        let view = pane()
        expect(view.summary.hasPrefix("connecting"), "a pointed pane with nothing heard is connecting: \(view.summary)")

        view.applyForTest(fixture("setup"))
        expect(view.summary == "settingUp rows=6", "the checklist draws every row: \(view.summary)")
        expect(view.checklistRowCount == 6, "one view per row: \(view.checklistRowCount)")
        expect(
            view.visibleButtonTitles == [PreviewReading.fixLabel("downloadIOSRuntime")],
            "only the fixable row offers a button: \(view.visibleButtonTitles)")
        expect(view.progressBarCount == 1, "a fix under way shows its progress: \(view.progressBarCount)")
        expect(view.slot.light.activity == .needsAnswer, "a Mac that needs setting up knocks")

        view.applyForTest(fixture("starting"))
        expect(
            view.summary == "starting [Building your app]", "starting says its line: \(view.summary)")
        expect(view.statusBadgeActivity == .connecting, "and the badge sweeps")

        view.applyForTest(fixture("live"), jpeg: PreviewDemo.picture)
        expect(view.summary == "live 604x1312", "a live pane carries the picture's size: \(view.summary)")
        expect(
            view.pictureDrawn?.width == 604 && view.pictureDrawn?.height == 1312,
            "the JPEG decodes at the size the host streamed")
        expect(view.lastPictureJPEG == PreviewDemo.picture, "the bytes kept are the bytes decoded")
        expect(
            view.visibleButtonTitles == [
                Localized.text("Light"), Localized.text("Dark"), Localized.text("Rebuild"),
                Localized.text("Copy picture"),
            ], "a live pane offers its four chips: \(view.visibleButtonTitles)")
        expect(view.pictureAlpha == 1 && view.reconnectWords == nil, "and says nothing while it is live")
        expect(!view.bannerShown && view.slot.light.activity == nil, "a settled picture wears no badge")
        drawsInk(view, expect)

        view.applyForTest(fixture("reconnecting"))
        expect(
            view.summary == "reconnecting 604x1312", "a dropped link keeps the last picture: \(view.summary)")
        expect(view.pictureAlpha < 1, "and dims it")
        expect(view.reconnectWords == PreviewLight.stale.line, "with the word for it: \(view.reconnectWords ?? "-")")
        expect(view.slot.light.activity == .reconnecting, "the strip's badge turns")

        view.applyForTest(fixture("broken"))
        expect(
            view.summary == "broken 604x1312 banner=NoteView.swift:42: cannot find 'noteTitle' in scope",
            "a failed build keeps the last good frame under a banner: \(view.summary)")
        expect(view.bannerShown, "the banner is up")
        expect(
            view.visibleButtonTitles.contains(Localized.text("Ask the agent to fix it")),
            "and offers the one button that hands it to the agent")
        expect(view.slot.light.activity == .failed, "the strip's badge holds the failure")
        var asked: String?
        view.onAskAgent = { asked = $0 }
        view.pressAskAgent()
        expect(
            asked?.contains("noteTitle") == true && asked?.contains("PhotoNotes") == true,
            "the request names the app and the first problem: \(asked ?? "-")")

        view.applyForTest(fixture("live"), jpeg: Data([0, 1, 2, 3]))
        expect(view.summary == "live 604x1312", "bytes that do not decode never replace the last good picture")
        view.applyForTest(fixture("starting"))
        view.discardPicture()
        expect(view.summary.hasPrefix("starting"), "with no picture a starting pane is the status face")
    }

    private static func drawsInk(_ view: PreviewSlotView, _ expect: (Bool, String) -> Void) {
        guard let drawn = view.renderedPicture(size: NSSize(width: 900, height: 760)) else {
            expect(false, "a live pane can be drawn into a bitmap")
            return
        }
        let rep = drawn.rep
        var colours = Set<UInt32>()
        let steps = 12
        for row in 0..<steps {
            for column in 0..<steps {
                let x = (rep.pixelsWide - 1) * column / (steps - 1)
                let y = (rep.pixelsHigh - 1) * row / (steps - 1)
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let packed =
                    UInt32(colour.redComponent * 15) << 8 | UInt32(colour.greenComponent * 15) << 4
                    | UInt32(colour.blueComponent * 15)
                colours.insert(packed)
            }
        }
        expect(colours.count > 2, "the drawn picture is not a blank rectangle: \(colours.count) colours")
        let shape = drawn.frame.width / max(drawn.frame.height, 1)
        expect(abs(shape - 604.0 / 1312.0) < 0.02, "the picture keeps the device's shape: \(shape)")
        expect(drawn.frame.height <= 760, "and fits the room it has: \(drawn.frame)")
    }

    private static func commands(_ expect: (Bool, String) -> Void) {
        let view = pane()
        view.applyForTest(fixture("live"), jpeg: PreviewDemo.picture)
        expect(view.slot.appearance == "light", "a pane starts light")
        view.handle(.rebuild)
        expect(view.slot.appearance == "light", "a rebuild does not touch the appearance")
        view.handle(.toggleAppearance)
        expect(view.slot.appearance == "dark", "the toggle flips the slot's appearance")
        view.handle(.toggleAppearance)
        expect(view.slot.appearance == "light", "and flips it back")
        let plain = KeyChord.canonical(keyval: UInt32(UInt8(ascii: "a")), state: 0)
        let chorded = KeyChord.canonical(keyval: UInt32(UInt8(ascii: "a")), state: KeyChord.controlMask)
        expect(
            plain.flatMap(PreviewCommand.command(for:)) == .toggleAppearance,
            "a plain letter is a command")
        expect(
            chorded.flatMap(PreviewCommand.command(for:)) == nil,
            "a chord with control belongs to the window")
        let asking = PreviewSlotView(target: nil, runs: false, secrets: PreviewMemorySecrets())
        asking.handle(.toggleAppearance)
        expect(asking.slot.appearance == "light", "an asking pane takes no commands")
    }

    private static func addresses(_ expect: (Bool, String) -> Void) {
        expect(
            PreviewDemo.target("127.0.0.1:4300:/Users/marcus/pvtest/PhotoNotes")
                == PreviewTarget(host: "127.0.0.1", port: 4300, project: "/Users/marcus/pvtest/PhotoNotes"),
            "the driver's address reads as a target")
        expect(PreviewDemo.target("") == nil, "an empty driver address asks")
        expect(PreviewSlotView.split("mac.local:4301") == ("mac.local", 4301), "host and port split")
        expect(PreviewSlotView.split("mac.local").port == nil, "a bare host keeps the default port")
        let target = PreviewTarget(host: "mac.local", project: PreviewDemo.project)
        let content = PaneContent.preview(target.address)
        let data = try? JSONEncoder().encode(content)
        let back = data.flatMap { try? JSONDecoder().decode(PaneContent.self, from: $0) }
        expect(back == content && content.kind == .preview, "a layout snapshot restores the same app")
    }

    private static func ownership(_ expect: (Bool, String) -> Void) {
        let view = PreviewSlotView(
            target: PreviewTarget(host: "127.0.0.1", port: 1, project: "/nowhere"), runs: true,
            secrets: PreviewMemorySecrets())
        expect(view.isRunning && view.lifetimeCount > 0, "a running pane holds a stream through its lifetime")
        view.park()
        expect(
            !view.isRunning && !view.hasLink && view.lifetimeCount == 0,
            "a parked pane owns no clock and no stream")
        view.unpark()
        expect(view.isRunning && view.lifetimeCount > 0, "shown again it takes its stream back")
        view.shutdown()
        expect(
            !view.isRunning && !view.hasLink && view.lifetimeCount == 0,
            "a shut-down pane owns neither")
        view.unpark()
        expect(!view.isRunning && view.lifetimeCount == 0, "and cannot be woken again")
    }
}
