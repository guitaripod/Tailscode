import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A model that answers from a script and counts what it was sent, so the wall's use of a local
/// model can be proved without a network: how many requests, to where, with what, and how many at once.
final class PlainStub: PlainWordsTransport, @unchecked Sendable {
    enum Mode {
        case line(String)
        case fail
    }

    private let lock = NSLock()
    private var _mode: Mode
    private var _posts: [Data] = []
    private var _urls: [URL] = []
    private var _gets: [URL] = []
    private var active = 0
    private var _widest = 0
    private let delay: Duration

    init(_ mode: Mode, delay: Duration = .milliseconds(20)) {
        _mode = mode
        self.delay = delay
    }

    var posts: [Data] { lock.withLock { _posts } }
    var urls: [URL] { lock.withLock { _urls } }
    var gets: [URL] { lock.withLock { _gets } }
    var widest: Int { lock.withLock { _widest } }
    var requests: Int { lock.withLock { _posts.count + _gets.count } }
    func set(_ mode: Mode) { lock.withLock { _mode = mode } }

    func get(_ url: URL) async throws -> Data {
        let mode = lock.withLock { () -> Mode in
            _gets.append(url)
            return _mode
        }
        if case .fail = mode { throw PlainWordsError.notAnswered }
        return Data(#"{"data":[{"id":"stub-model"},{"id":"other"}]}"#.utf8)
    }

    func post(_ url: URL, body: Data) async throws -> Data {
        let mode = lock.withLock { () -> Mode in
            _posts.append(body)
            _urls.append(url)
            active += 1
            _widest = max(_widest, active)
            return _mode
        }
        try? await Task.sleep(for: delay)
        lock.withLock { active -= 1 }
        switch mode {
        case .fail: throw PlainWordsError.notAnswered
        case .line(let text):
            let reply: [String: Any] = ["choices": [["message": ["role": "assistant", "content": text]]]]
            return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        }
    }
}

extension SelfTest {
    private static let deployCommand = "./deploy-edge --region eu --canary 5"
    private static let secretCommand = "TOKEN=abc123 ./deploy-edge --region us"
    private static let askedCommand = "./ship-it --now"

