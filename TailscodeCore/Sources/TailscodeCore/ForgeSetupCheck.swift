import CodingAgentKit
import Foundation

/// The setup's rules, checked headlessly — the parser, the sweep, every sentence a failure can
/// produce, and the one rule that is the renderer's own rather than the server flow's. Run from
/// `ForgeBoardCheck` so both desktops' `--selftest` carry it without a third call site.
public enum ForgeSetupCheck {
    public static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let arch = ForgeEndpoint(host: "arch")
        var setup = ForgeSetup(tailnet: .up(address: "100.64.0.9"))
        expect(setup.status.stage == .blank, "a setup with nothing typed is blank")
        expect(!setup.primary.isEnabled, "and its button does nothing")
        expect(setup.primary.action == .nothing, "which it says by offering no action")
        expect(setup.commit == nil, "nothing is filed from an empty field")
        expect(setup.tailnetLine.contains("100.64.0.9"), "the surface states this machine's own address")

        setup.type("0.0.0.0:8188")
        expect(setup.status.stage == .unreadable, "the address a server binds to is not one to reach")
        expect(setup.status.detail == ForgeEndpoint.complaint(.bindAll), "and the refusal is Core's own sentence")
        expect(!setup.primary.isEnabled, "which nothing can be checked from")

        setup.type("arch")
        expect(setup.status.stage == .ready, "a bare machine name reads")
        expect(setup.endpoint == arch, "as the machine and the port it answers on")
        expect(setup.hint == Localized.text("→ %@ (port added)", "arch:8188"), "and the supplied port is said out loud")
        expect(setup.primary.action == .check(arch), "the button asks the port")
        expect(setup.commit == nil, "and nothing is filed before it answers")

        setup.checking()
        expect(setup.status.stage == .checking, "asking is a state with its own words")
        expect(!setup.primary.isEnabled, "and nothing is pressed twice")

        setup.reached(.listening)
        expect(setup.status.stage == .listening, "a port that answered settles it")
        expect(setup.commit?.endpoint == arch, "and the renderer is ready to file")
        expect(setup.secondary == nil, "with nothing else to offer")
        expect(setup.status.diagnosis == nil, "and nothing to explain")

        setup.reached(.timedOut)
        expect(setup.status.stage == .failed, "silence is a failure")
        expect(setup.status.diagnosis != nil, "that explains itself")
        expect(setup.commit == nil, "and files nothing")
        expect(
            setup.secondary?.action == .save(ForgeRenderer(endpoint: arch, name: setup.name)),
            "but a renderer that sleeps may still be the right machine")
        expect(setup.secondaryNote != nil, "and saving it anyway says why")
        expect(setup.primary.action == .check(arch), "while the ordinary press asks again")

        setup.reached(.refused)
        expect(setup.status.diagnosis?.fix == .copyCommand(ForgeSetup.startCommand),
            "a machine that is up with nothing listening is handed the line that starts it")
        expect(setup.secondary != nil, "and can still be saved for later")

        setup.reached(.nameNotResolved)
        expect(setup.secondary == nil, "a name this machine cannot resolve is never filed")

        var offline = ForgeSetup(tailnet: .loggedOut)
        offline.type("arch")
        offline.reached(.timedOut)
        expect(offline.status.diagnosis?.fix == .openTailscale,
            "a probe from a machine with no tailnet blames the tailnet rather than the renderer")
        expect(!offline.discovery.isEnabled, "and there is nothing to scan from here")
        expect(offline.discoveryBlock?.fix == .openTailscale,
            "so the scan that cannot run says why and offers the one door out rather than greying out")
        expect(ForgeSetup(tailnet: .up(address: "100.64.0.9")).discovery.action == .scan, "while a connected one can sweep")
        expect(ForgeSetup(tailnet: .up(address: "100.64.0.9")).discoveryBlock == nil, "with nothing in its way to explain")

        let candidate = ForgeCandidate(machine: "arch", host: "100.64.0.3", port: ForgeSweep.port)
        var adopted = ForgeSetup()
        adopted.adopt(candidate)
        expect(adopted.status.stage == .listening, "a machine a scan found has already answered")
        expect(adopted.commit?.name == "arch", "and it brings the name the tailnet gave it")
        expect(adopted.commit?.endpoint == candidate.endpoint, "at the address it answered on")

