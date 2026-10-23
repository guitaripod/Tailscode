import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A probe's calls, counted from inside a concurrent scan. The sweep's probe is `@Sendable`, so a
/// local array cannot be written from it.
private final class AskedHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String] = []

    func add(_ host: String) {
        lock.lock()
        hosts.append(host)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }
}

/// Setting the renderer up is the half that decides whether video generation is a feature or a
/// rumour: an address typed blind into a one-field prompt is how it was, and every rule that makes
/// it feel like adding a server — the sweep, the check, the sentence a failure gets, the memory —
/// lives here rather than in three clients.
@Suite("Forge setup")
struct ForgeSetupTests {
    private let arch = ForgeEndpoint(host: "arch")

    private var tailnet: [TailscaleDevice] {
        [
            TailscaleDevice(
                name: "arch.tail1234.ts.net", hostname: "arch",
                addresses: ["100.64.0.3", "fd7a::3"], os: "linux"),
            TailscaleDevice(
                name: "phone.tail1234.ts.net", hostname: "phone", addresses: ["100.64.0.4"],
                os: "iOS"),
            TailscaleDevice(
                name: "mac.tail1234.ts.net", hostname: "macbook", addresses: ["100.64.0.5"],
                os: "macOS"),
        ]
    }

    @Test("The shared setup check passes")
    func sharedCheck() {
        let issues = ForgeSetupCheck.run()
        #expect(issues.isEmpty, "ForgeSetupCheck: \(issues)")
    }

    @Test("A typed address walks from nothing to a machine that answered, and files nothing early")
    func theWalk() {
        var setup = ForgeSetup(tailnet: .up(address: "100.64.0.9"))
        #expect(setup.status.stage == .blank)
        #expect(setup.commit == nil)
        setup.type("ftp://arch")
        #expect(setup.status.stage == .unreadable)
        #expect(setup.status.detail == ForgeEndpoint.complaint(.unsupportedScheme("ftp")))
        setup.type("arch:8188")
        #expect(setup.status.stage == .ready)
        #expect(setup.hint == nil, "a port somebody typed is not read back to them")
        #expect(setup.primary.action == .check(arch))
        setup.checking()
        #expect(setup.status.stage == .checking)
        #expect(!setup.primary.isEnabled)
        setup.reached(.listening)
        #expect(setup.status.stage == .listening)
        #expect(setup.commit == ForgeRenderer(endpoint: arch))
        #expect(setup.primary.action == .save(ForgeRenderer(endpoint: arch)))
        setup.type("other")
        #expect(setup.status.stage == .ready, "changing the address un-answers it")
        #expect(setup.commit == nil)
    }

    @Test("Every way the check can fail says the one thing that is wrong and the one press that fixes it")
    func everyFailureExplainsItself() {
        var setup = ForgeSetup(tailnet: .up(address: "100.64.0.9"))
        setup.type("arch")

        setup.reached(.timedOut)
        #expect(setup.status.diagnosis?.fix == .retry)
        #expect(setup.status.title == Localized.text("No answer from %@", "arch:8188"))
        #expect(setup.secondary != nil, "a sleeping renderer may still be the right machine")
        #expect(setup.secondaryNote != nil)

        setup.reached(.refused)
        #expect(setup.status.diagnosis?.fix == .copyCommand(ForgeSetup.startCommand))
        #expect(setup.status.diagnosis?.actionTitle == ForgeSetup.startCommandTitle)
        #expect(setup.status.title == Localized.text("Nothing is listening on %@ on %@", "8188", "arch"))
        #expect(setup.secondary != nil)

        setup.reached(.nameNotResolved)
        #expect(setup.status.diagnosis?.fix == .retry)
        #expect(setup.status.title == Localized.text("Can't resolve that name"))
        #expect(setup.secondary == nil, "an address that can never work is never filed")

        var offline = ForgeSetup(tailnet: .daemonDown)
        offline.type("arch")
        offline.reached(.timedOut)
        #expect(offline.status.diagnosis == ConnectDiagnosis.offTailnet(deviceName: offline.deviceName))
        #expect(!offline.discovery.isEnabled)

        #expect(ConnectDiagnosis.forge(verdict: .listening, endpoint: arch, tailnet: nil) == nil)
    }

