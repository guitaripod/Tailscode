import AgentTestSupport
import CodingAgentKit
import Foundation
import TailscodeCore
import UIKit

#if DEBUG
    /// `TAILSCODE_BENCH_OPEN=<turns>x<cycles>` pushes a conversation of that many turns onto the
    /// phone's stack and pops it again, `cycles` times, through the same navigation controller a
    /// finger uses, and writes what each trip cost the main thread to the `performance` log: the
    /// longest single run-loop turn and the sum of the turns longer than a frame between the push
    /// and the moment the chat appeared, the same two figures for the second after it settled and
    /// for the pop, what the pop gesture recogniser said at rest, and how many of the chat's views
    /// were still alive a moment after it left. Any survivor ends the run with
    /// `CHAT_LIFETIME_FAIL`, which is the check that a popped chat is really released.
    ///
    /// `TAILSCODE_BENCH_SCENARIO` stages a state before the pop (`keyboard` focuses the composer,
    /// `stream` leaves a turn running) and `TAILSCODE_BENCH_SWIPE=1` waits for a real edge swipe
    /// sent from outside instead of popping by call.
    @MainActor
    final class ChatOpenBench {
        private static var running: ChatOpenBench?

        static func runIfRequested(in window: UIWindow) {
            guard let value = ProcessInfo.processInfo.environment["TAILSCODE_BENCH_OPEN"] else {
                return
            }
            let parts = value.split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return }
            let bench = ChatOpenBench(window: window, turns: parts[0], cycles: parts[1])
            running = bench
            Task { await bench.run() }
        }

        private let window: UIWindow
        private let turns: Int
        private let cycles: Int
        private var observer: CFRunLoopObserver?
        private var turnStart: CFAbsoluteTime = 0
        private var longest = 0.0
        private var slowTotal = 0.0
        private var slowCount = 0

        private struct WeakView {
            weak var view: UIView?
            let name: String
        }

        private func census(of root: UIView) -> [WeakView] {
            var found: [WeakView] = []
            var pending = [root]
            while let next = pending.popLast() {
                found.append(WeakView(view: next, name: String(describing: type(of: next))))
                pending.append(contentsOf: next.subviews)
            }
            return found
        }

        private func survivors(of census: [WeakView], chat: WeakChat) -> String {
            let alive = census.filter { $0.view != nil }
            var byName: [String: Int] = [:]
            for item in alive { byName[item.name, default: 0] += 1 }
            let top = byName.sorted { $0.value > $1.value }.prefix(6)
                .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            return "controller=\(chat.value == nil ? "freed" : "ALIVE") views=\(alive.count)/\(census.count) \(top)"
        }

        private struct WeakChat {
            weak var value: ChatViewController?
        }

        private init(window: UIWindow, turns: Int, cycles: Int) {
            self.window = window
            self.turns = turns
            self.cycles = cycles
        }

        private var stack: UINavigationController? {
            (window.rootViewController as? WorkspaceSplitViewController)?.tourStack
        }

        private func run() async {
            try? await Task.sleep(for: .seconds(4))
            guard let stack else {
                AppLogger.performance.info("bench open: no stack")
                return
            }
            watchRunLoop()
            let script = Self.script(turns: turns)
            let session = AgentSession(
                id: "bench-open", agentType: .claudeCode, title: "Bench long conversation",
                directory: "/Users/demo/dev/bench", createdAt: Date(), updatedAt: Date(),
                model: "claude-fable-5")
            let backend = MockBackend(
                agentType: .claudeCode, scripts: [session.id: script], sessions: [session])
            var leakedViews = 0
            for cycle in 1...cycles {
                let trip = await trip(cycle: cycle, backend: backend, session: session, in: stack)
                try? await Task.sleep(for: .seconds(1.5))
                let left = survivors(of: trip.tree, chat: trip.chat)
                leakedViews = max(leakedViews, trip.tree.filter { $0.view != nil }.count)
                AppLogger.performance.info("bench open cycle=\(cycle) turns=\(turns) \(trip.report) afterPop[\(left)] footprintMB=\(footprintMegabytes())")
                try? await Task.sleep(for: .seconds(1))
            }
            AppLogger.performance.info(
                leakedViews == 0
                    ? "CHAT_LIFETIME_OK every popped chat released its views"
                    : "CHAT_LIFETIME_FAIL a popped chat left \(leakedViews) views alive")
            AppLogger.performance.info("bench open done turns=\(turns) cycles=\(cycles)")
        }

        private struct Trip {
            let report: String
            let tree: [WeakView]
            let chat: WeakChat
        }

        private func trip(
            cycle: Int, backend: MockBackend, session: AgentSession, in stack: UINavigationController
        ) async -> Trip {
            let model = ChatViewModel(
                backend: backend, session: session, contextID: DemoWorld.claudeProfile.id,
                serverName: "bench")
            let chat = ChatViewController(viewModel: model)
            reset()
            stack.pushViewController(chat, animated: true)
            await untilAppeared(chat, in: stack)
            let pushed = snapshot()
            reset()
            try? await Task.sleep(for: .seconds(2))
            let settled = snapshot()
            let tree = census(of: chat.view)
            await stage(scenario: ProcessInfo.processInfo.environment["TAILSCODE_BENCH_SCENARIO"], chat: chat, tree: tree)
            let rootAddress = String(describing: Unmanaged.passUnretained(chat.view).toOpaque())
            let collection = tree.compactMap { $0.view as? UICollectionView }.first
            let collectionAddress = collection.map {
                String(describing: Unmanaged.passUnretained($0).toOpaque())
            }
            AppLogger.performance.info(
                "bench addresses cycle=\(cycle) root=\(rootAddress) collection=\(collectionAddress ?? "-")")
            let gesture = popGestureReading(of: stack)
            reset()
            let swiped = await awaitSwipe(cycle: cycle, chat: chat, in: stack)
            if stack.topViewController === chat {
                stack.popViewController(animated: true)
                await untilGone(chat, in: stack)
            }
            let popped = snapshot()
            return Trip(
                report:
                    "push[\(pushed)] settled[\(settled)] pop[\(popped)] gesture[\(gesture)] swipe[\(swiped)]",
                tree: tree, chat: WeakChat(value: chat))
        }

        private func watchRunLoop() {
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                true, 3_000_000
            ) { [weak self] _, activity in
                MainActor.assumeIsolated { self?.noteTurn(activity) }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
        }

        private func noteTurn(_ activity: CFRunLoopActivity) {
            let now = CFAbsoluteTimeGetCurrent()
            if activity == .afterWaiting {
                turnStart = now
                return
            }
            guard turnStart > 0 else { return }
            let elapsed = (now - turnStart) * 1000
            turnStart = 0
            longest = max(longest, elapsed)
            if elapsed > 17 {
                slowTotal += elapsed
                slowCount += 1
            }
        }

        private func footprintMegabytes() -> Int {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
        }

        private func reset() {
            longest = 0
            slowTotal = 0
            slowCount = 0
        }

        private func snapshot() -> String {
            "longest=\(Int(longest))ms slowTurns=\(slowCount) slowTotal=\(Int(slowTotal))ms"
        }

        private func stage(scenario: String?, chat: ChatViewController, tree: [WeakView]) async {
            switch scenario {
            case "keyboard":
                let field = tree.compactMap { $0.view as? UITextView }.last
                field?.becomeFirstResponder()
                try? await Task.sleep(for: .seconds(1))
            default:
                break
            }
        }

        private func awaitSwipe(
            cycle: Int, chat: ChatViewController, in stack: UINavigationController
        ) async -> String {
            guard ProcessInfo.processInfo.environment["TAILSCODE_BENCH_SWIPE"] != nil else {
                return "off"
            }
            AppLogger.performance.info("bench swipe wait cycle=\(cycle)")
            let started = CFAbsoluteTimeGetCurrent()
            for _ in 0..<600 {
                try? await Task.sleep(for: .milliseconds(10))
                if stack.topViewController !== chat, stack.transitionCoordinator == nil {
                    return "popped after \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000))ms"
                }
            }
            return "stayed"
        }

        private func untilAppeared(_ chat: ChatViewController, in stack: UINavigationController) async {
            for _ in 0..<400 {
                try? await Task.sleep(for: .milliseconds(10))
                if stack.topViewController === chat, stack.transitionCoordinator == nil,
                    chat.isViewLoaded, chat.view.window != nil
                {
                    return
                }
            }
        }

        private func untilGone(_ chat: ChatViewController, in stack: UINavigationController) async {
            for _ in 0..<400 {
                try? await Task.sleep(for: .milliseconds(10))
                if stack.topViewController !== chat, stack.transitionCoordinator == nil { return }
            }
        }

        private func popGestureReading(of stack: UINavigationController) -> String {
            guard let pop = stack.interactivePopGestureRecognizer else { return "none" }
            let begins = pop.delegate?.gestureRecognizerShouldBegin?(pop) ?? true
            return
                "enabled=\(pop.isEnabled) state=\(pop.state.rawValue) shouldBegin=\(begins) depth=\(stack.viewControllers.count) transition=\(stack.transitionCoordinator != nil)"
        }

        private static func script(turns: Int) -> [MockScriptStep] {
            let messages = ChatRebuildBench.conversation(turns: turns, growing: "Done.")
            let steps = messages.map {
                MockScriptStep(.messageUpserted($0, replaceParts: true), delay: .milliseconds(0))
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_BENCH_SCENARIO"] == "stream" {
                return steps + [
                    MockScriptStep(.status(.running), delay: .milliseconds(0)),
                    MockScriptStep(.status(.running), delay: .seconds(600)),
                ]
            }
            return steps + [MockScriptStep(.status(.idle), delay: .milliseconds(0))]
        }
    }
#endif
