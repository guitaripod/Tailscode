import AgentTestSupport
import CodingAgentKit
import Foundation

extension DemoWorld {
    /// The demo machine's schedules: a morning digest that has gone quiet once, a check every few
    /// hours that Hermes runs on the GPU, a one-off tonight, and a paused weekly audit.
    static var demoSchedules: [MachineSchedule] {
        let calendar = Calendar.current
        let zone = TimeZone.current.identifier
        func at(_ hour: Int, _ minute: Int, dayOffset: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: Date())) ?? Date()
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? Date()
        }
        let news = ScheduleRule(kind: .weekdays, hour: 7, minute: 30)
        let gpu = ScheduleRule(kind: .hours, hour: 3, minute: 0, every: 6)
        let audit = ScheduleRule(kind: .weekly, hour: 9, minute: 0, weekday: 2)
        return [
            MachineSchedule(
                id: "demo-s1", text: "What's new in AI today? Three lines, links.", title: "AI news",
                model: "claude-sonnet-5", rule: news, timeZone: zone,
                next: news.next(after: Date(), calendar: calendar), sessionID: "demo-c4",
                createdAt: ago(9 * 86_400), createdBy: "iPhone",
                runs: [
                    ScheduleRun(
                        id: "demo-r1", scheduledFor: at(7, 30, dayOffset: 0), startedAt: at(7, 30, dayOffset: 0),
                        endedAt: at(7, 31, dayOffset: 0), sessionID: "demo-c4", outcome: .quiet),
                    ScheduleRun(
                        id: "demo-r2", scheduledFor: at(7, 30, dayOffset: -1), startedAt: at(7, 30, dayOffset: -1),
                        endedAt: at(7, 32, dayOffset: -1), sessionID: "demo-c4", outcome: .answered),
                    ScheduleRun(
                        id: "demo-r3", scheduledFor: at(7, 30, dayOffset: -2), startedAt: at(9, 12, dayOffset: -2),
                        endedAt: at(9, 14, dayOffset: -2), sessionID: "demo-c4", outcome: .caughtUp,
                        ending: .answered, missed: 1, failure: "off"),
                    ScheduleRun(
                        id: "demo-r4", scheduledFor: at(7, 30, dayOffset: -3), startedAt: at(7, 30, dayOffset: -3),
                        endedAt: at(7, 30, dayOffset: -3), sessionID: "demo-c4", outcome: .failed,
                        failure: "rate limited until 08:00"),
                ]),
            MachineSchedule(
                id: "demo-s2", text: "Check disk space and GPU memory. Tell me only if something looks wrong.",
                title: "Disk and GPU check", model: "hermes/custom:bolt", rule: gpu, timeZone: zone,
                next: gpu.next(after: Date(), calendar: calendar), createdAt: ago(4 * 86_400),
                runs: [
                    ScheduleRun(
                        id: "demo-r5", scheduledFor: at(3, 0, dayOffset: 0), startedAt: at(3, 0, dayOffset: 0),
                        endedAt: at(3, 1, dayOffset: 0), outcome: .answered)
                ]),
            MachineSchedule(
                id: "demo-s3", text: "Benchmark the new quant against yesterday's and write up the numbers.",
                title: "Benchmark the new quant", model: "claude-opus-4-8",
                rule: .once(at(21, 0, dayOffset: Calendar.current.component(.hour, from: Date()) >= 21 ? 1 : 0)),
                timeZone: zone, next: at(21, 0, dayOffset: Calendar.current.component(.hour, from: Date()) >= 21 ? 1 : 0),
                quiet: false, createdAt: ago(3_600)),
            MachineSchedule(
                id: "demo-s4", text: "Audit the dependencies for anything with a published advisory.",
                title: "Weekly dependency audit", model: "claude-sonnet-5", rule: audit, timeZone: zone,
                next: audit.next(after: Date(), calendar: calendar), paused: true, createdAt: ago(30 * 86_400)),
        ]
    }

    /// The demo machine's agents: Hermes thinking with Bolt on the GPU, Gemini CLI waiting for a
    /// key, goose found and not yet added; one model server to give a brain from.
    static var demoAgents: MachineAgentsReport {
        let brain = LocalBrain(
            id: "llama-swap", name: "llama-swap", baseURL: "http://127.0.0.1:8081/v1",
            models: [
                LocalBrain.Model(id: "bolt", name: "Bolt"), LocalBrain.Model(id: "qwen-daily", name: "Qwen Daily"),
                LocalBrain.Model(id: "glimmer", name: "Glimmer"),
            ])
        return MachineAgentsReport(
            agents: [
                MachineAgent(
                    id: "hermes", name: "Hermes", version: "0.19.0",
                    description: "Nous Research's agent that remembers, learns skills and runs on any model.",
                    website: "https://hermes-agent.nousresearch.com", source: "available", added: true,
                    state: .ready,
                    models: [
                        MachineAgent.Choice(id: "custom:bolt", name: "Bolt"),
                        MachineAgent.Choice(id: "custom:qwen-daily", name: "Qwen Daily"),
                        MachineAgent.Choice(id: "custom:glimmer", name: "Glimmer"),
                    ],
                    currentModel: "custom:bolt",
                    brain: MachineAgent.Brain(kind: "local", name: "llama-swap", baseURL: brain.baseURL, model: "bolt"),
                    brainStyle: "hermes", distribution: "uvx", checkedAt: ago(600)),
                MachineAgent(
                    id: "gemini", name: "Gemini CLI", version: "0.66.0", source: "found", added: true,
                    state: .needsKey, failure: "GEMINI_API_KEY is not set.",
                    keys: [
                        MachineAgent.Key(
                            env: "GEMINI_API_KEY", name: "Gemini API key",
                            url: "https://aistudio.google.com/apikey", set: false)
                    ],
                    signIn: [MachineAgent.SignInMethod(id: "oauth-personal", name: "Log in with Google", kind: "agent")],
                    distribution: "npx", checkedAt: ago(900)),
                MachineAgent(
                    id: "goose", name: "goose", version: "1.57.0", source: "found", added: false,
                    state: .notAdded, distribution: "download"),
            ],
            brains: [brain])
    }

    static var demoRegistry: [RegistryAgent] {
        [
            RegistryAgent(id: "codex-acp", name: "Codex", version: "2.5.0", authors: ["OpenAI"], distribution: "npx", installable: true),
            RegistryAgent(id: "github-copilot-cli", name: "GitHub Copilot", version: "1.0.105", authors: ["GitHub"], distribution: "npx", installable: true),
            RegistryAgent(id: "goose", name: "goose", version: "1.57.0", authors: ["Block"], distribution: "download", installable: true, here: "found"),
            RegistryAgent(id: "kimi", name: "Kimi CLI", version: "1.52.0", authors: ["Moonshot AI"], distribution: "download", installable: true),
            RegistryAgent(id: "qwen-code", name: "Qwen Code", version: "0.26.5", authors: ["Qwen"], distribution: "npx", installable: true),
            RegistryAgent(id: "mistral-vibe", name: "Mistral Vibe", version: "3.0.4", authors: ["Mistral AI"], distribution: "download", installable: true),
            RegistryAgent(id: "cursor", name: "Cursor", version: "2026.10.22", authors: ["Anysphere"], distribution: "download", installable: true),
            RegistryAgent(id: "gemini", name: "Gemini CLI", version: "0.66.0", authors: ["Google"], distribution: "npx", installable: true, here: "added"),
        ]
    }
}
