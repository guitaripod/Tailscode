import CodingAgentKit
import CodingAgentKitApple
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// One model one server offers, as a survey found it.
public struct YourModelCandidate: Sendable, Equatable, Identifiable {
    /// The server's base address, e.g. `http://127.0.0.1:8081`.
    public let address: String
    public let model: String
    public let name: String?
    /// The server's own description, which llama-swap fills with the model's full descriptor.
    public let detail: String?
    public let parameters: Double?
    /// Whether it is in memory now; nil where the server does not say.
    public let running: Bool?
    /// Whether the server keeps it in memory for good (llama-swap's `ttl: 0`): the model a person
    /// keeps warm is the one every app of theirs is pointed at.
    public let pinned: Bool
    public let software: String?
    public let machine: String

    public init(
        address: String, model: String, name: String? = nil, detail: String? = nil,
        parameters: Double? = nil, running: Bool? = nil, pinned: Bool = false,
        software: String? = nil, machine: String
    ) {
        self.address = address.hasSuffix("/") ? String(address.dropLast()) : address
        self.model = model
        self.name = name.flatMap { $0.isEmpty || $0 == model ? nil : $0 }
        self.detail = detail.flatMap { $0.isEmpty ? nil : $0 }
        self.parameters = parameters ?? PlainModelScout.parameters(in: [model, name ?? "", detail ?? ""])
        self.running = running
        self.pinned = pinned
        self.software = software
        self.machine = machine
    }

    public var id: String { address + "|" + model }
    public var label: String { name ?? model }

    /// What this model is filed as once chosen.
    public func helper(enabled: Bool = true, chosenByHand: Bool) -> ImageGenHelper {
        ImageGenHelper(
            address: address, model: model, label: name, enabled: enabled, chosenByHand: chosenByHand)
    }

    var scoutModel: PlainModelScout.Model {
        PlainModelScout.Model(
            id: model, name: name ?? "", detail: detail ?? "", parameters: parameters, running: running,
            kind: .other, base: URL(string: address) ?? URL(fileURLWithPath: "/"))
    }
}

/// One model server that answered, on one machine.
public struct YourModelServer: Sendable, Equatable, Identifiable {
    public let address: String
    public let software: String?
    public let machine: String
    public let models: [YourModelCandidate]

    public var id: String { address }

    /// The heading a list gives it: the machine, then the software where it is known.
    public var heading: String {
        guard let software else { return machine }
        return machine + " · " + software
    }
}

/// Finding the models a person runs without being told where: every port a model server listens
/// on, on this device, on each machine the person's agents run on and on the machine that paints,
/// all asked at once so the whole look is one short wait. What each server says it has is read
/// with what it says is in memory, which is what decides the default.
public enum YourModelSurvey {
    /// Ollama, llama-swap, llama.cpp, LM Studio, vLLM, SGLang, Lemonade, KoboldCpp and Jan.
    public static let ports = [11434, 8081, 8080, 1234, 8000, 30000, 13305, 5001, 1337]

    /// One machine to look on, and what a person calls it.
    public struct Place: Sendable, Equatable {
        public let host: String
        public let machine: String

        public init(host: String, machine: String) {
            self.host = host
            self.machine = machine
        }
    }

    /// The machines worth looking on, each once: this device first on a desk, where a model is
    /// most often run, then every server the person added, then the machine that paints.
    public static func places(
        profiles: [ConnectionProfile], painting: ImageGenEndpoint?, thisDevice: Bool
    ) -> [Place] {
        var hosts: [String] = []
        if thisDevice { hosts.append("127.0.0.1") }
        hosts += profiles.compactMap { $0.baseURL.host }
        if let painting { hosts.append(painting.host) }
        var seen = Set<String>()
        return hosts.compactMap { host in
            let key = host.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return Place(host: host, machine: machineName(host))
        }
    }

    /// What a person calls the machine at a host: this device for a loopback address, the first
    /// label of a name (`arch` for `arch.tail1234.ts.net`), and an address as it is.
    public static func machineName(_ host: String) -> String {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if bare == "localhost" || bare == "::1" || bare.hasPrefix("127.") {
            return YourModelWords.thisDevice
        }
        if bare.split(separator: ".").allSatisfy({ Int($0) != nil }) || bare.contains(":") {
            return host
        }
        return String(host.split(separator: ".").first ?? Substring(host))
    }