    @Test("The renderer's failures reuse the server flow's own sentences wherever they are the same fact")
    func sentencesAreNotForked() {
        let address = HostAddress.read("arch:8188", defaultPort: 8188)
        guard case .address(let parsed) = address else {
            Issue.record("arch:8188 is an address")
            return
        }
        let server = ConnectDiagnosis.make(
            outcome: .unreachable("x"), address: parsed, tailnetAddress: nil, alternatePort: nil,
            sentPassword: false, reachability: .timedOut)
        let forge = ConnectDiagnosis.forge(
            verdict: .timedOut, endpoint: arch, tailnet: .loggedOut)
        #expect(server == forge, "off the tailnet is one fact with one wording")

        let serverName = ConnectDiagnosis.make(
            outcome: .unreachable("x"), address: parsed, tailnetAddress: "100.64.0.9",
            alternatePort: nil, sentPassword: false, reachability: .nameNotResolved)
        let forgeName = ConnectDiagnosis.forge(
            verdict: .nameNotResolved, endpoint: arch, tailnet: .up(address: "100.64.0.9"))
        #expect(serverName == forgeName, "and so is a name that will not resolve")
    }

    @Test("The tailnet is swept for a machine answering on the forge port, not for an agent")
    func sweepFindsTheRenderer() async {
        let targets = ForgeSweep.targets(tailnet)
        #expect(targets.map(\.machine) == ["arch", "macbook"], "a phone is never asked")
        #expect(targets[0].hosts == ["arch.tail1234.ts.net", "100.64.0.3"])
        #expect(targets.allSatisfy { $0.hosts.count <= 2 }, "one address per family is enough")

        let probe: ForgeSweep.Probe = { host, port in
            guard port == ForgeSweep.port else { return .refused }
            if host.hasSuffix("ts.net") { return .nameNotResolved }
            return host == "100.64.0.3" ? .listening : .timedOut
        }
        let found = await ForgeSweep.run(targets: targets, probe: probe)
        #expect(found.count == 1)
        #expect(found[0].machine == "arch")
        #expect(found[0].host == "100.64.0.3", "the name did not resolve, so its number answered")
        #expect(found[0].endpoint == ForgeEndpoint(host: "100.64.0.3"))
        #expect(found[0].renderer.name == "arch")

        let named: ForgeSweep.Probe = { host, _ in host.hasSuffix("ts.net") ? .listening : .refused }
        let byName = await ForgeSweep.run(targets: targets, probe: named)
        #expect(byName.map(\.host) == ["arch.tail1234.ts.net", "mac.tail1234.ts.net"],
            "a resolving name is preferred, because it is what is worth remembering")

        let asked = AskedHosts()
        let counting: ForgeSweep.Probe = { host, _ in
            asked.add(host)
            return .timedOut
        }
        _ = await ForgeSweep.run(targets: [targets[0]], probe: counting)
        #expect(asked.all == ["arch.tail1234.ts.net"], "a machine that said nothing is not asked twice")

