import AppKit
import StoreKit
import TailscodeCore

/// The one place the Mac asks for a review — the phone's `ReviewPromptCoordinator`, shape for
/// shape. The policy is Core's (`ReviewPromptPolicy`); this object only carries it out with the
/// platform's own call, debounced behind the success that earned it and checked all over again
/// right before it fires so it never lands on a launch, a background app, or a window with a
/// sheet over it.
@MainActor
final class MacReviewPrompt {
    static let shared = MacReviewPrompt()

    private var pending: Task<Void, Never>?

    func turnCompleted(now: Date = Date()) {
        guard ReviewPromptPolicy.recordSuccess(now: now) else { return }
        scheduleAsk()
    }

    /// Every activation re-checks the pure policy: a success recorded while the app was not the
    /// active one still gets asked about once someone is here to see the sheet.
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
        guard NSApp.isActive else {
            AppLogger.ui.info("review: skipped (not foreground-active)")
            return
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            AppLogger.ui.info("review: skipped (no active window)")
            return
        }
        guard window.attachedSheet == nil else {
            AppLogger.ui.info("review: skipped (blocking UI on screen)")
            return
        }
        guard let host = window.contentViewController else {
            AppLogger.ui.info("review: skipped (no window host)")
            return
        }
        ReviewPromptPolicy.markAsked()
        AppLogger.ui.info("review: asking (#\(ReviewPromptPolicy.askDates.count))")
        AppStore.requestReview(in: host)
    }
}
