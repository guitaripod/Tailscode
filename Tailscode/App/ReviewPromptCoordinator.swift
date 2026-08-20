import StoreKit
import TailscodeCore
import UIKit

/// The one place the app asks for a review. The policy — when an ask is due — is Core's
/// (`ReviewPromptPolicy`); this coordinator only carries it out with the platform's own call,
/// debouncing the turn trigger so the ask lands on the person reading the answer rather than on
/// the frame the answer arrived.
@MainActor
final class ReviewPromptCoordinator {
    static let shared = ReviewPromptCoordinator()

    private var turnTask: Task<Void, Never>?

    func turnCompleted() {
        turnTask?.cancel()
        turnTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            self.askIfDue { ReviewPromptPolicy.recordSuccessfulTurn() }
        }
    }

    func trophyEarned() {
        turnTask?.cancel()
        askIfDue { ReviewPromptPolicy.noteTrophyEarned() }
    }

    private func askIfDue(_ evaluation: () -> Bool) {
        guard evaluation() else { return }
        ReviewPromptPolicy.markAsked()
        AppLogger.ui.info("review: asking")
        SKStoreReviewController.requestReview()
    }
}
