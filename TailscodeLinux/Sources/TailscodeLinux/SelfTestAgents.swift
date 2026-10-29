import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A source that answers from a fixed board and counts what it was asked, so a button's trip can
/// be held in the air, answered one way or another, and counted.
final class ScriptedAgentsSource: AgentsSource, @unchecked Sendable {
    private let lock = NSLock()
    let board: AgentBoard
    let now: Date
    private var held = false
    private var _opens = 0
    private var _closes = 0
    private var _approves: [(String, Bool)] = []
    private var _answers: [String] = []
    private var _stops: [String] = []
    private var _nudges: [String] = []
    private var _watches: [String] = []
    private var _stopReply: AgentTower.Reply = .sent
    private var _nudgeReply: AgentTower.Reply = .sent
    private var _approveReply: AgentTower.Reply = .sent

    init(now: Date, board: AgentBoard? = nil) {
        self.now = now
        self.board = board ?? AgentDemo.board(now: now)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var opens: Int { locked { _opens } }
    var closes: Int { locked { _closes } }
    var approves: [(String, Bool)] { locked { _approves } }
    var answers: [String] { locked { _answers } }
    var stops: [String] { locked { _stops } }
    var nudges: [String] { locked { _nudges } }
    var watches: [String] { locked { _watches } }
    func hold(_ on: Bool) { locked { held = on } }
    func reply(approve: AgentTower.Reply? = nil, stop: AgentTower.Reply? = nil, nudge: AgentTower.Reply? = nil) {
        locked {
            if let approve { _approveReply = approve }
            if let stop { _stopReply = stop }
            if let nudge { _nudgeReply = nudge }
        }
    }

    private func waitWhileHeld() async {
        while locked({ held }) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func open() async { locked { _opens += 1 } }
    func close() async { locked { _closes += 1 } }
    func current() async -> AgentBoard { board }

    func boards() async -> AsyncStream<AgentBoard> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: AgentBoard.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(board)
        return stream
    }

    func facts(for key: String) async -> AsyncStream<AgentFacts?> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: AgentFacts?.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(DemoAgentsSource.facts(for: key, now: now))
        return stream
    }

    func hour() async -> AgentHour { AgentDemo.hour(now: Date()) }

    func approve(_ key: String, allow: Bool) async -> AgentTower.Reply {
        locked { _approves.append((key, allow)) }
        await waitWhileHeld()
        return locked { _approveReply }
    }

    func answer(_ key: String, option: String) async -> AgentTower.Reply {
        locked { _answers.append(option) }
        await waitWhileHeld()
        return .sent
    }

    func stop(_ key: String) async -> AgentTower.Reply {
        locked { _stops.append(key) }
        await waitWhileHeld()
        return locked { _stopReply }
    }

    func nudge(_ key: String, text: String) async -> AgentTower.Reply {
        locked { _nudges.append(text) }
        await waitWhileHeld()
        return locked { _nudgeReply }
    }

    func watch(_ key: String) async { locked { _watches.append(key) } }
}

final class AgentsHookLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [(String, String?)] = []
    private var _asked: [String] = []
    private var _proceed: (@Sendable () -> Void)?
    private var _styleOpened = 0

    var styleOpened: Int { lock.withLock { _styleOpened } }

    var opened: [(String, String?)] { lock.withLock { _opened } }
    var asked: [String] { lock.withLock { _asked } }

    func opened(_ key: String, _ draft: String?) { lock.withLock { _opened.append((key, draft)) } }

    func asked(_ title: String, _ proceed: @escaping @Sendable () -> Void) {
        lock.withLock {
            _asked.append(title)
            _proceed = proceed
        }
    }

    func confirm() {
        let work = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { _proceed = nil }
            return _proceed
        }
        work?()
    }

    var hooks: AgentsHooks {
        AgentsHooks(
            openChat: { [self] key, draft in opened(key, draft) },
            confirmStop: { [self] title, proceed in asked(title, proceed) },
            openStyle: { [self] in lock.withLock { _styleOpened += 1 } })
    }
}

