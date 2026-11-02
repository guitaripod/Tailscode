import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension MainWindowController {
    /// The questions for later are this Mac's to ask, so the main window asks them: on a
    /// half-minute beat, at once when the list changes, and on launch for anything whose hour
    /// passed while the app was closed. A run that only stages, photographs or checks the app
    /// never asks.
    func startAskingLater() {
        let staged = ["--selftest", "--demo", "--shot", "--shot-live", "--bench", "--open", "--tree"]
        guard !CommandLine.arguments.contains(where: staged.contains) else { return }
        NotificationCenter.default.addObserver(
            forName: QuickAskLaterStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.askDueLater() }
        }
        laterBeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.askDueLater() }
        }
        askDueLater()
    }

    /// Each due question is minted and sent with no pane opened for it; it lands in the chat list
    /// like any other, and the window says it was asked. One that fails is tried again in ten
    /// minutes rather than on every beat.
    func askDueLater() {
        let now = Date()
        for later in QuickAskLaterStore.due(now: now) where !laterInFlight.contains(later.id) {
            laterInFlight.insert(later.id)
            guard
                let profile = ServerDirectory.shared.profiles.first(where: {
                    $0.id == later.profileID
                }), let backend = ServerDirectory.shared.backend(for: profile)
            else {
                laterInFlight.remove(later.id)
                QuickAskLaterStore.postpone(later, by: 600)
                continue
            }
            let password = ServerDirectory.shared.password(for: profile)
            Task { [weak self] in
                let outcome = await QuickAskLaterRunner.ask(
                    later, on: profile, using: backend, password: password)
                guard let self else { return }
                self.laterInFlight.remove(later.id)
                switch outcome {
                case .success:
                    QuickAskLaterStore.asked(later, at: Date())
                    self.toast(Localized.text("Asked for later: %@", later.headline))
                    await self.sidebar.refresh()
                case .failure(let failure):
                    QuickAskLaterStore.postpone(later, by: 600)
                    self.toast("\(failure.title) — \(later.headline)")
                }
            }
        }
    }
}
