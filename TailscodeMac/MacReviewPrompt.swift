import AppKit
import StoreKit
import TailscodeCore

/// The one place the Mac asks for a review — the phone's `ReviewPromptCoordinator`, shape for
/// shape. The policy is Core's (`ReviewPromptPolicy`); this object only carries it out with the
/// platform's own call, debouncing each trigger so the ask lands on the person reading the
/// answer rather than on the frame it arrived, or the frame the app came back to the front.
@MainActor
final class MacReviewPrompt {
    static let shared = MacReviewPrompt()

    private var pending: Task<Void, Never>?
    private var finishedWhileAway = false

    func turnCompleted() {
        schedule(after: .seconds(5)) { ReviewPromptPolicy.recordSuccessfulTurn() }
    }

    func trophyEarned() {
        pending?.cancel()
        askIfDue { ReviewPromptPolicy.noteTrophyEarned() }
    }

    /// A turn reached its end while the app was not active: the return, not this moment, is
    /// the one worth asking on.
    func turnFinishedWhileAway() {
        finishedWhileAway = true
    }

    /// Called on every activation; only one that follows a turn finished while away asks.
    func returnedToFinishedWork() {
        guard finishedWhileAway else { return }
        finishedWhileAway = false
        schedule(after: .seconds(3)) { ReviewPromptPolicy.noteReturnedToFinishedWork() }
    }

    private func schedule(after delay: Duration, _ evaluation: @escaping @MainActor () -> Bool) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.askIfDue(evaluation)
        }
    }

    private func askIfDue(_ evaluation: () -> Bool) {
        guard evaluation() else { return }
        guard let host = NSApp.keyWindow?.contentViewController ?? NSApp.mainWindow?.contentViewController
        else { return }
        ReviewPromptPolicy.markAsked()
        AppStore.requestReview(in: host)
    }
}
