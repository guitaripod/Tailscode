import MidgarCore
#if DEBUG
    import Foundation
    import TailscodeCore

    /// Starts the Live Activities the store's Lock Screen panel is photographed from: the app's own
    /// `AppActivityController` writes them, so the cards on the Lock Screen are the real ones, with
    /// the real words from Core, and the script that photographs them only locks the simulator.
    /// `TAILSCODE_LOCKSCREEN=1` after `--demo`; nothing here ships behaviour, it only drives what a
    /// running turn already does.
    enum LockScreenShot {
        private struct Card {
            let session: String
            let title: String
            let server: String
            let detail: LiveActivityDetail
            let tool: String?
            let toolCount: Int
        }

        private static let cards = [
            Card(
                session: "demo-c3", title: "Dark mode for the settings screen", server: "studio",
                detail: .approval, tool: "Edit", toolCount: 7),
            Card(
                session: "demo-c1", title: "Fix the flaky WebSocket reconnect test", server: "studio",
                detail: .tool, tool: "Bash", toolCount: 12),
            Card(
                session: "demo-o1", title: "Refactor the auth module to async/await", server: "homelab",
                detail: .writing, tool: nil, toolCount: 9),
        ]

        /// The brief a turn of this kind carries, from the same samples the Settings picker draws.
        private static func brief(for detail: LiveActivityDetail) -> LiveActivityBrief? {
            var brief: LiveActivityBrief?
            switch detail {
            case .approval: brief = CardSamples.needsYou().state.brief
            case .tool: brief = CardSamples.working().state.brief
            default: brief = LiveActivityBrief(moved: Date(), model: "gpt-5.1-codex")
            }
            brief?.moved = Date()
            return brief
        }

        @MainActor
        static func startIfAsked() {
            guard let mode = ProcessInfo.processInfo.environment["TAILSCODE_LOCKSCREEN"] else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if mode == "room" {
                    await crowd()
                    return
                }
                for card in cards {
                    AppActivityController.shared.start(
                        sessionID: card.session, sessionTitle: card.title, serverName: card.server)
                    try? await Task.sleep(for: .milliseconds(700))
                    AppActivityController.shared.update(
                        sessionID: card.session,
                        reading: LiveActivityReading(
                            detail: card.detail, tool: card.tool, toolCount: card.toolCount),
                        title: card.title, brief: brief(for: card.detail))
                    MidgarLog.info(
                        "lockscreen: card for \(card.session) (\(card.detail.rawValue))",
                        category: .ui
                    )
                }
            }
        }

        /// `TAILSCODE_LOCKSCREEN=room`: fills the Lock Screen with cards the app follows by itself,
        /// one settled and the rest running, and then asks for one the person sent, so the log
        /// shows which card iOS refused and which one gave way to it.
        @MainActor
        private static func crowd() async {
            let cards = AppActivityController.shared
            for index in 1...5 {
                let session = "room-\(index)"
                cards.start(
                    sessionID: session, sessionTitle: "Followed turn \(index)", serverName: "studio",
                    claim: .followed)
                try? await Task.sleep(for: .milliseconds(700))
                cards.update(
                    sessionID: session,
                    reading: LiveActivityReading(detail: .tool, tool: "Bash", toolCount: index),
                    title: nil, brief: brief(for: .tool))
                if index == 3 {
                    cards.settle(
                        sessionID: session, reading: LiveActivityReading(detail: .finished),
                        title: nil)
                }
            }
            try? await Task.sleep(for: .seconds(1))
            cards.start(sessionID: "room-asked", sessionTitle: "The turn I sent", serverName: "studio")
            try? await Task.sleep(for: .seconds(3))
            cards.start(sessionID: "room-asked-2", sessionTitle: "My second send", serverName: "studio")
            try? await Task.sleep(for: .seconds(3))
            MidgarLog.info("lockscreen: room standing \(cards.standingCount)", category: .ui)
        }
    }
#endif
