import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    /// A synthetic conversation around a compaction — the finished seam, the summarize still
    /// running, or the refusal — so every face of the card can be photographed headlessly without
    /// spending minutes compacting a real transcript.
    /// A conversation whose turn the machine was pulled out from under, so the card can be driven
    /// and photographed headlessly without stopping a real server mid-answer.
    func driverInterruptedDemo(_ mode: String) {
        let now = Date()
        let asked = ChatMessage(
            id: "demo-cut-prompt", role: .user, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "t", kind: .text("port the toggles to the mac and keep the tests green"))
            ],
            createdAt: now.addingTimeInterval(-900))
        var state = ConversationState(messages: [asked], status: .idle, hasLoadedTranscript: true)
        state.interruption = TurnInterruption(
            turnID: "demo-turn", prompt: "port the toggles to the mac and keep the tests green",
            startedAt: now.addingTimeInterval(-900), detectedAt: now.addingTimeInterval(-120),
            progress: mode == "clean"
                ? TurnInterruption.Progress()
                : TurnInterruption.Progress(
                    toolCount: 9, lastTool: "Edit",
                    filesTouched: [
                        "/home/m/Dev/Tailscode/TailscodeMac/Toggles.swift",
                        "/home/m/Dev/Tailscode/TailscodeMac/Theme.swift",
                    ],
                    commands: ["swift build", "swift test --filter Toggles"],
                    partialAnswer: "I have moved the first two toggles across and"),
            queued: mode == "queued" ? ["then do the same for the sidebar"] : [],
            resumedAt: mode == "resumed" ? now : nil)
        apply(state: state, rows: rowBuilder.rows(state: state))
    }

    /// The "Undo from here" confirmation and the banner that follows it, driven straight past the
    /// right-click popover a headless, software-rendered display never paints: this is the exact
    /// same `confirmUndo` the menu item calls, so everything past the press (the dialog's words,
    /// the revert, the banner, Restore) is the real path, not a stand-in for it, on a desktop that
    /// can actually show a modal window. `mode == "skip"` calls `performUndo` directly instead,
    /// for the same headless display, which cannot show that modal window either.
    func driverUndoDemo(_ mode: String) {
        guard isDemoConversation else { return }
        let messageID = "o1u1"
        if mode == "skip" {
            performUndo(messageID: messageID)
        } else {
            confirmUndo(messageID: messageID)
        }
    }

    /// The Restore press on a standing revert's banner, for the same headless display: a plain
    /// row button, so unlike the popover and the confirmation this one the display can actually
    /// show, but a driver verb still saves a click hunting for it across screenshots.
    func driverRestoreDemo() {
        guard isDemoConversation else { return }
        pressRestoreRevert()
    }

    /// Whether the open chat belongs to the demo world. The undo and restore drivers act on the
    /// server rather than drawing a synthetic state, so they refuse to touch a real machine's
    /// conversation even when a drive verb is typed against one by mistake.
    var isDemoConversation: Bool {
        entry?.profileID.hasPrefix(DemoWorld.profilePrefix) == true
    }

    /// A turn waiting on its provider between attempts, so the card and its countdown can be
    /// driven and photographed headlessly without an account that is actually rate-limited.
    /// `mode == "remedy"` adds the provider's own remedy and its link; anything else is the bare
    /// wait, which is the shape a client sees far more often.
    func driverRetryDemo(_ mode: String) {
        let now = Date()
        let asked = ChatMessage(
            id: "demo-retry-prompt", role: .user, agentType: .openCode,
            parts: [MessagePart(id: "t", kind: .text("Summarize the last ten commits."))],
            createdAt: now.addingTimeInterval(-40))
        var state = ConversationState(
            messages: [asked], status: .running, hasLoadedTranscript: true)
        let remedy: TurnRetry.Remedy? =
            mode == "remedy"
            ? TurnRetry.Remedy(
                title: "This plan is out of credit",
                message: "Add credit, or wait for the weekly reset.",
                label: "Open billing", link: "https://example.com/billing")
            : nil
        state.retry = TurnRetry(
            attempt: 3, reason: "The provider returned a 429 (rate limited).",
            nextAttemptAt: now.addingTimeInterval(75), remedy: remedy)
        reassert(state)
    }

    /// Applies a synthetic state again and again for a couple of seconds. The demo world's own
    /// sessions keep re-emitting their scripted state on a clock this pane is also subscribed to,
    /// which would overwrite the synthetic one within a frame or two, so a screenshot taken any
    /// time after the drive step would otherwise show something other than the card it drove.
    func reassert(_ state: ConversationState) {
        let rows = rowBuilder.rows(state: state)
        for delay: UInt32 in [0, 250, 500, 800, 1200, 1700, 2300] {
            Gtk.after(delay) { [weak self] in
                Gtk.onMain { [weak self] in self?.apply(state: state, rows: rows) }
            }
        }
    }

    static let tableDemoAnswer = """
            16 BSSIDs visible (5 distinct networks + a set of hidden-SSID radios), scanned on \
            `wlo1` (Intel AX200/210, `wlxac198e9d34d3`, currently **DOWN**, rfkill unblocked). \
            Sorted by signal.

            ## By network

            **Lord of the Pings** — Apple router (MAC `30:66:5E`), 3 bands + 4 hidden

            | Band | BSSID | Ch | Freq | Width | Rate | Sig | Security |
            |---|---|---|---|---|---|---|---|
            | 2.4 | `92:30:66:5E:BF:4D` | 6 | 2437 MHz | 20 | 130 Mb/s | 94 | WPA2+WPA3 (PSK+SAE) |
            | 6 | `96:30:66:5E:BF:4F` | 37 | 6135 MHz | 0 | 0 | 94 | WPA3 (SAE) |
            | 5 | `96:30:66:5E:BF:4E` | 128 | 5640 MHz | 80 | 1170 Mb/s | 92 | WPA2+WPA3 (PSK+SAE) |
            | 5 (hidden) | `8C:30:66:5E:BF:4E` | 128 | 5640 MHz | 80 | 1170 Mb/s | 94 | WPA2 (PSK) |
            | 5 (hidden) | `92:30:66:5E:BF:4E` | 128 | 5640 MHz | 80 | 1170 Mb/s | 94 | WPA2 (PSK) |
            | 6 (hidden) | `8C:30:66:5E:BF:4F` | 37 | 6135 MHz | 0 | 0 | 94 | WPA3 (SAE) |
            | 6 (hidden) | `92:30:66:5E:BF:4F` | 37 | 6135 MHz | 0 | 0 | 94 | WPA3 (SAE) |

            **DNA-WIFI-2E04** — DNA/Elisa router, 2 bands (BSSID pair `D8:33:B7:1E:2E:0x`)

            | Band | BSSID | Ch | Freq | Width | Rate | Sig | Sec |
            |---|---|---|---|---|---|---|---|
            | 2.4 | `D8:33:B7:1E:2E:08` | 11 | 2462 MHz | 20 | 540 Mb/s | 42 | WPA2+WPA3 |
            | 5 | `D8:33:B7:1E:2E:09` | 100 | 5500 MHz | 80 | 1170 Mb/s | 20 | WPA2+WPA3 |

            ## Radios

            | Interface | Driver | State |
            |---|---|---|
            | `wlo1` | iwlwifi | down |
            | `wlxac198e9d34d3` | rtl8xxxu | up |

            ## Notes

            - **Nearest / strongest**: "Lord of the Pings" (Apple, ~92–94/100) — almost certainly \
            your own network.
            - **6 GHz "0 Mbit/s / 0 MHz"**: normal — NM doesn't populate rate/width for 6 GHz in \
            this firmware path.
            """

    /// The answer that made the tables worth redesigning: eight sparse columns of readings, a
    /// column of addresses, a column of cipher suites long enough to fold, and a second table
    /// whose header is shorter than every cell under it.
    func driverTableDemo() {
        let now = Date()
        let asked = ChatMessage(
            id: "demo-table-prompt", role: .user, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "t",
                    kind: .text("List all wifi networks you can see. all the details about them as well."))
            ],
            createdAt: now.addingTimeInterval(-120))
        let answer = Self.tableDemoAnswer
        let reply = ChatMessage(
            id: "demo-table-answer", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "a", kind: .text(answer))],
            createdAt: now)
        let state = ConversationState(
            messages: [asked, reply], status: .idle, hasLoadedTranscript: true)
        apply(state: state, rows: rowBuilder.rows(state: state))
    }

    /// A conversation of code blocks for the harness: a two-line command, a one-liner, a block
    /// long enough to fold, and a line wide enough to scroll sideways.
    /// A conversation made mostly of furniture — two tool calls, two pictures the agent made, a
    /// compaction seam, three more tool calls, a code block and three addresses — for the
    /// compact-chat measure: the demo chats are mostly words, and a density that only ever shows
    /// on words has not been tried. The argument is a comma-separated list of image files the two
    /// pictures are read from. `landing` swaps the story for the one the landing page tells: two
    /// pictures painted on the person's own machine, then the reconnect fix.
    func driverFurnitureDemo(_ argument: String, landing: Bool = false) {
        let now = Date()
        let asked = ChatMessage(
            id: "demo-furn-prompt", role: .user, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "t",
                    kind: .text(
                        landing
                            ? "Paint two pictures for the release page on arch, then pin the jitter in the flaky reconnect test."
                            : "Render the Studio mocks so I can compare the painting and done states, then pin the jitter in the reconnect test."
                    ))
            ], createdAt: now.addingTimeInterval(-300))
        func tool(_ id: String, _ name: String, _ input: [String: JSONValue], _ title: String)
            -> MessagePart
        {
            MessagePart(
                id: id,
                kind: .tool(
                    ToolCall(
                        id: "call-\(id)", name: name, status: .completed, input: .object(input),
                        title: title)))
        }
        let paths = argument.split(separator: ",").map(String.init)
        var parts: [MessagePart] =
            landing
            ? [
                tool("b1", "Bash", ["command": .string("comfy-queue lighthouse.json aurora-cabin.json")], "Queue both renders on arch"),
                tool("b0", "Bash", ["command": .string("comfy-wait --collect")], "Wait for the renders and collect them"),
            ]
            : [
                tool("b1", "Bash", ["command": .string("python3 scripts/mock-comfyui.py")], "Start the mock"),
                tool("w1", "Write", ["file_path": .string("docs/studio-mocks/b-painting.png")], "Write b-painting.png"),
            ]
        for (index, path) in paths.prefix(30).enumerated() {
            let name = URL(fileURLWithPath: path).lastPathComponent
            let part = MessagePart(
                id: "pic\(index)",
                kind: .file(FileReference(path: path, mime: "image/png", filename: name)))
            parts.append(part)
            let key = "demo-furn-answer:pic\(index)"
            guard !context.pictures.has(key),
                let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            else { continue }
            context.storePreview(of: data, original: FileReference(path: path), forKey: key)
        }
        parts.append(
            MessagePart(
                id: "seam",
                kind: .compaction(
                    Compaction(
                        trigger: .manual, tokensBefore: 311_600, tokensAfter: 16_400, duration: 114,
                        preservedMessageCount: 9, summary: "The Studio mocks are written; the jitter test is next."
                    ))))
        parts += [
            tool("r1", "Read", ["file_path": .string("Sources/Pulse/ReconnectScheduler.swift")], "Read ReconnectScheduler.swift"),
            tool("e1", "Edit", ["file_path": .string("Tests/PulseTests/ReconnectTests.swift"), "old_string": .string("a"), "new_string": .string("b")], "Edit ReconnectTests.swift"),
            tool("b2", "Bash", ["command": .string("swift test --filter ReconnectTests")], "swift test --filter ReconnectTests"),
            MessagePart(
                id: "answer",
                kind: .text(
                    """
                    Found it. `ReconnectScheduler` applies ±40% jitter to the 400 ms base delay, so the worst case is 560 ms — past the test's 500 ms ceiling. Pin it in tests:

                    ```swift
                    protocol JitterSource: Sendable {
                        func factor(in range: ClosedRange<Double>) -> Double
                    }

                    struct FixedJitter: JitterSource {
                        let value: Double
                        func factor(in _: ClosedRange<Double>) -> Double { value }
                    }
                    ```

                    The suite now pins the factor to 1.0. The upstream discussion is at https://github.com/swiftlang/swift, the CI side in https://docs.github.com/en/actions/using-jobs/using-concurrency and the backoff rule in https://datatracker.ietf.org/doc/html/rfc6298.
                    """)),
        ]
        let reply = ChatMessage(
            id: "demo-furn-answer", role: .assistant, agentType: .claudeCode, parts: parts,
            createdAt: now)
        let state = ConversationState(
            messages: [asked, reply] + (landing ? landingFollowUp(after: now) : []),
            status: .idle, connection: landing ? .live : .connecting, hasLoadedTranscript: true)
        apply(state: state, rows: rowBuilder.rows(for: state.messages, turnOpen: false))
    }

    /// The second turn of the landing story: a question, a run of tools and a short answer, so the
    /// compact transcript is seen over more than one turn.
    func landingFollowUp(after now: Date) -> [ChatMessage] {
        func tool(_ id: String, _ name: String, _ input: [String: JSONValue], _ title: String)
            -> MessagePart
        {
            MessagePart(
                id: id,
                kind: .tool(
                    ToolCall(
                        id: "call-\(id)", name: name, status: .completed, input: .object(input),
                        title: title)))
        }
        let asked = ChatMessage(
            id: "demo-furn-prompt-2", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text("Run the whole suite once more, then tell me if the pictures need anything."))],
            createdAt: now.addingTimeInterval(60))
        let reply = ChatMessage(
            id: "demo-furn-answer-2", role: .assistant, agentType: .claudeCode,
            parts: [
                tool("b3", "Bash", ["command": .string("swift test")], "swift test"),
                tool("b4", "Bash", ["command": .string("swift test --filter ReconnectTests")], "swift test --filter ReconnectTests"),
                MessagePart(
                    id: "answer",
                    kind: .text(
                        "The suite is green and the reconnect test passed again with the jitter pinned. The two pictures stay on arch, so they are there to reuse for the release page.")),
            ], createdAt: now.addingTimeInterval(90))
        return [asked, reply]
    }
}