    private static func plainSource(
        _ id: String, _ title: String, command: String, asking: Bool, now: Date
    ) -> AgentSource {
        let call = ToolCall(
            id: "c-" + id, name: "Bash", status: asking ? .pending : .running,
            input: .object(["command": .string(command)]))
        let user = ChatMessage(
            id: "u-" + id, role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "p", kind: .text("ship it"))], createdAt: now.addingTimeInterval(-400))
        let turn = ChatMessage(
            id: "a-" + id, role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p-" + id, kind: .tool(call))], createdAt: now.addingTimeInterval(-380),
            isStreaming: true, providerID: "anthropic", modelID: "claude-opus-5", reasoningEffort: "xhigh")
        let request = PermissionRequest(id: "perm-" + id, sessionID: id, title: "Bash", toolName: "Bash")
        let state = ConversationState(
            messages: [user, turn], status: .running, pendingPermissions: asking ? [request] : [],
            hasLoadedTranscript: true)
        let session = AgentSession(
            id: id, agentType: .claudeCode, title: title, createdAt: now.addingTimeInterval(-7200),
            updatedAt: now, isActive: true, model: "claude-opus-5")
        let entry = SessionEntry(
            profileID: "studio", profileName: "studio", host: "studio", backendType: .claudeCode,
            session: session)
        let facts = AgentFacts.read(
            state: state, agents: [], seen: asking ? [request.id: now.addingTimeInterval(-20)] : [:],
            stamps: (0..<40).map { now.addingTimeInterval(-Double($0) * 1.4) }, now: now)
        return AgentSource(entry: entry, facts: facts, reachable: true, unread: false)
    }

    private static func plainBoard(now: Date) -> AgentBoard {
        AgentBoard.read(
            sources: [
                plainSource("pa", "Edge deploy", command: deployCommand, asking: false, now: now),
                plainSource("pb", "Other region", command: secretCommand, asking: false, now: now),
                plainSource("pc", "Shipping", command: askedCommand, asking: true, now: now),
            ], now: now)
    }

    private static func waitFor(_ check: WatchCheck, _ seconds: Double, _ done: () -> Bool) {
        var waited = 0.0
        while !done() && waited < seconds {
            check.pump(0.05)
            waited += 0.05
        }
        check.pump(0.1)
    }

    private static func shown(_ view: AgentsWatchView, raw: String) -> WatchTileView? {
        view.wall.tiles.first { $0.rewritable == raw }.flatMap { view.tileView($0.id) }
    }

    private static func body(_ data: Data) -> NSDictionary? {
        (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }

    /// A local model saying the commands no rule could read: nothing is sent while it is off or
    /// pointed outside this machine and the person's network; when on, one line per unknown command
    /// comes back marked as written by a model with the raw command still under it, one request at
    /// a time, none for an approval, none twice, none carrying a secret, a reply that reads like a
    /// command is dropped, and a failure is left alone for a minute.
    static func checkWatchPlain(_ check: WatchCheck) throws {
        let was = (Preferences.plainWords, Preferences.plainWordsAddress, Preferences.plainWordsModel)
        defer {
            Preferences.forgetAgentsWindowSize()
            Preferences.setPlainWords(was.0)
            Preferences.setPlainWordsAddress(was.1)
            Preferences.setPlainWordsModel(was.2)
        }
        Preferences.setPlainWords(false)
        Preferences.setPlainWordsAddress("")
        Preferences.setPlainWordsModel("")
        let now = Date()
        let source = ScriptedAgentsSource(now: now, board: plainBoard(now: now))
        let window = AgentsWindow.present(parent: nil, source: source, hooks: check.log.hooks, mode: .watch)
        defer { check.close(window) }
        check.resize(window, 1920, 1080)
        waitFor(check, 4) { window.boardsApplied > 0 }
        let view = window.watchView
        let clock = view.context.clock
        let marker = PlainWordsModel.marker
        let rules = "Running a command"

        guard let deploy = shown(view, raw: deployCommand),
            let asked = view.wall.tiles.first(where: { $0.state.isNeedsYou })
        else {
            throw SelfTestFailure("agents watch: the plain board lacks its tiles: \(view.wall.tiles.map { "\($0.title)=\($0.words)|\($0.rewritable ?? "-")" })")
        }
        try check.expect(
            deploy.words.text == rules && deploy.detail.text == deployCommand && deploy.tile?.rewritable == deployCommand,
            "an unknown command reads as the rules' line over the raw command: \(deploy.words.text) / \(deploy.detail.text)")
        try check.expect(
            asked.rewritable == nil && asked.detail == askedCommand,
            "an approval keeps its whole command and is never offered to a model: \(String(describing: asked.rewritable))")

        let off = PlainStub(.line("Deploying to the edge servers"))
        window.plainWordsChanged(transport: off)
        check.pump(0.4)
        try check.expect(
            view.context.plainModel == nil && off.requests == 0 && deploy.words.text == rules,
            "it is off by default: no model, no request, the rules' line")

        Preferences.setPlainWords(true)
        Preferences.setPlainWordsAddress("https://api.openai.com/v1")
        let outside = PlainStub(.line("Deploying to the edge servers"))
        window.plainWordsChanged(transport: outside)
        check.pump(0.4)
        try check.expect(
            view.context.plainModel == nil && outside.requests == 0 && deploy.words.text == rules,
            "an address outside this machine and the private ranges is the same as off: no request")
        let stray = PlainWordsModel(
            endpoint: URL(string: "https://api.openai.com/v1")!, model: "m", transport: outside)
        stray.ask(deployCommand)
        check.pump(0.4)
        try check.expect(outside.requests == 0 && stray.said(for: deployCommand) == nil, "an endpoint is vetted again at request time")

        Preferences.setPlainWordsAddress("http://127.0.0.1:8080/v1")
        Preferences.setPlainWordsModel("stub-model")
        let stub = PlainStub(.line("Deploying to the edge servers"))
        window.plainWordsChanged(transport: stub)
        waitFor(check, 6) { stub.posts.count >= 2 && deploy.words.text.hasSuffix(marker) }
        let line = "Deploying to the edge servers" + marker
        try check.expect(
            deploy.words.text == line && deploy.detail.text == deployCommand,
            "the tile says the model's line, marked, over the raw command: \(deploy.words.text) / \(deploy.detail.text)")
        let now2 = clock.now
        try check.expect(
            deploy.spoken(now: now2).contains(Localized.text("written by a model"))
                && tailscode_accessible_has_label(deploy.widget, deploy.spoken(now: now2)) != 0,
            "the accessible label says a model wrote it: \(deploy.spoken(now: now2))")
        try check.expect(
            stub.posts.count == 2 && stub.widest == 1 && stub.gets.isEmpty
                && stub.urls.allSatisfy { $0.absoluteString == "http://127.0.0.1:8080/v1/chat/completions" },
            "two unknown commands made two requests, one at a time, to the chat route: \(stub.posts.count) \(stub.widest)")
        let wanted = body(PlainModel.request(model: "stub-model", raw: deployCommand))
        try check.expect(
            stub.posts.contains { body($0) == wanted }, "the body is exactly what PlainModel builds")
        try check.expect(
            stub.posts.allSatisfy { !String(decoding: $0, as: UTF8.self).contains("abc123") },
            "no secret leaves in a request")
        let redacted = PlainModel.redact(secretCommand)
        try check.expect(
            stub.posts.contains { body($0) == body(PlainModel.request(model: "stub-model", raw: secretCommand)) }
                && !redacted.contains("abc123"),
            "the command that carried a secret was still asked about, with the secret taken out")
        try check.expect(
            stub.posts.allSatisfy { !String(decoding: $0, as: UTF8.self).contains("ship-it") }
                && !asked.words.contains("✦"),
            "an approval's command is never sent")
        view.replayWords()
        check.pump(0.4)
        try check.expect(stub.posts.count == 2, "a line already written is kept in memory and not asked for twice")

        Preferences.setPlainWords(false)
        window.plainWordsChanged(transport: stub)
        check.pump(0.2)
        try check.expect(
            view.context.plainModel == nil && deploy.words.text == rules && !deploy.writtenByModel,
            "turning it off puts the rules' line back at once")

        Preferences.setPlainWords(true)
        let command = PlainStub(.line("Running rm -rf /"))
        window.plainWordsChanged(transport: command)
        waitFor(check, 4) { command.posts.count >= 2 }
        view.replayWords()
        check.pump(0.3)
        try check.expect(
            command.posts.count == 2 && deploy.words.text == rules && !deploy.writtenByModel,
            "a reply that reads like a command is dropped: \(deploy.words.text)")
        clock.advance(by: 30)
        view.replayWords()
        check.pump(0.3)
        try check.expect(command.posts.count == 2, "a refused line is not asked for again within a minute")
        clock.advance(by: 40)
        view.replayWords()
        waitFor(check, 4) { command.posts.count >= 4 }
        try check.expect(command.posts.count == 4, "and is asked for again after it: \(command.posts.count)")

        let broken = PlainStub(.fail)
        window.plainWordsChanged(transport: broken)
        waitFor(check, 4) { broken.posts.count >= 2 }
        view.replayWords()
        clock.advance(by: 59)
        view.replayWords()
        check.pump(0.4)
        try check.expect(
            broken.posts.count == 2 && deploy.words.text == rules,
            "a failed request is not repeated within sixty seconds: \(broken.posts.count)")
        clock.advance(by: 2)
        view.replayWords()
        waitFor(check, 4) { broken.posts.count >= 4 }
        try check.expect(broken.posts.count == 4, "and is tried again after them: \(broken.posts.count)")

        Preferences.setPlainWordsModel("")
        let named = PlainStub(.line("Deploying to the edge servers"))
        window.plainWordsChanged(transport: named)
        waitFor(check, 6) { named.posts.count >= 2 }
        let used = named.posts.compactMap { body($0)?["model"] as? String }
        try check.expect(
            named.gets.count == 1 && named.gets[0].absoluteString == "http://127.0.0.1:8080/v1/models"
                && used.count == 2 && used.allSatisfy { $0 == "stub-model" },
            "with no model named it asks the server once and uses the first it lists: \(named.gets.count) \(used)")
        window.usePlainWords(nil)

        let crowd = PlainStub(.line("Deploying to the edge servers"), delay: .milliseconds(40))
        let queued = PlainWordsModel(
            endpoint: URL(string: "http://127.0.0.1:8080/v1")!, model: "stub-model", transport: crowd,
            clock: { clock.now })
        for index in 0..<10 { queued.ask("./job-\(index) run now") }
        waitFor(check, 6) { crowd.posts.count >= 7 }
        check.pump(0.5)
        try check.expect(
            crowd.posts.count == 7 && crowd.widest == 1,
            "one request in flight and six waiting, the oldest dropped: \(crowd.posts.count) \(crowd.widest)")

        let listing = PlainStub(.line("x"))
        let reached = PlainBox<Result<[String], Error>>()
        Task {
            reached.value = await PlainWordsModel.check(
                endpoint: URL(string: "http://127.0.0.1:8080/v1")!, transport: listing)
        }
        waitFor(check, 4) { reached.value != nil }
        let ids = (try? reached.value?.get()) ?? []
        try check.expect(
            ids == ["stub-model", "other"]
                && SettingsPlainWords.reading(.success(ids)) == Localized.text("Reachable · %d models", 2),
            "Check lists the server's models: \(ids)")
        let unreachable = PlainBox<Result<[String], Error>>()
        let down = PlainStub(.fail)
        Task {
            unreachable.value = await PlainWordsModel.check(
                endpoint: URL(string: "http://127.0.0.1:8080/v1")!, transport: down)
        }
        waitFor(check, 4) { unreachable.value != nil }
        try check.expect(
            SettingsPlainWords.reading(unreachable.value ?? .success([])) == Localized.text("Could not reach it"),
            "Check says it could not reach a server that does not answer")
    }
}

/// A result handed from a task to the check that is pumping the main loop.
final class PlainBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Value?

    var value: Value? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
}