extension SelfTest {
    /// The agents board, built over Core's demo fiction in a real window: its four sections and the
    /// sentence over them, an Approve that is dead while it travels and counted once however many
    /// times it is pressed, a Stop that asks first and a nudge that says why it failed, text that
    /// wraps instead of clipping at a command and a title far longer than any real one, the hour
    /// with as many lanes as Core has, the shortcut that toggles one window, and a tower that is
    /// opened and closed with nothing left watching.
    static func checkAgentsBoard() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var claims = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("agents: \(label)") }
            claims += 1
        }
        func pump(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while g_main_context_iteration(nil, 0) != 0 {}
                usleep(4000)
            }
        }
        MatrixTheme.install()
        let now = Date()
        let source = ScriptedAgentsSource(now: now)
        let log = AgentsHookLog()
        let builtBefore = AgentsWindow.built
        let window = AgentsWindow.present(parent: nil, source: source, hooks: log.hooks, mode: .now)
        pump(0.45)
        defer {
            window.close()
            pump(0.2)
        }

        let counts = window.boardView.counts()
        try expect(
            counts[.needsYou] == 1 && counts[.working] == 2 && counts[.background] == 1
                && counts[.finished] == 1,
            "the demo board shows its four sections with their counts: \(window.stateLine)")
        let sentence = gtk_label_get_text(op(window.boardView.sentenceLabel)).map { String(cString: $0) } ?? ""
        try expect(
            sentence == AgentDemo.board(now: now).sentence && sentence.contains("2"),
            "the sentence is Core's: \(sentence)")
        try expect(source.opens == 1 && window.isLive, "the board opened its source once and is live")
        try expect(
            AgentsRuntime.shared.openHeadline?.needsYou == 1,
            "the sidebar's chip reads the board while it is open")

        let askKey = AgentDemo.homelab + "/ask"
        guard let card = window.boardView.askCard(askKey), let approve = card.approveButton,
            let deny = card.denyButton
        else { throw SelfTestFailure("agents: the ask has no card with Approve and Deny") }
        let objectText = gtk_label_get_text(op(card.objectLabel)).map { String(cString: $0) } ?? ""
        try expect(
            objectText == "rm -rf build && swift build -c release",
            "the command is shown word for word: \(objectText)")
        try expect(gtk_label_get_selectable(op(card.objectLabel)) != 0, "and can be selected")
        try expect(
            gtk_widget_get_sensitive(approve) != 0 && gtk_widget_get_sensitive(deny) != 0,
            "Approve and Deny start live")

        source.hold(true)
        tailscode_emit_clicked(approve)
        pump(0.2)
        tailscode_emit_clicked(approve)
        pump(0.3)
        try expect(
            gtk_widget_get_sensitive(approve) == 0 && gtk_widget_get_sensitive(deny) == 0,
            "Approve is dead while it is in flight, and so is Deny")
        try expect(
            AgentsParts.buttonTitle(approve) == Localized.text("Approving…"),
            "and says it is going: \(AgentsParts.buttonTitle(approve))")
        try expect(source.approves.count == 1 && source.approves[0].1, "two presses are one send: \(source.approves.count)")
        source.hold(false)
        pump(0.4)
        try expect(
            AgentsParts.buttonTitle(approve) == Localized.text("Sent")
                && gtk_widget_get_sensitive(approve) == 0 && window.boardView.askCard(askKey) != nil,
            "a sent answer says so and the card stays until the board takes it away")

        let working = AgentDemo.studio + "/w"
        window.select(key: working)
        pump(0.45)
        try expect(window.peekRevealed && window.peek.key == working, "a row opens its peek in the inspector")
        let doing = gtk_label_get_text(op(window.peek.doingLabel)).map { String(cString: $0) } ?? ""
        try expect(doing.contains("Backoff"), "the peek says what it is doing in large type: \(doing)")
        let path = gtk_label_get_text(op(window.peek.objectLabel)).map { String(cString: $0) } ?? ""
        try expect(
            path.hasSuffix("Backoff.swift") && gtk_widget_get_visible(window.peek.objectLabel) != 0,
            "and the path of what it edits under it, wrapped whole: \(path)")
        try expect(window.peek.stepCount > 0, "and lists its last steps")
        try expect(
            window.peek.meterReading.hasCost && window.peek.meterReading.costText.hasPrefix("≈")
                && window.peek.meterReading.costCaptionText == Localized.text("API estimate"),
            "the cost is marked as an estimate: \(window.peek.meterReading.costText) \(window.peek.meterReading.costCaptionText)")
        try expect(source.stops.isEmpty && log.asked.isEmpty, "nothing has been stopped or asked yet")
        tailscode_emit_clicked(window.peek.stopControl)
        pump(0.2)
        try expect(
            log.asked == ["Fix reconnect test"] && source.stops.isEmpty,
            "Stop asks first, naming the chat, and sends nothing: \(log.asked) \(source.stops)")
        log.confirm()
        pump(0.4)
        try expect(source.stops == [working], "and sends once it is confirmed: \(source.stops)")

        gtk_editable_set_text(op(window.peek.nudgeField), "try the retry path first")
        pump(0.1)
        try expect(gtk_widget_get_sensitive(window.peek.nudgeControl) != 0, "a nudge with words is live")
        source.reply(nudge: .failed("The server refused it"))
        tailscode_emit_clicked(window.peek.nudgeControl)
        pump(0.4)
        let failure = gtk_label_get_text(op(window.peek.errorLabel)).map { String(cString: $0) } ?? ""
        try expect(
            failure.contains("The server refused it") && gtk_widget_get_sensitive(window.peek.nudgeControl) != 0,
            "a failed nudge says why in the peek and stays live: \(failure)")
        source.reply(nudge: .needsChat)
        tailscode_emit_clicked(window.peek.nudgeControl)
        pump(0.4)
        try expect(
            log.opened.last?.0 == working && log.opened.last?.1 == "try the retry path first",
            "a server with no queue opens the chat with the words left for the person: \(String(describing: log.opened.last))")

        window.select(key: askKey)
        pump(0.45)
        let command = window.peek.askCard.flatMap { gtk_label_get_text(op($0.objectLabel)) }
            .map { String(cString: $0) } ?? ""
        try expect(
            command.contains("swift build") && gtk_widget_get_visible(window.peek.objectLabel) == 0,
            "an approval's peek holds its card with the command and repeats nothing under the line: \(command)")
        window.deselect()
        pump(0.5)
        try expect(!window.peekRevealed, "the inspector collapses with nothing selected")

        try checkAgentsWrapping(window, expect: expect, pump: pump)
        try checkAgentsHour(window, source: source, now: now, expect: expect, pump: pump)

        let again = AgentsWindow.present(parent: nil, source: source, hooks: log.hooks)
        try expect(again === window && AgentsWindow.built == builtBefore + 1, "raising the board twice never builds a second window")
        let closesBefore = source.closes
        let toggled = window.handleKey(
            keyval: 0x41, state: KeyChord.controlMask | KeyChord.shiftMask)
        pump(0.4)
        try expect(
            toggled && AgentsWindow.current == nil && source.closes == closesBefore + 1,
            "Ctrl+Shift+A inside the board closes it and its source: \(source.closes)")
        try expect(
            ShortcutRegistry.all.first { $0.id == "view.agents" }?.defaults == ["ctrl+shift+a"],
            "the shortcut is bound to Ctrl+Shift+A")
        try expect(
            MainWindow.orbDestination(secondary: false, control: false) == .chat
                && MainWindow.orbDestination(secondary: true, control: false) == .board
                && MainWindow.orbDestination(secondary: false, control: true) == .board,
            "the orb's plain press still opens its chat; a right click or control opens the board")
        try expect(
            OrbPainter.tooltip("2 working").contains(Localized.text("Right-click or Ctrl+click for the agents board")),
            "and its tooltip says so")
        let help = ShortcutSet.build(overrides: [:]).helpSections().flatMap(\.rows)
        try expect(
            help.contains { $0.what == Localized.text("Show the agents board") && $0.keys.lowercased().contains("a") },
            "and the cheatsheet lists it")

        claims += try checkAgentsEntry(expect: expect, pump: pump)
        claims += try checkAgentsTower(pump: pump)
        return claims
    }
}
