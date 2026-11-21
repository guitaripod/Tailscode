import AgentTestSupport
import CodingAgentKit
import Foundation

extension DemoWorld {
    static let demoIPadMasterID = "demo-x-ipad"
    static let demoServerMasterID = "demo-x-server"
    static let demoReleasesMasterID = "demo-x-releases"
    /// The finished task whose debrief waits for the person. It has to be a conversation at rest:
    /// a debrief on one that still wants an approval is a card no client can show.
    public static let demoReviewedTaskID = "demo-c5"

    /// The demo machine's masters: one with a finished task whose notes wait for review, one at
    /// work on the live chat, and one whose guard broke overnight — every state the shelf says.
    static var demoMasters: MockExperts {
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
            id: demoIPadMasterID, name: "iPadOS", glyph: "iP", hue: "blue",
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
            id: demoServerMasterID, name: "Server", glyph: "Se", hue: "green",
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
            notebook: ExpertNotebookFacts(path: "~/.claude-bridge/masters/server/notebook", adopted: false, notes: 11, stale: 0, retired: 1),
            briefTokens: 1_870)

        let failingRun = ExpertGuardRun(
            at: at(3, 0, dayOffset: 0), passed: false, seconds: 8, exitCode: 1,
            output: "CHANGELOG.md has no section for 2.4.0\nThe tag v2.4.0 points at 6f1c2e9", failure: .exit)
        let releases = MachineExpert(
            id: demoReleasesMasterID, name: "Releases", glyph: "Re", hue: "orange",
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
            notebook: ExpertNotebookFacts(path: "~/.claude-bridge/masters/releases/notebook", adopted: false, notes: 7, stale: 0, retired: 0),
            briefTokens: 1_240)

