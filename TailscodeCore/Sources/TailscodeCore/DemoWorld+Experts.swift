import AgentTestSupport
import CodingAgentKit
import Foundation

extension DemoWorld {
    static let demoIPadExpertID = "demo-x-ipad"
    static let demoServerExpertID = "demo-x-server"
    static let demoReleasesExpertID = "demo-x-releases"

    /// The demo machine's experts: one with a finished task whose notes wait for review, one at
    /// work on the live chat, and one whose guard broke overnight — every state the shelf says.
    static var demoExperts: MockExperts {
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int, dayOffset: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: Date())) ?? Date()
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? Date()
        }
        let nightly = ScheduleRule(kind: .daily, hour: 3, minute: 0)
        func passed(_ seconds: Double, value: Double? = nil) -> ExpertGuardRun {
            ExpertGuardRun(at: at(3, 0, dayOffset: 0), passed: true, seconds: seconds, exitCode: 0, value: value)
        }
        let iPadGuards = [
            ExpertGuard(id: "g1", name: "PadLayoutTests", command: "xcodebuild test -scheme Pulse -only-testing:PulseTests/PadLayoutTests", last: passed(41)),
            ExpertGuard(id: "g2", name: "Resize redraw, iPad mini", command: "scripts/bench-resize.sh mini",
                metric: ExpertGuardMetric(pattern: "first frame ([0-9.]+) ms", atMost: 100, unit: "ms"),
                last: passed(184, value: 46)),
            ExpertGuard(id: "g3", name: "Launch to first frame, iPad Pro", command: "scripts/bench-launch.sh pro",
                metric: ExpertGuardMetric(pattern: "first frame ([0-9.]+) s", atMost: 3, unit: "s"),
                last: passed(73, value: 2.4)),
            ExpertGuard(id: "g4", name: "iPhone build", command: "xcodebuild build -scheme Pulse -destination generic/platform=iOS", last: passed(96)),
        ]
        let iPad = MachineExpert(
            id: demoIPadExpertID, name: "iPadOS", glyph: "iP", hue: "blue",
            purpose: "Makes the apps excellent on iPad, measured on the real iPads.",
            directory: "/Users/demo/dev/pulse-ios", model: "claude-fable-5", effort: "high",
            charter: """
                Make Pulse excellent on iPad at every window size and in both orientations, iPad mini through 13-inch. \
                A layout is a function of the window, never of the device. Measure on the real iPads before believing the \
                simulator, and hold each device's lock around anything installed on it. Keep the iPhone exactly as it was.
                """,
            skills: ["ipados", "ios-dev"], notebookPath: "/Users/demo/notes/pulse",
            bench: [
                ExpertBenchItem(
                    id: "b1", name: "iPad Pro M1", kind: .appleDevice, identifier: "00008103-0019349C0ED0801E",
                    lock: "/tmp/ipad-pro.lock", state: .ready,
                    facts: ["transport": "wired", "os": "iPadOS", "osVersion": "27.3"], checkedAt: Date()),
                ExpertBenchItem(
                    id: "b2", name: "iPad mini", kind: .appleDevice, identifier: "00008160-00080C6834700036",
                    state: .ready, facts: ["transport": "usb", "os": "iPadOS", "osVersion": "27.3"], checkedAt: Date()),
                ExpertBenchItem(
                    id: "b3", name: "iPhone XS", kind: .appleDevice, state: .ready,
                    facts: ["transport": "network", "os": "iOS", "osVersion": "18.7"], checkedAt: Date()),
                ExpertBenchItem(id: "b4", name: "iPhone Air", kind: .appleDevice, state: .locked, checkedAt: Date()),
            ],
            guards: iPadGuards, guardRule: nightly, guardNext: nightly.next(after: Date(), calendar: calendar),
            createdAt: ago(21 * 86_400), updatedAt: ago(2 * 86_400),
            notebook: ExpertNotebookFacts(path: "/Users/demo/notes/pulse", adopted: true, notes: 6, stale: 1, retired: 2),
            briefTokens: 3_104, watches: ["demo-s2"])

        let server = MachineExpert(
            id: demoServerExpertID, name: "Server", glyph: "Se", hue: "green",
            purpose: "Keeps pulse-server fast and its sockets honest.",
            directory: "/Users/demo/dev/pulse-server", model: "claude-fable-5", effort: "max",
            charter: "Every change to the socket layer ships with a test that fails without it. Measure p95 reconnect on staging before and after.",
            skills: ["swift-server"],
            bench: [
                ExpertBenchItem(
                    id: "b5", name: "Staging", kind: .port, host: "staging.pulse.internal", port: 8443, state: .ready,
                    checkedAt: Date()),
                ExpertBenchItem(
                    id: "b6", name: "Postgres", kind: .command, command: "pg_isready -h localhost", state: .ready,
                    facts: ["output": "localhost:5432 - accepting connections"], checkedAt: Date()),
            ],
            guards: [
                ExpertGuard(id: "g5", name: "Swift tests", command: "swift test", last: passed(212)),
                ExpertGuard(id: "g6", name: "p95 reconnect on staging", command: "scripts/reconnect-p95.sh",
                    metric: ExpertGuardMetric(pattern: "p95 ([0-9.]+) ms", atMost: 800, unit: "ms"),
                    last: passed(64, value: 412)),
            ],
            guardRule: nightly, guardNext: nightly.next(after: Date(), calendar: calendar),
            createdAt: ago(14 * 86_400), updatedAt: ago(3 * 86_400),
            notebook: ExpertNotebookFacts(path: "~/.claude-bridge/experts/server/notebook", adopted: false, notes: 11, stale: 0, retired: 1),
            briefTokens: 1_870)

        let failingRun = ExpertGuardRun(
            at: at(3, 0, dayOffset: 0), passed: false, seconds: 8, exitCode: 1,
            output: "CHANGELOG.md has no section for 2.4.0\nThe tag v2.4.0 points at 6f1c2e9", failure: .exit)
        let releases = MachineExpert(
            id: demoReleasesExpertID, name: "Releases", glyph: "Re", hue: "orange",
            purpose: "Ships Pulse: notes, store copy and the release itself.",
            directory: "/Users/demo/dev/pulse-ios", model: "claude-sonnet-5",
            charter: "A release is notes a person can read, store copy in every language, and a build that passed every guard.",
            skills: ["app-store"],
            guards: [
                ExpertGuard(
                    id: "g7", name: "Changelog matches the tag", command: "scripts/changelog-check.sh",
                    last: failingRun,
                    history: [failingRun, ExpertGuardRun(at: at(3, 0, dayOffset: -1), passed: true, seconds: 7)]),
                ExpertGuard(id: "g8", name: "Store copy in 11 languages", command: "scripts/store-copy-check.sh", last: passed(5)),
            ],
            guardRule: nightly, guardNext: nightly.next(after: Date(), calendar: calendar),
            createdAt: ago(9 * 86_400), updatedAt: ago(9 * 86_400),
            notebook: ExpertNotebookFacts(path: "~/.claude-bridge/experts/releases/notebook", adopted: false, notes: 7, stale: 0, retired: 0),
            briefTokens: 1_240)

        let notes = [
            ExpertNote(
                id: "settings-rows-read-the-palette.md", title: "Settings rows read the palette",
                summary: "Every row's colour comes from Palette, never a literal", body: "…", written: ago(86_400)),
            ExpertNote(
                id: "the-test-devices.md", title: "The test devices",
                summary: "iPad Pro sideways, mini upright, XS on iOS 18.7, Air when unlocked", body: "…",
                written: ago(2 * 86_400)),
            ExpertNote(
                id: "two-thumbs-held-sideways.md", title: "Two thumbs, held sideways",
                summary: "Navigation under the left thumb, the main action under the right", body: "…",
                written: ago(4 * 86_400)),
            ExpertNote(
                id: "a-resize-shows-the-old-frame.md", title: "A resize shows the old frame",
                summary: "Until the app draws, iPadOS stretches its last picture", body: "…", written: ago(4 * 86_400)),
            ExpertNote(
                id: "the-split-widths.md", title: "The split widths",
                summary: "375, 592 and 834 points on an 11-inch held sideways", body: "…", written: ago(6 * 86_400)),
            ExpertNote(
                id: "builds-with-the-release-candidate.md", title: "Pulse builds with the release candidate",
                summary: "The beta Xcode fails its asset catalog", body: "…", written: ago(69 * 86_400), stale: true),
            ExpertNote(
                id: "settings-hard-codes-two-greys.md", title: "Settings hard-codes two greys",
                summary: "Rows 3 and 7 use literal colours", body: "…", written: ago(30 * 86_400),
                retired: ExpertNoteRetirement(at: ago(86_400), reason: "Every row reads the palette now")),
            ExpertNote(
                id: "the-mini-is-on-wi-fi.md", title: "The mini is on the Mac’s Wi-Fi",
                summary: "Install over the network", body: "…", written: ago(40 * 86_400),
                retired: ExpertNoteRetirement(at: ago(3 * 86_400), reason: "It moved to USB on the other machine")),
        ]
        let journal = [
            ExpertJournalEntry(
                id: "j1", sessionID: "demo-c3", title: "Dark mode for Settings", at: ago(1_560),
                outcome: "Every Settings row reads from the palette; the two hard-coded greys are gone.",
                measured: ["0 contrast warnings in both appearances"], commits: ["4be21c0 Read Settings colours from the palette"]),
            ExpertJournalEntry(
                id: "j2", title: "Performance round", at: ago(2 * 86_400),
                outcome: "The board scrolls without late frames and a resize redraws at once.",
                measured: ["late frames 30 → 11 ms/s on the iPad Pro", "resize 450 → 83 ms on the mini"]),
            ExpertJournalEntry(
                id: "j3", title: "iPad mini layout", at: ago(4 * 86_400),
                outcome: "The mini gets measurements of its own instead of a 13-inch's.", commits: ["9c0d1aa", "77e1f02"]),
        ]
        let debrief = ExpertDebrief(
            sessionID: "demo-c3", expertID: demoIPadExpertID, at: ago(1_500), coveredTurns: 3, state: .open,
            journal: journal[0],
            proposals: [
                ExpertProposal(
                    id: "p1", op: .add, title: "Settings rows read the palette",
                    summary: "Every row's colour comes from Palette, never a literal",
                    body: "Every Settings row takes its colours from Palette.\n**Why:** literals drifted in dark mode.\n**How to apply:** a new row reads Palette, never a hex.",
                    reason: "This task replaced the last two literal greys."),
                ExpertProposal(
                    id: "p2", op: .add, title: "Check both appearances on the iPad Pro",
                    summary: "Contrast is checked in light and dark before a colour change ships",
                    body: "…", reason: "Dark mode looked right in the simulator and wrong on the device."),
                ExpertProposal(
                    id: "p3", op: .retire, note: "settings-hard-codes-two-greys.md", title: "Settings hard-codes two greys",
                    summary: "Rows 3 and 7 use literal colours", body: "",
                    reason: "Not true any more: every row reads the palette."),
            ])
        return MockExperts(
            experts: [iPad, server, releases],
            notes: [demoIPadExpertID: notes],
            journals: [demoIPadExpertID: journal],
            debriefs: ["demo-c3": debrief],
            skills: [
                ExpertSkill(name: "ipados", description: "Make an iOS app excellent on iPad at every window size.", path: "~/.claude/skills/ipados/SKILL.md"),
                ExpertSkill(name: "ios-dev", description: "Logging, signing and running on devices.", path: "~/.claude/skills/ios-dev/SKILL.md"),
                ExpertSkill(name: "app-store", description: "Releases, TestFlight and store copy.", path: "~/.claude/skills/app-store/SKILL.md"),
                ExpertSkill(name: "swift-server", description: "Server-side Swift: Hummingbird, NIO, tests.", path: "~/.claude/skills/swift-server/SKILL.md"),
            ])
    }
}