    /// Every server that answered, in the places' order and each port's, with the same server
    /// reached by two names (this device and its tailnet name) kept once, under the first.
    public static func survey(
        _ places: [Place], session: URLSession = .shared
    ) async -> [YourModelServer] {
        let doors = places.flatMap { place in ports.map { (place, $0) } }
        let found = await withTaskGroup(of: (Int, YourModelServer?).self) { group in
            for (index, door) in doors.enumerated() {
                group.addTask {
                    (index, await server(host: door.0.host, port: door.1, machine: door.0.machine, session: session))
                }
            }
            var answered: [(Int, YourModelServer)] = []
            for await (index, server) in group {
                if let server, !server.models.isEmpty { answered.append((index, server)) }
            }
            return answered.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return deduplicated(found)
    }

    /// The same server reached twice lists the same models on the same port.
    static func deduplicated(_ servers: [YourModelServer]) -> [YourModelServer] {
        var seen = Set<String>()
        return servers.filter { server in
            let port = URLComponents(string: server.address)?.port ?? 0
            let print = "\(port)|" + server.models.map(\.model).sorted().joined(separator: ",")
            return seen.insert(print).inserted
        }
    }

    /// Everything one door says: its list, and the document that says what is in memory for the
    /// servers that keep one (llama-swap, Ollama, LM Studio).
    static func server(
        host: String, port: Int, machine: String, session: URLSession
    ) async -> YourModelServer? {
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let base = "http://\(bracketed):\(port)"
        guard let listing = await fetch(base + "/v1/models", session: session) else { return nil }
        let software = software(of: listing, port: port)
        var memory = Memory()
        switch software {
        case PlainModelScout.Kind.llamaSwap.title:
            if let data = await fetch(base + "/running", session: session) {
                memory = Memory(swap: data)
            }
        case PlainModelScout.Kind.ollama.title:
            if let data = await fetch(base + "/api/ps", session: session) {
                memory = Memory(ollama: data)
            }
        case PlainModelScout.Kind.lmStudio.title:
            if let data = await fetch(base + "/api/v0/models", session: session) {
                memory = Memory(lmStudio: data)
            }
        default:
            break
        }
        return read(listing: listing, address: base, machine: machine, software: software, memory: memory)
    }

    /// What a server says is in memory, read from its own document.
    public struct Memory: Sendable, Equatable {
        public var running: Set<String>?
        public var pinned: Set<String> = []
        public var embedding: Set<String> = []

        public init(running: Set<String>? = nil, pinned: Set<String> = [], embedding: Set<String> = []) {
            self.running = running
            self.pinned = pinned
            self.embedding = embedding
        }

        /// llama-swap's `/running`: what is up, and what it keeps up for good (`ttl` 0).
        public init(swap data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let list = object["running"] as? [[String: Any]]
            else { return }
            running = Set(list.compactMap { $0["model"] as? String })
            pinned = Set(list.compactMap { entry in
                guard let ttl = (entry["ttl"] as? NSNumber)?.intValue, ttl == 0 else { return nil }
                return entry["model"] as? String
            })
        }

        /// Ollama's `/api/ps`.
        public init(ollama data: Data) {
            guard let loaded = PlainModelScout.ollamaModels(data) else { return }
            running = Set(loaded.map(\.name))
        }

        /// LM Studio's `/api/v0/models`.
        public init(lmStudio data: Data) {
            guard let states = PlainModelScout.lmStudioStates(data) else { return }
            running = Set(states.filter(\.value.loaded).map(\.key))
            embedding = Set(states.filter(\.value.embedding).map(\.key))
        }
    }

    /// Which software answered, from the owner its list names or the port it answers on.
    static func software(of listing: Data, port: Int) -> String? {
        let owner = (try? JSONSerialization.jsonObject(with: listing) as? [String: Any])
            .flatMap { ($0["data"] as? [[String: Any]])?.first?["owned_by"] as? String }?.lowercased()
        switch owner {
        case "llama-swap": return PlainModelScout.Kind.llamaSwap.title
        case "library", "ollama": return PlainModelScout.Kind.ollama.title
        case "organization_owner", "lmstudio": return PlainModelScout.Kind.lmStudio.title
        default: break
        }
        if let kind = PlainModelScout.kind(ofList: listing) { return kind.title }
        switch port {
        case 11434: return PlainModelScout.Kind.ollama.title
        case 8081: return PlainModelScout.Kind.llamaSwap.title
        case 1234: return PlainModelScout.Kind.lmStudio.title
        case 8080: return PlainModelScout.Kind.llamaCpp.title
        case 8000: return PlainModelScout.Kind.vllm.title
        case 30000: return PlainModelScout.Kind.sglang.title
        default: return nil
        }
    }

    /// Reads a `/v1/models` body with what is known of memory. A server that runs only what it
    /// lists (llama.cpp, vLLM, SGLang) has everything it lists in memory. Public so a client's
    /// selftest can pin the shapes the servers send.
    public static func read(
        listing data: Data, address: String, machine: String, software: String?, memory: Memory = Memory()
    ) -> YourModelServer? {
        let base = URL(string: address) ?? URL(fileURLWithPath: "/")
        let listed = PlainModelScout.models(fromList: data, kind: .other, base: base)
        guard !listed.isEmpty else { return nil }
        let servesWhatItLists = [
            PlainModelScout.Kind.llamaCpp.title, PlainModelScout.Kind.vllm.title,
            PlainModelScout.Kind.sglang.title,
        ].contains(software ?? "")
        let models = listed.compactMap { model -> YourModelCandidate? in
            guard !memory.embedding.contains(model.id) else { return nil }
            var running = model.running
            if let known = memory.running { running = known.contains(model.id) || running == true }
            if running == nil, servesWhatItLists { running = true }
            return YourModelCandidate(
                address: address, model: model.id, name: model.name, detail: model.detail,
                parameters: model.parameters, running: running, pinned: memory.pinned.contains(model.id),
                software: software, machine: machine)
        }
        return YourModelServer(address: address, software: software, machine: machine, models: models)
    }

    private static func fetch(_ address: String, session: URLSession) async -> Data? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }
}