        let devices = [
            TailscaleDevice(
                name: "arch.tail1234.ts.net", hostname: "arch", addresses: ["100.64.0.3", "fd7a::3"],
                os: "linux", lastSeen: nil),
            TailscaleDevice(
                name: "phone.tail1234.ts.net", hostname: "phone", addresses: ["100.64.0.4"],
                os: "iOS", lastSeen: nil),
            TailscaleDevice(
                name: "mac.tail1234.ts.net", hostname: "macbook", addresses: ["100.64.0.5"],
                os: "macOS", lastSeen: nil),
        ]
        let targets = ForgeSweep.targets(devices)
        expect(targets.map(\.machine) == ["arch", "macbook"], "a phone can never hold a card, so it is not asked")
        expect(targets[0].hosts == ["arch.tail1234.ts.net", "100.64.0.3"],
            "each machine is asked by name first and by one address behind it")

        expect(ForgeSweep.step(for: .listening) == .found, "a port that answered is the machine")
        expect(
            ForgeSweep.step(for: .nameNotResolved) == .tryNext,
            "MagicDNS being off says nothing about the machine, so its number is tried next")
        expect(ForgeSweep.step(for: .refused) == .notIt, "a machine that refused is not it")
        expect(
            ForgeSweep.step(for: .timedOut) == .notIt,
            "and one that said nothing is not asked twice — the second address would only spend the timeout again")

        let candidate2 = ForgeCandidate(machine: "arch", host: "100.64.0.3", port: ForgeSweep.port)
        expect(candidate2.detail.contains("100.64.0.3:8188"), "a found machine says where it answered")
        expect(candidate2.renderer.name == "arch", "and carries the name the tailnet gave it")

        var sweep = ForgeSweepReading()
        expect(sweep.actionTitle == Localized.text("Scan my tailnet"), "a dial nobody has spun offers to spin")
        expect(!sweep.isScanning, "and is not scanning")
        sweep.began(targets, at: 0)
        expect(sweep.blips.count == 2, "every machine takes its place before a probe lands")
        expect(sweep.blips.allSatisfy { $0.tone == .pending }, "unlit until it answers")
        expect(sweep.isScanning, "and the dial is turning")
        sweep.advanced(checked: 1, total: 2)
        expect(sweep.detail == Localized.text("Asked %@ of %@.", "1", "2"), "the wait counts itself")
        sweep.found(candidate2, at: 0.4)
        expect(sweep.blips.first { $0.key == "arch" }?.tone == .ready, "a machine that answers lights")
        sweep.finished()
        expect(sweep.blips.count == 1, "and one that never did leaves the dial rather than reading as a maybe")
        expect(sweep.title == Localized.text("%@ found", "1"), "the result is a count")
        expect(sweep.actionTitle == Localized.text("Scan again"), "and the dial can be spun again")

        var empty = ForgeSweepReading()
        empty.began(targets, at: 0)
        empty.finished()
        expect(empty.title == Localized.text("No renderer answered"), "a sweep that found nothing says so")
        expect(empty.detail.contains("\(ForgeSweep.port)"), "and names the port it asked on")

        let blocked = ForgeSweepReading(blocked: .notInstalled)
        expect(blocked.title == TailscaleReading.notInstalled.title, "a machine with no tailnet cannot scan one")
        expect(blocked.actionTitle == TailscaleReading.notInstalled.actionTitle, "and is offered the fix rather than a result")

        expect(ForgeSweepKey.missing.actionTitle != ForgeSweepKey.rejected.actionTitle,
            "a key never given and a key refused are fixed by different presses")
        expect(ForgeSweepKey.rejected.tone == .danger, "a key the tailnet would not accept is a failure")
        expect(ForgeSweepKey.missing.tone == .attention, "while one that was never given is only a step not taken")

        let renderer = ForgeRenderer(endpoint: arch, name: "  arch  ")
        expect(renderer.name == "arch", "a name is trimmed before it is kept")
        expect(ForgeRenderer(endpoint: arch, name: "   ").name == nil, "and whitespace is no name at all")
        expect(renderer.title == "arch" && renderer.detail == "arch:8188", "a row says the machine and the address")
        expect(ForgeRenderer(endpoint: arch).title == "arch", "an address typed blind still names itself")
        expect(
            ForgeEndpoint(host: "arch.taila1a09.ts.net").shortName == "arch",
            "a MagicDNS name is the machine, not the tailnet")
        expect(ForgeEndpoint(host: "arch").shortName == "arch", "and a bare name is already the machine")
        expect(
            ForgeBoard(endpoint: ForgeEndpoint(host: "arch.taila1a09.ts.net")).value(of: .endpoint)
                == "arch",
            "the chip wears the machine")
        expect(
            ForgeBoard(
                endpoint: ForgeEndpoint(host: "100.64.0.3"), rendererName: "studio"
            ).value(of: .endpoint) == "studio",
            "a name this device filed outranks the address")
        expect(ForgeRenderer.badge(current: true) != nil, "the machine in use wears a word")
        expect(ForgeRenderer.badge(current: false) == nil, "and the others do not")

