import CodingAgentKit
import Foundation
import Testing
@testable import TailscodeCore

private var helsinki: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Helsinki")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

private func local(_ text: String) -> Date {
    let format = DateFormatter()
    format.calendar = helsinki
    format.timeZone = helsinki.timeZone
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyy-MM-dd HH:mm"
    return format.date(from: text)!
}

/// Monday 2 November 2026, 20:30 in Helsinki.
private let monday = local("2026-11-02 20:30")

@Suite("Schedule phrases")
struct ScheduleSpeechTests {
    private func read(_ phrase: String) -> ScheduleSpeech.Understanding? {
        ScheduleSpeech.read(phrase, now: monday, calendar: helsinki)
    }

    @Test("Weekdays at a time repeat Monday to Friday and start on the next one")
    func weekdays() throws {
        let understood = try #require(read("weekdays 7:30"))
        #expect(understood.rule == ScheduleRule(kind: .weekdays, hour: 7, minute: 30))
        #expect(understood.next == local("2026-11-03 07:30"))
        #expect(read("every weekday at 7.30am")?.rule == ScheduleRule(kind: .weekdays, hour: 7, minute: 30))
    }

    @Test("Every few hours anchors on the next whole hour")
    func everyHours() {
        #expect(read("every 2 hours")?.rule == ScheduleRule(kind: .hours, hour: 21, minute: 0, every: 2))
        #expect(read("hourly")?.rule.every == 1)
        #expect(read("every 6h")?.rule.every == 6)
    }

    @Test("A weekday said once is a one-off; said as a habit it repeats")
    func weekdayOnceAndWeekly() throws {
        let once = try #require(read("fri 17:00"))
        #expect(once.rule.kind == .once)
        #expect(once.next == local("2026-11-06 17:00"))
        #expect(read("every monday 9am")?.rule == ScheduleRule(kind: .weekly, hour: 9, minute: 0, weekday: 2))
        #expect(read("mondays at 9")?.rule == ScheduleRule(kind: .weekly, hour: 9, minute: 0, weekday: 2))
    }

    @Test("Relative times round to the minute")
    func relative() throws {
        let understood = try #require(read("in 20 min"))
        #expect(understood.rule.kind == .once)
        #expect(understood.next == local("2026-11-02 20:50"))
        #expect(read("in an hour")?.next == local("2026-11-02 21:30"))
        #expect(read("in 2 days")?.next == local("2026-11-04 20:30"))
    }

    @Test("Parts of the day and the evening words")
    func partsOfDay() {
        #expect(read("every morning at 6")?.rule == ScheduleRule(kind: .daily, hour: 6, minute: 0))
        #expect(read("every evening")?.rule == ScheduleRule(kind: .daily, hour: 21, minute: 0))
        #expect(read("tonight")?.next == local("2026-11-02 21:00"))
        #expect(read("tonight at 10")?.next == local("2026-11-02 22:00"))
        #expect(read("tomorrow 9am")?.next == local("2026-11-03 09:00"))
        #expect(read("tomorrow")?.next == local("2026-11-03 08:00"))
    }

    @Test("A bare time is the next time the clock says it")
    func bareTime() {
        #expect(read("7:30")?.next == local("2026-11-03 07:30"))
        #expect(read("22:15")?.next == local("2026-11-02 22:15"))
    }

    @Test("Every pattern in the phrasebook compiles")
    func phrasebookCompiles() {
        #expect(ScheduleSpeech.rewrites.count == ScheduleSpeech.phrasebook.count)
    }

