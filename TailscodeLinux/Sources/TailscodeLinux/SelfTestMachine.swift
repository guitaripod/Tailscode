import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// What the agents a machine runs and the schedules it keeps promise on this desk, against the
    /// demo machine: its agents read as rows and a proving checklist, the registry offers installs,
    /// the schedules read soonest first with Home's line, a chat bound to an agent carries a pick of
    /// another, the Ask later dialog understands a phrase before it saves, and every window opens on
    /// what the machine said.
    static func checkMachine() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("machine: \(label)") }
            checks += 1
        }
        let backend = DemoWorld.claude
        let profile = DemoWorld.claudeProfile
        let features = try waitFor { await MachineFeatures.read(backend) }
        try expect(features.schedules, "the demo machine keeps schedules")
        try expect(features.agents, "the demo machine hosts agents")
        let report = try waitFor { try await backend.machineAgents(refreshBrains: false) }
        let rows = MachineAgentReading.rows(report, machine: profile.name, builtIn: .claudeCode)
        try expect(rows.count == 4, "Claude Code and three agents are listed, not \(rows.count)")
        try expect(rows.first?.isBuiltIn == true, "Claude Code leads, built in")
        try expect(rows.contains { $0.id == "goose" && $0.press == .add }, "goose, found, is offered to add")
        let hermes = try unwrap(report?.agents.first { $0.id == "hermes" }, "Hermes is on the machine")
        let steps = MachineAgentReading.steps(hermes, machine: profile.name)
        try expect(steps.map(\.id) == ["machine", "brain", "answered"], "Hermes is proved in three steps")
        try expect(steps.allSatisfy { $0.state == .done }, "and each of them is done")
        let gemini = try unwrap(report?.agents.first { $0.id == "gemini" }, "Gemini CLI is on the machine")
        let geminiPrimary = MachineAgentReading.primary(gemini, brains: [], machine: profile.name)
        try expect(geminiPrimary?.0 == .enterKey(env: "GEMINI_API_KEY"), "Gemini CLI leads with its key")
        let registry = try waitFor { try await backend.agentRegistry() }
        try expect(registry.count == 8, "the registry offers eight agents, not \(registry.count)")
        let codex = try unwrap(registry.first { $0.id == "codex-acp" }, "Codex is in the registry")
        try expect(MachineAgentReading.registryRow(codex, machine: profile.name).press == Localized.text("Install"), "Codex installs")

        let schedules = try waitFor { try await backend.machineSchedules() } ?? []
        let board = ScheduleBoard.make([ScheduleBoard.Source(profileID: profile.id, machine: profile.name, schedules: schedules)])
        try expect(board.rows.count == 4, "four schedules are listed, not \(board.rows.count)")
        try expect(board.rows.last?.schedule.paused == true, "the paused audit is last")
        try expect(board.homeLine()?.contains(profile.name) == true, "Home's line names the machine")
        let caught = try unwrap(schedules.first { $0.id == "demo-s1" }?.runs.first { $0.outcome == .caughtUp }, "a caught-up run")
        try expect(ScheduleWords.run(caught, machine: profile.name).mark == .caughtUp, "a caught-up run is said to be one")

        let models = try waitFor { try await backend.availableModels() }
        let engine = ChatEngine.of(agentID: "hermes", hasTurns: true)
        let bolt = try unwrap(models.first { $0.providerID == "hermes" && $0.id == "custom:bolt" }, "Hermes offers Bolt")
        let sonnet = try unwrap(models.first { $0.id == "claude-sonnet-5" }, "Claude offers Sonnet")
        try expect(bolt.agentName == "Hermes", "Bolt is worn as Hermes's")
        try expect(engine.admits(bolt), "Hermes's own models stay in a Hermes chat")
        try expect(!engine.admits(sonnet), "and a Claude model carries")
        try expect(ModelBadge.word(for: bolt.selection, in: models) == "Hermes · Bolt", "the pill names the agent first")

        if case .implemented(let anchor) = ParityManifest.evidence(for: .machineAgents) {
            try expect(anchor == "MachineAgentsWindow", "the agents are answered for by their window")
        } else {
            try expect(false, "the agents are answered for")
        }
        if case .implemented(let anchor) = ParityManifest.evidence(for: .machineSchedules) {
            try expect(anchor == "AskLaterDialog", "the schedules are answered for by Ask later")
        } else {
            try expect(false, "the schedules are answered for")
        }
        guard gtk_init_check() != 0 else { return checks }
        try checkMachineWindows(expect, backend: backend, profile: profile, schedules: schedules)
        return checks
    }

    private static func checkMachineWindows(
        _ expect: (Bool, String) throws -> Void, backend: any CodingAgentBackend & MachineAgentHosting & MachineScheduling,
        profile: ConnectionProfile,
        schedules: [MachineSchedule]
    ) throws {
        func pump(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while g_main_context_iteration(nil, 0) != 0 {}
                usleep(4000)
            }
        }
        let target = AskLaterDialog.Target(
            profile: profile, backend: backend, model: ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5"),
            effort: "high", directory: nil, sessionID: "demo-c4")
        AskLaterDialog.present(text: MainWindow.driveLaterQuestion, target: target, parent: nil)
        pump(0.6)
        let dialog = try unwrap(AskLaterDialog.current, "Ask later opens")
        try expect(dialog.sheet.machineKeepsSchedules, "on a machine that keeps schedules")
        dialog.type("weekdays 7:30")
        pump(0.1)
        try expect(dialog.sheet.understanding()?.rule == ScheduleRule(kind: .weekdays, hour: 7, minute: 30), "weekdays 7:30 is understood")
        try expect(dialog.sheet.confirmTitle().contains("7:30") || dialog.sheet.confirmTitle().contains("07:30"), "the press says when")
        dialog.type("someday")
        pump(0.1)
        try expect(dialog.sheet.understoodLine()?.headline == ScheduleWords.notUnderstood, "an unread phrase is said to be unread")
        dialog.closeWindow()
        pump(0.2)
        try expect(AskLaterDialog.current == nil, "and the dialog lets go when it closes")

        MachineAgentsWindow.present(profile: profile, backend: backend, parent: nil)
        pump(0.6)
        let shelf = try unwrap(
            MachineWindowRegistry.existing(MachineAgentsWindow.key(profile.id)) as? MachineAgentsWindow, "the agents window opens")
        try expect(shelf.report?.agents.count == 3, "and reads the machine's agents")
        try expect(shelf.groups.count == 1, "in one group")
        shelf.close()

        AgentCardWindow.present(profile: profile, backend: backend, agentID: "hermes", parent: nil)
        pump(0.6)
        let card = try unwrap(
            MachineWindowRegistry.existing(AgentCardWindow.key(profile.id, "hermes")) as? AgentCardWindow, "Hermes's card opens")
        try expect(card.agent?.state == .ready, "Hermes is ready")
        try expect(card.groups.count == 3, "steps, models and presses, not \(card.groups.count) groups")
        card.close()

        AgentCardWindow.present(profile: profile, backend: backend, agentID: "gemini", parent: nil)
        pump(0.6)
        let gemini = try unwrap(
            MachineWindowRegistry.existing(AgentCardWindow.key(profile.id, "gemini")) as? AgentCardWindow, "Gemini CLI's card opens")
        try expect(gemini.agent?.state == .needsKey, "Gemini CLI waits for its key")
        gemini.startSignIn("oauth-personal")
        pump(0.6)
        try expect(gemini.relay?.links == ["https://example.com/device"], "a sign-in relays its link")
        try expect(gemini.relay?.codes == ["ABCD-1234"], "and its code")
        try expect(gemini.groups.count == 3, "the console sits between the steps and the presses")
        gemini.sendSignIn("ok")
        pump(1.8)
        try expect(gemini.agent?.state == .ready, "a finished sign-in is proved and the agent is ready")
        gemini.close()

        AgentRegistryWindow.present(profile: profile, backend: backend, parent: nil)
        pump(0.6)
        let more = try unwrap(
            MachineWindowRegistry.existing(AgentRegistryWindow.key(profile.id)) as? AgentRegistryWindow, "More agents opens")
        try expect(more.agents?.count == 8, "with the registry")
        more.query = "kimi"
        try expect(more.shown.map(\.id) == ["kimi"], "and finds an agent by name")
        more.close()

        let first = try unwrap(schedules.first { $0.id == "demo-s1" }, "the morning digest")
        ScheduleDetailWindow.present(profileID: profile.id, machine: profile.name, backend: backend, schedule: first, parent: nil)
        pump(0.6)
        let page = try unwrap(
            MachineWindowRegistry.existing(ScheduleDetailWindow.key(profile.id, first.id)) as? ScheduleDetailWindow,
            "a schedule's page opens")
        try expect(page.groups.count == 4, "words, when, presses and history")
        try expect(page.schedule.runs.count == 4, "with its four runs")
        page.close()
        pump(0.2)
    }

    private static func unwrap<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw SelfTestFailure("machine: \(label)") }
        return value
    }

    /// One async answer from the demo machine, waited for on this thread.
    private static func waitFor<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = MachineBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success, let result = box.result else {
            throw SelfTestFailure("machine: the demo machine did not answer")
        }
        return try result.get()
    }
}

private final class MachineBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}
