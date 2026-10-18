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
            case settled, working, thinking, writing, waiting, approval, question, failed, stopped,
                offline, compacting, large, largeRunning
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
                view()?.hoverStep(value.isEmpty ? nil : step(Int(value) ?? 1, in: store))
            case "pin":
                if let id = step(Int(value) ?? 1, in: store) { view()?.browse(.click(id, double: false), grabFocus: true) }
            case "clear":
                view()?.hoverStep(nil)
                view()?.stage?.setProvenance(nil)
                view()?.browse(.key(.escape), grabFocus: false)
            case "chip":
                let chips = view()?.footer?.chips.chips ?? []
                let index = (Int(value) ?? 1) - 1
                view()?.stage?.setProvenance(chips.indices.contains(index) ? chips[index].token : nil)
            case "dive":
                guard let zone = zone(named: value), let stage = stage() else { break }
                stage.dive(into: zone)
                stage.completeDive()
            case "surface":
                stage()?.surface()
                stage()?.completeDive()
            case "replay":
                view()?.toggleReplay()
            case "stopreplay":
                if store.model(store.openTurnID ?? "")?.isReplaying == true { view()?.toggleReplay() }
            case "scrub":
                view()?.scrub(to: Double(value) ?? 0.5)
            case "theme":
                ThemeSelection.setThemeID(value)
                MacTheme.Chrome.apply()
            case "appearance":
                ThemeSelection.setAppearance(ThemeAppearance(rawValue: value) ?? .system)
                MacTheme.Chrome.apply()
            case "style":
                ActivityStyleSetting.set(value == "lines" ? .lines : .brain)
            case "sidebar":
                main.driveSetSidebar(shown: value != "hide")
            case "density":
                ChatDensitySetting.set(value == "compact" ? .compact : .comfortable)
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
                focus(value, main: main)
            case "key":
                return press(value, main: main)
            case "search":
                view()?.browse(.searchText(value), grabFocus: false)
            case "zonechip":
                if let zone = zone(named: value) { view()?.browse(.zoneChip(zone, solo: false), grabFocus: false) }
            case "failed":
                view()?.browse(.failedToggle, grabFocus: false)
            case "legend":
                view()?.browse(.key(.character("?")), grabFocus: false)
            case "menu":
                if let id = step(Int(value) ?? 1, in: store) { view()?.browse(.contextMenu(id), grabFocus: false) }
            case "ask":
                view()?.browse(.key(.character("a")), grabFocus: false)
            case "said":
                view()?.browse(.key(.character("s")), grabFocus: false)
            case "acct":
                return BrainAccountDrive.perform(value)
            case "listhover":
                let digits = value.filter(\.isNumber)
                view()?.list?.driveHover(
                    digits.isEmpty ? nil : step(Int(digits) ?? 1, in: store), copy: value.hasSuffix("copy"))
            case "listscroll":
                view()?.list?.driveScroll(to: CGFloat(Double(value) ?? 0))
            case "copied":
                if let id = step(Int(value) ?? 1, in: store) { view()?.list?.flashCopied(id, seconds: 120) }
            case "moveat":
                moveAt(value, store: store)
            case "moveend":
                for id in store.order {
                    guard let row = store.view(forTurn: id), let held = row.mover else { continue }
                    row.finishMove(snapOpen: held.isOpening)
                }
            case "settle":
                for card in BrainRowView.live { card.card.forceSettleStart() }
            case "snap":
                LiveShot.snap(to: value)
            case "sharepanel":
                view()?.presentShare()
            case "share":
                share(to: value, store: store, transcript: transcript)
                return "BRAIN share \(value) started"
            case "stream":
                return stream(Int(value) ?? 60, transcript: transcript)
            case "checks":
                do {
                    return "BRAIN checks passed \(try BrainViewChecks.run())"
                } catch {
                    return "BRAIN checks FAILED \(error)"
                }
            case "report":
                return report(store)
            default:
                return "BRAIN unknown verb \(verb)"
            }
            return report(store)
        }

        /// Streams `count` tokens into the running turn's trailing note, each through the whole
        /// transcript pipeline the way a state arrives, and says what one token cost on the main
        /// thread: the median and the worst, in milliseconds.
        private static func stream(_ count: Int, transcript: TranscriptViewController) -> String {
            guard var state = transcript.currentState,
                var index = state.messages.indices.last(where: { state.messages[$0].role == .assistant })
            else { return "BRAIN stream no turn" }
            var message = state.messages[index]
            let noteID = "stream-note"
            if !message.parts.contains(where: { $0.id == noteID }) {
                message.parts.append(MessagePart(id: noteID, kind: .text("Streaming")))
            }
            var costs: [Double] = []
            for step in 0..<count {
                if let at = message.parts.firstIndex(where: { $0.id == noteID }),
                    case .text(let words) = message.parts[at].kind
                {
                    message.parts[at].kind = .text(words + " token\(step)")
                }
                index = state.messages.indices.last(where: { state.messages[$0].role == .assistant }) ?? index
                state.messages[index] = message
                let begun = CACurrentMediaTime()
                transcript.show(state: state)
                RunLoop.current.run(until: Date())
                costs.append((CACurrentMediaTime() - begun) * 1000)
            }
            let sorted = costs.sorted()
            return String(
                format: "BRAIN stream tokens=%d median=%.2fms worst=%.2fms", count,
                sorted[sorted.count / 2], sorted.last ?? 0)
        }

        /// Holds a move at one frame, with no clock: `moveat=open:0.4` stands the newest card 40
        /// percent of the way to open, `close:0.4` the open brain 40 percent of the way back,
        /// `openrev:0.5:0.3` an opening turned round at its half and now 30 percent into the way
        /// back, `swap:0.4` the open older brain closing as the newest opens.
        private static func moveAt(_ value: String, store: BrainStore) {
            let pieces = value.split(separator: ":").map(String.init)
            guard pieces.count >= 2 else { return }
            let kind = pieces[0]
            let numbers = pieces.dropFirst().compactMap { Double($0) }
            guard let u = numbers.last else { return }
            let newest = store.order.last
            switch kind {
            case "open":
                newest.flatMap { store.view(forTurn: $0) }?.holdMove(direction: .open, at: u)
            case "close":
                (store.openTurnID ?? newest).flatMap { store.view(forTurn: $0) }?.holdMove(
                    direction: .close, at: u)
            case "openrev":
                guard numbers.count == 2 else { return }
                newest.flatMap { store.view(forTurn: $0) }?.holdMove(
                    direction: .open, at: u, reversedFrom: numbers[0])
            case "swap":
                guard let open = store.openTurnID, let new = newest, open != new else { return }
                store.view(forTurn: open)?.holdMove(direction: .swapClose, at: u)
                store.view(forTurn: new)?.holdMove(direction: .swap, at: u)
            default:
                break
            }
        }

        private static func focus(_ value: String, main: MainWindowController) {
            guard let row = view(), let window = main.window else { return }
            switch value {
            case "list": window.makeFirstResponder(row.list)
            case "account": window.makeFirstResponder(row.account)
            default: window.makeFirstResponder(row.stage)
            }
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
            case .working, .thinking, .writing, .waiting, .approval, .question, .largeRunning: live = true
            default: live = false
            }
            var messages =
                NeuralDemo.buildFix(prefix: "a-", origin: 1_792_000_000)
                + NeuralDemo.turn(
                    prefix: "b-", origin: 1_792_003_600,
                    answer: scenario == .settled || scenario == .writing)
            if scenario == .large || scenario == .largeRunning {
                messages =
                    NeuralDemo.buildFix(prefix: "a-", origin: 1_792_000_000)
                    + NeuralDemo.largeTurn(
                        steps: 174, prefix: "b-", origin: 1_792_003_600,
                        answer: scenario == .large)
            }
            var state = ConversationState(
                messages: messages, status: live ? .running : .idle, connection: .live,
                hasLoadedTranscript: true)
            switch scenario {
            case .settled, .offline, .compacting, .writing, .thinking, .large:
                break
            case .approval:
                markLastTool(&messages, .running)
                commandLastTool(&messages, "swift build -c release 2>&1 | tail -20")
                state.pendingPermissions = [
                    PermissionRequest(id: "perm", sessionID: "demo", title: nil, toolName: "Bash")
                ]
            case .working, .largeRunning:
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

        /// Makes the last tool call a shell command, so an approval has a command to show.
        private static func commandLastTool(_ messages: inout [ChatMessage], _ command: String) {
            for index in messages.indices.reversed() where messages[index].role == .assistant {
                for part in messages[index].parts.indices.reversed() {
                    guard case .tool(var call) = messages[index].parts[part].kind else { continue }
                    call.name = "Bash"
                    call.input = .object(["command": .string(command)])
                    messages[index].parts[part].kind = .tool(call)
                    return
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
            "esc": (53, "\u{1B}"), "up": (126, "\u{F700}"), "down": (125, "\u{F701}"),
            "space": (49, " "), "tab": (48, "\t"), "pagedown": (121, "\u{F72D}"),
            "pageup": (116, "\u{F72C}"), "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"),
        ]

        private static func press(_ name: String, main: MainWindowController) -> String {
            let literal: (code: UInt16, characters: String)? =
                name.count == 1 ? (0, name) : nil
            guard let key = keys[name] ?? literal, let window = main.window,
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
            let card = store.order.last.flatMap { store.view(forTurn: $0) }
            let cardReading = card?.card.reading
            let list = open?.browseState.list
            var parts: [String] = []
            parts.append("BRAIN active=\(store.isActive) turns=\(store.order.count) open=\(store.openTurnID ?? "-")")
            parts.append("state=\(open?.state.label ?? "-") nodes=\(open?.nodeCount ?? 0)")
            parts.append("hover=\(open?.browseState.hovered ?? "-") cursor=\(open?.pinnedStep ?? "-")")
            parts.append("filter=[\(list.map { "\($0.visibleCount)/\($0.total)" } ?? "-")]")
            parts.append("card=[\(cardReading?.headline ?? "-") chips=\(cardReading?.chips ?? 0) live=\(cardReading?.hasLive ?? false)]")
            parts.append("phase=\(row.map { String(describing: $0.phase) } ?? "-") height=\(row.map { Int($0.frame.height) } ?? 0)")
            parts.append("footer=\(row?.footer?.shown.map { String(describing: $0) }.joined(separator: ",") ?? "-")")
            parts.append("leader=\(row?.leader.stepID ?? "-") dived=\(stage?.divedZone.map { $0.label } ?? "-")")
            if let card {
                let layer = card.picture.container
                parts.append("picture=[img:\(card.picture.hasImage) rendered:\(BrainPictures.rendered) pos:\(layer.position) bounds:\(layer.bounds.size) hidden:\(layer.isHidden) opacity:\(layer.opacity) tr:\(card.carrier.layer?.sublayerTransform.m11 ?? 0),\(card.carrier.layer?.sublayerTransform.m41 ?? 0) sub:\(card.carrier.layer?.sublayers?.count ?? 0)]")
            }
            parts.append("list=[\(row?.list?.reading ?? "-")]")
            parts.append("textures=\(NeuralMetalContext.shared?.retainCount ?? 0)")
            parts.append("head=[ready:\(stage?.head.isReady ?? false) suspended:\(stage?.head.isSuspended ?? false) window:\(stage?.head.window != nil) clock:\(stage?.head.isClockRunning ?? false) gate:\(DisplayGate.allows(stage))]")
            parts.append("move=[gap:\(row.map { String(format: "%.1f", $0.maxFrameGap * 1000) } ?? "-")ms runs:\(row?.movesRun ?? 0)]")
            parts.append("tempo=\(open.map { String(describing: $0.tempo) } ?? "-")")
            return parts.joined(separator: " ")
        }
    }
#endif
