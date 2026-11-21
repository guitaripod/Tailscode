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

private func master(
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

@Suite("Master shelf")
struct MasterShelfTests {
    @Test("A running task outranks notes waiting, which outrank a failing guard")
    func priority() {
        let task = ExpertTaskRef(sessionID: "S", title: "Unrager posts", updatedAt: now.addingTimeInterval(-840), active: true)
        let failing = failingGuard(since: now.addingTimeInterval(-7_200))
        #expect(MasterReading.state(master(task: task, pending: 3, guards: [failing]), now: now)
            == MasterLine("Working on “Unrager posts” · 14m", .active))
        #expect(MasterReading.state(master(pending: 3, guards: [failing]), now: now)
            == MasterLine("3 notes to review", .attention))
        let failingLine = MasterReading.state(master(guards: [failing]), calendar: utc, now: now)
        #expect(failingLine.tone == .failing)
        #expect(failingLine.text.hasPrefix("Guard failing · AdaptiveLayoutTests · since today"))
        let passing = ExpertGuard(name: "T", command: "x", last: ExpertGuardRun(at: now, passed: true, seconds: 1))
        #expect(MasterReading.state(master(guards: [passing]), now: now).text == "Idle · 23 notes · guards passing")
        #expect(MasterReading.state(master(notes: 1), now: now).text == "Idle · 1 note")
        let drafting = ExpertTaskRef(sessionID: "S", title: "T", updatedAt: now, active: false, debrief: .drafting)
        #expect(MasterReading.state(master(tasks: [drafting]), now: now).tone == .active)
    }

    @Test("The board keeps machines in the person's order and masters in the order they were made")
    func order() {
        var later = master()
        later.id = "E2"
        later.name = "Releases"
        later.createdAt = now.addingTimeInterval(60)
        let board = MasterBoard.make([
            .init(profileID: "mac", machine: "macbook", masters: [later, master()]),
            .init(profileID: "arch", machine: "arch", masters: []),
        ])
        #expect(board.rows.map(\.master.name) == ["iPadOS", "Releases"])
        #expect(board.machines.map(\.profileID) == ["mac", "arch"])
        #expect(board.keepsExperts)
        #expect(board.row(profileID: "mac", expertID: "E2")?.machine == "macbook")
        let session = AgentSession(
            id: "S", agentType: .claudeCode, title: "t", createdAt: now, updatedAt: now, expertID: "E2")
        #expect(board.master(for: session, profileID: "mac")?.master.name == "Releases")
    }

    @Test("The board reads every machine that keeps masters and leaves out one that keeps none")
    func load() async throws {
        let keeping = MockBackend(agentType: .claudeCode, experts: MockExperts(experts: [master()]))
        let none = MockBackend(agentType: .claudeCode)
        let board = await MasterBoard.load([
            (ConnectionProfile(id: "a", name: "macbook", backend: .claudeCode, baseURL: URL(string: "http://a")!), keeping),
            (ConnectionProfile(id: "b", name: "arch", backend: .claudeCode, baseURL: URL(string: "http://b")!), none),
        ])
        #expect(board.rows.map(\.machine) == ["macbook"])
        #expect(board.machines.map(\.machine) == ["macbook"])
        #expect(board.unanswered.isEmpty)
    }

    @Test("Every hue has a dark and a light value, and an unknown one reads as blue")
    func hues() {
        #expect(MasterHue("chartreuse") == .blue)
        #expect(MasterHue.allCases.allSatisfy { $0.rgb.dark != $0.rgb.light })
        #expect(MasterHue.yellow.wantsDarkGlyph)
    }
}

@Suite("Master page readings")
struct MasterPageTests {
    @Test("A bench item says how it is reached, whether it is free, who holds it, or that it is locked")
    func bench() {
        let ready = ExpertBenchItem(
            name: "iPad Pro M1", kind: .appleDevice, lock: "/tmp/l", state: .ready,
            facts: ["transport": "wired", "os": "iOS", "osVersion": "27.3"])
        #expect(MasterReading.benchLine(ready, machine: "macbook") == MasterLine("By cable · iOS 27.3 · free", .good))
        let held = ExpertBenchItem(
            name: "iPad Pro M1", kind: .appleDevice, state: .held, holder: ExpertBenchHolder(title: "Unrager posts"))
        #expect(MasterReading.benchLine(held, machine: "macbook") == MasterLine("Held by “Unrager posts”", .active))
        let locked = ExpertBenchItem(name: "iPhone Air", kind: .appleDevice, state: .locked)
        #expect(MasterReading.benchLine(locked, machine: "macbook").tone == .attention)
        let away = ExpertBenchItem(name: "iPad mini", kind: .appleDevice, state: .absent)
        #expect(MasterReading.benchLine(away, machine: "macbook").text == "Not reachable from macbook")
        let probe = ExpertBenchItem(name: "mini on arch", kind: .command, state: .ready, facts: ["output": "iPad Mini USB"])
        #expect(MasterReading.benchLine(probe, machine: "macbook").text == "iPad Mini USB")
        #expect(MasterReading.benchLine(ExpertBenchItem(name: "x", kind: .port), machine: "m").text == "Not checked yet")
    }

