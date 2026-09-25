import StoreKit
import TailscodeCore
import UIKit

/// The one place the app asks for a review. The policy — when an ask is due — is Core's
/// (`ReviewPromptPolicy`); this coordinator only carries it out with the platform's own call,
/// debounced behind the success that earned it so the ask lands on the person reading the
/// answer, and checked all over again right before it fires so it never lands on a launch, a
/// background app, or a screen a system prompt has no business interrupting.
@MainActor
final class ReviewPromptCoordinator {
    static let shared = ReviewPromptCoordinator()

    private var pending: Task<Void, Never>?

    func turnCompleted(now: Date = Date()) {
        guard ReviewPromptPolicy.recordSuccess(now: now) else { return }
        scheduleAsk()
    }

    /// Every activation re-checks the pure policy: a success recorded while the app was not in
    /// front still gets asked about once someone is here to see the sheet.
    func appDidBecomeActive() {
        guard ReviewPromptPolicy.isDue() else { return }
        scheduleAsk()
    }

    private func scheduleAsk() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled else { return }
            self.askIfEligible()
        }
    }

    private func askIfEligible() {
        guard ReviewPromptPolicy.isDue() else {
            AppLogger.ui.info("review: skipped (not due)")
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            AppLogger.ui.info("review: skipped (not foreground-active)")
            return
        }
        guard let scene = Self.activeScene else {
            AppLogger.ui.info("review: skipped (no active window scene)")
            return
        }
        guard !Self.blockingUIPresented(in: scene) else {
            AppLogger.ui.info("review: skipped (blocking UI on screen)")
            return
        }
        ReviewPromptPolicy.markAsked()
        AppLogger.ui.info("review: asking (#\(ReviewPromptPolicy.askDates.count))")
        AppStore.requestReview(in: scene)
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    /// A paywall, an alert, a sheet, onboarding's own root — anything that would otherwise take
    /// the store's own prompt on the chin. `present(_:)` bubbles to the window's root controller
    /// by default in this app (nothing sets `definesPresentationContext` above the screens that
    /// need it kept local), so one check at the root answers for the whole window.
    private static func blockingUIPresented(in scene: UIWindowScene) -> Bool {
        guard let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else {
            return true
        }
        return window.rootViewController?.presentedViewController != nil
    }
}
