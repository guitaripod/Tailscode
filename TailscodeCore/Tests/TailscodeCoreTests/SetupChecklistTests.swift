import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Setup checklist")
struct SetupChecklistTests {
    private let english = Locale(identifier: "en_US")

    private func checklist(_ name: String) throws -> SetupChecklist {
        SetupChecklist(snapshot: try #require(SetupFixtures.snapshot(named: name)), locale: english)
    }

    @Test("A ready machine says so and offers the one thing to do next")
    func ready() throws {
        let list = try checklist("ready")
        #expect(list.status == .ready)
        #expect(list.headline == "Voice calls are ready")
        #expect(list.primary == .finish(label: "Try a call"))
        #expect(list.rows.count == 8)
        #expect(list.rows.allSatisfy { $0.state == .done && $0.icon.motion == .still })
        #expect(list.beta == .voiceCall)
        #expect(list.tone == .live)
    }

    @Test("A command is a monospace block with its reason, and the primary button copies it")
    func command() throws {
        let list = try checklist("command")
        #expect(list.status == .needs(4))
        #expect(list.headline == "Needs 4 things")
        let row = try #require(list.rows.first { $0.id == "voice.cdi" })
        #expect(row.state == .needsYou)
        #expect(row.fix?.kind == .command)
        #expect(row.fix?.command == "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml")
        #expect(row.fix?.reason?.contains("administrator rights") == true)
        #expect(list.primary == .copy(command: row.fix!.command!, label: "Copy command"))
        let model = try #require(list.rows.first { $0.id == "voice.model" })
        #expect(model.state == .todo)
        #expect(model.fix?.cost == "44 GB, about 12 minutes")
    }

    @Test("A blocker is an explanation with no fix, and the button does not pretend there is one")
    func blocker() throws {
        let list = try checklist("blocker")
        #expect(list.status == .needs(1))
        let row = try #require(list.rows.first { $0.id == "voice.engine" })
        #expect(row.state == .needsYou)
        #expect(row.fix == nil)
        #expect(row.line?.contains("Only 2 GB") == true)
        #expect(row.icon.tone == .attention && row.icon.motion == .still)
        #expect(list.primary == nil)
    }

    @Test("A row waiting on another is quiet, not a blocker")
    func waitingRows() throws {
        let list = try checklist("command")
        let engine = try #require(list.rows.first { $0.id == "voice.engine" })
        #expect(engine.state == .todo)
        #expect(engine.line == "Waits for GPU access in containers")
        #expect(engine.icon.tone == .quiet)
    }

    @Test("A download breathes with its bytes and its time left, and nothing else offers a button")
    func downloading() throws {
        let list = try checklist("downloading")
        #expect(list.status == .working)
        #expect(list.headline == "Working: downloading the voice model, 31%")
        #expect(list.primary == nil)
        #expect(list.canCancel)
        let row = try #require(list.jobRow)
        #expect(row.id == "voice.model")
        #expect(row.state == .working)
        #expect(row.icon.motion.isAnimated)
        #expect(row.job?.line == "14 of 44 GB, about 8 minutes left")
        #expect(row.job?.fraction == 0.31)
        let next = try #require(list.rows.first { $0.id == "voice.image" })
        #expect(next.state == .todo)
        #expect(next.fix?.enabled == false)
    }

    @Test("A machine that can never do it says so once, with the reason, and offers nothing")
    func unavailable() throws {
        let list = try checklist("unavailable")
        #expect(list.status == .unavailable)
        #expect(list.unavailable)
        #expect(list.headline == "Not possible on this machine: it has no NVIDIA GPU with 80 GB")
        #expect(list.primary == nil)
        #expect(list.tone == .quiet)
        let row = try #require(list.rows.first { $0.id == "voice.gpu" })
        #expect(row.state == .unavailable)
        #expect(row.icon.motion == .still)
        let small = try checklist("smallgpu")
        #expect(small.headline == "Not possible on this machine: its GPU has 24 GB of memory and voice needs 80 GB")
        #expect(small.rows.first { $0.id == "voice.gpu" }?.state == .done)
        #expect(small.rows.first { $0.id == "voice.vram" }?.state == .unavailable)
    }

    @Test("A failed job keeps its row, says why in words and offers to try again")
    func failed() throws {
        let list = try checklist("failed")
        let row = try #require(list.rows.first { $0.id == "voice.model" })
        #expect(row.state == .failed)
        #expect(row.failure == "There is not enough room on the disk: 9 GB free, 44 GB needed.")
        let relaunched = SetupChecklist(
            snapshot: SetupSnapshot(
                target: SetupTarget(host: "x", capability: "voice"), phase: .loaded,
                report: (try #require(SetupFixtures.snapshot(named: "failed"))).report),
            locale: english)
        let again = try #require(relaunched.rows.first { $0.id == "voice.model" })
        #expect(again.state == .failed)
        #expect(again.failure == "There is not enough room on the disk.")
        #expect(row.icon.tone == .danger && row.icon.motion == .still)
        #expect(list.primary == .setUp(label: "Try again"))
    }

    @Test("The engine starting is work without a job to cancel")
    func starting() throws {
        let list = try checklist("starting")
        #expect(list.status == .working)
        #expect(list.rows.first { $0.id == "voice.engine" }?.state == .working)
        #expect(list.rows.first { $0.id == "voice.engine" }?.line == "Starting, 40%. This can take a few minutes.")
        #expect(!list.canCancel)
    }

    @Test("A machine with no gateway is one command, said with what voice asks of it")
    func absent() throws {
        let list = try checklist("absent")
        #expect(list.rows.count == 1)
        let row = list.rows[0]
        #expect(row.id == "voice.gateway")
        #expect(row.state == .needsYou)
        #expect(row.fix?.command == VoiceBridgeInstall.installCommand)
        #expect(row.line?.contains("NVIDIA GPU with 80 GB") == true)
        #expect(list.primary == .copy(command: VoiceBridgeInstall.installCommand, label: "Copy command"))
        #expect(list.headline == "Needs one thing")
    }

    @Test("Checking, an unreachable machine and a password have a headline and no rows")
    func plainStates() throws {
        let checking = try checklist("checking")
        #expect(checking.status == .checking && checking.rows.isEmpty && checking.primary == nil)
        let unreachable = try checklist("unreachable")
        #expect(unreachable.status == .unreachable)
        #expect(unreachable.headline == "Could not reach this machine: check that it is on and that Tailscale is connected")
        let password = try checklist("password")
        #expect(password.status == .wantsPassword)
        #expect(password.primary == .askPassword(label: "Add the password"))
    }

    @Test("Every named fixture reads, and an unknown name does not")
    func fixturesRead() {
        for name in SetupFixtures.names {
            let snapshot = SetupFixtures.snapshot(named: name)
            #expect(snapshot != nil, "\(name)")
            if let snapshot {
                let list = SetupChecklist(snapshot: snapshot, locale: english)
                #expect(!list.headline.isEmpty && !list.spoken.isEmpty)
            }
        }
        #expect(SetupFixtures.snapshot(named: "nonsense") == nil)
    }

    @Test("A newer daemon's unknown ids and states still make rows with honest words")
    func unknownIDsStillDraw() {
        let report = SetupReport(
            capability: "voice", ready: false,
            checks: [
                SetupCheck(id: "voice.gateway", state: .ok),
                SetupCheck(id: "voice.future", state: .blocked, detail: "A new kernel module is missing"),
            ])
        let snapshot = SetupSnapshot(target: .voice(VoiceEndpoint(host: "box")), phase: .loaded, report: report)
        let list = SetupChecklist(snapshot: snapshot, locale: english)
        #expect(list.rows[1].title == "A new kernel module is missing")
        #expect(list.rows[1].state == .needsYou)
        #expect(list.headline == "Needs one thing")
    }

    @Test("The row for each state is in the activity vocabulary: only work moves")
    func vocabulary() {
        let rows: [SetupRow.State] = [.done, .todo, .working, .needsYou, .failed, .unavailable]
        for state in rows {
            let row = SetupRow(id: "x", state: state, title: "t", line: nil)
            #expect(row.icon.motion.isAnimated == (state == .working), "\(state)")
            #expect(!row.icon.glyph.isEmpty && !row.icon.symbol.isEmpty)
            #expect(!row.word.isEmpty)
        }
    }

    private func capabilityRow(_ name: String) throws -> SetupCapabilityRow? {
        let snapshot = try #require(SetupFixtures.snapshot(named: name))
        return SetupCapabilityRow.row(for: snapshot, locale: english)
    }

    @Test("Capability rows show what is available, offer the rest quietly and hide what can never be")
    func capabilityRows() throws {
        let ready = try #require(try capabilityRow("ready"))
        #expect(ready.title == "Voice calls" && ready.chip == "Ready" && ready.line == "Voice calls are ready")
        #expect(!ready.quiet)
        let needs = try #require(try capabilityRow("command"))
        #expect(needs.chip == "Needs setup")
        let working = try #require(try capabilityRow("downloading"))
        #expect(working.chip == "Setting up")
        let absent = try #require(try capabilityRow("absent"))
        #expect(absent.title == "Add voice calls" && absent.quiet)
        for hidden in ["unavailable", "unreachable", "checking", "password"] {
            #expect(try capabilityRow(hidden) == nil, "\(hidden)")
        }
        let all = SetupCapabilityRow.rows(
            for: ["ready", "unavailable", "absent"].compactMap { SetupFixtures.snapshot(named: $0) }, locale: english)
        #expect(all.count == 2)
    }
}
