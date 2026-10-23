import AppKit
import os
import CodingAgentKit
import TailscodeCore

#if DEBUG
    extension TranscriptViewController {
        /// `advance=<ms>` — a turn that keeps running while its tools advance, fed to the transcript as
        /// the states a stream would emit, so what the page does at each one can be measured: the
        /// scroll origin, the bottom inset and the height of the page at every display tick and at every
        /// change, written to `TAILSCODE_PROBE` when the run is over.
        func driveAdvance(every milliseconds: Int) {
            let driver = AdvanceDriver(transcript: self, interval: Double(milliseconds) / 1000)
            driver.start()
            advanceDrivers.append(driver)
        }

        func emitProbe(_ state: ConversationState) {
            apply(state: state, rows: buildRows(state.messages, state: state))
        }

        var probeSnapshot: (clip: CGFloat, inset: CGFloat, page: CGFloat, last: CGFloat, glass: CGFloat) {
            (
                scrollView.contentView.bounds.origin.y, scrollView.contentInsets.bottom,
                canvas.frame.height,
                rowViews.last.map { $0.convert($0.bounds, to: nil).minY } ?? -1,
                composerGlass?.frame.height ?? -1
            )
        }

        var probeClip: NSClipView { scrollView.contentView }
        var probeCanvas: NSView { canvas }
    }

    @MainActor
    private var advanceDrivers: [AdvanceDriver] {
        get { AdvanceDriver.live }
        set { AdvanceDriver.live = newValue }
    }

    @MainActor
    final class AdvanceDriver: NSObject {
        static var live: [AdvanceDriver] = []
        private weak var transcript: TranscriptViewController?
        private let interval: Double
        private var parts: [MessagePart] = []
        private var counter = 0
        private var step = 0
        private var timer: Timer?
        private let probe: LayoutProbe
        private let user = ChatMessage(
            id: "probe-u", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "u", kind: .text("Find why the guest image is zeroed."))],
            createdAt: Date().addingTimeInterval(-600))

        init(transcript: TranscriptViewController, interval: Double) {
            self.transcript = transcript
            self.interval = interval
            self.probe = LayoutProbe(transcript: transcript)
        }

        private func work() {
            parts.append(
                MessagePart(id: "r\(counter)", kind: .reasoning("Reading the next place to look \(counter).")))
            parts.append(
                MessagePart(
                    id: "t\(counter)",
                    kind: .tool(
                        ToolCall(
                            id: "tool\(counter)", name: "Bash", status: .completed,
                            input: .object(["command": .string("gdb -batch -ex 'info registers' \(counter)")]),
                            output: "ok", title: "gdb \(counter)"))))
            counter += 1
        }

        private func emit() {
            let assistant = ChatMessage(
                id: "probe-a", role: .assistant, agentType: .claudeCode, parts: parts,
                createdAt: Date().addingTimeInterval(-590), isStreaming: true)
            transcript?.emitProbe(
                ConversationState(
                    messages: [user, assistant], status: .running, connection: .live,
                    hasLoadedTranscript: true))
        }

        func start() {
            for block in 0..<16 {
                parts.append(
                    MessagePart(
                        id: "p\(block)",
                        kind: .text(
                            "The process died at the same fault. Let me look at every reference to that region \(block).")))
                for _ in 0..<(2 + block % 3) { work() }
            }
            probe.start()
            emit()
            timer = Timer.scheduledTimer(
                timeInterval: interval, target: self, selector: #selector(advance), userInfo: nil,
                repeats: true)
        }

        @objc private func advance() {
            step += 1
            work()
            emit()
            guard step >= 10 else { return }
            timer?.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [probe] in probe.finish() }
        }
    }

    @MainActor
    final class LayoutProbe: NSObject {
        private weak var transcript: TranscriptViewController?
        private var lines: [String] = []
        private var link: CADisplayLink?
        private let started = ContinuousClock.now
        private var observers: [NSObjectProtocol] = []

        init(transcript: TranscriptViewController) {
            self.transcript = transcript
        }

        private func stamp(_ kind: String) {
            guard let transcript else { return }
            let now = ContinuousClock.now - started
            let milliseconds =
                Double(now.components.seconds) * 1000 + Double(now.components.attoseconds) / 1e15
            let s = transcript.probeSnapshot
            lines.append(
                String(
                    format: "%9.2f %-7@ clip=%8.2f inset=%6.1f page=%8.1f last=%8.1f glass=%6.1f",
                    milliseconds, kind as NSString, s.clip, s.inset, s.page, s.last, s.glass))
        }

        func start() {
            guard let transcript else { return }
            transcript.probeClip.postsBoundsChangedNotifications = true
            transcript.probeCanvas.postsFrameChangedNotifications = true
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: transcript.probeClip,
                    queue: .main
                ) { [weak self] _ in MainThread.call { self?.stamp("bounds") } })
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: transcript.probeCanvas,
                    queue: .main
                ) { [weak self] _ in MainThread.call { self?.stamp("canvas") } })
            let link = transcript.view.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func tick() { stamp("tick") }

        func finish() {
            link?.invalidate()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            guard let path = ProcessInfo.processInfo.environment["TAILSCODE_PROBE"] else { return }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
#endif
