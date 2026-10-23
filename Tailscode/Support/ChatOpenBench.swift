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
        private var turnCPU: UInt64 = 0
        private var longestCPU = 0.0
        private var cpuTotal = 0.0
        private var bigTurns: [Int] = []
        private var longest = 0.0
        private var slowTotal = 0.0
        private var slowCount = 0
        private var busyTotal = 0.0
        private var windowStart = CFAbsoluteTimeGetCurrent()

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

        private func chromeCensus(of root: UIView) -> String {
            var views = 0
            var constraints = 0
            var byName: [String: Int] = [:]
            var pending = [root]
            while let next = pending.popLast() {
                views += 1
                constraints += next.constraints.count
                byName[String(describing: type(of: next)), default: 0] += 1
                if next is UICollectionView {
                    pending.append(contentsOf: next.subviews.filter { !($0 is UICollectionViewCell) })
                } else {
                    pending.append(contentsOf: next.subviews)
                }
            }
            let top = byName.sorted { $0.value > $1.value }.prefix(10)
                .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            return "views=\(views) constraints=\(constraints) \(top)"
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
            if ProcessInfo.processInfo.environment["TAILSCODE_BENCH_SCENARIO"] == "plainpush" {
                let root = UIViewController()
                root.view.backgroundColor = .systemBackground
                root.title = "Root"
                let plain = UINavigationController(rootViewController: root)
                plain.navigationBar.prefersLargeTitles = true
                window.rootViewController?.present(plain, animated: false)
                try? await Task.sleep(for: .seconds(1))
                for cycle in 1...cycles {
                    let empty = UIViewController()
                    empty.view.backgroundColor = .systemBackground
                    empty.title = "Pushed"
                    reset()
                    plain.pushViewController(empty, animated: true)
                    try? await Task.sleep(for: .seconds(1))
                    AppLogger.performance.info("bench plainpush cycle=\(cycle) \(snapshot())")
                    plain.popViewController(animated: false)
                    try? await Task.sleep(for: .seconds(0.5))
                }
                AppLogger.performance.info("bench open done turns=\(turns) cycles=\(cycles)")
                return
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_BENCH_SCENARIO"] == "emptypush" {
                for cycle in 1...cycles {
                    let empty = UIViewController()
                    empty.view.backgroundColor = .systemBackground
                    reset()
                    stack.pushViewController(empty, animated: true)
                    try? await Task.sleep(for: .seconds(1))
                    AppLogger.performance.info("bench emptypush cycle=\(cycle) \(snapshot())")
                    stack.popViewController(animated: false)
                    try? await Task.sleep(for: .seconds(0.5))
                }
                AppLogger.performance.info("bench open done turns=\(turns) cycles=\(cycles)")
                return
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_BENCH_SCENARIO"] == "double" {
                await doublePush(backend: backend, session: session, in: stack)
                AppLogger.performance.info("bench open done turns=\(turns) cycles=\(cycles)")
                return
            }
            let rest = ProcessInfo.processInfo.environment["TAILSCODE_BENCH_REST"].flatMap(Double.init) ?? 1
            for cycle in 1...cycles {
                let trip = await trip(cycle: cycle, backend: backend, session: session, in: stack)
                try? await Task.sleep(for: .seconds(1.5 * rest))
                let left = survivors(of: trip.tree, chat: trip.chat)
                leakedViews = max(leakedViews, trip.tree.filter { $0.view != nil }.count)
                AppLogger.performance.info("bench open cycle=\(cycle) turns=\(turns) \(trip.report) afterPop[\(left)] footprintMB=\(footprintMegabytes())")
                try? await Task.sleep(for: .seconds(rest))
            }
            let beforeWarning = footprintMegabytes()
            NotificationCenter.default.post(
                name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
            try? await Task.sleep(for: .seconds(0.5))
            AppLogger.performance.info(
                "bench memorywarning footprintMB before=\(beforeWarning) after=\(footprintMegabytes())")
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

        private func doublePush(
            backend: MockBackend, session: AgentSession, in stack: UINavigationController
        ) async {
            let base = stack.viewControllers.count
            AppLogger.performance.info("bench double start depth=\(base)")
            let other = AgentSession(
                id: "bench-other", agentType: .claudeCode, title: "Bench other conversation",
                directory: "/Users/demo/dev/bench", createdAt: Date(), updatedAt: Date(),
                model: "claude-fable-5")
            let third = AgentSession(
                id: "bench-third", agentType: .claudeCode, title: "Bench third conversation",
                directory: "/Users/demo/dev/bench", createdAt: Date(), updatedAt: Date(),
                model: "claude-fable-5")
            let both = MockBackend(
                agentType: .claudeCode,
                scripts: [
                    session.id: Self.script(turns: turns), other.id: Self.script(turns: 4),
                    third.id: Self.script(turns: 4),
                ],
                sessions: [session, other, third])
            let make = { (target: AgentSession) in
                ChatViewController(
                    viewModel: ChatViewModel(
                        backend: both, session: target, contextID: DemoWorld.claudeProfile.id,
                        serverName: "bench"))
            }
            let unguarded = ProcessInfo.processInfo.environment["TAILSCODE_BENCH_NOGUARD"] != nil
            let push = { (chat: ChatViewController) in
                if unguarded {
                    stack.pushViewController(chat, animated: true)
                } else {
                    ChatNavigator.shared.push(chat, on: stack, animated: true)
                }
            }

            push(make(session))
            try? await Task.sleep(for: .milliseconds(80))
            push(make(session))
            try? await Task.sleep(for: .seconds(2.5))
            report("same chat twice", expect: base + 1, stack: stack)

            if ProcessInfo.processInfo.environment["TAILSCODE_BENCH_ROTATE"] != nil {
                push(make(other))
                try? await Task.sleep(for: .milliseconds(120))
                turn(to: .landscapeRight)
                try? await Task.sleep(for: .seconds(2.5))
                report("a rotation during the push", expect: base + 2, stack: stack)
                turn(to: .portrait)
                try? await Task.sleep(for: .seconds(1.5))
                stack.popViewController(animated: false)
            }

            push(make(other))
            try? await Task.sleep(for: .milliseconds(80))
            push(make(session))
            try? await Task.sleep(for: .seconds(2.5))
            report("another chat during the push", expect: base + 3, stack: stack)

            stack.popViewController(animated: true)
            try? await Task.sleep(for: .milliseconds(80))
            push(make(third))
            try? await Task.sleep(for: .seconds(2.5))
            report("a push during a pop", expect: base + 3, stack: stack)

            AppLogger.performance.info("bench swipe wait cycle=1")
            let started = CFAbsoluteTimeGetCurrent()
            let depth = stack.viewControllers.count
            for _ in 0..<500 {
                try? await Task.sleep(for: .milliseconds(10))
                if stack.viewControllers.count < depth, stack.transitionCoordinator == nil { break }
            }
            AppLogger.performance.info(
                "bench double swipe depth=\(depth)->\(stack.viewControllers.count) after \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000))ms gesture[\(popGestureReading(of: stack))]"
            )
            stack.popToRootViewController(animated: false)
        }

        private func turn(to mask: UIInterfaceOrientationMask) {
            window.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                AppLogger.performance.info("bench rotate refused \(error)")
            }
        }

        private func report(_ name: String, expect depth: Int, stack: UINavigationController) {
            let got = stack.viewControllers.count
            AppLogger.performance.info(
                "\(got == depth ? "NAV_GUARD_OK" : "NAV_GUARD_FAIL") \(name) depth=\(got) expected=\(depth) gesture[\(popGestureReading(of: stack))] transition=\(stack.transitionCoordinator != nil)"
            )
        }

        private func trip(
            cycle: Int, backend: MockBackend, session: AgentSession, in stack: UINavigationController
        ) async -> Trip {
            let model = ChatViewModel(
                backend: backend, session: session, contextID: DemoWorld.claudeProfile.id,
                serverName: "bench")
            let chat = ChatViewController(viewModel: model)
            reset()
            ChatNavigator.shared.push(chat, on: stack, animated: true)
            await untilOpened(chat)
            let opened = snapshot()
            await untilAppeared(chat, in: stack)
            let pushed = snapshot()
            AppLogger.performance.info(
                "bench cells provided=\(chat.providedItems.count) items=\(chat.providedItems.prefix(40).map(String.init).joined(separator: ","))")
            reset()
            let settle = ProcessInfo.processInfo.environment["TAILSCODE_BENCH_SETTLE"].flatMap(Double.init) ?? 2
            try? await Task.sleep(for: .seconds(settle))
            let settled = snapshot()
            let tree = census(of: chat.view)
            AppLogger.performance.info("bench chrome \(chromeCensus(of: chat.view))")
            let endGap = tree.compactMap { $0.view as? UICollectionView }.first.map {
                Int($0.contentSize.height + $0.adjustedContentInset.bottom - $0.bounds.height - $0.contentOffset.y)
            }
            AppLogger.performance.info("bench end gap=\(endGap.map(String.init) ?? "-")pt")
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
            var brainViews: [String: Int] = [:]
            for item in tree where item.name.contains("Brain") || item.name.contains("Neural") {
                brainViews[item.name, default: 0] += 1
            }
            let heads = brainViews.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            return Trip(
                report:
                    "open[\(opened)] push[\(pushed)] settled[\(settled)] pop[\(popped)] gesture[\(gesture)] swipe[\(swiped)] brain[\(heads)]",
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
                turnCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                return
            }
            guard turnStart > 0 else { return }
            let elapsed = (now - turnStart) * 1000
            let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - turnCPU) / 1_000_000
            if cpu > 6 { bigTurns.append(Int(cpu)) }
            longestCPU = max(longestCPU, cpu)
            cpuTotal += cpu
            turnStart = 0
            longest = max(longest, elapsed)
            busyTotal += elapsed
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
            busyTotal = 0
            windowStart = CFAbsoluteTimeGetCurrent()
            longest = 0
            longestCPU = 0
            cpuTotal = 0
            bigTurns = []
            slowTotal = 0
            slowCount = 0
        }

        private func snapshot() -> String {
            "fits=\(TextBubbleCell.fitCount) verified=\(TextBubbleCell.verifiedFits) cpuLongest=\(Int(longestCPU))ms cpuTotal=\(Int(cpuTotal))ms turns>6ms=\(bigTurns.map(String.init).joined(separator: "/")) longest=\(Int(longest))ms slowTurns=\(slowCount) slowTotal=\(Int(slowTotal))ms busy=\(Int(busyTotal))/\(Int((CFAbsoluteTimeGetCurrent() - windowStart) * 1000))ms window=\(Int((CFAbsoluteTimeGetCurrent() - windowStart) * 1000))ms"
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

        private func untilOpened(_ chat: ChatViewController) async {
            for _ in 0..<600 {
                try? await Task.sleep(for: .milliseconds(5))
                if chat.isOpenedForBench { return }
            }
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

        /// An answer of that many words in paragraphs of forty, the way a model writes one, so a
        /// streamed token is measured against a row the size of a paragraph and not against one
        /// ever-growing block of text.
        private static func answer(words: Int) -> String {
            var paragraphs: [String] = []
            var remaining = words
            while remaining > 0 {
                let take = min(remaining, 40)
                paragraphs.append(String(repeating: "streaming word ", count: take))
                remaining -= take
            }
            return paragraphs.joined(separator: "\n\n")
        }

        private static func script(turns: Int) -> [MockScriptStep] {
            let messages = ChatRebuildBench.conversation(turns: turns, growing: "Done.")
            let steps = messages.map {
                MockScriptStep(.messageUpserted($0, replaceParts: true), delay: .milliseconds(0))
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_BENCH_SCENARIO"] == "tokens",
                let last = messages.last
            {
                var growing = steps
                for index in 1...300 {
                    var grown = last
                    grown.parts = [
                        MessagePart(id: "a", kind: .text(Self.answer(words: index)))
                    ]
                    growing.append(
                        MockScriptStep(
                            .messageUpserted(grown, replaceParts: true), delay: .milliseconds(30)))
                }
                return growing + [MockScriptStep(.status(.idle), delay: .milliseconds(0))]
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