    @Test("A guard says its number against its line, how it failed, and since when")
    func guards() {
        let metric = ExpertGuardMetric(pattern: "(\\d+) ms", atMost: 100, unit: "ms")
        let passed = ExpertGuard(
            name: "Resize", command: "b", metric: metric,
            last: ExpertGuardRun(at: now, passed: true, seconds: 180, value: 46))
        let row = MasterReading.guardRow(passed, calendar: utc, now: now)
        #expect(row.detail == MasterLine("46 ms · at most 100 ms", .quiet))
        #expect(row.trailing == "3 min")
        let over = ExpertGuard(
            name: "Resize", command: "b", metric: metric,
            last: ExpertGuardRun(at: now, passed: false, seconds: 12, value: 450, failure: .metric))
        #expect(MasterReading.guardRow(over, calendar: utc, now: now).detail.text.hasPrefix("450 ms · over its 100 ms line"))
        #expect(MasterReading.duration(3_580) == "1 h")
        #expect(MasterReading.duration(3_500) == "58 min")
        let failing = failingGuard(since: now.addingTimeInterval(-9 * 3_600))
        let failed = MasterReading.guardRow(failing, calendar: utc, now: now)
        #expect(failed.detail.tone == .failing)
        #expect(failed.detail.text.hasPrefix("Failed · exit 65 · since today"))
        let timeout = ExpertGuard(name: "Slow", command: "b", last: ExpertGuardRun(at: now, passed: false, seconds: 1_800, failure: .timeout))
        #expect(MasterReading.guardRow(timeout, calendar: utc, now: now).detail.text.hasPrefix("Stopped after 30 min"))
        let running = ExpertGuard(name: "R", command: "b", running: true)
        #expect(MasterReading.guardRow(running, calendar: utc, now: now).detail.tone == .active)
    }

    @Test("The guards' line counts what passes and says when they were checked")
    func guardsLine() {
        let passing = ExpertGuard(name: "T", command: "x", last: ExpertGuardRun(at: now.addingTimeInterval(-9 * 3_600), passed: true, seconds: 1))
        let line = MasterReading.guardsLine(master(guards: [passing, passing]), calendar: utc, now: now)
        #expect(line.tone == .good)
        #expect(line.text.hasPrefix("2 of 2 passing · checked today"))
        let failingLine = MasterReading.guardsLine(
            master(guards: [passing, failingGuard(since: now)]), calendar: utc, now: now)
        #expect(failingLine.tone == .failing && failingLine.text.hasPrefix("1 of 2 failing"))
        #expect(MasterReading.guardsLine(master()).text == "None")
    }

    @Test("A stale note says since when; a note from a task names the task")
    func notes() {
        let stale = ExpertNote(
            id: "a.md", title: "Flaccy builds with the 27.1 RC", summary: "The beta fails",
            written: utc.date(from: DateComponents(year: 2026, month: 9, day: 12)), stale: true)
        let row = MasterReading.noteRow(stale, calendar: utc, now: now)
        #expect(row.tag == MasterLine("Not confirmed since Sep", .attention))
        #expect(row.trailing?.contains("12") == true && row.trailing?.contains("Sep") == true)
        let fresh = ExpertNote(
            id: "b.md", title: "Open natively", summary: "s", written: now, source: "tailscode-expert:E1:S1")
        #expect(MasterReading.noteRow(fresh, taskTitles: ["S1": "Unrager posts"], calendar: utc, now: now).trailing
            == "today\nUnrager posts")
        let retired = ExpertNote(
            id: "c.md", title: "Column", summary: "s", retired: ExpertNoteRetirement(at: now, reason: "Replaced"))
        #expect(MasterReading.noteRow(retired, calendar: utc, now: now).detail.text == "Replaced · today")
    }

    @Test("A task starts with facts about its brief, never settings")
    func startsWith() {
        var full = master(guards: [ExpertGuard(name: "T", command: "x", last: ExpertGuardRun(at: now, passed: true, seconds: 1))])
        full.journal = [ExpertJournalEntry(title: "A", at: now, outcome: "o")]
        full.bench = [
            ExpertBenchItem(name: "iPad Pro", kind: .appleDevice, state: .ready),
            ExpertBenchItem(name: "iPhone Air", kind: .appleDevice, state: .locked),
        ]
        let chips = MasterReading.startsWith(full).map(\.text)
        #expect(chips == [
            "Its charter", "ipados skill", "23 notes", "The last task", "iPad Pro free", "iPhone Air locked",
            "Guards passing",
        ])
        #expect(MasterWords.tokens(3_104) == "3.1k tokens, outside the conversation")
    }

    @Test("A measured number keeps only the digits it has")
    func numbers() {
        #expect(MasterReading.number(2.4) == "2.4")
        #expect(MasterReading.number(46) == "46")
        #expect(MasterReading.number(0.05) == "0.05")
        #expect(MasterReading.number(3.10) == "3.1")
    }

    @Test("Paths read with the home folder as a tilde")
    func paths() {
        #expect(MasterReading.shortPath("/Users/marcus/Dev") == "~/Dev")
        #expect(MasterReading.shortPath("/home/marcus") == "~")
        #expect(MasterReading.shortPath("/srv/app") == "/srv/app")
    }
}