/// Which model is the default: the one the person already keeps warm. A model that is running
/// answers at once and costs nothing more to ask, and the one a server keeps up for good is the
/// one the person points everything else at; among running models the larger writes the better
/// paragraph. With nothing running, the best writer that would have to start, which is a
/// mid-sized instruct model. Embedding, speech and picture models never; a model that thinks
/// first only when nothing else will do.
public enum YourModelPick {
    public static func score(_ candidate: YourModelCandidate) -> Double? {
        let traits = PlainModelScout.traits(candidate.scoutModel)
        guard !traits.embeds, !traits.listens else { return nil }
        var score: Double
        if candidate.running == true {
            score = 1000 + (candidate.pinned ? 300 : 0) + min(candidate.parameters ?? 8, 400) / 4
        } else {
            let helper = ImageGenHelperModel(
                id: candidate.model, name: candidate.name, loaded: candidate.running)
            score = Double(ImageGenHelperFinder.score(helper)) * 10
            if candidate.software == PlainModelScout.Kind.llamaSwap.title { score -= 20 }
        }
        if traits.reasons { score -= 400 }
        if !traits.known { score -= 5 }
        return score
    }

    /// Every model worth using, best first; equal scores keep the servers' order.
    public static func ranked(_ servers: [YourModelServer]) -> [YourModelCandidate] {
        var scored: [(YourModelCandidate, Double, Int)] = []
        for (index, candidate) in servers.flatMap(\.models).enumerated() {
            if let score = score(candidate) { scored.append((candidate, score, index)) }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
        return scored.map(\.0)
    }

    public static func best(_ servers: [YourModelServer]) -> YourModelCandidate? {
        ranked(servers).first
    }

    /// Whether the model may be asked without the person pressing anything: never one a server
    /// would have to load by stopping another (llama-swap swaps), and never one the survey did
    /// not find, since asking a server for a model it does not hold can make it load one.
    public static func asksOnItsOwn(_ candidate: YourModelCandidate?) -> Bool {
        guard let candidate else { return false }
        return !(candidate.running == false && candidate.software == PlainModelScout.Kind.llamaSwap.title)
    }

    /// Whether a better find takes the filed model's place: only a model the app filed itself,
    /// never one the person picked, and only for the default the survey would choose now.
    public static func replaces(_ filed: ImageGenHelper?, with best: YourModelCandidate?) -> Bool {
        guard let best else { return false }
        guard let filed else { return true }
        guard filed.chosenByHand != true else { return false }
        return filed.address != best.address || filed.model != best.model
    }

    /// A model to suggest in place of the filed one when the filed one is not in memory and another
    /// is: the default the survey would choose, offered with one press rather than swapped in, since
    /// the filed one was the person's own pick.
    public static func suggestion(
        for filed: ImageGenHelper?, in servers: [YourModelServer]
    ) -> YourModelCandidate? {
        guard let filed, let best = best(servers), best.running == true else { return nil }
        guard best.address != filed.address || best.model != filed.model else { return nil }
        return find(filed, in: servers)?.running == true ? nil : best
    }

    /// The filed model as the survey sees it now, when it is still there.
    public static func find(_ helper: ImageGenHelper?, in servers: [YourModelServer]) -> YourModelCandidate? {
        guard let helper else { return nil }
        return servers.flatMap(\.models).first { $0.address == helper.address && $0.model == helper.model }
    }
}

/// What asking the model once showed: how long the first word took, how fast the rest came and
/// what it wrote.
public struct YourModelProof: Sendable, Equatable {
    public let firstWord: TimeInterval
    public let perSecond: Double?
    public let text: String

