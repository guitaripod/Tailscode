import AgentTestSupport
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import Testing

@testable import TailscodeCore

private let now = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

private func expert(
    task: ExpertTaskRef? = nil, pending: Int = 0, guards: [ExpertGuard] = [], notes: Int = 23,
    tasks: [ExpertTaskRef] = []
) -> MachineExpert {
    MachineExpert(
        id: "E1", name: "iPadOS", glyph: "iP", hue: "blue", purpose: "p", charter: "Measure.",
        skills: ["ipados"], guards: guards, createdAt: now,
        notebook: ExpertNotebookFacts(path: "/n", adopted: true, notes: notes, stale: 2, retired: 4),
        task: task, tasks: tasks, pending: pending)
}

private func failingGuard(since: Date) -> ExpertGuard {
    let last = ExpertGuardRun(at: now.addingTimeInterval(-3_600), passed: false, seconds: 41, exitCode: 65, failure: .exit)
    return ExpertGuard(
        id: "G", name: "AdaptiveLayoutTests", command: "x", last: last,
        history: [last, ExpertGuardRun(at: since, passed: false, seconds: 40, failure: .exit),
                  ExpertGuardRun(at: since.addingTimeInterval(-86_400), passed: true, seconds: 39)])
}

@Suite("Expert shelf")
struct ExpertShelfTests {
    @Test("A running task outranks notes waiting, which outrank a failing guard")
    func priority() {
        let task = ExpertTaskRef(sessionID: "S", title: "Unrager posts", updatedAt: now.addingTimeInterval(-840), active: true)
        let failing = failingGuard(since: now.addingTimeInterval(-7_200))
        #expect(ExpertReading.state(expert(task: task, pending: 3, guards: [failing]), now: now)
            == ExpertLine("Working on “Unrager posts” · 14m", .active))
        #expect(ExpertReading.state(expert(pending: 3, guards: [failing]), now: now)
            == ExpertLine("Idle · 3 notes to review", .attention))
        let failingLine = ExpertReading.state(expert(guards: [failing]), calendar: utc, now: now)
        #expect(failingLine.tone == .failing)
        #expect(failingLine.text.hasPrefix("Guard failing · AdaptiveLayoutTests · since today"))
        let passing = ExpertGuard(name: "T", command: "x", last: ExpertGuardRun(at: now, passed: true, seconds: 1))
        #expect(ExpertReading.state(expert(guards: [passing]), now: now).text == "Idle · 23 notes · guards passing")
        #expect(ExpertReading.state(expert(notes: 1), now: now).text == "Idle · 1 note")
        let drafting = ExpertTaskRef(sessionID: "S", title: "T", updatedAt: now, active: false, debrief: .drafting)
        #expect(ExpertReading.state(expert(tasks: [drafting]), now: now).tone == .active)
    }

    @Test("The board keeps machines in the person's order and experts in the order they were made")
    func order() {
        var later = expert()
        later.id = "E2"
        later.name = "Releases"
        later.createdAt = now.addingTimeInterval(60)
        let board = ExpertBoard.make([
            .init(profileID: "mac", machine: "macbook", experts: [later, expert()]),
            .init(profileID: "arch", machine: "arch", experts: []),
        ])
        #expect(board.rows.map(\.expert.name) == ["iPadOS", "Releases"])
        #expect(board.machines.map(\.profileID) == ["mac", "arch"])
        #expect(board.keepsExperts)
        #expect(board.row(profileID: "mac", expertID: "E2")?.machine == "macbook")
        let session = AgentSession(
            id: "S", agentType: .claudeCode, title: "t", createdAt: now, updatedAt: now, expertID: "E2")
        #expect(board.expert(for: session, profileID: "mac")?.expert.name == "Releases")
    }

    @Test("The board reads every machine that keeps experts and leaves out one that keeps none")
    func load() async throws {
        let keeping = MockBackend(agentType: .claudeCode, experts: MockExperts(experts: [expert()]))
        let none = MockBackend(agentType: .claudeCode)
        let board = await ExpertBoard.load([
            (ConnectionProfile(id: "a", name: "macbook", backend: .claudeCode, baseURL: URL(string: "http://a")!), keeping),
            (ConnectionProfile(id: "b", name: "arch", backend: .claudeCode, baseURL: URL(string: "http://b")!), none),
        ])
        #expect(board.rows.map(\.machine) == ["macbook"])
        #expect(board.machines.map(\.machine) == ["macbook"])
        #expect(board.unanswered.isEmpty)
    }

    @Test("Every hue has a dark and a light value, and an unknown one reads as blue")
    func hues() {
        #expect(ExpertHue("chartreuse") == .blue)
        #expect(ExpertHue.allCases.allSatisfy { $0.rgb.dark != $0.rgb.light })
        #expect(ExpertHue.yellow.wantsDarkGlyph)
    }
}