@Suite("Master debrief")
struct MasterDebriefTests {
    private func debrief(_ ops: [ExpertProposal.Operation], state: ExpertDebrief.State = .open) -> ExpertDebrief {
        ExpertDebrief(
            sessionID: "S", expertID: "E", at: now, coveredTurns: 2, state: state,
            proposals: ops.map { ExpertProposal(op: $0, title: "t", summary: "s", body: "b", reason: "r") })
    }

    @Test("The headline says what was learned, corrected and retired, in one sentence")
    func headline() {
        #expect(MasterReading.debriefHeadline(debrief([.add, .add, .retire]), name: "iPadOS").text
            == "iPadOS learned 2 things and wants to retire 1")
        #expect(MasterReading.debriefHeadline(debrief([.add, .change, .retire]), name: "iPadOS").text
            == "iPadOS learned 1 thing, corrected 1 note and wants to retire 1")
        #expect(MasterReading.debriefHeadline(debrief([.change]), name: "iPadOS").text == "iPadOS corrected 1 note")
        #expect(MasterReading.debriefHeadline(debrief([], state: .settled), name: "iPadOS").text
            == "Nothing new for the notebook")
        var skipped = debrief([.add], state: .settled)
        skipped.proposals[0].state = .skipped
        #expect(MasterReading.debriefHeadline(skipped, name: "iPadOS").text == "Nothing new for the notebook")
        skipped.proposals[0].state = .accepted
        #expect(MasterReading.debriefHeadline(skipped, name: "iPadOS").text == "Notebook updated")
        #expect(MasterReading.debriefHeadline(debrief([], state: .failed), name: "iPadOS").tone == .failing)
    }

    @Test("Each row names its own action; Accept all is the one filled press")
    func actions() {
        #expect(MasterWords.accept(.add) == "Add")
        #expect(MasterWords.accept(.change) == "Change")
        #expect(MasterWords.accept(.retire) == "Retire")
        #expect(MasterWords.proposalState(.accepted, op: .retire) == "Retired")
        #expect(MasterWords.proposalState(.pending, op: .add) == nil)
    }

    @Test("A draft sends only the notes left ticked, and a lasting-false note starts unticked")
    func draft() {
        let draft = ExpertDraft(
            name: "iPad OS", notes: [
                ExpertDraftNote(title: "Devices", summary: "s", body: "b"),
                ExpertDraftNote(title: "Port 8795", summary: "s", body: "b", lasting: false),
            ])
        let ticks = MasterMaking.defaultTicks(draft)
        #expect(ticks == ["Devices"])
        let final = MasterMaking.finalized(draft, keeping: ticks.union(["Port 8795"]))
        #expect(final.notes?.map(\.title) == ["Devices", "Port 8795"])
        #expect(final.notes?.allSatisfy { $0.lasting == true } == true)
        #expect(final.glyph == "Ip")
    }
}

@Suite("Master capability")
struct MasterCapabilityTests {
    @Test("The demo machine keeps masters, so every client's demo offers them")
    func demoKeepsMasters() async throws {
        #expect(DemoWorld.claude.capabilities.supportsExperts)
        let masters = try await DemoWorld.claude.machineExperts()
        #expect(masters?.count == 3)
    }

    @Test("Masters is a capability every client must answer")
    func registered() {
        #expect(AppCapability.allCases.contains(.masters))
        #expect(CapabilityRegistry.definition(for: .masters).id == .masters)
    }

