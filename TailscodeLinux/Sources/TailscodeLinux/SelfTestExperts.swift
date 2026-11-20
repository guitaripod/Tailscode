import AgentTestSupport
import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// What experts promise on this desk, against the demo machine and a machine of the test's
    /// own: the shelf reads every state in its tone, the page draws every section, the notebook
    /// folds what was retired, the editor fills from an expert, a task starts and carries what it
    /// was handed, a debrief is finished, accepted and settled, and the parity answer is the page.
    static func checkExperts() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("experts: \(label)") }
            checks += 1
        }
        func unwrap<T>(_ value: T?, _ label: String) throws -> T {
            guard let value else { throw SelfTestFailure("experts: \(label)") }
            return value
        }

        let demo = DemoWorld.claude
        let profile = DemoWorld.claudeProfile
        let demoExperts = try expertsWait { try await demo.machineExperts() } ?? []
        try expect(demoExperts.count == 3, "the demo machine keeps three experts, not \(demoExperts.count)")
        let demoBoard = ExpertBoard.make([.init(profileID: profile.id, machine: profile.name, experts: demoExperts)])
        try expect(demoBoard.keepsExperts, "the demo machine keeps experts")
        try expect(demoBoard.rows.map(\.expert.id) == ["demo-x-ipad", "demo-x-server", "demo-x-releases"],
                   "the shelf keeps the order they were made in")
        let iPad = try unwrap(demoBoard.rows.first, "iPadOS is on the shelf")
        try expect(iPad.state().tone == .attention, "iPadOS has notes waiting")
        try expect(ExpertReading.badge(iPad.expert) == 3, "three of them")
        try expect(demoBoard.rows[1].state().tone == .active, "Server is at work")
        try expect(demoBoard.rows[2].state().tone == .failing, "Releases has a guard failing")
        let debrief = try unwrap(try expertsWait { try await demo.expertDebrief(sessionID: "demo-c3") }, "demo-c3 has a debrief")
        try expect(debrief.state == .open && debrief.pending.count == 3, "its three proposals wait")
        try expect(ExpertReading.debriefHeadline(debrief, name: "iPadOS").text.hasPrefix("iPadOS learned 2"),
                   "and the headline says what was learned")
        try expect(MatrixTheme.css.contains(".expert-hue-blue"), "every hue is in the stylesheet")
        try expect(MatrixTheme.css.contains(".expert-card"), "and so is the debrief card")
        if case .implemented(let anchor) = ParityManifest.evidence(for: .experts) {
            try expect(anchor == "ExpertWindow", "experts are answered for by the expert's page")
        } else {
            try expect(false, "experts are answered for")
        }

        let own = MockBackend(agentType: .claudeCode, experts: MockExperts(
                experts: demoExperts,
                skills: [ExpertSkill(name: "app-store", description: "Releases and store copy.", path: "~/.claude/skills/app-store")]))
        let ownProfile = ConnectionProfile(
            id: "selftest-experts", name: "bench", backend: .claudeCode, baseURL: URL(string: "http://127.0.0.1:9")!)
        try expect(ExpertDesk.mayKeepExperts(own), "a claude-bridge machine keeps experts")
        try expect(!ExpertDesk.mayKeepExperts(MockBackend(agentType: .openCode)), "an opencode machine does not")
        try expect(!ExpertDesk.mayKeepExperts(MockBackend(agentType: .claudeCode)), "nor a claude-bridge too old for experts")
        try expect(!ExpertEditorWindow.number(1e20).isEmpty && !ExpertEditorWindow.number(.infinity).isEmpty,
                   "a limit too large for an integer is said back, not trapped on")
        let started = try expertsWait {
            try await own.startExpertTask("demo-x-ipad", ExpertTaskRequest(text: "Make the board fit the mini"))
        }
        try expect(started.session.expertID == "demo-x-ipad", "a started task is the expert's")
        let ownExperts = try expertsWait { try await own.machineExperts() } ?? []
        try expect(ownExperts.first?.task?.sessionID == started.session.id, "and the shelf says it is at work")
        let finished = try expertsWait { try await own.finishExpertTask(sessionID: started.session.id) }
        try expect(finished.state == .open && !finished.proposals.isEmpty, "finishing a task drafts its debrief")
        let accepted = try expertsWait {
            try await own.decideExpertDebrief(
                sessionID: started.session.id, ExpertDebriefDecision(accepted: finished.proposals.map(\.id)))
        }
        try expect(accepted.state == .settled, "accepting every proposal settles it")
        let notes = try expertsWait { try await own.expertNotes("demo-x-ipad", retired: false) }
        try expect(notes.count >= finished.proposals.filter { $0.op == .add }.count, "and the notes are written")

        guard gtk_init_check() != 0 else { return checks }
        func pump(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while g_main_context_iteration(nil, 0) != 0 {}
                usleep(4000)
            }
        }
        let board = ExpertBoard.make([.init(profileID: ownProfile.id, machine: ownProfile.name, experts: ownExperts)])
        ExpertDesk.shared.seed(board, servers: [(ownProfile, own)])
        pump(0.2)
        let row = try unwrap(board.rows.first, "the seeded shelf has iPadOS")

        ExpertsWindow.present(parent: nil)
        pump(0.5)
        let list = try unwrap(MachineWindowRegistry.existing(ExpertsWindow.windowKey) as? ExpertsWindow, "Experts opens")
        try expect(list.groups.count >= 1, "with a group for the machine")
        list.close()

        ExpertWindow.present(row: row, parent: nil)
        pump(0.8)
        let page = try unwrap(
            MachineWindowRegistry.existing(ExpertWindow.key(row.profileID, row.expert.id)) as? ExpertWindow,
            "the expert's page opens")
        try expect(page.groups.count >= 8, "head, task, bench, guards, notebook, journal, charter and delete, not \(page.groups.count)")
        try expect(page.expert.bench.count == 4, "the bench lists four devices")
        page.checkGuards(only: nil)
        pump(0.6)
        try expect(page.expert.guards.allSatisfy { $0.last?.passed == true }, "Check now runs the guards")
        try expect(ExpertWindow.failureTask(ExpertGuard(name: "G", command: "c"), machine: "m").contains("G"),
                   "a failing guard's hand-over names it")
        page.close()

        ExpertNotebookWindow.present(row: row, keeper: own, parent: nil)
        pump(0.6)
        let book = try unwrap(
            MachineWindowRegistry.existing(ExpertNotebookWindow.key(row)) as? ExpertNotebookWindow, "the notebook opens")
        try expect(book.notes?.isEmpty == false, "and reads the notes")
        book.close()

        ExpertEditorWindow.presentEdit(row: row, keeper: own, parent: nil)
        pump(0.5)
        let editor = try unwrap(
            MachineWindowRegistry.existing(ExpertEditorWindow.key(row.profileID, .edit(expertID: row.expert.id)))
                as? ExpertEditorWindow, "the editor opens")
        try expect(editor.name == "iPadOS", "filled from the expert")
        try expect(editor.skills != nil && editor.skillsFailure == nil, "and the machine's skills are read, not guessed empty")
        try expect(editor.bench.count == 4 && editor.guards.count == 4, "with its bench and guards")
        try expect(editor.outline.map(\.part) == [.charter, .skills, .notebook, .bench, .guards, .model],
                   "its front page is one line for each part, not \(editor.outline.map(\.part.rawValue))")
        try expect(editor.outline.first { $0.part == .guards }?.value.hasPrefix("4 guards") == true,
                   "and the guards' line says how many there are")
        try expect(editor.groups.count == 3, "the front page is the expert, its parts and Delete, not \(editor.groups.count) groups")
        try expect(!editor.offersSkillDraft, "an expert being changed is not offered a draft from a skill")
        editor.open(.guards)
        pump(0.5)
        try expect(editor.part == .guards && editor.partGroups.count == 2, "a part opens as a page in the same window")
        editor.guards.removeLast()
        editor.render()
        try expect(editor.partGroups.count == 2, "and is drawn again when it changes")
        editor.closePart()
        pump(0.8)
        try expect(editor.part == nil, "going back closes it")
        try expect(editor.outline.first { $0.part == .guards }?.value.hasPrefix("3 guards") == true,
                   "and the front page says what the part holds now")
        editor.open(.charter)
        pump(0.4)
        editor.render()
        try expect(editor.part == .charter && editor.partGroups.count == 1, "the charter's page stays as it is while it is typed in")
        editor.close()
        pump(0.2)

        ExpertEditorWindow.presentNew(profileID: row.profileID, machine: row.machine, keeper: own, parent: nil)
        pump(0.6)
        let blank = try unwrap(
            MachineWindowRegistry.existing(ExpertEditorWindow.key(row.profileID, .new)) as? ExpertEditorWindow,
            "a new expert opens")
        try expect(blank.groups.count == 2 && blank.outline.allSatisfy { !$0.isSet },
                   "as one short page with every part still empty")
        try expect(blank.offersSkillDraft, "and offers to draft it from a skill")
        blank.name = "Store"
        blank.directory = "~/store"
        let skill = try unwrap(blank.skills?.first?.name, "the machine has a skill to draft from")
        blank.draft(session: nil, skill: skill)
        pump(0.8)
        try expect(blank.name == "Store" && blank.directory == "~/store", "a draft from a skill keeps what was typed")
        try expect(!blank.charter.isEmpty && !blank.offersSkillDraft, "writes the charter, and is not offered twice")
        blank.close()
        pump(0.2)

        ExpertEditorWindow.presentDraft(
            profileID: row.profileID, machine: row.machine, keeper: own, sessionID: started.session.id, parent: nil)
        pump(0.8)
        let draft = try unwrap(
            MachineWindowRegistry.existing(
                ExpertEditorWindow.key(row.profileID, .draft(sessionID: started.session.id))) as? ExpertEditorWindow,
            "a draft from a chat opens")
        try expect(!draft.notes.isEmpty, "with the drafted notes")
        try expect(draft.notes.contains { $0.lasting == false } && draft.ticks.count == draft.notes.count - 1,
                   "a note true only that day starts unticked")
        try expect(draft.outline.contains { $0.part == .notes }, "and the first notes have a line of their own")
        draft.close()

        let brief = ConversationBrief(source: "Bridge restart wording", body: "Person: hello", kept: 1, total: 1, pictures: 0)
        ExpertTaskWindow.present(row: row, keeper: own, carry: brief, text: "", parent: nil)
        pump(0.4)
        let composer = try unwrap(ExpertTaskWindow.current, "the task composer opens")
        composer.type("Take this over")
        composer.submit()
        pump(0.8)
        let sent = own.recordedPrompts.last?.text ?? ""
        try expect(sent.hasPrefix("Take this over"), "the person's words come first")
        try expect(CarryMark.split(sent) != nil, "and the conversation rides after them as a brief")
        try expect(ExpertTaskWindow.current == nil, "and the composer closes once the task started")

        ExpertDesk.shared.seed(ExpertBoard.make([], unanswered: [(profileID: "silent", machine: "arch")]), servers: [])
        pump(0.2)
        ExpertsWindow.present(parent: nil)
        pump(0.4)
        let quiet = try unwrap(MachineWindowRegistry.existing(ExpertsWindow.windowKey) as? ExpertsWindow, "Experts opens again")
        pump(0.6)
        ExpertDesk.shared.seed(ExpertBoard.make([], unanswered: [(profileID: "silent", machine: "arch")]), servers: [])
        pump(0.1)
        quiet.servers = [(id: "silent", name: "arch"), (id: "oc", name: "homelab")]
        quiet.render()
        try expect(quiet.others == ["homelab"], "a machine not answering is never said to be one that cannot keep experts, not \(quiet.others)")
        try expect(quiet.groups.count == 2, "it reads as not answering, apart from the one that cannot")
        quiet.close()
        pump(0.2)
        ExpertDesk.shared.seed(.empty, servers: [])
        pump(0.2)
        return checks
    }

    private static func expertsWait<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ExpertsBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success, let result = box.result else {
            throw SelfTestFailure("experts: the machine did not answer")
        }
        return try result.get()
    }
}

private final class ExpertsBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}
