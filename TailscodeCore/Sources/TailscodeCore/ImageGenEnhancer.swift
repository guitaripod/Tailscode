import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A small language model on the same tailnet, asked to turn three words into the paragraph this
/// image model was trained behind.
///
/// Qwen-Image-2.1 never saw short prompts: a rewriter expanded every ask into one long description
/// of the finished frame, and that is what reached the transformer. The studio can teach that
/// shape (``ImageGenBrief``) but a person who types "cat astronaut" wants the picture, not a
/// lesson — so if the machine that paints also serves an OpenAI-shaped chat endpoint, the studio
/// borrows it for a second and writes the paragraph itself.
///
/// Anything OpenAI-shaped answers: Ollama, llama-swap, llama.cpp's own server, LM Studio, vLLM.
public struct ImageGenHelper: Sendable, Equatable, Codable {
    /// Base address of the OpenAI-shaped API, e.g. `http://127.0.0.1:8081`.
    public var address: String
    /// Which model answers. The endpoint's own name for it, as `/v1/models` lists it.
    public var model: String
    /// What the endpoint calls the model for a person, when it has a better name than the id —
    /// llama-swap lists "Qwen 3.8 27B · NVFP4" beside `qwen38-nvfp4`. Nil where the id is the name.
    public var label: String?
    /// Whether the studio may use it. A helper is remembered even while it is off, so turning it
    /// back on costs no setup.
    public var enabled: Bool
    /// Whether a person picked this one from the list, as opposed to the studio filing the best
    /// it found. A found helper is replaced by a better find; a chosen one is kept until the
    /// person chooses again. Nil on a record written before the distinction existed.
    public var chosenByHand: Bool?

    public init(
        address: String, model: String, label: String? = nil, enabled: Bool = true,
        chosenByHand: Bool? = nil
    ) {
        self.address = address.hasSuffix("/") ? String(address.dropLast()) : address
        self.model = model
        self.label = label
        self.enabled = enabled
        self.chosenByHand = chosenByHand
    }

    public init(
        address: String, model: ImageGenHelperModel, enabled: Bool = true,
        chosenByHand: Bool? = nil
    ) {
        self.init(
            address: address, model: model.id, label: model.name, enabled: enabled,
            chosenByHand: chosenByHand)
    }

    public var isChosenByHand: Bool { chosenByHand == true }

    /// Whether `found` should replace this one as the filed helper: only a helper nobody chose
    /// gives way, and only to a different model.
    public func yields(to found: ImageGenHelper) -> Bool {
        guard !isChosenByHand else { return false }
        return found.address != address || found.model != model
    }

    public var host: String { URLComponents(string: address)?.host ?? address }

    public var displayHost: String {
        guard let parts = URLComponents(string: address), let host = parts.host else {
            return address
        }
        guard let port = parts.port else { return host }
        return "\(host):\(port)"
    }

    /// The model as a person would say it: the display name's first segment where the endpoint
    /// gave one, else the id up to its tag.
    public var name: String {
        if let label, let first = label.split(separator: "·").first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return model.split(separator: ":").first.map(String.init) ?? model
    }

    /// What the chip says: the model, short enough to sit beside the other decisions.
    public var chip: String {
        let name = self.name
        return name.count > 18 ? String(name.prefix(16)) + "…" : name
    }
}

