#if DEBUG
    import UIKit

    /// A touch-free walkthrough of the demo world, so the launch film is a scripted
    /// take that lands identically every run instead of a recording of someone's thumbs.
    ///
    /// The script is one build, start to finish — a feature is requested from the board,
    /// planned, escalated, approved, fanned out to subagents, answered on a second
    /// machine, compacted, and paid for — so every screen it opens is the next thing
    /// that build needs rather than an item on a checklist.
    ///
    /// Timing is written against the mock backend's own pacing: scripted transcripts
    /// repaint instantly, but a *sent* turn streams at human speed, so the sends are
    /// where the camera lingers.
    @MainActor
    final class TourDriver {
        private static var running: TourDriver?

        /// Screens consult this to trade UIKit's fixed-duration scrolls for eased,
        /// distance-aware ones while a take is being shot.
        private(set) static var isFilming = false

        static func start(in window: UIWindow) {
            AppPreferences.autoExpandThinking = true
            isFilming = true
            let driver = TourDriver(window: window)
            running = driver
            Task { await driver.run() }
        }

        private let window: UIWindow

        private init(window: UIWindow) { self.window = window }

        private var nav: UINavigationController? {
            window.rootViewController as? UINavigationController
        }

        private var home: HomeViewController? {
            nav?.viewControllers.first as? HomeViewController
        }

        private var chat: ChatViewController? {
            nav?.topViewController as? ChatViewController
        }

        private var list: SessionListViewController? {
            nav?.viewControllers.compactMap { $0 as? SessionListViewController }.last
        }

        private var presentedNav: UINavigationController? {
            window.rootViewController?.presentedViewController as? UINavigationController
        }

        private var settings: SettingsViewController? {
            presentedNav?.viewControllers.first as? SettingsViewController
        }

        private var modelPicker: ModelPickerViewController? {
            presentedNav?.viewControllers.first as? ModelPickerViewController
        }

        private var subagentList: SubagentListViewController? {
            presentedNav?.viewControllers.first as? SubagentListViewController
        }

        private var topScrollView: UIScrollView? {
            let top = presentedNav?.topViewController ?? nav?.topViewController
            guard let root = top?.view else { return nil }
            return Self.firstScrollView(in: root)
        }

        private static func firstScrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            for child in view.subviews {
                if let found = firstScrollView(in: child) { return found }
            }
            return nil
        }

        private func run() async {
            AppLogger.ui.info("tour: begin")
            await board()
            await oneSentence()
            await watchItWork()
            await escalate()
            await tailnet()
            await approve()
            await subagents()
            await questions()
            await seam()
            await budget()
            AppLogger.ui.info("tour: end")
        }

        /// 0.0–9.5 — the whole fleet on one board, then aim at the project this
        /// feature belongs in.
        private func board() async {
            home?.tourResetBoard(seenAge: 300_000)
            await hold(3.4)
            await glide(home?.tourScrollView, by: 300, duration: 2.4)
            await hold(0.5)
            await glideX(home?.tourProjectsRail, by: 170, duration: 1.5)
            home?.tourAim(serverIndex: 0, directory: "/Users/demo/dev/pulse-server")
            await hold(1.7)
        }

        /// 9.5–20.5 — one sentence typed into the board starts the work, and the next
        /// instruction is queued without waiting for the turn to finish.
        private func oneSentence() async {
            home?.tourFocusComposer()
            await hold(0.9)
            await home?.tourType("Add a retry budget to the sync client", perCharacter: 0.055)
            await hold(1.0)
            home?.tourSendComposer()
            await hold(3.4)
            await chat?.tourType("What breaks if the return type changes?", perCharacter: 0.04)
            chat?.tourSend("What breaks if the return type changes?")
            chat?.tourClearComposer()
            await hold(2.2)
        }

        /// 20.5–28.5 — the turn streaming: reasoning, plan, the suite running.
        private func watchItWork() async {
            await glide(chat?.tourScrollView, by: -300, duration: 2.1)
            await hold(0.6)
            chat?.tourScrollToBottom()
            await hold(3.4)
            await glide(chat?.tourScrollView, by: -240, duration: 1.9)
        }

        /// 28.5–42.0 — the next step is the hard part, so trade up the model, give the
        /// thread a name, and keep it.
        private func escalate() async {
            chat?.tourOpenCommandPalette()
            await hold(1.9)
            chat?.tourRunAppCommand("model")
            await hold(2.4)
            modelPicker?.tourSelect(matching: "claude-opus-4-8")
            await hold(1.3)
            chat?.tourDismissKeyboard()
            await hold(0.7)
            chat?.tourPromptRename(to: "Retry budget for the sync client")
            await hold(2.3)
            chat?.tourConfirmRename(to: "Retry budget for the sync client")
            await hold(1.9)
            chat?.tourToggleSaved()
            await hold(2.4)
            await popToHome(hold: 1.8)
        }

        /// 42.0–49.0 — before letting anything edit, check where it actually runs.
        private func tailnet() async {
            home?.tourOpenSettings()
            await hold(2.2)
            settings?.reveal(section: .tailnet)
            await hold(3.0)
            await dismissPresented()
            await hold(1.4)
        }

        /// 49.0–60.5 — an agent that stopped because it wants to change a file.
        private func approve() async {
            home?.openSession(withID: "demo-c3")
            await hold(2.1)
            await glide(chat?.tourScrollView, by: -430, duration: 1.9)
            await hold(2.6)
            await glide(chat?.tourScrollView, by: 430, duration: 1.5)
            await hold(0.5)
            chat?.tourAllowPermission()
            await hold(2.3)
            await popToHome(hold: 1.8)
        }

        /// 60.5–73.0 — the agents it spawned are rows inside the conversation that
        /// spawned them, reachable from an index that never leaves the thread.
        private func subagents() async {
            home?.openSession(withID: "demo-c2")
            await hold(2.1)
            await glide(chat?.tourScrollView, by: 300, duration: 1.9)
            await hold(0.5)
            chat?.tourPresentSubagents()
            await hold(2.1)
            subagentList?.tourSelect(0)
            await hold(5.0)
            await popToHome(hold: 1.8)
        }

        /// 73.0–85.5 — every conversation on both machines, and the one that is
        /// blocked on an actual question.
        private func questions() async {
            home?.tourPushChats()
            await hold(3.0)
            list?.tourOpen("demo-o2")
            await hold(3.2)
            chat?.tourPickQuestionOption(0)
            await hold(1.1)
            chat?.tourPickQuestionOption(3)
            await hold(1.3)
            chat?.tourSubmitQuestion()
            await hold(2.4)
            nav?.popViewController(animated: true)
            await hold(1.6)
        }

        /// 85.5–97.0 — a thread that outgrew its context days ago, and the summary it
        /// traded that context for.
        private func seam() async {
            list?.tourOpen("demo-c4")
            await hold(2.1)
            chat?.tourScrollToCompaction()
            await hold(3.0)
            chat?.tourOpenCompactionSummary()
            await hold(3.2)
            await dismissPresented()
            await hold(1.3)
            await popToHome(hold: 2.0)
        }

        /// 97.0–105.0 — the last question anyone running agents on three models asks.
        private func budget() async {
            await glide(home?.tourScrollView, to: 4000, duration: 1.5)
            home?.pushUsage()
            await hold(3.2)
            await glide(topScrollView, by: 240, duration: 2.2)
            await hold(3.0)
        }


        private func hold(_ seconds: Double) async {
            try? await Task.sleep(for: .seconds(seconds))
        }

        private func popToHome(hold seconds: Double) async {
            nav?.popToRootViewController(animated: true)
            await hold(seconds)
        }

        private func dismissPresented() async {
            guard let presented = window.rootViewController?.presentedViewController else { return }
            await withCheckedContinuation { continuation in
                presented.dismiss(animated: true) { continuation.resume() }
            }
        }

        private func glide(_ scroll: UIScrollView?, by delta: CGFloat, duration: Double) async {
            guard let scroll else { return }
            await glide(scroll, to: scroll.contentOffset.y + delta, duration: duration)
        }

        /// A camera move, not a flick: a fixed-duration eased slide with no deceleration
        /// tail, so the cut points are exactly where the script says they are.
        private func glide(_ scroll: UIScrollView?, to y: CGFloat, duration: Double) async {
            guard let scroll else { return }
            let top = -scroll.adjustedContentInset.top
            let bottom = max(
                top,
                scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
            )
            let target = min(max(y, top), bottom)
            guard abs(target - scroll.contentOffset.y) > 1 else { return }
            await withCheckedContinuation { continuation in
                UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
                    scroll.contentOffset.y = target
                } completion: { _ in
                    continuation.resume()
                }
            }
        }

        /// The horizontal twin of `glide`, for the orthogonal rails a compositional
        /// layout owns.
        private func glideX(_ scroll: UIScrollView?, by delta: CGFloat, duration: Double) async {
            guard let scroll else { return }
            let left = -scroll.adjustedContentInset.left
            let right = max(
                left,
                scroll.contentSize.width + scroll.adjustedContentInset.right - scroll.bounds.width
            )
            let target = min(max(scroll.contentOffset.x + delta, left), right)
            guard abs(target - scroll.contentOffset.x) > 1 else { return }
            await withCheckedContinuation { continuation in
                UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
                    scroll.contentOffset.x = target
                } completion: { _ in
                    continuation.resume()
                }
            }
        }
    }
#endif