    @Test(
        "Each language's placeholder examples read as what they say",
        arguments: [
            ("werktags 7:30", "alle 2 Stunden", "Fr 17:00", "in 20 Min"),
            ("entre semana 7:30", "cada 2 horas", "vie 17:00", "en 20 min"),
            ("en semaine 7:30", "toutes les 2 heures", "ven. 17:00", "dans 20 min"),
            ("nei giorni feriali 7:30", "ogni 2 ore", "ven 17:00", "tra 20 min"),
            ("dias úteis 7:30", "a cada 2 horas", "sex 17:00", "em 20 min"),
            ("dni robocze 7:30", "co 2 godziny", "pt 17:00", "za 20 min"),
            ("平日 7:30", "2時間ごと", "金 17:00", "20分後"),
            ("평일 7:30", "2시간마다", "금 17:00", "20분 뒤"),
            ("工作日 7:30", "每 2 小时", "周五 17:00", "20 分钟后"),
            ("平日 7:30", "每 2 小時", "週五 17:00", "20 分鐘後"),
            ("vardagar 7:30", "var 2:e timme", "fre 17:00", "om 20 min"),
            ("hverdage 7:30", "hver 2. time", "fre 17:00", "om 20 min"),
            ("hverdager 7:30", "hver 2. time", "fre 17:00", "om 20 min"),
            ("arkisin 7:30", "2 tunnin välein", "pe 17:00", "20 min päästä"),
            ("virka daga 7:30", "á 2 klukkustunda fresti", "fös 17:00", "eftir 20 mín"),
        ])
    func placeholderExamples(weekdays: String, hours: String, friday: String, soon: String) throws {
        #expect(read(weekdays)?.rule == ScheduleRule(kind: .weekdays, hour: 7, minute: 30), "\(weekdays)")
        #expect(read(hours)?.rule == ScheduleRule(kind: .hours, hour: 21, minute: 0, every: 2), "\(hours)")
        let once = try #require(read(friday), "\(friday)")
        #expect(once.rule.kind == .once)
        #expect(once.next == local("2026-11-06 17:00"), "\(friday)")
        #expect(read(soon)?.next == local("2026-11-02 20:50"), "\(soon)")
    }

    @Test("Habits, days and clocks said the way each language says them")
    func otherLanguages() {
        let daily7 = ScheduleRule(kind: .daily, hour: 7, minute: 0)
        let friday9 = ScheduleRule(kind: .weekly, hour: 9, minute: 0, weekday: 6)
        #expect(read("毎朝7時")?.rule == daily7)
        #expect(read("매일 아침 7시")?.rule == daily7)
        #expect(read("每天早上7点")?.rule == daily7)
        #expect(read("jeden Tag um 7 Uhr")?.rule == daily7)
        #expect(read("tous les jours à 7h")?.rule == daily7)
        #expect(read("todos los días a las 7")?.rule == daily7)
        #expect(read("ogni giorno alle 7")?.rule == daily7)
        #expect(read("codziennie o 7")?.rule == daily7)
        #expect(read("freitags 9 Uhr")?.rule == friday9)
        #expect(read("varje dag kl 7")?.rule == daily7)
        #expect(read("hver dag kl. 7")?.rule == daily7)
        #expect(read("joka päivä klo 7")?.rule == daily7)
        #expect(read("á hverjum degi klukkan 7")?.rule == daily7)
        #expect(read("på fredagar kl 9")?.rule == friday9)
        #expect(read("perjantaisin klo 9")?.rule == friday9)
        #expect(read("om fredagen kl. 9")?.rule == friday9)
        #expect(read("á föstudögum klukkan 9")?.rule == friday9)
        #expect(read("毎週金曜 9時")?.rule == friday9)
        #expect(read("매주 금요일 9시")?.rule == friday9)
        #expect(read("每周五 9点")?.rule == friday9)
        #expect(read("toda sexta às 9")?.rule == friday9)
        #expect(read("每天晚上9点")?.rule == ScheduleRule(kind: .daily, hour: 21, minute: 0))
        #expect(read("7時半")?.next == local("2026-11-03 07:30"))
        #expect(read("明日の朝")?.next == local("2026-11-03 08:00"))
        #expect(read("morgen früh")?.next == local("2026-11-03 08:00"))
        #expect(read("mañana a las 9")?.next == local("2026-11-03 09:00"))
        #expect(read("demain 9h")?.next == local("2026-11-03 09:00"))
        #expect(read("今晚")?.next == local("2026-11-02 21:00"))
        #expect(read("ce soir")?.next == local("2026-11-02 21:00"))
        #expect(read("in einer Stunde")?.next == local("2026-11-02 21:30"))
        #expect(read("dentro de una hora")?.next == local("2026-11-02 21:30"))
        #expect(read("tra mezz'ora")?.next == local("2026-11-02 21:00"))
        #expect(read("１時間後")?.next == local("2026-11-02 21:30"))
    }

