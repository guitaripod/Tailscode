import AgentTestSupport
import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The agents a machine hosts and the schedules it keeps, over the demo world's machine: the
    /// desk reads both, the sidebar's Scheduled entry wears Home's line, the Scheduled window lists
    /// every schedule soonest first with its history in Core's words, the Ask later sheet confirms a
    /// date before it can save and refuses a phrase it did not understand, a schedule made through
    /// it reaches the machine, the machine's Agents section and each agent's card draw the
    /// checklist the machine proves, More agents lists and filters the registry, the news line
    /// names a found agent once, and a desktop's later question is handed to a machine that keeps
    /// schedules. Every key it touches is put back.
    static func checkMachine() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
            checks += 1
        }
        let defaults = UserDefaults.standard
        let keptNews = defaults.stringArray(forKey: AgentNewsStore.key)
        defaults.removeObject(forKey: AgentNewsStore.key)
        defer {
            if let keptNews { defaults.set(keptNews, forKey: AgentNewsStore.key) } else {
                defaults.removeObject(forKey: AgentNewsStore.key)
            }
        }
        let desk = MachineDesk.shared
        desk.stageDemo()
        await desk.refresh()
        let demo = DemoWorld.claudeProfile
        try expect(desk.keepsSchedules(demo.id), "the demo machine keeps schedules")
        try expect(desk.board.rows.count == 4, "four demo schedules, got \(desk.board.rows.count)")
        try expect(
            desk.board.rows.last?.schedule.paused == true, "the paused audit sorts after the waiting ones")
        try expect(
            desk.reports[demo.id]?.agents.map(\.id) == ["hermes", "gemini", "goose"],
            "the demo machine hosts Hermes, Gemini CLI and goose")

        let entry = ScheduledSidebarEntry()
        entry.render()
        try expect(!entry.isHidden, "the sidebar's Scheduled entry shows while a machine keeps schedules")
        try expect(
            entry.lineText == desk.board.homeLine(), "the entry wears Home's line: \(entry.lineText)")

        let window = ScheduledWindow()
        window.present(selecting: "demo-s1")
        try expect(window.shownRows.count == 4, "Scheduled lists every schedule")
        try expect(window.detailView.row?.schedule.id == "demo-s1", "the chosen schedule is the one on the right")
        let history = window.detailView.historyTitles
        try expect(history.count == 4, "the digest's four runs are its history, got \(history)")
        try expect(history.contains(Localized.text("Quiet")), "a quiet run is said to be quiet")
        try expect(history.contains(Localized.text("Failed")), "a failed run is said to have failed")
        try expect(
            history.contains { $0.hasPrefix(Localized.text("Caught up at %@", "").trimmingCharacters(in: .whitespaces)) },
            "a run the machine owed is said to have been caught up: \(history)")
        window.detailView.type(phrase: "weekdays 7:30")
        try expect(!window.detailView.understoodText.isEmpty, "a typed time is read back before it is used")
        window.detailView.type(phrase: "someday")
        try expect(
            window.detailView.understoodText.hasPrefix(ScheduleWords.notUnderstood),
            "a phrase nobody could read is said to be unread")
        window.close()

        let host = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 600), styleMask: [.titled],
            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.orderFront(nil)
        defer { host.close() }
        let aim = AskLaterSheetController.Aim(
            profile: demo, model: ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5"),
            effort: nil, directory: nil, sessionID: nil)
        let sheet = AskLaterSheetController.present(
            on: host, text: "What's new in AI today? Three lines, links.", aim: aim, modelWord: "Sonnet 5",
            keepsSchedules: true, phrase: "weekdays 7:30"
        ) { _ in }
        try expect(sheet.headlineText.hasPrefix(Localized.text("Next: %@", "")), "the sheet names the date: \(sheet.headlineText)")
        try expect(sheet.detailText.contains(demo.name), "the sheet names the machine that asks")
        try expect(sheet.canSave, "an understood phrase on a machine that keeps schedules can be saved")
        try expect(sheet.switchesShown, "a repeat offers one conversation and quiet")
        try expect(
            sheet.confirmTitle != ScheduleWords.askLater && sheet.confirmTitle.contains("30"),
            "the press says the time: \(sheet.confirmTitle)")
        sheet.type("in 20 min")
        try expect(!sheet.switchesShown, "a one-off has no repeat switches")
        sheet.type("someday")
        try expect(!sheet.canSave, "an unread phrase cannot be saved")
        try expect(sheet.headlineText == ScheduleWords.notUnderstood, "an unread phrase is said to be unread")
        sheet.pick(.everyMorning)
        try expect(sheet.canSave, "a chip is an answer")
        host.endSheet(sheet.sheet)

        let refused = AskLaterSheetController.present(
            on: host, text: "x", aim: aim, modelWord: nil, keepsSchedules: false
        ) { _ in }
        refused.pick(.tonight)
        try expect(!refused.canSave, "a machine that keeps no schedules cannot be asked to")
        host.endSheet(refused.sheet)

        guard let scheduling = desk.scheduling(for: demo.id) else {
            throw SelfTestFailure("the demo machine schedules")
        }
        let made = try await scheduling.createSchedule(
            ScheduleDraft(text: "selftest", rule: ScheduleRule(kind: .daily, hour: 6, minute: 0)))
        await desk.refreshSchedules()
        try expect(desk.board.rows.count == 5, "a schedule made reaches the machine and the list")
        try await scheduling.deleteSchedule(made.id)
        await desk.refreshSchedules()
        try expect(desk.board.rows.count == 4, "a schedule deleted leaves the list")

        let keeper = MockBackend(agentType: .claudeCode, schedules: [])
        let later = QuickAskLater(text: "selftest later", profileID: demo.id, fireAt: Date().addingTimeInterval(3_600))
        let placed = await QuickAskLaterHandoff.place(later, using: keeper)
        let kept = try await keeper.machineSchedules() ?? []
        try expect(
            placed && kept.first?.text == "selftest later" && kept.first?.rule.kind == .once,
            "a desktop's later question is handed to a machine that keeps schedules")
        let opencode = MockBackend(agentType: .openCode)
        try expect(
            !(await QuickAskLaterHandoff.place(later, using: opencode)),
            "a machine that keeps no schedules is not handed one")

        let section = MachineAgentsSection(profile: demo)
        section.render()
        let rows = section.rowTexts
        try expect(section.showsAgents, "a machine that hosts agents shows its Agents section")
        try expect(rows.first?.0 == AgentType.claudeCode.displayName, "the machine's own agent leads, built in")
        try expect(
            rows.contains { $0.0 == "Hermes" && $0.1.hasPrefix(Localized.text("Ready")) },
            "Hermes is ready: \(rows)")
        try expect(rows.contains { $0.0 == "goose" && $0.1.contains(demo.name) }, "goose was found on the machine")

        let hermes = AgentCardSheet.present(on: host, profile: demo, agentID: "hermes")
        await desk.refreshAgents(profileID: demo.id)
        hermes.render()
        try expect(
            hermes.stepStates.allSatisfy { $0.1 == .done }, "every step of a ready agent is done: \(hermes.stepStates)")
        try expect(
            hermes.primaryTitle == Localized.text("Start a chat with %@", "Hermes"), "a ready agent leads with a chat")
        host.endSheet(hermes.sheet)

        let gemini = AgentCardSheet.present(on: host, profile: demo, agentID: "gemini")
        gemini.render()
        try expect(
            gemini.stepStates.contains { $0.1 == .next }, "the step an agent waits on is the next one")
        try expect(gemini.primaryTitle.contains("Gemini API key"), "a keyless agent asks for its key: \(gemini.primaryTitle)")
        host.endSheet(gemini.sheet)

        let registry = AgentRegistrySheet.present(on: host, profile: demo)
        for _ in 0..<40 where registry.rowTitles.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        try expect(registry.rowTitles.count == 8, "More agents lists the registry: \(registry.rowTitles)")
        registry.filter("kimi")
        try expect(registry.rowTitles == ["Kimi CLI"], "the registry filters by name")
        host.endSheet(registry.sheet)

        let news = AgentNewsView()
        news.render()
        try expect(news.headlineText.contains("goose"), "a found agent is news once: \(news.headlineText)")
        if let found = desk.news() { AgentNewsStore.markSeen(found.agents, profileID: found.profileID) }
        news.render()
        try expect(news.isHidden, "news told is not told again")

        let catalog = (try? await desk.backend(for: demo.id)?.availableModels()) ?? []
        try expect(
            catalog.contains { $0.providerID == "hermes" && $0.agentName == "Hermes" },
            "a ready agent's models are in the machine's catalog under its name")
        let sources = ModelChooserSheet.fleetSources(
            profiles: [demo], current: demo.id, currentModels: catalog, backend: .claudeCode,
            allowsServerDefault: true, reachable: true, engine: .own)
        try expect(
            sources.first { $0.isCurrent }?.engine == .own,
            "a chat's chooser knows which agent the chat is with")
        return checks
    }
}
