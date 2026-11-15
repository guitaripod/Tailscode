import CAdw
import Foundation
import TailscodeCore

/// A machine that answers like the model servers on it, from a script: what each port serves and
/// how each model answers, and every request it was sent, so the finder can be proved without one.
final class PlainScoutStub: PlainWordsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let pages: [String: String]
    private let lines: [String: String]
    private var _posts: [String] = []

    init(pages: [String: String], lines: [String: String]) {
        self.pages = pages
        self.lines = lines
    }

    var posts: [String] { lock.withLock { _posts } }

    func get(_ url: URL) async throws -> Data {
        guard let page = pages["\(url.port ?? 0)\(url.path)"] else { throw PlainWordsError.notAnswered }
        return Data(page.utf8)
    }

    func post(_ url: URL, body: Data) async throws -> Data {
        let model = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["model"] as? String ?? ""
        lock.withLock { _posts.append(model) }
        guard let line = lines[model] else { throw PlainWordsError.notAnswered }
        let reply: [String: Any] = ["choices": [["message": ["role": "assistant", "content": line]]]]
        return try JSONSerialization.data(withJSONObject: reply)
    }
}

extension SelfTest {
    static func checkPlainWordsScout(_ check: WatchCheck) throws {
        let swapPages = [
            "8081/v1/models": #"{"data":[{"id":"big-74b","name":"Big","description":"Nemotron 74B","status":{"value":"loaded"}},{"id":"helper-4b","name":"Helper","description":"Tuned 4B","status":{"value":"loaded"}},{"id":"qwen3-4b-instruct-gguf","name":"Qwen3 Instruct","description":"Qwen3 4B Instruct","status":{"value":"unloaded"}}]}"#,
            "8081/running": #"{"running":[{"model":"big-74b"},{"model":"helper-4b"}]}"#,
        ]
        let swap = PlainScoutStub(
            pages: swapPages,
            lines: ["helper-4b": "`git status` shows the tree", "qwen3-4b-instruct-gguf": "Showing what changed in the project"])
        let asked = blockingOutcome { await PlainWordsScout(transport: swap).settle() }
        guard case .ask(let model)? = asked else {
            throw SelfTestFailure("agents watch: plain words: a model llama-swap would have to start is asked about, got \(String(describing: asked))")
        }
        try check.expect(model.id == "qwen3-4b-instruct-gguf" && model.kind == .llamaSwap, "the finder offers the small instruct model llama-swap is not running")
        try check.expect(swap.posts == ["helper-4b"], "after trying the small running one, and never the big one or the one that would have to start: \(swap.posts)")
        let started = blockingOutcome { await PlainWordsScout(transport: swap).start(model) }
        guard case .ready(let ready, let line, _)? = started else {
            throw SelfTestFailure("agents watch: plain words: a model the person starts is tried and used")
        }
        try check.expect(ready.id == model.id && line == "Showing what changed in the project", "and once started it is proved with one line")

        let ollama = PlainScoutStub(
            pages: [
                "11434/v1/models": #"{"data":[{"id":"qwen3:4b"},{"id":"llama3.3:70b"},{"id":"nomic-embed-text:latest"}]}"#,
                "11434/api/ps": #"{"models":[]}"#,
                "11434/api/tags": #"{"models":[{"name":"qwen3:4b","details":{"parameter_size":"4.0B"}},{"name":"llama3.3:70b","details":{"parameter_size":"70.6B"}}]}"#,
            ],
            lines: ["qwen3:4b": "Checking the project's changes"])
        let found = blockingOutcome { await PlainWordsScout(transport: ollama).settle() }
        guard case .ready(let picked, _, _)? = found else {
            throw SelfTestFailure("agents watch: plain words: Ollama's small model is used without asking, got \(String(describing: found))")
        }
        try check.expect(picked.id == "qwen3:4b" && picked.kind == .ollama && picked.base.absoluteString == "http://127.0.0.1:11434/v1", "Ollama's small model is found, tried and used without asking")

        let empty = PlainScoutStub(pages: [:], lines: [:])
        try check.expect(blockingOutcome { await PlainWordsScout(transport: empty).settle() } == PlainWordsScout.Outcome.none, "a machine with no model server says so")

        let was = (Preferences.plainWords, Preferences.plainWordsAddress, Preferences.plainWordsModel, Preferences.plainWordsLabel)
        defer {
            Preferences.setPlainWords(was.0)
            Preferences.setPlainWordsAddress(was.1)
            Preferences.setPlainWordsModel(was.2)
            Preferences.setPlainWordsFound(label: was.3)
        }
        let setup = PlainWordsSetup()
        _ = setup.build()
        setup.landed(.ready(picked, line: "Checking the project's changes", seconds: 0.4))
        try check.expect(
            Preferences.plainWordsAddress == "http://127.0.0.1:11434/v1" && Preferences.plainWordsModel == "qwen3:4b"
                && Preferences.plainWordsLabel == "qwen3:4b · Ollama",
            "the model it proved is the one the wall uses, and Settings names it")
        setup.typed()
        try check.expect(!Preferences.plainWordsFound, "an address the person types is theirs, not the finder's")
    }

    private static func blockingOutcome(_ work: @escaping @Sendable () async -> PlainWordsScout.Outcome) -> PlainWordsScout.Outcome? {
        let box = OutcomeBox()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.value = await work()
            done.signal()
        }
        while done.wait(timeout: .now() + 0.01) == .timedOut {
            while g_main_context_iteration(nil, 0) != 0 {}
        }
        return box.value
    }

    private final class OutcomeBox: @unchecked Sendable {
        var value: PlainWordsScout.Outcome?
    }
}