    @Test("The store captions' examples read as weekdays at 7:30 in every language")
    func captionExamples() {
        let weekdays = ScheduleRule(kind: .weekdays, hour: 7, minute: 30)
        for phrase in [
            "werktags 7:30", "laborables a las 7:30", "jours ouvrés à 7:30", "feriali alle 7:30",
            "dni robocze 7:30", "dias úteis às 7:30", "平日 7:30", "평일 7:30", "工作日 7:30",
        ] {
            #expect(read(phrase)?.rule == weekdays, "\(phrase)")
        }
    }

    @Test("English phrases read exactly as before")
    func englishUntouched() {
        for phrase in ["weekdays 7:30", "every 2 hours", "fri 17:00", "in 20 min", "every monday 9am", "tonight at 10", "tomorrow 9am", "in half an hour", "sat 10:00", "every evening"] {
            #expect(ScheduleSpeech.english(phrase).split(separator: " ").joined(separator: " ") == phrase, "\(phrase)")
        }
    }

    @Test("A phrase with no time in it is not guessed")
    func unreadable() {
        #expect(read("whenever") == nil)
        #expect(read("") == nil)
        #expect(read("every 30 hours") == nil || read("every 30 hours")?.rule.kind != .hours)
    }
}

@Suite("Schedule words and board")
struct ScheduleBoardTests {
    private func schedule(
        _ title: String, rule: ScheduleRule, next: Date?, paused: Bool = false, runs: [ScheduleRun] = []
    ) -> MachineSchedule {
        MachineSchedule(
            id: title, text: title, title: title, rule: rule, timeZone: "Europe/Helsinki", next: next,
            paused: paused, createdAt: monday, runs: runs)
    }

    @Test("Soonest first, paused after, finished one-offs last, and Home names the next")
    func order() {
        let board = ScheduleBoard.make(
            [
                .init(
                    profileID: "a", machine: "arch",
                    schedules: [
                        schedule("Done", rule: .once(local("2026-11-02 08:00")), next: nil,
                                 runs: [ScheduleRun(id: "r", scheduledFor: monday, outcome: .answered)]),
                        schedule("Later", rule: ScheduleRule(kind: .daily, hour: 9, minute: 0), next: local("2026-11-03 09:00")),
                    ]),
                .init(
                    profileID: "b", machine: "studio",
                    schedules: [
                        schedule("Paused", rule: ScheduleRule(kind: .daily, hour: 6, minute: 0), next: local("2026-11-03 06:00"), paused: true),
                        schedule("Soon", rule: ScheduleRule(kind: .weekdays, hour: 7, minute: 30), next: local("2026-11-03 07:30")),
                    ]),
            ], calendar: helsinki, now: monday)
        #expect(board.rows.map(\.title) == ["Soon", "Later", "Paused", "Done"])
        #expect(board.next?.title == "Soon")
        #expect(board.homeLine(calendar: helsinki, now: monday)?.contains("Soon") == true)
        #expect(board.homeLine(calendar: helsinki, now: monday)?.contains("studio") == true)
        #expect(board.rows.last?.mark == .answered)
    }

    @Test("A run the machine slept through is said with the machine's name and the count")
    func missedWords() {
        let run = ScheduleRun(id: "r", scheduledFor: local("2026-11-02 07:30"), outcome: .missed, missed: 3, failure: "off")
        let words = ScheduleWords.run(run, machine: "arch", calendar: helsinki, now: monday)
        #expect(words.mark == .missed)
        #expect(words.detail?.contains("arch") == true)
        #expect(words.detail?.contains("3") == true)
        let caught = ScheduleRun(
            id: "c", scheduledFor: local("2026-11-02 07:30"), startedAt: local("2026-11-02 09:12"),
            outcome: .caughtUp, ending: .quiet, missed: 1, failure: "off")
        let caughtWords = ScheduleWords.run(caught, machine: "arch", calendar: helsinki, now: monday)
        #expect(caughtWords.mark == .quiet)
        #expect(caughtWords.title.contains("9:12") || caughtWords.title.contains("09:12"))
    }
}

