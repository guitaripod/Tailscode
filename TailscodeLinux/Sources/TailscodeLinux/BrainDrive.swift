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
    /// `reduce=on|off`, `reading`, `perf`, `double=<step>`, `card` (closes the turn to its card),
    /// `unpin`, `readout=digest|now|zone=<zone>`, `transition=<0..1>[,close]` (freezes the move at
    /// a progress for a picture; `transition=release` lets it land), `anim[=slow]` (runs the move at
    /// full or a quarter of its speed), `width=<points>` (resizes the window until the brain's row
    /// is that wide), `text` (the words the readout says), `demo=cards` (every kind of card),
    /// `share[=dark|light][,app|neural]` (writes the poster's PNG to `TAILSCODE_BRAIN_SHARE_OUT`, a file
    /// or a folder, or to the harness data directory), `shareopen` (the sheet itself).
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
        case "open", "close", "toggle", "card":
            guard let turn = pane.brainTurn(value) else { break }
            switch verb {
            case "open": host.setOpen(true, turnID: turn)
            case "close", "card": host.setOpen(false, turnID: turn)
            default: host.toggleOpen(turnID: turn)
            }
        case "anim":
            BrainMove.timeScale = value == "slow" ? 4 : 1
            guard let turn = pane.brainTurn("") else { break }
            host.toggleOpen(turnID: turn)
        case "width":
            driveWidth(Double(value) ?? 700, pane: pane)
        case "height":
            driveHeight(Double(value) ?? 900)
        case "settletest":
            pane.driverBrainSettle(value)
        case "settlearm":
            BrainCard.armedSettleFreeze = Double(value).map { $0 / 1000 }
        case "settlefreeze":
            let held = Double(value)
            for view in host.liveViews { view.card.freezeSettle(held.map { $0 / 1000 }) }
        case "quote":
            let held = Double(value) ?? 60
            for view in host.liveViews {
                view.card.live.quoteArrivedAt = Date().addingTimeInterval(held - NeuralLiveCard.quoteHold)
            }
        case "debug":
            if value.hasPrefix("-") { BrainStage.debugSkip.remove(String(value.dropFirst())) } else { BrainStage.debugSkip.insert(value) }
            for view in host.liveViews {
                guard let stage = view.stage else { continue }
                let all = BrainStage.debugSkip.contains("layers")
                gtk_widget_set_opacity(stage.interior, all || BrainStage.debugSkip.contains("hide-interior") ? 0 : 1)
                gtk_widget_set_opacity(stage.front, all || BrainStage.debugSkip.contains("hide-front") ? 0 : 1)
                gtk_widget_set_opacity(stage.merged, all || BrainStage.debugSkip.contains("hide-merged") ? 0 : 1)
                gtk_widget_set_opacity(stage.nodes, all || BrainStage.debugSkip.contains("hide-nodes") ? 0 : 1)
            }
        case "lagprobe":
            driveLagProbe(seconds: Double(value) ?? 5)
        case "scrollbench":
            driveScrollBench(seconds: Double(value) ?? 4, pane: pane)
        case "rows":
            if let turn = pane.brainTurn(value) { host.toggleRows(turnID: turn) }
        case "reading", "perf", "text", "dump":
            break
        default:
            guard let view = pane.brainView(value: Self.browseVerbs.contains(verb) ? "" : value) else {
                write("none")
                return
            }
            driveBrainView(view, verb: verb, value: value)
        }
        let views = host.liveViews.sorted { $0.turnID < $1.turnID }
        write(host.reading + " anchor=\(pane.heldAnchorKey ?? "-")")
        for view in views { write(view.reading) }
        if verb == "dump" {
            for view in views { write("dump \(view.turnID): \(view.readout?.overflowReading ?? "-")") }
        }
        if verb == "dump" {
            for view in views { write("adump \(view.turnID): \(view.account?.overflowReading() ?? "-")") }
        }
        if verb == "text" {
            for view in views { write("atext \(view.turnID): \(view.account?.visibleText.replacingOccurrences(of: "\n", with: " | ") ?? "-")") }
            for view in views { write("text \(view.turnID): \(view.readout?.visibleText.replacingOccurrences(of: "\n", with: " | ") ?? "-")") }
        }
        if verb == "perf" {
            for view in views { write("perf \(view.performance)") }
            for view in views { write("ticks \(view.tickReading)") }
            for view in views { write("compose \(view.stage?.composeReading ?? "-") paint \(view.stage?.paintReading ?? "-")") }
            var hits = 0
            var misses = 0
            var entries: Int32 = 0
            tailscode_text_cache_stats(&hits, &misses, &entries)
            let apply = BrainMoveLog.lastApply
            let mean = apply.isEmpty ? 0 : apply.reduce(0, +) / Double(apply.count)
            write("move-apply mean=\(Int(mean))us max=\(Int(apply.max() ?? 0))us gaps=\(BrainMoveLog.lastGaps.count) widgetsPerView=\(views.map { $0.widgetCount }.max() ?? 0) widgetsTotal=\(views.reduce(0) { $0 + $1.widgetCount })")
            write("text-cache hits=\(hits) misses=\(misses) entries=\(entries) pictures=\(BrainPictures.resident.count) renders=\(BrainPictures.renders) moves=\(BrainMoveLog.moves) worstGap=\(Int(BrainMoveLog.worstGap * 1000))ms")
            write(
                "compositors=\(BrainCompositors.resident.compositors) holders=\(BrainCompositors.resident.holders) "
                    + "bytes=\(BrainCompositors.footprint) store=\(NeuralAssetStore.shared.residentBytes) "
                    + "ticks=\(tailscode_live_ticks()) rss=\(Self.residentKilobytes)")
        }
    }

    /// Asks the main loop for a callback every 10 ms for a few seconds and says how late the
    /// callbacks came: a stall of the loop is a late callback, and the longest is the number a
    /// freeze is measured by.
    private func driveLagProbe(seconds: Double) {
        let probe = LagProbe(seconds: seconds)
        probe.arm()
    }

    private final class LagProbe: @unchecked Sendable {
        let seconds: Double
        var start = 0.0
        var expected = 0.0
        var worst = 0.0
        var over50 = 0
        var over100 = 0
        var count = 0
        var busy: [Double] = []
        var cpu0 = 0.0
        var wall0 = 0.0

        init(seconds: Double) { self.seconds = seconds }

        static func mainThreadCPU() -> Double {
            guard let text = try? String(contentsOfFile: "/proc/self/task/\(getpid())/stat", encoding: .utf8) else { return 0 }
            let fields = text.split(separator: ")").last?.split(separator: " ") ?? []
            guard fields.count > 13, let user = Double(fields[11]), let system = Double(fields[12]) else { return 0 }
            return (user + system) / 100
        }

        func arm() {
            start = BrainClock.now
            wall0 = start
            cpu0 = Self.mainThreadCPU()
            expected = start + 0.01
            fire()
        }

        func fire() {
            Gtk.after(10) { [self] in
                Gtk.onMain { [self] in
                    let now = BrainClock.now
                    let late = now - expected
                    count += 1
                    worst = max(worst, late)
                    if late > 0.05 { over50 += 1 }
                    if late > 0.1 { over100 += 1 }
                    expected = now + 0.01
                    if now - start < seconds {
                        fire()
                        return
                    }
                    let wall = now - wall0
                    let cpu = Self.mainThreadCPU() - cpu0
                    let line = String(
                        format: "BRAIN lagprobe seconds=%.1f callbacks=%d worstLate=%.0fms over50=%d over100=%d mainThreadBusy=%.2f rss=%dMB threads=%d\n",
                        wall, count, worst * 1000, over50, over100, wall > 0 ? cpu / wall : 0,
                        MainWindow.residentKilobytes / 1024,
                        (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/task").count) ?? 0)
                    FileHandle.standardOutput.write(Data(line.utf8))
                }
            }
        }
    }

    /// Scrolls the transcript up by a fixed step on every frame for a few seconds and says how long
    /// the frames took: the claim about a long conversation of cards is a number, not a feeling.
    private func driveScrollBench(seconds: Double, pane: ChatPane) {
        guard let window = windowWidget else { return }
        let bench = ScrollBench(pane: pane, seconds: seconds)
        let box = Unmanaged.passRetained(bench).toOpaque()
        _ = Gtk.releaseInstalled
        _ = tailscode_add_owned_tick(
            window,
            { raw in
                guard let raw else { return 0 }
                return Unmanaged<ScrollBench>.fromOpaque(raw).takeUnretainedValue().tick() ? 1 : 0
            }, box)
    }

    private final class ScrollBench: @unchecked Sendable {
        let pane: ChatPane
        let seconds: Double
        var last = 0.0
        var start = 0.0
        var gaps: [Double] = []
        var direction = -1.0

        init(pane: ChatPane, seconds: Double) {
            self.pane = pane
            self.seconds = seconds
        }

        func tick() -> Bool {
            let now = BrainClock.now
            if start == 0 { start = now }
            if last != 0 { gaps.append(now - last) }
            last = now
            pane.scroll(by: direction * 40)
            if now - start < seconds { return true }
            let sorted = gaps.sorted()
            func at(_ fraction: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))] }
            let line = String(
                format: "BRAIN scrollbench frames=%d median=%.1fms p95=%.1fms p99=%.1fms max=%.1fms over25ms=%d\n",
                gaps.count + 1, at(0.5) * 1000, at(0.95) * 1000, at(0.99) * 1000, (sorted.last ?? 0) * 1000,
                gaps.filter { $0 > 0.025 }.count)
            FileHandle.standardOutput.write(Data(line.utf8))
            return false
        }
    }

    /// Resizes the window until the brain's row is `target` points wide, for looking at the
    /// breakpoints: the row is as wide as the window less what is beside it.
    private func driveWidth(_ target: Double, pane: ChatPane) {
        guard let window = windowWidget, let view = pane.brains.liveViews.first else { return }
        let row = Double(gtk_widget_get_width(view.widget))
        let current = Double(gtk_widget_get_width(window))
        let height = Double(gtk_widget_get_height(window))
        guard row > 0, current > 0 else { return }
        gtk_window_set_default_size(
            ptr(window), Int32(max(260, current + target - row)), Int32(height))
    }

    /// Resizes the window to `target` points tall, keeping its width, for looking at a brain with
    /// room to be seen whole.
    private func driveHeight(_ target: Double) {
        guard let window = windowWidget else { return }
        let width = Double(gtk_widget_get_width(window))
        guard width > 0 else { return }
        gtk_window_set_default_size(ptr(window), Int32(width), Int32(max(300, target)))
    }

    static let browseVerbs: Set<String> = [
        "hover", "pin", "transition", "readout", "key", "click", "filter", "search", "menu", "menuitem",
        "legend", "scroll", "expand", "rowhover", "account", "reply", "copy", "said", "ask", "follow", "unfold",
        "acctscroll", "acctfocus", "acctkey", "acctbench",
    ]

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
        case "unpin":
            view.clearSelection()
        case "readout":
            let words = value.split(separator: "=", maxSplits: 1).map(String.init)
            switch words.first ?? "" {
            case "digest", "now":
                view.clearSelection()
                if view.stage?.diveZone != nil { view.dive(nil) }
            case "zone":
                view.clearSelection()
                view.dive(NeuralZone.allCases.first { String(describing: $0) == (words.count > 1 ? words[1] : "") })
            default: break
            }
        case "transition":
            if value == "release" {
                view.releaseFrozenMove()
            } else {
                let closing = value.hasPrefix("close")
                let number = value.split(separator: ",").first.flatMap { Double($0.replacingOccurrences(of: "close:", with: "")) }
                    ?? Double(value.replacingOccurrences(of: "close:", with: "")) ?? 0.5
                view.freezeMove(opening: !closing, at: number)
            }
        case "clear":
            view.clearSelection()
        case "esc":
            _ = view.escapePressed()
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
        case "key", "click", "filter", "search", "menu", "menuitem", "legend", "scroll", "expand", "rowhover":
            view.driveBrowse(verb: verb, value: value)
        case "account", "reply", "copy", "said", "ask", "follow", "unfold", "acctscroll", "acctfocus", "acctkey", "acctbench":
            view.driveAccount(verb: verb, value: value)
        case "share":
            driveShare(view, words: value.split(separator: ",").map(String.init))
        case "shareopen":
            view.presentShare()
        default:
            break
        }
    }

    /// Paints the poster of a turn in a look and an appearance and writes it where the harness
    /// can read it, saying where and how big on the line it prints.
    private func driveShare(_ view: BrainView, words: [String]) {
        let look = NeuralShare.looks.first { words.contains($0.id) } ?? BrainPoster.savedLook()
        let dark = words.contains("dark") ? true : (words.contains("light") ? false : MatrixTheme.palette.isDark)
        let scale = words.compactMap { $0.hasPrefix("x") ? Double($0.dropFirst()) : nil }.first ?? 1
        let name = "brain-share-\(look.id)-\(dark ? "dark" : "light").png"
        let target = ProcessInfo.processInfo.environment["TAILSCODE_BRAIN_SHARE_OUT"].flatMap {
            $0.isEmpty ? nil : $0
        }
        let path: String
        if let target, target.hasSuffix(".png") {
            path = target
        } else {
            let folder = target.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? XDG.dataDirectory
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            path = folder.appendingPathComponent(name).path
        }
        BrainPoster.render(
            model: view.model, prompt: view.row.prompt, style: look, dark: dark, scale: scale
        ) { poster in
            let line: String
            if let poster, let png = poster.png, (try? png.write(to: URL(fileURLWithPath: path))) != nil {
                line = "share path=\(path) size=\(poster.width)x\(poster.height) look=\(look.id) dark=\(dark)"
            } else {
                line = "share failed look=\(look.id) dark=\(dark)"
            }
            FileHandle.standardOutput.write(Data("BRAIN \(line)\n".utf8))
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
        case "cards":
            messages = Self.cardsConversation(now: now)
        case "many":
            let origin = now.timeIntervalSince1970 - 600_000
            messages = (0..<300).flatMap { index in
                NeuralDemo.buildFix(prefix: "m\(index)-", origin: origin + Double(index) * 1_800)
            }
        case "waiting":
            messages = NeuralDemo.buildFix(prefix: "a-", origin: now.timeIntervalSince1970 - 240, answer: false)
            Self.makeWaiting(&messages)
            state.status = .running
            state.pendingPermissions = [PermissionRequest(id: "call-wait", sessionID: "demo", toolName: "Bash")]
        default:
            if let script = BrainAccountDemo.script(kind: kind, now: now) {
                messages = script.messages
                if script.running { state.status = .running }
                if script.waiting {
                    state.pendingPermissions = [PermissionRequest(id: "call-wait", sessionID: "demo", toolName: "Bash")]
                }
            } else {
                messages = NeuralDemo.conversation()
            }
        }
        state.messages = messages
        apply(state: state, rows: rowBuilder.rows(state: state))
    }

    /// A running turn that ends after a moment: the demo `kind` as it runs, then the same words with
    /// its last step done and the turn over, so a card can be looked at settling.
    func driverBrainSettle(_ kind: String) {
        driverBrainDemo(kind)
        Gtk.after(1500) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, var state = self.lastState else { return }
                state.status = .idle
                state.pendingPermissions = []
                if var last = state.messages.popLast() {
                    last.isStreaming = false
                    last.completedAt = Date()
                    last.parts = last.parts.map { part in
                        guard case .tool(var call) = part.kind, call.status == .running else { return part }
                        call.status = .completed
                        return MessagePart(id: part.id, kind: .tool(call))
                    }
                    state.messages.append(last)
                }
                self.apply(state: state, rows: self.rowBuilder.rows(state: state))
            }
        }
    }

    /// Every kind of card in one conversation: a settled turn that failed and was repaired, one
    /// that failed and was not, one that was stopped, a short one, and a long one.
    private static func cardsConversation(now: Date) -> [ChatMessage] {
        let origin = now.timeIntervalSince1970 - 7_200
        var failed = NeuralDemo.buildFix(prefix: "c-", origin: origin + 600, answer: false)
        if var last = failed.popLast() {
            last.error = "API Error: 529 overloaded"
            failed.append(last)
        }
        var stopped = NeuralDemo.buildFix(prefix: "d-", origin: origin + 1_500, answer: false)
        if var last = stopped.popLast() {
            last.finishReason = "aborted"
            stopped.append(last)
        }
        return NeuralDemo.buildFix(prefix: "a-", origin: origin) + failed + stopped
            + NeuralDemo.turn(prefix: "b-", origin: origin + 2_400)
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
