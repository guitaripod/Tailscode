import Foundation
import TailscodeCore

/// Cards that stand for every kind of turn a person follows, drawn by the real Live Activity views
/// wherever the app shows what a card will look like: the picker in Settings and the headless
/// screenshots. Their clocks are set from `now`, so the timers on them read as a turn would.
enum CardSamples {
    typealias State = ChatActivityAttributes.ContentState

    struct Sample {
        let name: String
        let title: String
        let state: State
    }

    static let server = "studio"

    static func all(now: Date = Date()) -> [Sample] {
        [working(now: now), needsYou(now: now), finished(now: now), failed(now: now), quiet(now: now)]
    }

    static func working(now: Date = Date()) -> Sample {
        let began = now.addingTimeInterval(-372)
        return Sample(
            name: "WORKING", title: "Fix the reconnect test",
            state: State(
                phase: .tool, statusText: "Running Bash", lastTool: "Bash", toolCount: 14,
                startedAt: began, endedAt: nil, title: nil, symbol: "terminal", tone: "live",
                detail: LiveActivityDetail.tool.rawValue, background: nil,
                brief: LiveActivityBrief(
                    steps: [
                        step("s1", "Grep", ["pattern": "jitter", "path": "Sources"], .done),
                        step("s2", "Read", ["file_path": "/src/ReconnectTests.swift"], .done),
                        step("s3", "Edit", ["file_path": "/src/Backoff.swift"], .done),
                        step("s4", "Bash", ["command": "swift test --filter Reconnect"], .running),
                    ],
                    plan: LiveActivityPlan(
                        done: 3, total: 5, current: "Run the reconnect tests",
                        next: "Write the changelog"),
                    files: 2, added: 18, removed: 6, beat: "000120310224123004213421",
                    moved: now.addingTimeInterval(-1), model: "claude-opus-4-5", ultra: nil, fill: 0.47)))
    }

    static func needsYou(now: Date = Date()) -> Sample {
        let began = now.addingTimeInterval(-221)
        return Sample(
            name: "NEEDS YOU", title: "CI migration",
            state: State(
                phase: .approval, statusText: "Awaiting your approval", lastTool: "Bash", toolCount: 6,
                startedAt: began, endedAt: nil, title: nil, symbol: "hand.raised", tone: "attention",
                detail: LiveActivityDetail.approval.rawValue, background: nil,
                brief: LiveActivityBrief(
                    steps: [step("n1", "Read", ["file_path": "/.github/workflows/ci.yml"], .done)],
                    beat: "000000000000000000000000", moved: now.addingTimeInterval(-21),
                    model: "claude-sonnet-4-5", fill: 0.31,
                    ask: "rm -rf build && swift build -c release")))
    }

    static func finished(now: Date = Date()) -> Sample {
        let began = now.addingTimeInterval(-900)
        return Sample(
            name: "DONE", title: "Fix the reconnect test",
            state: State(
                phase: .done, statusText: "Done", lastTool: nil, toolCount: 14, startedAt: began,
                endedAt: began.addingTimeInterval(372), title: nil, symbol: "checkmark.circle",
                tone: "live", detail: LiveActivityDetail.finished.rawValue, background: nil,
                brief: LiveActivityBrief(
                    steps: [
                        step("s3", "Edit", ["file_path": "/src/Backoff.swift"], .done),
                        step("s4", "Bash", ["command": "swift test --filter Reconnect"], .done),
                    ],
                    said: "The reconnect test passes now: the backoff no longer resets its jitter on every retry.",
                    files: 2, added: 18, removed: 6, model: "claude-opus-4-5")))
    }

    static func failed(now: Date = Date()) -> Sample {
        let began = now.addingTimeInterval(-640)
        return Sample(
            name: "FAILED", title: "Auth flow",
            state: State(
                phase: .error, statusText: "Something went wrong", lastTool: nil, toolCount: 9,
                startedAt: began, endedAt: began.addingTimeInterval(151), title: nil,
                symbol: "exclamationmark.triangle", tone: "danger",
                detail: LiveActivityDetail.failed.rawValue, background: nil,
                brief: LiveActivityBrief(
                    steps: [step("f1", "Bash", ["command": "swift build"], .failed)],
                    said: "The build failed: Token.swift does not compile after the rename.",
                    files: 1, added: 4, removed: 2, model: "gpt-5.1-codex")))
    }

    static func quiet(now: Date = Date()) -> Sample {
        let began = now.addingTimeInterval(-1260)
        return Sample(
            name: "QUIET", title: "Nightly backup",
            state: State(
                phase: .tool, statusText: "Running Bash", lastTool: "Bash", toolCount: 3,
                startedAt: began, endedAt: nil, title: nil, symbol: "terminal", tone: "live",
                detail: LiveActivityDetail.tool.rawValue, background: nil,
                brief: LiveActivityBrief(
                    steps: [step("q1", "Bash", ["command": "rsync -a ~/Dev /Volumes/Backup"], .running)],
                    beat: "000000000000000000000000", moved: now.addingTimeInterval(-200),
                    model: "claude-haiku-4-5", fill: 0.12)))
    }

    private static func step(
        _ id: String, _ tool: String, _ input: [String: String], _ state: LiveActivityStep.State
    ) -> LiveActivityStep {
        LiveActivityStep(id: id, tool: tool, input: input, state: state)
    }
}