        expect(ForgeEntryPoint.tooltip(configured: true) != ForgeEntryPoint.tooltip(configured: false),
            "the control promises something different before a renderer exists")
        expect(ForgeEntryPoint.activity(rendering: true) == .working, "and wears a live mark while one is out")
        expect(ForgeEntryPoint.activity(rendering: false) == nil, "but never an idle decoration")
        expect(ForgeSurface.dismissNote(rendering: true) != nil, "closing over a render says what it does not do")
        expect(ForgeSurface.dismissNote(rendering: false) == nil, "and says nothing when there is nothing to say")
        expect(ForgeSurface.title == ForgeBoard.heading, "the control, the modal and the surface share one name")
        expect(ForgeSurface.subtitle == ForgeBoard.notice, "and the modal carries the board's own line about where rendering happens")
        expect(ForgeSweep.deadline > ForgeSweep.probeTimeout, "a scan outlives any one probe in it")
        expect(ForgeSurface.preferredWidth >= ForgeSurface.minimumWidth, "the modal's sizes are consistent")
        expect(ForgeSurface.preferredHeight >= ForgeSurface.minimumHeight, "in both directions")
        expect(
            ForgeSurface.preferredWidth > ForgeSurface.preferredHeight,
            "the desktop is a landscape studio, not a tall form")
        expect(ForgeStudio.chips.contains(.size) && ForgeStudio.chips.contains(.seed), "the chips are the walkable settings")
        expect(ForgeModel.label.contains(ForgeModel.family), "the model is named by its transformer, not a nickname")
        expect(!ForgeStudio.chips.contains(.prompt), "the prompt is the composer, not a chip")
        expect(!ForgeStudio.chips.contains(.endpoint), "the renderer is a status, not a chip")
        expect(ForgeStudio.stageShare > 0.5 && ForgeStudio.stageShare < 0.75, "the stage is the room")
        expect(ForgeStudio.controlWidth > 280, "the control column has a line length")
        expect(ForgeStudio.filmHeight > 60, "the filmstrip can hold a thumb")
        for field in ForgeField.allCases {
            expect(!field.symbol.isEmpty, "every decision has a face (\(field.rawValue))")
        }
        expect(ForgeSetup.startCommand.contains("--listen"), "the command handed over binds where the tailnet can reach it")
        expect(ForgeSetup.startCommand.contains("\(ForgeSweep.port)"), "on the port everything else asks")

        expect(
            ForgeSetup.order == [.intro, .find, .known, .address, .outcome],
            "the setup is met in one order on every desk: what this is, the way in that is not typing, the machines that already answered, the address as typed, and what became of it")
        expect(ForgeSetup.order == ForgeSetupArea.allCases, "and no area is left undrawn")

        for field in ForgeField.allCases {
            expect(
                field.isCyclable
                    ? (field.affordanceGlyph == "▾" && field.affordanceSymbol == "chevron.down")
                    : (field.affordanceGlyph == "›" && field.affordanceSymbol == "chevron.right"),
                "a row that opens a list and a row that opens a field wear different marks (\(field.rawValue))")
        }

        expect(ForgeJobPhase.running(0.5).activity == .working, "a render that is working breathes")
        expect(ForgeJobPhase.queued(2).activity == .queued(2), "a queued one waits with its count")
        expect(ForgeJobPhase.done(ForgeAsset(filename: "x.mp4")).activity == nil, "and a settled one holds still")
        expect(ForgeJobPhase.failed("x").tone == .danger, "a failure wears the danger slot")
        expect(ForgeJobPhase.failed("x").stageGlyph == "✕", "and its stage says so in one column")
        expect(
            ForgeJobPhase.done(ForgeAsset(filename: "x.mp4")).stageSymbol == "play.rectangle",
            "a finished stage offers the play it promises")
        return failures
    }
}