    public init(firstWord: TimeInterval, perSecond: Double?, text: String) {
        self.firstWord = firstWord
        self.perSecond = perSecond
        self.text = text
    }

    /// "First word in 0.21 s · 148 tokens a second".
    public var line: String {
        let first = YourModelWords.seconds(firstWord)
        guard let perSecond else { return Localized.text("First word in %@", first) }
        return Localized.text("First word in %@ · %d tokens a second", first, Int(perSecond.rounded()))
    }
}

/// Asking the model one fixed question and timing the answer as it streams. The question is
/// short and fixed so the numbers compare from one model to the next.
public enum YourModelProving {
    public static let system = "Answer in plain prose, two sentences, no lists and no preamble."
    public static let ask = "Describe a quiet harbour at first light."

    public static func prove(
        _ helper: ImageGenHelper, session: URLSession = .shared,
        onText: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> YourModelProof {
        guard let url = URL(string: helper.address + "/v1/chat/completions") else {
            throw ImageGenEnhancer.Failure.unreachable
        }
        let body: [String: Any] = [
            "model": helper.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": ask]],
            "temperature": 0.3, "max_tokens": 120, "stream": true,
            "stream_options": ["include_usage": true],
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let started = Date()
        var firstAt: Date?
        var pieces = 0
        var text = ""
        let counted = Counted()
        for try await piece in ChatCompletionStream.open(request, session: session, onUsage: { counted.tokens = $0 }) {
            text += piece
            let shown = ImageGenBrief.stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !shown.isEmpty else { continue }
            if firstAt == nil { firstAt = Date() }
            pieces += 1
            onText(shown)
        }
        let finished = Date()
        let written = ImageGenBrief.stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstAt, !written.isEmpty else { throw ImageGenEnhancer.Failure.unreadable }
        return YourModelProof(
            firstWord: firstAt.timeIntervalSince(started),
            perSecond: rate(pieces: counted.tokens ?? pieces, from: firstAt, to: finished), text: written)
    }

    private final class Counted: @unchecked Sendable {
        private let lock = NSLock()
        private var held: Int?
        var tokens: Int? {
            get { lock.withLock { held } }
            set { lock.withLock { held = newValue } }
        }
    }

    /// Tokens a second after the first: the server's own count when it reports one, since a server
    /// that decodes speculatively sends several tokens a chunk, otherwise one token a streamed piece.
    /// Too few to say is nil rather than a guess.
    static func rate(pieces: Int, from first: Date, to last: Date) -> Double? {
        let span = last.timeIntervalSince(first)
        guard pieces >= 8, span > 0.05 else { return nil }
        return Double(pieces - 1) / span
    }
}

/// The agent servers that already run the model, so it can be carried in the party and picked
/// for a chat like any other.
public enum YourModelAgents {
    public struct Offer: Sendable, Equatable {
        public let profileID: String
        public let server: String
        public let agent: String
        public let model: ModelInfo

        /// "Oh My Pi on arch": two servers on one machine are told apart by their agent.
        public var said: String { Localized.text("%@ on %@", agent, server) }
    }

    /// Each server whose remembered catalog lists the model by its id.
    public static func offers(of model: String, profiles: [ConnectionProfile]) -> [Offer] {
        let wanted = model.lowercased()
        return profiles.compactMap { profile in
            guard let info = ModelCatalogStore.cached(profile.id).first(where: { $0.id.lowercased() == wanted })
            else { return nil }
            return Offer(profileID: profile.id, server: profile.name, agent: profile.backend.displayName, model: info)
        }
    }

    public static func preset(_ offer: Offer) -> ModelPreset {
        ModelPreset(selection: offer.model.selection, effort: .server)
    }

    public static func isCarried(_ offer: Offer) -> Bool {
        ModelParty.presets().contains { $0.selection == offer.model.selection }
    }

    @discardableResult
    public static func carry(_ offer: Offer, name: String?) -> PartyPlacement {
        ModelParty.place(preset(offer), name: name)
    }
}

/// The ask an agent is handed when nothing answered: set up a small model on its machine.
public enum YourModelGetOne {
    public static var brief: String {
        Localized.text(
            "Set up a small local language model on this machine for Tailscode to use. First check whether a model server is already running here (Ollama on port 11434, llama-swap, llama.cpp, LM Studio or vLLM) and, if one is, tell me which models it has instead of installing anything. Otherwise install Ollama the way this system usually installs software, pull a current instruct model from its library that suits this machine's memory (about 4 billion parameters, or 12 to 14 billion with 24 GB of GPU memory or more), preferring one that answers without a thinking phase, check that http://127.0.0.1:11434/v1/models lists it, and tell me its name. Ask me before anything needs administrator rights."
        )
    }
}