@Suite("Ask later sheet")
struct AskLaterSheetTests {
    @Test("A typed phrase clears the chip, and the understood line names the date and the machine")
    func phraseWins() throws {
        var sheet = AskLaterSheet(text: "news", machine: "arch", modelWord: "Opus")
        sheet.pick(.everyMorning)
        #expect(sheet.understanding(now: monday, calendar: helsinki)?.rule.kind == .daily)
        sheet.type("weekdays 7:30")
        #expect(sheet.chip == nil)
        let line = try #require(sheet.understoodLine(now: monday, calendar: helsinki))
        #expect(line.headline.contains("Tomorrow"))
        #expect(line.detail.contains("arch"))
        #expect(line.detail.contains("Opus"))
        let draft = try #require(
            sheet.draft(model: nil, wireModel: "opus", effort: "high", directory: nil, now: monday, calendar: helsinki))
        #expect(draft.rule == ScheduleRule(kind: .weekdays, hour: 7, minute: 30))
        #expect(draft.thread == .continue)
        #expect(draft.quiet == true)
        #expect(draft.timeZone == "Europe/Helsinki")
    }

    @Test("An unreadable phrase says so and saves nothing; a one-off is never quiet")
    func unreadable() {
        var sheet = AskLaterSheet(text: "news", machine: "arch")
        sheet.type("someday")
        #expect(sheet.understoodLine(now: monday, calendar: helsinki)?.headline == ScheduleWords.notUnderstood)
        #expect(sheet.draft(model: nil, wireModel: nil, effort: nil, directory: nil, now: monday, calendar: helsinki) == nil)
        sheet.type("in 20 min")
        let draft = sheet.draft(model: nil, wireModel: nil, effort: nil, directory: nil, now: monday, calendar: helsinki)
        #expect(draft?.quiet == false)
        #expect(!sheet.showsRepeatSwitches(now: monday, calendar: helsinki))
    }

    @Test("A machine that keeps no schedules cannot save")
    func cannotKeep() {
        var sheet = AskLaterSheet(text: "news", machine: "studio", machineKeepsSchedules: false)
        sheet.pick(.tonight)
        #expect(!sheet.canSave)
        #expect(sheet.understoodLine(now: monday, calendar: helsinki) == nil)
    }

    @Test("A desktop's later question becomes the machine's rule at the same hour")
    func handoffRule() {
        let later = QuickAskLater(text: "x", profileID: "a", fireAt: local("2026-11-03 08:00"), repeats: .weekly)
        #expect(
            QuickAskLaterHandoff.rule(for: later, calendar: helsinki)
                == ScheduleRule(kind: .weekly, hour: 8, minute: 0, weekday: 3))
    }
}

@Suite("Agents on a machine")
struct MachineAgentReadingTests {
    private let hermes = MachineAgent(
        id: "hermes", name: "Hermes", version: "0.19.0", source: "available", added: true,
        state: .needsBrain, failure: "No LLM provider configured.", brainStyle: "hermes",
        distribution: "uvx")

    private let brains = MachineAgentsReport(
        agents: [],
        brains: [LocalBrain(id: "llama-swap", name: "llama-swap", baseURL: "http://127.0.0.1:8081/v1",
                            models: [LocalBrain.Model(id: "bolt", name: "Bolt")])])