@Suite("Expert page readings")
struct ExpertPageTests {
    @Test("A bench item says how it is reached, whether it is free, who holds it, or that it is locked")
    func bench() {
        let ready = ExpertBenchItem(
            name: "iPad Pro M1", kind: .appleDevice, lock: "/tmp/l", state: .ready,
            facts: ["transport": "wired", "os": "iOS", "osVersion": "27.3"])
        #expect(ExpertReading.benchLine(ready, machine: "macbook") == ExpertLine("By cable · iOS 27.3 · free", .good))
        let held = ExpertBenchItem(
            name: "iPad Pro M1", kind: .appleDevice, state: .held, holder: ExpertBenchHolder(title: "Unrager posts"))
        #expect(ExpertReading.benchLine(held, machine: "macbook") == ExpertLine("Held by “Unrager posts”", .active))
        let locked = ExpertBenchItem(name: "iPhone Air", kind: .appleDevice, state: .locked)
        #expect(ExpertReading.benchLine(locked, machine: "macbook").tone == .attention)
        let away = ExpertBenchItem(name: "iPad mini", kind: .appleDevice, state: .absent)
        #expect(ExpertReading.benchLine(away, machine: "macbook").text == "Not reachable from macbook")
        let probe = ExpertBenchItem(name: "mini on arch", kind: .command, state: .ready, facts: ["output": "iPad Mini USB"])
        #expect(ExpertReading.benchLine(probe, machine: "macbook").text == "iPad Mini USB")
        #expect(ExpertReading.benchLine(ExpertBenchItem(name: "x", kind: .port), machine: "m").text == "Not checked yet")
    }

    @Test("A guard says its number against its line, how it failed, and since when")
    func guards() {
        let metric = ExpertGuardMetric(pattern: "(\\d+) ms", atMost: 100, unit: "ms")
        let passed = ExpertGuard(
            name: "Resize", command: "b", metric: metric,
            last: ExpertGuardRun(at: now, passed: true, seconds: 180, value: 46))
        let row = ExpertReading.guardRow(passed, calendar: utc, now: now)
        #expect(row.detail == ExpertLine("46 ms · at most 100 ms", .quiet))
        #expect(row.trailing == "3 min")
        let over = ExpertGuard(
            name: "Resize", command: "b", metric: metric,
            last: ExpertGuardRun(at: now, passed: false, seconds: 12, value: 450, failure: .metric))
        #expect(ExpertReading.guardRow(over, calendar: utc, now: now).detail.text.hasPrefix("450 ms · over its 100 ms line"))
        #expect(ExpertReading.duration(3_580) == "1 h")
        #expect(ExpertReading.duration(3_500) == "58 min")
        let failing = failingGuard(since: now.addingTimeInterval(-9 * 3_600))
        let failed = ExpertReading.guardRow(failing, calendar: utc, now: now)
        #expect(failed.detail.tone == .failing)
        #expect(failed.detail.text.hasPrefix("Failed · exit 65 · since today"))
        let timeout = ExpertGuard(name: "Slow", command: "b", last: ExpertGuardRun(at: now, passed: false, seconds: 1_800, failure: .timeout))
        #expect(ExpertReading.guardRow(timeout, calendar: utc, now: now).detail.text.hasPrefix("Stopped after 30 min"))
        let running = ExpertGuard(name: "R", command: "b", running: true)
        #expect(ExpertReading.guardRow(running, calendar: utc, now: now).detail.tone == .active)
    }

    @Test("The guards' line counts what passes and says when they were checked")
    func guardsLine() {
        let passing = ExpertGuard(name: "T", command: "x", last: ExpertGuardRun(at: now.addingTimeInterval(-9 * 3_600), passed: true, seconds: 1))
        let line = ExpertReading.guardsLine(expert(guards: [passing, passing]), calendar: utc, now: now)
        #expect(line.tone == .good)
        #expect(line.text.hasPrefix("2 of 2 passing · checked today"))
        let failingLine = ExpertReading.guardsLine(
            expert(guards: [passing, failingGuard(since: now)]), calendar: utc, now: now)
        #expect(failingLine.tone == .failing && failingLine.text.hasPrefix("1 of 2 failing"))
        #expect(ExpertReading.guardsLine(expert()).text == "None")
    }

