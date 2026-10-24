import AppKit
import MidgarCore
import StoreKit
import TailscodeCore

/// The one place the Mac asks for a review — the phone's `ReviewPromptCoordinator`, shape for
/// shape. The policy is Core's (`ReviewPromptPolicy`); this object only carries it out with the
/// platform's own call, debounced behind the success that earned it and checked all over again
/// right before it fires so it never lands on a launch, a window with a sheet over it, or the
/// purchase window itself — the app's one window, so a sheet on it is the only "blocking UI"
/// a key check can see, and the Pro window is a second window rather than a sheet.
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
        #if DEBUG
            guard !LiveShot.holdsBack("review prompt") else { return }
        #endif
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
            MidgarLog.info("review: skipped (not due)", category: .ui)
            return
        }
        guard NSApp.isActive else {
            MidgarLog.info("review: skipped (not foreground-active)", category: .ui)
            return
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            MidgarLog.info("review: skipped (no active window)", category: .ui)
            return
        }
        guard window.attachedSheet == nil else {
            MidgarLog.info("review: skipped (blocking UI on screen)", category: .ui)
            return
        }
        guard !(window.windowController is ProWindowController) else {
            MidgarLog.info("review: skipped (purchase window on screen)", category: .ui)
            return
        }
        guard let host = window.contentViewController else {
            MidgarLog.info("review: skipped (no window host)", category: .ui)
            return
        }
        ReviewPromptPolicy.markAsked()
        MidgarLog.info("review: asking (#\(ReviewPromptPolicy.askDates.count))", category: .ui)
        AppStore.requestReview(in: host)
    }
}