        #expect(await ForgeSweep.run(targets: [], probe: probe).isEmpty)
        #expect(ForgeSweep.targets([]).isEmpty)
    }

    @Test("The scan is a dial, and it never leaves a machine on it that did not answer")
    func theDial() {
        let targets = ForgeSweep.targets(tailnet)
        var reading = ForgeSweepReading()
        #expect(reading.stage == .rest)
        #expect(reading.actionTitle == Localized.text("Scan my tailnet"))
        reading.began(targets, at: 0)
        #expect(reading.blips.count == 2)
        #expect(reading.blips.allSatisfy { $0.tone == .pending })
        #expect(reading.isScanning)
        reading.advanced(checked: 2, total: 2)
        #expect(reading.detail == Localized.text("Asked %@ of %@.", "2", "2"))
        let found = ForgeCandidate(machine: "arch", host: "100.64.0.3", port: ForgeSweep.port)
        reading.found(found, at: 0.2)
        reading.found(found, at: 0.3)
        #expect(reading.found.count == 1, "the same machine twice is one machine")
        #expect(reading.blips.first { $0.key == "arch" }?.tone == .ready)
        reading.finished()
        #expect(reading.blips.map(\.key) == ["arch"])
        #expect(reading.title == Localized.text("%@ found", "1"))
        #expect(reading.tone == .live)

        var nothing = ForgeSweepReading()
        nothing.began(targets, at: 0)
        nothing.finished()
        #expect(nothing.blips.isEmpty)
        #expect(nothing.title == Localized.text("No renderer answered"))
        #expect(nothing.tone == .attention)

        let blocked = ForgeSweepReading(blocked: .loggedOut)
        #expect(blocked.title == TailscaleReading.loggedOut.title)
        #expect(blocked.detail == TailscaleReading.loggedOut.detail)
        #expect(blocked.actionTitle == TailscaleReading.loggedOut.actionTitle)
        #expect(!blocked.isScanning)

        let stable = RadarBlip(key: "arch", tone: .ready, bornAt: 0)
        #expect(stable.angle == TailnetRadar.angle(for: "arch"), "the constellation is the tailnet's own")
    }

    @Test("A machine a scan found is adopted already checked")
    func adoptingSkipsTheSecondAsk() {
        let candidate = ForgeCandidate(
            machine: "arch", host: "100.64.0.3", port: ForgeSweep.port, os: "linux")
        var setup = ForgeSetup()
        setup.adopt(candidate)
        #expect(setup.status.stage == .listening)
        #expect(setup.commit == ForgeRenderer(endpoint: candidate.endpoint, name: "arch"))
        #expect(candidate.detail.contains(Localized.text("answering")))
        #expect(candidate.id == "100.64.0.3:8188")
    }

    @Test("The control that opens the forge says one thing everywhere and wears a mark only when there is one")
    func theEntryControl() {
        #expect(ForgeEntryPoint.title == ForgeBoard().heading, "the button and the surface share a name")
        #expect(ForgeEntryPoint.menuTitle.hasSuffix("…"))
        #expect(!ForgeEntryPoint.symbol.isEmpty && !ForgeEntryPoint.glyph.isEmpty)
        #expect(ForgeEntryPoint.glyph.count == 1, "a text client has one column to spend")
        #expect(ForgeEntryPoint.tooltip(configured: false) != ForgeEntryPoint.tooltip(configured: true))
        #expect(ForgeEntryPoint.activity(rendering: true)?.icon.motion == .working)
        #expect(ForgeEntryPoint.activity(rendering: false) == nil)
        #expect(ForgeEntryPoint.accessibilityLabel(rendering: false) == ForgeEntryPoint.title)
        #expect(ForgeEntryPoint.accessibilityLabel(rendering: true) != ForgeEntryPoint.title)
    }

    @Test("The forge opens over the work and closing it never stops the render")
    func theModal() {
        #expect(ForgeSurface.title == ForgeEntryPoint.title)
        #expect(ForgeSurface.subtitle == ForgeBoard().notice)
        #expect(!ForgeSurface.dismissTitle.isEmpty)
        #expect(ForgeSurface.dismissNote(rendering: false) == nil)
        let note = ForgeSurface.dismissNote(rendering: true)
        #expect(note != nil)
        #expect(ForgeSurface.preferredWidth > ForgeSurface.minimumWidth)
        #expect(ForgeSurface.preferredHeight > ForgeSurface.minimumHeight)
        #expect(ForgeSurface.preferredWidth > ForgeSurface.preferredHeight)
        #expect(!ForgeStudio.chips.contains(.prompt))
    }

    @Test("The renderer row is the setup, not a text field")
    func theRendererRowOpensTheSetup() {
        var board = ForgeBoard()
        #expect(board.renderCall == ForgeSetup.title)
        #expect(board.sections[0].detail == Localized.text("Find it on your tailnet, or type its address"))
        guard let index = board.rows.firstIndex(where: { $0.kind == .field(.endpoint) }) else {
            Issue.record("the renderer is a row")
            return
        }
        board.focus(index)
        #expect(board.activate() == .configure)
        #expect(ForgeField.allCases.filter(\.opensSetup) == [.endpoint])
        #expect(!ForgeField.endpoint.isCyclable)
    }
}
