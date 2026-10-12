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

        @MainActor
        static func startIfAsked() {
            guard ProcessInfo.processInfo.environment["TAILSCODE_LOCKSCREEN"] != nil else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                for card in cards {
                    AppActivityController.shared.start(
                        sessionID: card.session, sessionTitle: card.title, serverName: card.server)
                    try? await Task.sleep(for: .milliseconds(700))
                    AppActivityController.shared.update(
                        sessionID: card.session,
                        reading: LiveActivityReading(
                            detail: card.detail, tool: card.tool, toolCount: card.toolCount),
                        title: card.title)
                    AppLogger.ui.info("lockscreen: card for \(card.session) (\(card.detail.rawValue))")
                }
            }
        }
    }
#endif