    @Test("A stale note says since when; a note from a task names the task")
    func notes() {
        let stale = ExpertNote(
            id: "a.md", title: "Flaccy builds with the 27.1 RC", summary: "The beta fails",
            written: utc.date(from: DateComponents(year: 2026, month: 9, day: 12)), stale: true)
        let row = ExpertReading.noteRow(stale, calendar: utc, now: now)
        #expect(row.tag == ExpertLine("Not confirmed since Sep", .attention))
        #expect(row.trailing == "Sep 12")
        let fresh = ExpertNote(
            id: "b.md", title: "Open natively", summary: "s", written: now, source: "tailscode-expert:E1:S1")
        #expect(ExpertReading.noteRow(fresh, taskTitles: ["S1": "Unrager posts"], calendar: utc, now: now).trailing
            == "today\nUnrager posts")
        let retired = ExpertNote(
            id: "c.md", title: "Column", summary: "s", retired: ExpertNoteRetirement(at: now, reason: "Replaced"))
        #expect(ExpertReading.noteRow(retired, calendar: utc, now: now).detail.text == "Replaced · today")
    }

    @Test("A task starts with facts about its brief, never settings")
    func startsWith() {
        var full = expert(guards: [ExpertGuard(name: "T", command: "x", last: ExpertGuardRun(at: now, passed: true, seconds: 1))])
        full.journal = [ExpertJournalEntry(title: "A", at: now, outcome: "o")]
        full.bench = [
            ExpertBenchItem(name: "iPad Pro", kind: .appleDevice, state: .ready),
            ExpertBenchItem(name: "iPhone Air", kind: .appleDevice, state: .locked),
        ]
        let chips = ExpertReading.startsWith(full).map(\.text)
        #expect(chips == [
            "Its charter", "ipados skill", "23 notes", "The last task", "iPad Pro free", "iPhone Air locked",
            "Guards passing",
        ])
        #expect(ExpertWords.tokens(3_104) == "3.1k tokens, outside the conversation")
    }

    @Test("A measured number keeps only the digits it has")
    func numbers() {
        #expect(ExpertReading.number(2.4) == "2.4")
        #expect(ExpertReading.number(46) == "46")
        #expect(ExpertReading.number(0.05) == "0.05")
        #expect(ExpertReading.number(3.10) == "3.1")
    }

    @Test("Paths read with the home folder as a tilde")
    func paths() {
        #expect(ExpertReading.shortPath("/Users/marcus/Dev") == "~/Dev")
        #expect(ExpertReading.shortPath("/home/marcus") == "~")
        #expect(ExpertReading.shortPath("/srv/app") == "/srv/app")
    }
}

@Suite("Expert debrief")
struct ExpertDebriefTests {
    private func debrief(_ ops: [ExpertProposal.Operation], state: ExpertDebrief.State = .open) -> ExpertDebrief {
        ExpertDebrief(
            sessionID: "S", expertID: "E", at: now, coveredTurns: 2, state: state,
            proposals: ops.map { ExpertProposal(op: $0, title: "t", summary: "s", body: "b", reason: "r") })
    }

    @Test("The headline says what was learned, corrected and retired, in one sentence")
    func headline() {
        #expect(ExpertReading.debriefHeadline(debrief([.add, .add, .retire]), name: "iPadOS").text
            == "iPadOS learned 2 things and wants to retire 1")
        #expect(ExpertReading.debriefHeadline(debrief([.add, .change, .retire]), name: "iPadOS").text
            == "iPadOS learned 1 thing, corrected 1 note and wants to retire 1")
        #expect(ExpertReading.debriefHeadline(debrief([.change]), name: "iPadOS").text == "iPadOS corrected 1 note")
        #expect(ExpertReading.debriefHeadline(debrief([], state: .settled), name: "iPadOS").text
            == "Nothing new for the notebook")
        var skipped = debrief([.add], state: .settled)
        skipped.proposals[0].state = .skipped
        #expect(ExpertReading.debriefHeadline(skipped, name: "iPadOS").text == "Nothing new for the notebook")
        skipped.proposals[0].state = .accepted
        #expect(ExpertReading.debriefHeadline(skipped, name: "iPadOS").text == "Notebook updated")
        #expect(ExpertReading.debriefHeadline(debrief([], state: .failed), name: "iPadOS").tone == .failing)
    }

    @Test("Each row names its own action; Accept all is the one filled press")
    func actions() {
        #expect(ExpertWords.accept(.add) == "Add")
        #expect(ExpertWords.accept(.change) == "Change")
        #expect(ExpertWords.accept(.retire) == "Retire")
        #expect(ExpertWords.proposalState(.accepted, op: .retire) == "Retired")
        #expect(ExpertWords.proposalState(.pending, op: .add) == nil)
    }

    @Test("A draft sends only the notes left ticked, and a lasting-false note starts unticked")
    func draft() {
        let draft = ExpertDraft(
            name: "iPad OS", notes: [
                ExpertDraftNote(title: "Devices", summary: "s", body: "b"),
                ExpertDraftNote(title: "Port 8795", summary: "s", body: "b", lasting: false),
            ])
        let ticks = ExpertMaking.defaultTicks(draft)
        #expect(ticks == ["Devices"])
        let final = ExpertMaking.finalized(draft, keeping: ticks.union(["Port 8795"]))
        #expect(final.notes?.map(\.title) == ["Devices", "Port 8795"])
        #expect(final.notes?.allSatisfy { $0.lasting == true } == true)
        #expect(final.glyph == "Ip")
    }
}

@Suite("Expert capability")
struct ExpertCapabilityTests {
    @Test("The demo machine keeps experts, so every client's demo offers them")
    func demoKeepsExperts() async throws {
        #expect(DemoWorld.claude.capabilities.supportsExperts)
        let experts = try await DemoWorld.claude.machineExperts()
        #expect(experts?.count == 3)
    }

    @Test("Experts is a capability every client must answer")
    func registered() {
        #expect(AppCapability.allCases.contains(.experts))
        #expect(CapabilityRegistry.definition(for: .experts).id == .experts)
    }
}