    @Test("A brainless agent's card leads with the machine's own model")
    func brainFirst() throws {
        let steps = MachineAgentReading.steps(hermes, machine: "arch")
        #expect(steps.map(\.id) == ["machine", "brain", "answered"])
        #expect(steps[1].state == .next)
        let options = MachineAgentReading.brains(brains, for: hermes, machine: "arch")
        #expect(options.first?.title == "Bolt")
        #expect(options.contains { $0.keyProvider == "openrouter" })
        let primary = try #require(MachineAgentReading.primary(hermes, brains: options, machine: "arch"))
        #expect(primary.0 == .giveBrain)
        #expect(primary.1.contains("Bolt"))
    }

    @Test("A found agent is offered to add, never started; the built-in agent leads the list")
    func rows() {
        let goose = MachineAgent(id: "goose", name: "goose", version: "1.57.0", source: "found", added: false, state: .notAdded)
        let rows = MachineAgentReading.rows(
            MachineAgentsReport(agents: [goose], brains: []), machine: "arch", builtIn: .claudeCode)
        #expect(rows.first?.isBuiltIn == true)
        #expect(rows.last?.press == .add)
        #expect(rows.last?.subtitle.contains("arch") == true)
    }

    @Test("News is said once per agent")
    func news() {
        let goose = MachineAgent(id: "goose", name: "goose", source: "found", added: false, state: .notAdded)
        UserDefaults.standard.removeObject(forKey: AgentNewsStore.key)
        let report = MachineAgentsReport(agents: [goose], brains: [])
        #expect(AgentNewsStore.unseen(report, profileID: "p").map(\.id) == ["goose"])
        AgentNewsStore.markSeen([goose], profileID: "p")
        #expect(AgentNewsStore.unseen(report, profileID: "p").isEmpty)
        UserDefaults.standard.removeObject(forKey: AgentNewsStore.key)
    }
}

@Suite("Agents in the model pill")
struct AgentModelChooserTests {
    private let models = [
        ModelInfo(id: "opus", name: "Opus", providerID: "anthropic"),
        ModelInfo(id: "custom:bolt", name: "Bolt", providerID: "hermes", agentName: "Hermes"),
        ModelInfo(id: "bolt", name: "Bolt", providerID: "llama-server"),
    ]

    @Test("An agent's model is its own section and never folds with the same model elsewhere")
    func agentFamily() {
        let candidates = ModelChooser.fold(models)
        let agent = candidates.first { $0.family.title == "Hermes" }
        #expect(agent?.offers.count == 1)
        #expect(candidates.count == 3)
    }

    @Test("Inside a Claude chat, an agent's model is a carry; inside a fresh chat it is not")
    func engineCarry() {
        let bound = ModelSource(
            profileID: "a", name: "arch", backend: .claudeCode, models: models, isCurrent: true,
            allowsServerDefault: true, acceptsAnyModelID: true, engine: .own)
        let candidates = ModelChooser.fold(source: bound)
        let hermes = candidates.first { $0.family.title == "Hermes" }
        #expect(hermes?.isElsewhere == true)
        #expect(hermes?.serverName.contains("Hermes") == true)
        #expect(candidates.first { $0.name == "Opus" }?.isElsewhere == false)
        let open = ModelSource(
            profileID: "a", name: "arch", backend: .claudeCode, models: models, isCurrent: true,
            allowsServerDefault: true, acceptsAnyModelID: true, engine: .open)
        #expect(ModelChooser.fold(source: open).allSatisfy { !$0.isElsewhere })
    }

    @Test("An agent's model row never shows the agent's own custom: prefix")
    func agentRowDetail() {
        let chooser = ModelChooser(models: models, selected: nil, recents: [])
        let rows = chooser.sections.flatMap(\.rows)
        #expect(!rows.contains { $0.detail.contains("custom:") })
    }

    @Test("A pill names the agent before its model")
    func badge() {
        let word = ModelBadge.word(for: ModelSelection(providerID: "hermes", modelID: "custom:bolt"), in: models)
        #expect(word == "Hermes · Bolt")
        #expect(ChatEngine.of(agentID: "hermes", hasTurns: true) == .agent("hermes"))
        #expect(ChatEngine.of(agentID: nil, hasTurns: false) == .open)
    }
}