/// One model an OpenAI-shaped endpoint offers, as it lists it. The id is what a request names;
/// the name and the loaded mark are what llama-swap adds and the others leave out.
public struct ImageGenHelperModel: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let name: String?
    /// Whether the model is in memory right now — llama-swap says so, and a model that is loaded
    /// answers in a second where one that is not costs its own load first. Nil where the endpoint
    /// does not say.
    public let loaded: Bool?

    public init(id: String, name: String? = nil, loaded: Bool? = nil) {
        self.id = id
        self.name = name
        self.loaded = loaded
    }

    public var label: String { name ?? id }

    /// The row's second line: the id when the name hides it, and whether it is in memory.
    public var detail: String? {
        var parts: [String] = []
        if name != nil, name != id { parts.append(id) }
        if loaded == true { parts.append(ImageGenRewriteWords.loadedMark) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How many billion parameters the name admits to, read from the "27b", "4B", "0_6b" or
    /// "e2b" a model file is almost always called by. Nil when the name does not say.
    public var billions: Double? {
        let lower = (name ?? id).lowercased() + " " + id.lowercased()
        let pattern = #"(?<![a-z])(?:e)?(\d+(?:[._]\d+)?)\s*b(?![a-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(lower.startIndex..., in: lower)
        guard let match = regex.firstMatch(in: lower, range: range),
            let digits = Range(match.range(at: 1), in: lower)
        else { return nil }
        return Double(lower[digits].replacingOccurrences(of: "_", with: "."))
    }

    /// Reads one entry of `/v1/models`: the id every endpoint gives, the name llama-swap gives,
    /// and the loaded mark llama-swap keeps under `status.value`.
    static func read(_ entry: [String: Any]) -> ImageGenHelperModel? {
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        let name = (entry["name"] as? String).flatMap { $0.isEmpty || $0 == id ? nil : $0 }
        var loaded: Bool?
        if let status = entry["status"] as? [String: Any], let value = status["value"] as? String {
            loaded = value == "loaded" || value == "ready"
        }
        return ImageGenHelperModel(id: id, name: name, loaded: loaded)
    }
}

/// One machine that answered `/v1/models`, and what it offered. A survey lists every door on
/// the tailnet that answered, so the person picks among all of them rather than among the first.
public struct ImageGenHelperServer: Sendable, Equatable, Identifiable {
    public let address: String
    public let models: [ImageGenHelperModel]
    /// What the endpoint said it was, when the listing says: llama-swap owns its models, Ollama
    /// files them under "library". Nil where nothing in the answer names the software.
    public let software: String?

    public init(address: String, models: [ImageGenHelperModel], software: String? = nil) {
        self.address = address.hasSuffix("/") ? String(address.dropLast()) : address
        self.models = models
        self.software = software
    }

    public var id: String { address }

    public var displayHost: String {
        guard let parts = URLComponents(string: address), let host = parts.host else {
            return address
        }
        guard let port = parts.port else { return host }
        return "\(host):\(port)"
    }

    /// The heading a menu gives this machine: the software where it is known, and the address.
    public var heading: String {
        guard let software else { return displayHost }
        return "\(software) · \(displayHost)"
    }

    /// Which software this is, from the owner the listing names or the port it answers on.
    static func software(ownedBy owner: String?, port: Int?) -> String? {
        switch owner?.lowercased() {
        case "llama-swap": return "llama-swap"
        case "library", "ollama": return "Ollama"
        case "vllm": return "vLLM"
        case "llamacpp", "llama.cpp": return "llama.cpp"
        case "organization_owner", "lmstudio", "lm studio": return "LM Studio"
        default: break
        }
        switch port {
        case 11434: return "Ollama"
        case 8081: return "llama-swap"
        case 8080: return "llama.cpp"
        case 1234: return "LM Studio"
        case 8000: return "vLLM"
        default: return nil
        }
    }
}

/// Where a helper might be, and what it is. Nothing here is configured by hand unless the person
/// wants it to be: the ports are the ones these servers actually use, and the host is the machine
/// already painting, because that is the box with the card in it.
public enum ImageGenHelperFinder {
    /// Ollama, llama-swap, llama.cpp, LM Studio, vLLM — in the order a box is likely to run them.
    public static let ports = [11434, 8081, 8080, 1234, 8000]

    /// Every address worth asking, the painting machine first and this device second.
    public static func candidates(near endpoint: ImageGenEndpoint?) -> [String] {
        var hosts: [String] = []
        if let endpoint { hosts.append(endpoint.host) }
        for local in ["127.0.0.1"] where !hosts.contains(local) { hosts.append(local) }
        return hosts.flatMap { host in ports.map { "http://\(host):\($0)" } }
    }

    /// Asks every candidate at once what it has and answers with each that answered, in the
    /// candidates' own order. A machine that is not there costs one short timeout, and every
    /// timeout runs beside the others rather than after them, so the whole sweep is one wait.
    public static func survey(
        near endpoint: ImageGenEndpoint?, session: URLSession = .shared
    ) async -> [ImageGenHelperServer] {
        let addresses = candidates(near: endpoint)
        let answered = await withTaskGroup(of: (Int, ImageGenHelperServer?).self) { group in
            for (index, address) in addresses.enumerated() {
                group.addTask { (index, await Self.server(at: address, session: session)) }
            }
            var found: [(Int, ImageGenHelperServer)] = []
            for await (index, server) in group {
                if let server, !server.models.isEmpty { found.append((index, server)) }
            }
            return found.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        return answered
    }

    /// The first machine that answers, for a caller that wants one helper rather than a menu.
    public static func find(
        near endpoint: ImageGenEndpoint?, session: URLSession = .shared
    ) async -> (address: String, models: [String])? {
        guard let first = await survey(near: endpoint, session: session).first else { return nil }
        return (first.address, first.models.map(\.id))
    }

    /// The model names an endpoint offers, as it lists them.
    public static func models(at address: String, session: URLSession = .shared) async -> [String] {
        await server(at: address, session: session)?.models.map(\.id) ?? []
    }

    /// Everything one endpoint says about itself: its models with their names and loaded marks,
    /// and which software it is. Nil when nothing answered.
    public static func server(
        at address: String, session: URLSession = .shared
    ) async -> ImageGenHelperServer? {
        let base = address.hasSuffix("/") ? String(address.dropLast()) : address
        guard let url = URL(string: base + "/v1/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return read(listing: data, address: base)
    }

    /// Reads a `/v1/models` body. Public so a client's selftest can pin the shapes llama-swap
    /// and Ollama actually send.
    public static func read(listing data: Data, address: String) -> ImageGenHelperServer? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = object["data"] as? [[String: Any]]
        else { return nil }
        let models = list.compactMap(ImageGenHelperModel.read)
        let owner = list.compactMap { $0["owned_by"] as? String }.first
        let port = URLComponents(string: address)?.port
        return ImageGenHelperServer(
            address: address, models: models,
            software: ImageGenHelperServer.software(ownedBy: owner, port: port))
    }

    /// Which of the offered models to try first. The paragraph is judged on what it says, so a
    /// bigger writer is a better default than a faster one: an instruct model in the twenty- to
    /// forty-billion class writes a frame with every corner filled, the four-billion class writes
    /// a serviceable one in a second and a half, and a two-billion one often answers with nothing
    /// at all. A model already in memory wins a tie, because it answers now; a model over forty
    /// billion is a minute's load for one paragraph, and a thinking model spends its budget
    /// thinking.
    public static func preferred(among models: [ImageGenHelperModel]) -> ImageGenHelperModel? {
        var best: (ImageGenHelperModel, Int)?
        for model in models {
            let worth = score(model)
            if let held = best, held.1 >= worth { continue }
            best = (model, worth)
        }
        return best?.0
    }

    public static func preferred(amongNames models: [String]) -> String? {
        preferred(among: models.map { ImageGenHelperModel(id: $0) })?.id
    }

    /// The first choice across every machine that answered, in the machines' own order.
    public static func preferred(across servers: [ImageGenHelperServer]) -> ImageGenHelper? {
        var best: (ImageGenHelper, Int)?
        for server in servers {
            for model in server.models {
                let worth = score(model)
                if let held = best, held.1 >= worth { continue }
                best = (ImageGenHelper(address: server.address, model: model), worth)
            }
        }
        return best?.0
    }

    static func score(_ name: String) -> Int {
        score(ImageGenHelperModel(id: name))
    }

    static func score(_ model: ImageGenHelperModel) -> Int {
        let name = (model.label + " " + model.id).lowercased()
        var score = 0
        for stranger in ["embed", "rerank", "whisper", "tts", "clip", "vae", "diffusion"]
        where name.contains(stranger) {
            return -100
        }
        if name.contains("instruct") || name.contains("chat") { score += 3 }
        if name.contains("thinking") || name.contains("reason") { score -= 6 }
        if let billions = model.billions {
            switch billions {
            case ..<1.5: score -= 4
            case ..<3: score += 0
            case ..<6: score += 4
            case ..<14: score += 6
            case ..<40: score += 12
            default: score += 3
            }
        }
        if model.loaded == true { score += 2 }
        return score
    }
}

/// One rewrite, asked and read back. The failure cases are all sentences rather than codes,
/// because this runs behind a chip and whatever goes wrong has to fit beside it.
public struct ImageGenEnhancer: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case unreachable
        case refused(String)
        case unreadable
        case cancelled

        public var reason: String {
            switch self {
            case .unreachable: return Localized.text("The prompt helper is not answering")
            case .refused(let detail): return detail
            case .unreadable:
                return Localized.text("The prompt helper answered with something unreadable")
            case .cancelled: return Localized.text("Rewrite stopped")
            }
        }
    }

    public let helper: ImageGenHelper
    private let session: URLSession

    public init(helper: ImageGenHelper, session: URLSession = .shared) {
        self.helper = helper
        self.session = session
    }

    /// The rules the helper writes to, which are Qwen's own cut to one turn. They live beside
    /// ``ImageGenBrief`` so the studio teaches exactly what the helper writes.
    public static var systemPrompt: String { ImageGenBrief.expansionSystem }

    /// Rewrites one brief and hands back the whole answer at once: the paragraph and the shape
    /// it wants, which is a suggestion the caller may take or leave.
    public func enhance(
        _ brief: String, context: ImageGenRewriteContext = ImageGenRewriteContext()
    ) async throws -> (prompt: String, aspect: ImageGenAspect?) {
        try await stream(brief, context: context, onText: { _ in })
    }

    /// Rewrites one brief and reports the paragraph as it is written. `onText` is handed the
    /// whole paragraph so far, decoded out of the JSON the model is streaming, each time a
    /// token lands; the return value is the finished reading, shape included.
    public func stream(
        _ brief: String, context: ImageGenRewriteContext = ImageGenRewriteContext(),
        onText: @escaping @Sendable (String) -> Void
    ) async throws -> (prompt: String, aspect: ImageGenAspect?) {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.unreadable }
        guard let url = URL(string: helper.address + "/v1/chat/completions") else {
            throw Failure.unreachable
        }
        let body: [String: Any] = [
            "model": helper.model,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": ImageGenBrief.expansionAsk(trimmed, context: context)],
            ],
            "temperature": 0.7,
            "max_tokens": 1600,
            "stream": true,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        var answer = ""
        var shown = ""
        for try await piece in ChatCompletionStream.open(request, session: session) {
            answer += piece
            let partial = ImageGenBrief.partialExpansion(answer)
            if partial != shown {
                shown = partial
                onText(partial)
            }
        }
        guard let read = ImageGenBrief.readExpansion(answer) else {
            let plain = ImageGenBrief.stripThinking(answer)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard ImageGenBrief.words(in: plain) >= ImageGenBrief.thinWordCount else {
                throw Failure.unreadable
            }
            return (plain, nil)
        }
        return read
    }
}

