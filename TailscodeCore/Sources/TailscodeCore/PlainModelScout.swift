import Foundation

/// Finding a model for plain words without being told where one is: the model servers people run
/// on their own machine, what each one has and which of it is already running, and which model is
/// the one to ask. Toolkit-free and transport-free: a client fetches the few documents named here
/// from this machine and hands them over; nothing here makes a request.
///
/// The choice keeps to what is cheap and safe to ask: a small general model that is already
/// running, and never one that would have to be started by a server that may stop another model
/// to make room for it unless the person says so.
public enum PlainModelScout {
    /// The model servers looked for, by the port each listens on unless told otherwise.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case ollama, llamaSwap, lmStudio, llamaCpp, vllm, sglang, lemonade, kobold, other

        /// The name a person knows it by.
        public var title: String {
            switch self {
            case .ollama: return "Ollama"
            case .llamaSwap: return "llama-swap"
            case .lmStudio: return "LM Studio"
            case .llamaCpp: return "llama.cpp"
            case .vllm: return "vLLM"
            case .sglang: return "SGLang"
            case .lemonade: return "Lemonade"
            case .kobold: return "KoboldCpp"
            case .other: return Localized.text("A model server")
            }
        }

        /// Whether asking it for a model that is not running may stop another one to make room.
        /// llama-swap runs one model at a time unless its configuration groups them.
        public var mayStopAnother: Bool { self == .llamaSwap }
    }

    /// The ports looked at on this machine: Ollama, llama.cpp, llama-swap and LocalAI, LM Studio,
    /// vLLM and Lemonade, SGLang, Jan, KoboldCpp, text-generation-webui and TabbyAPI.
    public static let ports = [11434, 8080, 8081, 1234, 8000, 13305, 30000, 1337, 5001, 5000, 9292]

    /// One model a server offers, with what is known about it.
    public struct Model: Sendable, Equatable {
        public var id: String
        public var name: String
        public var detail: String
        public var parameters: Double?
        public var running: Bool?
        public var kind: Kind
        public var base: URL

        public init(
            id: String, name: String = "", detail: String = "", parameters: Double? = nil,
            running: Bool? = nil, kind: Kind, base: URL
        ) {
            self.id = id
            self.name = name
            self.detail = detail
            self.parameters = parameters ?? PlainModelScout.parameters(in: [id, name, detail])
            self.running = running
            self.kind = kind
            self.base = base
        }

        /// What a person reads: the server's own name for it when it has one.
        public var title: String { name.isEmpty ? id : name }

        var words: String { (id + " " + name + " " + detail).lowercased() }
    }

    /// The models a `/v1/models` list names, with the running state llama-swap, llama.cpp's router
    /// and KoboldCpp put on each entry and the size llama.cpp puts in its meta.
    public static func models(fromList data: Data, kind: Kind, base: URL) -> [Model] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = object["data"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let status = (entry["status"] as? [String: Any])?["value"] as? String
            let meta = entry["meta"] as? [String: Any]
            let count = (meta?["n_params"] as? NSNumber)?.doubleValue
            return Model(
                id: id, name: entry["name"] as? String ?? "", detail: entry["description"] as? String ?? "",
                parameters: count.map { $0 / 1e9 }, running: status.map { $0 == "loaded" || $0 == "ready" },
                kind: kind, base: base)
        }
    }

    /// Who a `/v1/models` list says it is from (`owned_by` of its first entry): llamacpp, koboldcpp,
    /// vllm, sglang, lemonade.
    public static func kind(ofList data: Data) -> Kind? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let owner = ((object["data"] as? [[String: Any]])?.first?["owned_by"] as? String)?.lowercased()
        else { return nil }
        switch owner {
        case "llamacpp": return .llamaCpp
        case "koboldcpp": return .kobold
        case "vllm": return .vllm
        case "sglang": return .sglang
        case "lemonade": return .lemonade
        default: return nil
        }
    }

    /// The ids llama-swap's `/running` says are up, or nil when the document is not llama-swap's.
    public static func swapRunning(_ data: Data) -> Set<String>? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let running = object["running"] as? [[String: Any]]
        else { return nil }
        return Set(running.compactMap { $0["model"] as? String })
    }

    /// Ollama's `/api/tags` (what it has) or `/api/ps` (what is loaded): name and parameter size.
    public static func ollamaModels(_ data: Data) -> [(name: String, parameters: Double?)]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = object["models"] as? [[String: Any]]
        else { return nil }
        return list.compactMap { entry in
            guard let name = (entry["name"] as? String) ?? (entry["model"] as? String) else { return nil }
            let size = ((entry["details"] as? [String: Any])?["parameter_size"] as? String).flatMap {
                parameters(in: [$0])
            }
            return (name, size)
        }
    }

    /// LM Studio's `/api/v0/models`: each id with whether it is loaded and whether it is an
    /// embedding model.
    public static func lmStudioStates(_ data: Data) -> [String: (loaded: Bool, embedding: Bool)]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = object["data"] as? [[String: Any]], list.contains(where: { $0["state"] != nil })
        else { return nil }
        var out: [String: (loaded: Bool, embedding: Bool)] = [:]
        for entry in list {
            guard let id = entry["id"] as? String else { continue }
            out[id] = ((entry["state"] as? String) == "loaded", (entry["type"] as? String) == "embeddings")
        }
        return out
    }

    /// The size a name or description says, in billions of parameters: `4B`, `1.7b`, `0.6B`, a
    /// mixture's total before its active count (`74B-A9B` is 74), Gemma's effective `E2B` as 2,
    /// and `7.6B` from Ollama.
    public static func parameters(in texts: [String]) -> Double? {
        let pattern = "(?<![a-z0-9.])(?:e)?([0-9]+(?:[._][0-9]+)?)\\s*b(?![a-z])"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        for text in texts where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in expression.matches(in: text, range: range) {
                guard let span = Range(match.range(at: 1), in: text) else { continue }
                let digits = text[span].replacingOccurrences(of: "_", with: ".")
                if let value = Double(digits), value > 0 { return value }
            }
        }
        return nil
    }

    /// What a model is for, read from its names.
    public struct Traits: Sendable, Equatable {
        public var reasons: Bool
        public var embeds: Bool
        public var listens: Bool
        public var sees: Bool
        public var instructed: Bool
        public var known: Bool
    }

    static let families = [
        "qwen", "llama", "gemma", "mistral", "ministral", "phi", "lfm", "granite", "smollm", "nemotron",
        "glm", "olmo", "deepseek", "hermes", "command", "falcon", "internlm", "exaone", "aya", "yi-",
        "gpt-oss", "seed", "minicpm", "ernie", "kimi", "hunyuan",
    ]

    public static func traits(_ model: Model) -> Traits {
        let words = model.words
        func has(_ any: [String]) -> Bool { any.contains { words.contains($0) } }
        return Traits(
            reasons: has(["thinking", "-think", " think", "reason", "-r1", " r1", "qwq"]),
            embeds: has(["embed", "rerank", "bge-", "e5-", "colbert", "nomic-embed", "minilm"]),
            listens: has(["whisper", "tts", "parakeet", "voxtral", "kokoro", "musicgen", "flux", "stable-diffusion"]),
            sees: has(["-vl", " vl", "vision", "llava", "mmproj"]),
            instructed: has(["instruct", "-it", " it ", "chat", "-it-"]),
            known: has(families))
    }

    /// How well a model suits one plain line, higher is better; nil for one that cannot write it at
    /// all. Running counts for most: a model already up answers at once and costs nothing more to
    /// ask, whatever its size, so among running models the larger writes the better line. A model
    /// that would have to be started should be small, a few billion parameters, and none should
    /// think first.
    public static func score(_ model: Model) -> Double? {
        let traits = traits(model)
        guard !traits.embeds, !traits.listens else { return nil }
        var score = 0.0
        if model.running == true {
            score = 100
            if let size = model.parameters { score += size < 1.2 ? -10 : (size < 3 ? 0 : 10) }
        } else if let size = model.parameters {
            switch size {
            case ..<1.2: score += 8
            case ..<10: score += 40 - 8 * abs(log2(size / 4))
            case ..<16: score += 12
            case ..<41: score -= 30
            default: score -= 60
            }
        }
        if traits.reasons { score -= 80 }
        if traits.sees { score -= 8 }
        if traits.instructed { score += 10 }
        score += traits.known ? 5 : -15
        if families.contains(where: model.id.lowercased().contains) { score += 3 }
        return score
    }

    /// What is chosen and how sure it is.
    public enum Verdict: Sendable, Equatable {
        /// Nothing on this machine answers like a model server.
        case none
        /// Use this model: it is running or its server starts it without stopping another.
        case use(Model)
        /// The best model is not running and its server may stop another one to start it: ask first.
        case ask(Model)
    }

    /// The models worth trying, best first, each with whether it may be used without asking.
    /// Models of equal score keep the order the servers listed them in.
    public static func ranked(_ models: [Model]) -> [(model: Model, asks: Bool)] {
        var scored: [(model: Model, score: Double, index: Int)] = []
        for (index, model) in models.enumerated() {
            if let score = score(model) { scored.append((model, score, index)) }
        }
        scored.sort { left, right in
            left.score != right.score ? left.score > right.score : left.index < right.index
        }
        return scored.map { entry in
            (entry.model, entry.model.running != true && entry.model.kind.mayStopAnother)
        }
    }

    /// The model to use, given the ones a test line was already refused by.
    public static func choose(_ models: [Model], refused: Set<String> = []) -> Verdict {
        guard let best = ranked(models).first(where: { !refused.contains(key($0.model)) }) else { return .none }
        return best.asks ? .ask(best.model) : .use(best.model)
    }

    /// The best model that can be asked now without starting anything that could stop another: one
    /// that is running, or on a server that never stops one model for another, one it has not said
    /// is stopped. Given the ones a test line was already refused by. This is what is asked when the
    /// person named no model, at the moment a line is wanted, so a model that comes and goes is used
    /// while it is there and the one that stays takes over when it is not.
    public static func bestReady(_ models: [Model], refused: Set<String> = []) -> Model? {
        ranked(models).map(\.model).first { model in
            !refused.contains(key(model))
                && (model.running == true || (model.running == nil && !model.kind.mayStopAnother))
        }
    }

    /// One model on one server, as a refusal remembers it.
    public static func key(_ model: Model) -> String { model.base.absoluteString + "|" + model.id }

    /// The line a model is asked for to prove it can do the job, and what its answer must look like:
    /// what `PlainModel.reply` accepts, starting with a word that ends in -ing.
    public static let trial = "git status --short"

    public static func passes(_ line: String?) -> Bool {
        guard let line, let first = line.split(separator: " ").first?.lowercased() else { return false }
        return first.hasSuffix("ing")
    }
}
