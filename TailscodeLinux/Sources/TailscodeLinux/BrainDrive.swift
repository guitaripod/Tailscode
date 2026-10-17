import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// Hooks for looking at the brain without a server: a scripted conversation, a turn that streams
/// in a loop, and a verb for each thing a person can do to a head. Every verb prints one line the
/// harness reads back, because a screenshot cannot tell a clock that stopped from one that never
/// ran.
extension MainWindow {
    /// `TAILSCODE_DRIVE="2000:brain=demo;3000:brain=hover=4;4000:brain=pin=4"`. The argument after
    /// `brain=` is one of: `demo[=build|turn|both|running|failed|waiting|stopped]`, `live[=seconds]`,
    /// `open|close|toggle[=turn]`, `state=<activity>`, `theme=<id>[,light|dark]`,
    /// `style=brain|lines`, `replay`, `stop`, `scrub=<0..1>`, `hover=<step>`, `pin=<step>`,
    /// `clear`, `esc`, `walk=next|previous`, `dive=<zone>`, `surface`, `chip=<n>`, `rows`,
    /// `reduce=on|off`, `reading`, `perf`, `double=<step>`.
    func driveBrain(_ argument: String) {
        let pane = activePane
        let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
        let verb = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""
        let host = pane.brains
        let write = { (line: String) in FileHandle.standardOutput.write(Data("BRAIN \(line)\n".utf8)) }
        switch verb {
        case "demo":
            pane.driverBrainDemo(value)
        case "live":
            pane.driverBrainLive(seconds: Double(value) ?? 120)
        case "livestop":
            pane.driverBrainLiveStop()
        case "style":
            Preferences.setActivityStyle(ActivityStyle(rawValue: value) ?? .brain)
        case "theme":
            let words = value.split(separator: ",").map(String.init)
            Preferences.setTheme(AppTheme.named(words.first))
            Preferences.setAppearance(words.dropFirst().first == "light" ? .light : .dark)
            Preferences.applyAppearance()
            MatrixTheme.install()
            splitHost.eachPane { $0.retheme() }
        case "state":
            host.force(activity: Self.brainActivity(value))
        case "reduce":
            tailscode_set_animations_enabled(value == "on" ? 0 : 1)
            tailscode_notify_animations()
        case "open", "close", "toggle":
            guard let turn = pane.brainTurn(value) else { break }
            switch verb {
            case "open": host.setOpen(true, turnID: turn)
            case "close": host.setOpen(false, turnID: turn)
            default: host.toggleOpen(turnID: turn)
            }
        case "rows":
            if let turn = pane.brainTurn(value) { host.toggleRows(turnID: turn) }
        case "reading", "perf":
            break
        default:
            guard let view = pane.brainView(value: verb == "hover" || verb == "pin" ? "" : value) else {
                write("none")
                return
            }
            driveBrainView(view, verb: verb, value: value)
        }
        let views = host.liveViews.sorted { $0.turnID < $1.turnID }
        write(host.reading)
        for view in views { write(view.reading) }
        if verb == "perf" {
            for view in views { write("perf \(view.performance)") }
            write(
                "compositors=\(BrainCompositors.resident.compositors) holders=\(BrainCompositors.resident.holders) "
                    + "bytes=\(BrainCompositors.footprint) store=\(NeuralAssetStore.shared.residentBytes) "
                    + "ticks=\(tailscode_live_ticks()) rss=\(Self.residentKilobytes)")
        }
    }