        func body(_ fact: String, why: String, how: String) -> String {
            "\(fact)\n\n**Why:** \(why)\n**How to apply:** \(how)"
        }
        let notes = [
            ExpertNote(
                id: "settings-rows-read-the-palette.md", title: "Settings rows read the palette",
                summary: "Every row's colour comes from Palette, never a literal", body: body(
                    "Every Settings row takes its colours from Palette.",
                    why: "literal greys drifted in dark mode.",
                    how: "a new row reads Palette, never a hex."), written: ago(86_400)),
            ExpertNote(
                id: "the-test-devices.md", title: "The test devices",
                summary: "iPad Pro sideways, mini upright, XS on iOS 18.7, Air when unlocked", body: body(
                    "The iPad Pro is tested held sideways and the mini upright; the iPhone XS is the oldest iOS, and the iPhone Air joins whenever it is unlocked.",
                    why: "each device is tested the way it is held.",
                    how: "take a device’s lock before installing on it, and say which devices a result was measured on."),
                written: ago(2 * 86_400)),
            ExpertNote(
                id: "two-thumbs-held-sideways.md", title: "Two thumbs, held sideways",
                summary: "Navigation under the left thumb, the main action under the right", body: body(
                    "Held sideways in both hands, navigation sits under the left thumb and the main action under the right.",
                    why: "a control in the middle of the screen means letting go of the iPad.",
                    how: "check a new screen against both thumbs’ reach before its centre."),
                written: ago(4 * 86_400)),
            ExpertNote(
                id: "a-resize-shows-the-old-frame.md", title: "A resize shows the old frame",
                summary: "Until the app draws, iPadOS stretches its last picture", body: body(
                    "While a window is resized, iPadOS stretches the app’s last picture until the app draws again.",
                    why: "a slow first layout after a resize shows as a smeared frame.",
                    how: "measure the first frame after a resize on the mini, and keep it under 100 ms."), written: ago(4 * 86_400)),
            ExpertNote(
                id: "the-split-widths.md", title: "The split widths",
                summary: "375, 592 and 834 points on an 11-inch held sideways", body: body(
                    "An 11-inch iPad held sideways gives a split window 375, 592 or 834 points.",
                    why: "a layout tested only full screen breaks at the narrow split.",
                    how: "lay out from the window’s width, and check all three."), written: ago(6 * 86_400)),
            ExpertNote(
                id: "builds-with-the-release-candidate.md", title: "Pulse builds with the release candidate",
                summary: "The beta Xcode fails its asset catalog", body: body(
                    "Pulse builds with the release candidate; the beta Xcode fails on its asset catalog.",
                    why: "the beta’s catalog compiler rejected the app icon’s layers.",
                    how: "build with the release candidate until a newer beta is tried."), written: ago(69 * 86_400), stale: true),
            ExpertNote(
                id: "settings-hard-codes-two-greys.md", title: "Settings hard-codes two greys",
                summary: "Rows 3 and 7 use literal colours", body: body(
                    "Rows 3 and 7 of Settings use literal greys.",
                    why: "they were written before the palette.",
                    how: "move them to the palette when Settings is next touched."), written: ago(30 * 86_400),
                retired: ExpertNoteRetirement(at: ago(86_400), reason: "Every row reads the palette now")),
            ExpertNote(
                id: "the-mini-is-on-wi-fi.md", title: "The mini is on the Mac’s Wi-Fi",
                summary: "Install over the network", body: body(
                    "The iPad mini is reached over the Mac’s Wi-Fi.",
                    why: "it has no cable to the Mac.",
                    how: "install over the network, and expect it to be slower."), written: ago(40 * 86_400),
                retired: ExpertNoteRetirement(at: ago(3 * 86_400), reason: "It moved to USB on the other machine")),
        ]
        let journal = [
            ExpertJournalEntry(
                id: "j1", sessionID: demoReviewedTaskID, title: "Composer redesign", at: ago(2_400),
                outcome: "Three directions for the composer are on the board; the docked one keeps Send under the right thumb.",
                measured: ["reach checked on the iPad Pro and the mini"]),
            ExpertJournalEntry(
                id: "j2", title: "Performance round", at: ago(2 * 86_400),
                outcome: "The board scrolls without late frames and a resize redraws at once.",
                measured: ["late frames 30 → 11 ms/s on the iPad Pro", "resize 450 → 83 ms on the mini"]),
            ExpertJournalEntry(
                id: "j3", title: "iPad mini layout", at: ago(4 * 86_400),
                outcome: "The mini gets measurements of its own instead of a 13-inch's.", commits: ["9c0d1aa", "77e1f02"]),
        ]
        let serverNotes = [
            ExpertNote(
                id: "jitter-is-injected.md", title: "Jitter is injected",
                summary: "A scheduler takes its jitter source, so a test can pin it", body: body(
                    "A scheduler takes its jitter source as a parameter.",
                    why: "a test that cannot pin the jitter fails one run in five.",
                    how: "new timing code takes its randomness from outside."), written: ago(3 * 86_400)),
            ExpertNote(
                id: "staging-drops-idle-sockets.md", title: "Staging drops idle sockets",
                summary: "The load balancer closes a socket idle for 60 s", body: body(
                    "Staging’s load balancer closes a socket that has been idle for 60 seconds.",
                    why: "reconnects there are the balancer’s doing, not the server’s.",
                    how: "send a ping every 30 seconds before reading a staging reconnect as a bug."), written: ago(8 * 86_400)),
            ExpertNote(
                id: "tests-run-serially.md", title: "The socket tests run one at a time",
                summary: "They share a port, so a parallel run fails at random", body: body(
                    "The socket tests share a port and run one at a time.",
                    why: "a parallel run fails at random on the bind.",
                    how: "keep them in the serial suite."), written: ago(12 * 86_400)),
        ]
        let serverJournal = [
            ExpertJournalEntry(
                id: "j4", title: "Reconnect backoff", at: ago(3 * 86_400),
                outcome: "A dropped socket retries with capped, jittered delays.",
                measured: ["p95 reconnect 1.9 s → 412 ms on staging"], commits: ["a41c7de Cap the reconnect backoff"]),
        ]
        let releaseNotes = [
            ExpertNote(
                id: "notes-lead-with-the-person.md", title: "Notes lead with what a person sees",
                summary: "The first line of a release note is the change on screen, never the cause", body: body(
                    "The first line of a release note is the change a person sees on screen.",
                    why: "nobody reads past a line about internals.",
                    how: "lead with the screen, and leave the cause for the changelog."),
                written: ago(9 * 86_400)),
            ExpertNote(
                id: "store-copy-before-the-build.md", title: "Store copy before the build",
                summary: "What’s New is written in every language before the build is uploaded",
                body: body(
                    "What’s New is written in every language before the build is uploaded.",
                    why: "a build waiting for review with English-only notes shipped that way once.",
                    how: "run the store copy guard before the upload, not after."),
                written: ago(9 * 86_400)),
        ]
        let releaseJournal = [
            ExpertJournalEntry(
                id: "j5", title: "Pulse 2.3.0", at: ago(9 * 86_400),
                outcome: "2.3.0 is on sale with notes in 11 languages.", commits: ["c07e3b1 Pulse 2.3.0"]),
        ]
        let debrief = ExpertDebrief(
            sessionID: demoReviewedTaskID, expertID: demoIPadMasterID, at: ago(2_340), coveredTurns: 3, state: .open,
            journal: journal[0],
            proposals: [
                ExpertProposal(
                    id: "p1", op: .add, title: "The composer docks at the foot",
                    summary: "Docked, Send stays under the right thumb at every window width",
                    body: body(
                        "The composer docks at the foot of the window.",
                        why: "floating, Send left the right thumb’s reach in the narrow split.",
                        how: "a new control in the composer is placed from the trailing edge inward."),
                    reason: "Two of the three directions put Send out of reach held sideways."),
                ExpertProposal(
                    id: "p2", op: .add, title: "Check both appearances on the iPad Pro",
                    summary: "A mock is looked at in light and dark on the device before it is picked",
                    body: body(
                        "A mock is looked at in light and dark on the iPad Pro before it is picked.",
                        why: "the floating direction looked right in the simulator and washed out on the device.",
                        how: "photograph both appearances on the device and read the contrast warnings."),
                    reason: "The floating direction washed out on the device in light mode."),
                ExpertProposal(
                    id: "p3", op: .retire, note: "builds-with-the-release-candidate.md",
                    title: "Pulse builds with the release candidate",
                    summary: "The beta Xcode fails its asset catalog", body: "",
                    reason: "Not true any more: this task built with the current beta."),
            ])
        return MockExperts(
            experts: [iPad, server, releases],
            notes: [demoIPadMasterID: notes, demoServerMasterID: serverNotes, demoReleasesMasterID: releaseNotes],
            journals: [demoIPadMasterID: journal, demoServerMasterID: serverJournal, demoReleasesMasterID: releaseJournal],
            debriefs: [demoReviewedTaskID: debrief],
            skills: [
                ExpertSkill(name: "ipados", description: "Make an iOS app excellent on iPad at every window size.", path: "~/.claude/skills/ipados/SKILL.md"),
                ExpertSkill(name: "ios-dev", description: "Logging, signing and running on devices.", path: "~/.claude/skills/ios-dev/SKILL.md"),
                ExpertSkill(name: "app-store", description: "Releases, TestFlight and store copy.", path: "~/.claude/skills/app-store/SKILL.md"),
                ExpertSkill(name: "swift-server", description: "Server-side Swift: Hummingbird, NIO, tests.", path: "~/.claude/skills/swift-server/SKILL.md"),
            ])
    }
}
