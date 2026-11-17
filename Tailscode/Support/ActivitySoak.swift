import AgentTestSupport
import CodingAgentKit
import Foundation
import MidgarCore
import TailscodeCore

#if DEBUG
    /// `TAILSCODE_ACTIVITY_SOAK=<ms>[,<sessions>]` keeps the demo fleet busy without a server: every
    /// `<ms>` one conversation the listing holds starts or stops a turn, round the list in order,
    /// and the live tick a running turn posts arrives every two seconds between them, so a screen
    /// that reads activity is watched under the churn a few agents at work make. `<sessions>` pads
    /// the demo servers' listings to that many conversations first, the size a fleet that has been
    /// used for months lists. Each change is written to the `performance` log, so the stall lines
    /// around it say what it cost.
    @MainActor
    enum ActivitySoak {
        static func runIfRequested() {
            guard let value = ProcessInfo.processInfo.environment["TAILSCODE_ACTIVITY_SOAK"] else {
                return
            }
            let parts = value.split(separator: ",").compactMap { Int($0) }
            guard let pace = parts.first, pace > 0 else { return }
            let padding = parts.count > 1 ? parts[1] : 0
            Task { await run(pace: .milliseconds(pace), padding: padding) }
        }

        private static func run(pace: Duration, padding: Int) async {
            let backends = DemoWorld.profiles.compactMap { DemoWorld.backend(for: $0.id) as? MockBackend }
            guard !backends.isEmpty else { return }
            if padding > 0 {
                await pad(backends, to: padding)
                NotificationCenter.default.post(name: ConnectionController.didChange, object: nil)
            }
            try? await Task.sleep(for: .seconds(4))
            var ids: [String] = []
            for backend in backends {
                ids += ((try? await backend.listSessions()) ?? []).prefix(6).map(\.id)
            }
            guard !ids.isEmpty else { return }
            MidgarLog.info("activity soak sessions=\(ids.count) pace=\(pace)", category: .performance)
            var turn = 0
            var lastTick = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: pace)
                let id = ids[turn % ids.count]
                turn += 1
                SessionActivity.shared.soakFlip(id)
                if ContinuousClock.now - lastTick > .seconds(2) {
                    lastTick = .now
                    SessionActivity.shared.soakTick()
                }
            }
        }

        private static func pad(_ backends: [MockBackend], to total: Int) async {
            let per = max(0, total / backends.count)
            for backend in backends {
                let held = ((try? await backend.listSessions()) ?? []).count
                guard held < per else { continue }
                for index in held..<per {
                    _ = try? await backend.createSession(
                        title: "Soak conversation \(index)", directory: "/Users/demo/dev/soak-\(index % 9)")
                }
            }
        }
    }
#endif