    private func driveBrainView(_ view: BrainView, verb: String, value: String) {
        let steps = view.model.steps
        func step(_ text: String) -> String? {
            guard let number = Int(text), number >= 1, number <= steps.count else { return nil }
            return view.model.layout.representative(of: steps[number - 1].id)
        }
        switch verb {
        case "hover":
            view.hover(step(value))
        case "pin":
            if let id = step(value) { view.pin(id) }
        case "clear":
            view.clearSelection()
        case "esc":
            view.escape()
        case "walk":
            view.walkStep(value == "previous" ? -1 : 1)
        case "focus":
            view.focusStage()
        case "replay":
            if !view.model.isReplaying { view.toggleReplay() }
        case "stop":
            if view.model.isReplaying { view.toggleReplay() }
        case "scrub":
            view.scrub(to: Double(value) ?? 0.5)
        case "endscrub":
            view.endScrub()
        case "dive":
            view.dive(NeuralZone.allCases.first { String(describing: $0) == value })
        case "surface":
            view.dive(nil)
        case "chip":
            view.driveChip(Int(value))
        case "double":
            if let id = step(value) { view.openSubagent(of: id) }
        default:
            break
        }
    }

    static func brainActivity(_ name: String) -> ActivityKind? {
        switch name {
        case "working": return .working
        case "thinking": return .thinking
        case "writing": return .writing
        case "read", "sense": return .usingTool(name: "Read", kind: .fileRead)
        case "edit", "act": return .usingTool(name: "Edit", kind: .fileEdit)
        case "shell", "bash": return .usingTool(name: "Bash", kind: .shell)
        case "delegating": return .delegating(active: 2)
        case "background": return .inBackground(tasks: 1)
        case "stalled": return .stalled(tasks: 1)
        case "retrying": return .retrying(attempt: 2)
        case "compacting": return .compacting
        case "approval": return .needsApproval
        case "question": return .needsAnswer
        case "queued": return .queued(2)
        case "connecting": return .connecting
        case "reconnecting": return .reconnecting
        case "failed": return .failed
        case "offline": return .offline
        default: return nil
        }
    }

    static var residentKilobytes: Int {
        guard let text = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else { return 0 }
        let fields = text.split(separator: " ")
        guard fields.count > 1, let pages = Int(fields[1]) else { return 0 }
        return pages * 4
    }
}

extension ChatPane {
    func brainTurn(_ value: String) -> String? {
        let ids = brains.turnIDs
        if let number = Int(value), number >= 0, number < ids.count { return ids[number] }
        return ids.last
    }

    func brainView(value: String) -> BrainView? {
        if let turn = brainTurn(value) { return brains.view(forTurn: turn) }
        return brains.liveViews.first
    }

    /// A conversation of scripted turns with no server behind it: the two the design was drawn from,
    /// or one of them in a state a turn can be in.
    func driverBrainDemo(_ kind: String) {
        driverBrainLiveStop()
        detachStreamForScript()
        brains.sessionKey = "demo"
        brains.choices = [:]
        brains.rowsShown = []
        brains.force(activity: nil)
        syncBrainSettings()
        let now = Date()
        let origin = now.timeIntervalSince1970 - 3_600
        var messages: [ChatMessage]
        var state = ConversationState(status: .idle, connection: .live, hasLoadedTranscript: true)
        switch kind {
        case "build":
            messages = NeuralDemo.buildFix(prefix: "a-", origin: origin)
        case "turn":
            messages = NeuralDemo.turn(prefix: "b-", origin: origin)
        case "running":
            messages = NeuralDemo.turn(prefix: "b-", origin: now.timeIntervalSince1970 - 300, answer: false)
            Self.makeStreaming(&messages)
            state.status = .running
        case "failed":
            messages = NeuralDemo.buildFix(prefix: "a-", origin: origin, answer: false)
            if var last = messages.popLast() {
                last.error = "API Error: 529 overloaded"
                messages.append(last)
            }
        case "stopped":
            messages = NeuralDemo.buildFix(prefix: "a-", origin: origin, answer: false)
            if var last = messages.popLast() {
                last.finishReason = "aborted"
                messages.append(last)
            }
        case "waiting":
            messages = NeuralDemo.buildFix(prefix: "a-", origin: now.timeIntervalSince1970 - 240, answer: false)
            Self.makeWaiting(&messages)
            state.status = .running
            state.pendingPermissions = [PermissionRequest(id: "call-wait", sessionID: "demo", toolName: "Bash")]
        default:
            messages = NeuralDemo.conversation()
        }
        state.messages = messages
        apply(state: state, rows: rowBuilder.rows(state: state))
    }