    @Test("The editor's front page says what each part holds in one line")
    func outline() {
        let empty = MasterOutline.rows(ExpertDraft(name: ""))
        #expect(empty.map(\.part) == [.charter, .skills, .notebook, .bench, .guards, .model])
        #expect(empty.allSatisfy { !$0.isSet })
        let draft = ExpertDraft(
            name: "iPadOS", effort: "high", charter: "A map, not a manual.", skills: ["ipados", "ios-dev", "app-store"],
            notebookPath: "~/notes", bench: [ExpertBenchItem(name: "iPad Pro", kind: .appleDevice)],
            guards: [ExpertGuard(name: "Layout", command: "swift test")],
            guardRule: ScheduleRule(kind: .daily, hour: 3, minute: 0),
            notes: [
                ExpertDraftNote(title: "a", summary: "", body: ""),
                ExpertDraftNote(title: "b", summary: "", body: "", lasting: false),
            ])
        let rows = MasterOutline.rows(draft, kept: 1, modelName: "Fable 5", calendar: utc, now: now)
        let values = Dictionary(uniqueKeysWithValues: rows.map { ($0.part, $0.value) })
        #expect(rows.map(\.part) == MasterOutline.Part.allCases)
        #expect(rows.allSatisfy { $0.isSet })
        #expect(values[.charter] == "5 words")
        #expect(values[.skills] == "ipados, ios-dev +1")
        #expect(values[.notebook] == "~/notes")
        #expect(values[.notes] == "1 of 2 kept")
        #expect(values[.bench] == "iPad Pro")
        #expect(values[.guards]?.hasPrefix("1 guard · every day") == true)
        #expect(values[.model] == "Fable 5 · high")
    }

    @Test("A draft from a skill keeps what was already typed")
    func outlineMerge() {
        let drafted = ExpertDraft(name: "Releases", glyph: "Re", hue: "green", purpose: "Ships.", directory: "~/a", charter: "Ship it.")
        let untouched = MasterOutline.merged(drafted, over: ExpertDraft(name: " "))
        #expect(untouched == drafted)
        let typed = ExpertDraft(name: "Store", hue: "pink", purpose: "", directory: "~/b", effort: "max")
        let merged = MasterOutline.merged(drafted, over: typed)
        #expect(merged.name == "Store")
        #expect(merged.glyph == nil)
        #expect(merged.hue == "pink")
        #expect(merged.purpose == "Ships.")
        #expect(merged.directory == "~/b")
        #expect(merged.effort == "max")
        #expect(merged.charter == "Ship it.")
        #expect(MasterOutline.canDraft(typed))
        #expect(!MasterOutline.canDraft(merged))
    }
}

@Suite("Master polish")
struct MasterPolishTests {
    @Test("A master with no notes says it is idle and nothing about a count of none")
    func emptyNotebook() {
        #expect(MasterReading.state(master(notes: 0), now: now).text == "Idle")
        var fresh = master(notes: 0)
        fresh.notebook = ExpertNotebookFacts(path: "/n", adopted: false, notes: 0, stale: 0, retired: 0)
        #expect(MasterReading.notebookLine(fresh).text == "None yet")
    }

    @Test("What a task measured is a line of its own under what it did")
    func measuredLine() {
        let entry = ExpertJournalEntry(
            id: "j", title: "Round", at: now, outcome: "Resizes redraw at once.", measured: ["450 → 83 ms", "280 tests"],
            commits: ["abc"])
        #expect(MasterReading.journalRow(entry, calendar: utc, now: now).detail.text == "Resizes redraw at once.\n450 → 83 ms · 280 tests")
        #expect(MasterReading.journalPreview(entry) == "Resizes redraw at once.\n450 → 83 ms · 280 tests · 1 commit")
    }

    @Test("The editor says an adopted notebook's folder from the home folder")
    func outlinePath() {
        var draft = ExpertDraft(name: "iPadOS")
        draft.notebookPath = "/Users/demo/notes/pulse"
        #expect(MasterOutline.row(.notebook, draft).value == "~/notes/pulse")
    }

    @Test("The demo's waiting debrief belongs to a conversation at rest, and every demo note has words")
    func demoDebriefIsReachable() async throws {
        let sessions = try await DemoWorld.claude.listSessions()
        let task = try #require(sessions.first { $0.id == DemoWorld.demoReviewedTaskID })
        #expect(task.expertID == DemoWorld.demoIPadMasterID && task.isActive != true)
        let debrief = try #require(try await DemoWorld.claude.expertDebrief(sessionID: DemoWorld.demoReviewedTaskID))
        #expect(debrief.state == .open && debrief.pending.count == 3)
        let masters = try #require(try await DemoWorld.claude.machineExperts())
        for master in masters {
            #expect(master.notebook.notes > 0)
            for note in try await DemoWorld.claude.expertNotes(master.id, retired: false) {
                #expect((note.body ?? "").count > 20)
            }
        }
    }
}
