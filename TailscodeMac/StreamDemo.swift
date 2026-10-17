#if DEBUG
    import AppKit
    import CodingAgentKit
    import TailscodeCore

    /// `TAILSCODE_DRIVE="4000:stream=20"` (or `streamidle=20`: eight seconds of writing, then a turn that
    /// stays open with nothing arriving, the shape of a long tool call) — a turn that keeps running for half a minute on top of the
    /// two scripted ones: a thought, tool calls that start and finish, and prose written into the
    /// answer at about fifty characters a second, handed to the transcript as the states a stream
    /// would emit, twenty a second by default. It is how the cost of a running turn is measured
    /// from outside the process (CPU time over twenty seconds) in the build that has the brain and
    /// the build that has not, with the same words arriving at the same pace.
    @MainActor
    final class StreamDemo {
        static var live: [StreamDemo] = []

        private weak var transcript: TranscriptViewController?
        private let idleAfter: Double?
        private var messages = NeuralDemo.conversation()
        private var assistant: ChatMessage
        private var timer: Timer?
        private var tick = 0
        private let hz: Int
        private let started = Date()
        private static let paragraph =
            "The reconnect path retries with a capped backoff and the jitter stays inside its range, "
            + "so a burst of failures spreads out instead of landing together. "

        static func start(_ transcript: TranscriptViewController?, hz: Int, idleAfter: Double? = nil) {
            guard let transcript else { return }
            let demo = StreamDemo(transcript: transcript, hz: max(1, hz), idleAfter: idleAfter)
            live.append(demo)
            demo.begin()
        }

        private init(transcript: TranscriptViewController, hz: Int, idleAfter: Double?) {
            self.transcript = transcript
            self.hz = hz
            self.idleAfter = idleAfter
            assistant = ChatMessage(
                id: "stream-a", role: .assistant, agentType: .claudeCode,
                parts: [
                    MessagePart(
                        id: "think",
                        kind: .reasoning("Looking at how the reconnect test decides it has failed."))
                ],
                createdAt: Date(), isStreaming: true)
            messages.append(
                ChatMessage(
                    id: "stream-u", role: .user, agentType: .claudeCode,
                    parts: [MessagePart(id: "u", kind: .text("Why is the reconnect test flaky?"))],
                    createdAt: Date().addingTimeInterval(-2)))
        }

        private func begin() {
            push(running: true)
            timer = Timer.scheduledTimer(
                withTimeInterval: 1 / Double(hz), repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.step() }
            }
        }

        private func step() {
            tick += 1
            let seconds = Date().timeIntervalSince(started)
            if let idleAfter, seconds > idleAfter, seconds <= 70 { return }
            if seconds > (idleAfter == nil ? 30 : 70) {
                timer?.invalidate()
                assistant.isStreaming = false
                assistant.completedAt = Date()
                push(running: false)
                return
            }
            let block = Int(seconds / 3)
            let haveBlocks = assistant.parts.filter { $0.id.hasPrefix("text") }.count
            if block >= haveBlocks {
                assistant.parts.append(
                    MessagePart(
                        id: "tool\(block)a",
                        kind: .tool(
                            ToolCall(
                                id: "call-\(block)a", name: "Read", status: .completed,
                                input: .object(["file_path": .string("/src/Reconnect\(block).swift")]),
                                output: "ok"))))
                assistant.parts.append(
                    MessagePart(
                        id: "tool\(block)b",
                        kind: .tool(
                            ToolCall(
                                id: "call-\(block)b", name: "Bash", status: .completed,
                                input: .object(["command": .string("swift test --filter Reconnect\(block)")]),
                                output: "Test Suite passed"))))
                assistant.parts.append(MessagePart(id: "text\(block)", kind: .text("")))
            }
            if let index = assistant.parts.lastIndex(where: { $0.id.hasPrefix("text") }),
                case .text(let words) = assistant.parts[index].kind
            {
                let want = Int((seconds - Double(block * 3)) * 50)
                let source = Self.paragraph + Self.paragraph
                let count = min(source.count, max(words.count, want))
                assistant.parts[index].kind = .text(String(source.prefix(count)))
            }
            push(running: true)
        }

        private func push(running: Bool) {
            var all = messages
            all.append(assistant)
            let state = ConversationState(
                messages: all, status: running ? .running : .idle, connection: .live,
                hasLoadedTranscript: true)
            transcript?.show(state: state)
        }
    }
#endif
