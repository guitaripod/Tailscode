#if DEBUG
    import AppKit
    import CodingAgentKit
    import TailscodeCore

    /// `TAILSCODE_DRIVE="2000:brain=demo;4000:brain=state=working;6000:brain=hover=7"` — the brain's
    /// verbs on a timer from launch, so a head can be put in any state and looked at without a
    /// server that would write the right conversation.
    ///
    /// - `demo` shows the two scripted turns the design was drawn from, settled, in the pane
    /// - `state=<settled|working|thinking|writing|waiting|question|failed|stopped|offline|compacting>`
    ///   shows the newer turn in that state, with the state the pane would be in for it
    /// - `open[=<turn>]`, `close`, `rows` open and close the newest brain (or the n-th), list its old rows
    /// - `hover=<n>`, `pin=<n>`, `clear` act on the open head's n-th node; `chip=<n>` points at the
    ///   n-th answer word
    /// - `dive=<zone>` dives at once into plan, sense, act, shell, delegate or say; `surface` comes out
    /// - `replay`, `stopreplay`, `scrub=<0…1>` drive the replay
    /// - `theme=<id>`, `appearance=<dark|light|system>`, `style=<brain|lines>` change how it is drawn
    /// - `dismiss` closes the first-run checklist and any other window over the chat
    /// - `park`, `unpark` park the pane; `key=<left|right|return|esc>` sends that key to the head
    /// - `share=<path>` paints the poster to a PNG; `report` prints what the head holds
    @MainActor
    enum BrainDrive {
        enum Scenario: String, CaseIterable {
            case settled, working, thinking, writing, waiting, question, failed, stopped, offline,
                compacting
        }

        private static func say(_ line: String) {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }

        static func perform(_ argument: String, main: MainWindowController?) -> String {
            guard let main else { return "BRAIN no window" }
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let verb = parts.first ?? ""
            let value = parts.count > 1 ? parts[1] : ""
            let transcript = main.transcript
            let store = transcript.brains
            switch verb {
            case "demo":
                show(.settled, in: transcript)
            case "state":
                guard let scenario = Scenario(rawValue: value) else {
                    return "BRAIN unknown state \(value)"
                }
                show(scenario, in: transcript)
            case "open":
                guard let id = turn(value, in: store), !store.isOpen(id) else { break }
                store.toggleOpen(id)
            case "close":
                guard let id = store.openTurnID else { break }
                store.toggleOpen(id)
            case "rows":
                guard let id = turn(value, in: store) else { break }
                store.toggleRows(id)
            case "hover":
                stage()?.setHover(step(Int(value) ?? 1, in: store))
            case "pin":
                if let id = step(Int(value) ?? 1, in: store) { stage()?.togglePin(id) }
            case "clear":
                stage()?.clearSelection()
                stage()?.setProvenance(nil)
            case "chip":
                let chips = view()?.chipViews ?? []
                let index = (Int(value) ?? 1) - 1
                stage()?.setProvenance(chips.indices.contains(index) ? chips[index].token : nil)
            case "dive":
                guard let zone = zone(named: value), let stage = stage() else { break }
                stage.dive(into: zone)
                stage.completeDive()
            case "surface":
                stage()?.surface()
                stage()?.completeDive()
            case "replay":
                view()?.replayButton.onTap?()
            case "stopreplay":
                view()?.playButton.onTap?()
            case "scrub":
                if let row = view() { row.scrubberView.onScrub?(Double(value) ?? 0.5) }
            case "theme":
                ThemeSelection.setThemeID(value)
                MacTheme.Chrome.apply()
            case "appearance":
                ThemeSelection.setAppearance(ThemeAppearance(rawValue: value) ?? .system)
                MacTheme.Chrome.apply()
            case "style":
                ActivityStyleSetting.set(value == "lines" ? .lines : .brain)
            case "dismiss":
                for window in NSApp.windows
                where window.isVisible && !(window.windowController is MainWindowController)
                    && window.styleMask.contains(.titled)
                {
                    window.close()
                }
            case "park":
                transcript.setParked(true)
            case "unpark":
                transcript.setParked(false)
            case "focus":
                if let stage = stage() { main.window?.makeFirstResponder(stage) }
            case "key":
                return press(value, main: main)
            case "share":
                share(to: value, store: store, transcript: transcript)
                return "BRAIN share \(value) started"
            case "report":
                return report(store)
            default:
                return "BRAIN unknown verb \(verb)"
            }
            return report(store)
        }

        private static func view() -> BrainRowView? {
            BrainRowView.live.first { $0.isOpenShown && $0.window != nil }
        }

        private static func stage() -> BrainStageView? { view()?.stage }

        private static func turn(_ value: String, in store: BrainStore) -> String? {
            if let number = Int(value), store.order.indices.contains(number - 1) {
                return store.order[number - 1]
            }
            return store.order.last
        }

        private static func step(_ number: Int, in store: BrainStore) -> String? {
            guard let id = store.openTurnID, let model = store.model(id),
                model.steps.indices.contains(number - 1)
            else { return nil }
            return model.steps[number - 1].id
        }

        private static func zone(named name: String) -> NeuralZone? {
            switch name.lowercased() {
            case "plan", "think": return .think
            case "sense": return .sense
            case "act": return .act
            case "shell": return .shell
            case "delegate": return .delegate
            case "say": return .say
            default: return nil
            }
        }

        /// The two scripted turns with the newer one in a state, as the pane would hold them: a turn
        /// still running has no answer and a tool still out, a waiting one has the approval pending.
        static func show(_ scenario: Scenario, in transcript: TranscriptViewController) {
            let live: Bool
            switch scenario {
            case .working, .thinking, .writing, .waiting, .question: live = true
            default: live = false
            }
            var messages =
                NeuralDemo.buildFix(prefix: "a-", origin: 1_792_000_000)
                + NeuralDemo.turn(
                    prefix: "b-", origin: 1_792_003_600,
                    answer: scenario == .settled || scenario == .writing)
            var state = ConversationState(
                messages: messages, status: live ? .running : .idle, connection: .live,
                hasLoadedTranscript: true)
            switch scenario {
            case .settled, .offline, .compacting, .writing, .thinking:
                break
            case .working:
                markLastTool(&messages, .running)
            case .waiting:
                markLastTool(&messages, .running)
                state.pendingPermissions = [
                    PermissionRequest(id: "perm", sessionID: "demo", title: nil, toolName: nil)
                ]
            case .question:
                markLastTool(&messages, .running)
                state.pendingQuestions = [
                    QuestionRequest(
                        id: "ask", sessionID: "demo",
                        questions: [
                            QuestionRequest.Item(
                                question: "Keep the 4K master?", header: "Master",
                                options: [
                                    .init(label: "Keep", description: ""),
                                    .init(label: "Drop", description: ""),
                                ])
                        ])
                ]
            case .failed:
                markLastTool(&messages, .error)
                if let index = messages.lastIndex(where: { $0.role == .assistant }) {
                    messages[index].error = "ssh macbook timed out after 30 s."
                }
            case .stopped:
                markLastTool(&messages, .stopped)
                if let index = messages.lastIndex(where: { $0.role == .assistant }) {
                    messages[index].finishReason = "abort"
                }
            }
            if scenario == .thinking, let index = messages.lastIndex(where: { $0.role == .assistant }) {
                messages[index].parts.append(
                    MessagePart(
                        id: "think-live",
                        kind: .reasoning("Checking whether the mux step needs the audio offset.")))
                messages[index].isStreaming = true
                messages[index].completedAt = nil
            }
            if live, scenario != .thinking, let index = messages.lastIndex(where: { $0.role == .assistant }) {
                messages[index].isStreaming = true
                messages[index].completedAt = nil
            }
            if live { Self.rebase(&messages, endingAt: Date()) }
            state.messages = messages
            if scenario == .offline { state.connection = .offline }
            if scenario == .compacting {
                state.compaction = CompactionActivity(startedAt: Date().addingTimeInterval(-9))
            }
            transcript.show(state: state)
        }

        /// Moves the last turn's clock so a running scenario started minutes ago, not days.
        private static func rebase(_ messages: inout [ChatMessage], endingAt now: Date) {
            guard let start = messages.lastIndex(where: { $0.role == .user }),
                let last = messages.last?.createdAt
            else { return }
            let shift = now.timeIntervalSince(last) - 40
            for index in start..<messages.count {
                messages[index].createdAt = messages[index].createdAt.addingTimeInterval(shift)
                if let done = messages[index].completedAt {
                    messages[index].completedAt = done.addingTimeInterval(shift)
                }
            }
        }

        private static func markLastTool(_ messages: inout [ChatMessage], _ status: ToolStatus) {
            for index in messages.indices.reversed() where messages[index].role == .assistant {
                for part in messages[index].parts.indices.reversed() {
                    guard case .tool(var call) = messages[index].parts[part].kind else { continue }
                    call.status = status
                    if status == .running || status == .pending { call.output = nil }
                    messages[index].parts[part].kind = .tool(call)
                    return
                }
            }
        }

        private static let keys: [String: (code: UInt16, characters: String)] = [
            "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "return": (36, "\r"),
            "esc": (53, "\u{1B}"),
        ]

        private static func press(_ name: String, main: MainWindowController) -> String {
            guard let key = keys[name], let window = main.window,
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: key.characters,
                    charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code)
            else { return "BRAIN key \(name) not sent" }
            NSApp.sendEvent(event)
            return "BRAIN key \(name) sent to \(String(describing: window.firstResponder))"
        }

        private static func share(
            to path: String, store: BrainStore, transcript: TranscriptViewController
        ) {
            guard let id = store.openTurnID ?? store.order.last else { return }
            let context = transcript.driveContext
            let dark = NSApp.effectiveAppearance.isDark
            let style = ThemeSelection.usesSystemPalette ? CardStyle.neural : CardStyle.app
            Task { @MainActor in
                let poster = await BrainPoster.render(
                    store: store, context: context, turnID: id, style: style, dark: dark, scale: 1)
                guard let poster else {
                    say("BRAIN share failed")
                    return
                }
                try? poster.data.write(to: URL(fileURLWithPath: path))
                say("BRAIN share wrote \(path) \(poster.data.count) bytes")
            }
        }

        static func report(_ store: BrainStore) -> String {
            let open = store.openTurnID.flatMap { store.model($0) }
            let row = view()
            let stage = row?.stage
            return
                "BRAIN active=\(store.isActive) turns=\(store.order.count) open=\(store.openTurnID ?? "-") "
                + "state=\(open?.state.label ?? "-") nodes=\(open?.nodeCount ?? 0) "
                + "hover=\(open?.hovered ?? "-") pin=\(open?.pinned ?? "-") "
                + "line=[\(row?.linePieces.count ?? "") \(row?.linePieces.detail ?? "")] "
                + "ticker=[\(row?.tickerText ?? "-")] scrub=\(row?.scrubberShown ?? false) "
                + "dived=\(stage?.divedZone.map { $0.label } ?? "-") card=\(stage?.cardReading?.title ?? "-") "
                + "textures=\(NeuralMetalContext.shared?.retainCount ?? 0) "
                + "head=[ready:\(stage?.head.isReady ?? false) suspended:\(stage?.head.isSuspended ?? false) "
                + "window:\(stage?.head.window != nil) resident:\(NeuralMetalContext.shared?.isResident ?? false) "
                + "active:\(NSApp.isActive) visible:\(stage?.window?.occlusionState.contains(.visible) ?? false) "
                + "gate:\(DisplayGate.allows(stage)) frame:\(stage.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "-")] "
                + "tempo=\(open.map { String(describing: $0.tempo) } ?? "-")"
        }
    }
#endif
