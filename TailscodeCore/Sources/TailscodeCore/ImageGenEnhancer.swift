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
/// A four-billion-parameter instruct model does this in about a second and a half, which is why
/// the helper is offered rather than a nineteen-gigabyte rewriter nobody asked to download.
public struct ImageGenHelper: Sendable, Equatable, Codable {
    /// Base address of the OpenAI-shaped API, e.g. `http://127.0.0.1:8081`.
    public var address: String
    /// Which model answers. The endpoint's own name for it, as `/v1/models` lists it.
    public var model: String
    /// Whether the studio may use it. A helper is remembered even while it is off, so turning it
    /// back on costs no setup.
    public var enabled: Bool

    public init(address: String, model: String, enabled: Bool = true) {
        self.address = address.hasSuffix("/") ? String(address.dropLast()) : address
        self.model = model
        self.enabled = enabled
    }

    public var host: String { URLComponents(string: address)?.host ?? address }

    public var displayHost: String {
        guard let parts = URLComponents(string: address), let host = parts.host else {
            return address
        }
        guard let port = parts.port else { return host }
        return "\(host):\(port)"
    }

    /// What the chip says: the model, short enough to sit beside the other decisions.
    public var chip: String {
        let name = model.split(separator: ":").first.map(String.init) ?? model
        return name.count > 18 ? String(name.prefix(16)) + "…" : name
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

    /// Asks each candidate what models it has, and answers with the first that answers. A machine
    /// that is not there costs one short timeout, not a stall: the whole sweep is bounded.
    public static func find(
        near endpoint: ImageGenEndpoint?, session: URLSession = .shared
    ) async -> (address: String, models: [String])? {
        for address in candidates(near: endpoint) {
            let models = await Self.models(at: address, session: session)
            if !models.isEmpty { return (address, models) }
        }
        return nil
    }

    /// The model names an endpoint offers, newest-looking first as it lists them.
    public static func models(at address: String, session: URLSession = .shared) async -> [String] {
        guard let url = URL(string: address.hasSuffix("/") ? address + "v1/models" : address + "/v1/models")
        else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = object["data"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0["id"] as? String }
    }

    /// Which of the offered models to try first: an instruct model in the four-billion class is
    /// the measured sweet spot — it writes the paragraph in about a second and a half, where a
    /// two-billion one often answers with nothing at all.
    public static func preferred(among models: [String]) -> String? {
        let ranked = models.sorted { left, right in
            score(left) > score(right)
        }
        return ranked.first
    }

    static func score(_ model: String) -> Int {
        let name = model.lowercased()
        var score = 0
        if name.contains("instruct") || name.contains("chat") { score += 3 }
        if name.contains("thinking") || name.contains("reason") { score -= 4 }
        if name.contains("embed") || name.contains("rerank") || name.contains("whisper") {
            score -= 20
        }
        for (needle, worth) in [("4b", 4), ("7b", 3), ("8b", 3), ("3b", 2), ("2b", 1), ("1b", -1)] {
            if name.contains(needle) { score += worth }
        }
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

        public var reason: String {
            switch self {
            case .unreachable: return Localized.text("The prompt helper is not answering")
            case .refused(let detail): return detail
            case .unreadable:
                return Localized.text("The prompt helper answered with something unreadable")
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

    /// Rewrites one brief. The answer carries the paragraph and the shape it wants, and the shape
    /// is a suggestion the caller may take or leave — a person who has chosen 21:9 by hand has
    /// chosen it.
    public func enhance(_ brief: String) async throws -> (prompt: String, aspect: ImageGenAspect?) {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.unreadable }
        guard let url = URL(string: helper.address + "/v1/chat/completions") else {
            throw Failure.unreachable
        }
        let body: [String: Any] = [
            "model": helper.model,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": trimmed],
            ],
            "temperature": 0.7,
            "max_tokens": 1600,
            "stream": false,
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        guard http.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = detail?["error"] as? [String: Any]
            throw Failure.refused(
                (error?["message"] as? String)
                    ?? Localized.text("The prompt helper refused the request"))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String
        else { throw Failure.unreadable }
        guard let read = ImageGenBrief.readExpansion(text) else {
            // A model that ignored the JSON but wrote a real description is still useful: the
            // paragraph is the thing, and a shape it never named is one the chips already hold.
            let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ImageGenBrief.words(in: plain) >= ImageGenBrief.thinWordCount else {
                throw Failure.unreadable
            }
            return (plain, nil)
        }
        return read
    }
}