/// What the helper is told beside the brief: which engine paints, whether the shape is already
/// decided, how many pictures the words address, what to keep out of the frame, and — for a
/// second pass — what to change about the paragraph it wrote last time.
public struct ImageGenRewriteContext: Sendable, Equatable {
    public var engine: ImageGenEngine
    /// The shape the person chose by hand, which the helper must keep. Nil lets it choose.
    public var aspect: ImageGenAspect?
    public var referenceCount: Int
    public var negative: String
    /// What to change, when the person is asking for a revision rather than a first draft.
    public var instruction: String?
    /// The paragraph a revision starts from.
    public var previous: String?

    public init(
        engine: ImageGenEngine = .quality, aspect: ImageGenAspect? = nil, referenceCount: Int = 0,
        negative: String = "", instruction: String? = nil, previous: String? = nil
    ) {
        self.engine = engine
        self.aspect = aspect
        self.referenceCount = referenceCount
        self.negative = negative
        self.instruction = instruction
        self.previous = previous
    }

    public var isRevision: Bool {
        guard let instruction, let previous else { return false }
        return !instruction.trimmingCharacters(in: .whitespaces).isEmpty
            && !previous.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// The streamed half of an OpenAI-shaped chat completion, read as it arrives. A delegate rather
/// than `URLSession.bytes`, because the delegate road is the one every Foundation has. An
/// endpoint that ignores `stream` and answers whole is read whole at the end, so a server that
/// never learned to stream still answers.
final class ChatCompletionStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let lock = NSLock()
    private var status: Int?
    private var streaming = false
    private var pending = Data()
    private var whole = Data()
    private var finished = false

    private init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    static func open(_ request: URLRequest, session base: URLSession) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let reader = ChatCompletionStream(continuation: continuation)
            let session = URLSession(
                configuration: base.configuration, delegate: reader, delegateQueue: nil)
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                session.finishTasksAndInvalidate()
            }
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let http = response as? HTTPURLResponse
        status = http?.statusCode
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        streaming = type.contains("text/event-stream")
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard status == 200, streaming else {
            whole.append(data)
            return
        }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            handle(line: String(decoding: line, as: UTF8.self))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            continuation.finish(
                throwing: cancelled
                    ? ImageGenEnhancer.Failure.cancelled : ImageGenEnhancer.Failure.unreachable)
            return
        }
        guard status == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: whole)) as? [String: Any]
            let message = (detail?["error"] as? [String: Any])?["message"] as? String
            continuation.finish(
                throwing: ImageGenEnhancer.Failure.refused(
                    message ?? Localized.text("The prompt helper refused the request")))
            return
        }
        if !streaming {
            if let text = Self.wholeContent(whole) {
                continuation.yield(text)
                continuation.finish()
            } else {
                continuation.finish(throwing: ImageGenEnhancer.Failure.unreadable)
            }
            return
        }
        if !pending.isEmpty { handle(line: String(decoding: pending, as: UTF8.self)) }
        continuation.finish()
    }

    private func handle(line raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", !payload.isEmpty else { return }
        guard let data = payload.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let delta = choices.first?["delta"] as? [String: Any],
            let content = delta["content"] as? String, !content.isEmpty
        else { return }
        continuation.yield(content)
    }

    private static func wholeContent(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String
        else { return nil }
        return text
    }
}