    private static func makeStreaming(_ messages: inout [ChatMessage]) {
        guard var last = messages.popLast() else { return }
        last.isStreaming = true
        last.completedAt = nil
        messages.append(last)
    }

    private static func makeWaiting(_ messages: inout [ChatMessage]) {
        guard var last = messages.popLast() else { return }
        last.isStreaming = true
        last.completedAt = nil
        let waiting = MessagePart(
            id: "wait",
            kind: .tool(
                ToolCall(
                    id: "call-wait", name: "Bash", status: .running,
                    input: .object(["command": .string("swift build -c release 2>&1 | tail -20")]))))
        last.parts.append(waiting)
        messages.append(last)
    }

    /// A turn that is written the way a server writes one: a message at a time, tools and thoughts
    /// arriving one after another, the answer a few characters at a time, then the turn settling and
    /// the whole thing starting over, for as long as it is asked to. It is the stream a brain is
    /// measured against.
    func driverBrainLive(seconds: Double) {
        driverBrainLiveStop()
        detachStreamForScript()
        brains.sessionKey = "live"
        brains.choices = [:]
        brains.rowsShown = []
        brains.force(activity: nil)
        syncBrainSettings()
        liveDemoTicket += 1
        let ticket = liveDemoTicket
        liveDemoDeadline = Date().addingTimeInterval(seconds)
        stepLiveDemo(ticket: ticket, round: 0, shown: 1, characters: 0)
    }

    func driverBrainLiveStop() {
        liveDemoTicket += 1
    }

    private func stepLiveDemo(ticket: Int, round: Int, shown: Int, characters: Int) {
        guard liveDemoTicket == ticket, Date() < liveDemoDeadline else { return }
        let now = Date().timeIntervalSince1970
        let script = NeuralDemo.turn(prefix: "r\(round)-", origin: now - 300)
        let assistants = Array(script.dropFirst())
        let toolMessages = assistants.count - 1
        var delay: UInt32 = 1100
        var next = (round, shown + 1, 0)
        var messages: [ChatMessage]
        var state = ConversationState(status: .running, connection: .live, hasLoadedTranscript: true)
        if shown <= toolMessages {
            messages = Array(assistants.prefix(shown))
            if var last = messages.popLast() {
                last.isStreaming = true
                last.completedAt = nil
                messages.append(last)
            }
        } else {
            messages = Array(assistants.prefix(toolMessages))
            var answer = assistants[toolMessages]
            let full = answer.parts.compactMap { part -> String? in
                if case .text(let text) = part.kind { return text }
                return nil
            }.joined(separator: " ")
            let count = min(full.count, characters + 6)
            answer.parts = [MessagePart(id: "p0", kind: .text(String(full.prefix(count))))]
            answer.isStreaming = count < full.count
            if answer.isStreaming { answer.completedAt = nil }
            messages.append(answer)
            if count < full.count {
                delay = 70
                next = (round, shown, count)
            } else {
                state.status = .idle
                delay = 4000
                next = (round + 1, 1, 0)
            }
        }
        state.messages = [script[0]] + messages
        brainSettingsChanged(demo: state)
        let (nextRound, nextShown, nextCharacters) = next
        Gtk.after(delay) { [weak self] in
            Gtk.onMain { [weak self] in
                self?.stepLiveDemo(
                    ticket: ticket, round: nextRound, shown: nextShown, characters: nextCharacters)
            }
        }
    }

    /// Applies a scripted state the way a stream's would be: through the row builder, then the pane.
    private func brainSettingsChanged(demo state: ConversationState) {
        apply(state: state, rows: rowBuilder.rows(state: state))
    }
}
