import Foundation

/// The opt-in way a tile's words get better: a model the person runs themselves says the few
/// commands the built-in rules could not read (`AgentPlain`, `PlainLine.rewritable`). Toolkit-free
/// and transport-free: this decides where a request may go, what may be sent, what is asked and what
/// a reply must look like to be shown. Nothing here makes a request.
///
/// What it never does: it is never asked about an approval, which keeps its command whole beside
/// the rules' own lead; it never sees a secret it can be kept from; and it never leaves the machine
/// or the tailnet.
public enum PlainModel {
    public static let longestReply = 72
    public static let fallback = "Running a command"

    /// The instruction the model is given. Fixed, so a person can read exactly what is asked.
    public static let systemPrompt =
        "You rewrite one shell command or tool name as a single short line of plain English for someone who does not program. Use 3 to 9 words. Start with a verb ending in -ing. Say what it does, never how. No quotes, no code, no file paths, no punctuation at the end. If you are not sure, answer exactly: Running a command"

    /// Where a request may go: this machine, or a private network the person already trusts. Anything
    /// else, credentials in the address or a plain typo gives nil, so a model is never reached by
    /// accident and a command never goes to a service on the internet.
    public static func endpoint(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let host = parts.host?.lowercased(), !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            isPrivate(host: host)
        else { return nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
    }

    static func isPrivate(host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare == "localhost" || bare.hasSuffix(".localhost") || bare.hasSuffix(".local")
            || bare.hasSuffix(".ts.net")
        {
            return true
        }
        if bare.contains(":") { return isPrivate(v6: bare) }
        let octets = bare.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }),
            bare.split(separator: ".").count == 4
        else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    private static func isPrivate(v6 host: String) -> Bool {
        host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
    }

    private static let secretWords = ["token", "key", "secret", "pass", "auth", "bearer", "credential", "cookie", "session"]

    /// The command with what looks like a secret taken out, because a command line carries them.
    /// Values after `NAME=` where the name reads as a secret, header values, `--token x`
    /// style flags, passwords in an address and any long unbroken run of letters and digits.
    public static func redact(_ raw: String) -> String {
        var text = String(raw.prefix(400))
        let patterns: [(String, String)] = [
            ("(?i)(://[^/\\s:@]+:)[^@\\s/]+(@)", "$1…$2"),
            ("(?i)(authorization:\\s*)(bearer\\s+|basic\\s+|token\\s+)?[^\\s'\"]+", "$1$2…"),
            ("(?i)(\\b[A-Za-z0-9_]*(?:\(secretWords.joined(separator: "|")))[A-Za-z0-9_]*=)(\"[^\"]*\"|'[^']*'|[^\\s]+)", "$1…"),
            ("(?i)(--?[A-Za-z-]*(?:\(secretWords.joined(separator: "|")))[A-Za-z-]*[=\\s]+)(\"[^\"]*\"|'[^']*'|[^\\s-][^\\s]*)", "$1…"),
            ("\\b[A-Za-z0-9+/_=-]{28,}\\b", "…"),
        ]
        for (pattern, template) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            text = expression.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        return text
    }

    /// The JSON body of a chat completion asking for one line about `raw`, redacted.
    public static func request(model: String, raw: String) -> Data {
        let body: [String: Any] = [
            "model": model, "stream": false, "temperature": 0.1, "max_tokens": 40,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": redact(raw)],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// The one line a reply may show, or nil when it is not fit to: more than a line, longer than
    /// seventy-two characters, empty, a refusal to commit (the fixed fallback) or something that
    /// still looks like a command.
    public static func reply(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choice = (object["choices"] as? [[String: Any]])?.first,
            let message = choice["message"] as? [String: Any], let content = message["content"] as? String
        else { return nil }
        return sanitize(content)
    }

    static func sanitize(_ content: String) -> String? {
        var line = content.replacingOccurrences(of: "<think>", with: "")
        if let end = line.range(of: "</think>") { line = String(line[end.upperBound...]) }
        line = line.split(whereSeparator: \.isNewline).map(String.init).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let noise = CharacterSet(charactersIn: "\"'`*_#>-• \t.")
        line = line.trimmingCharacters(in: noise)
        line = line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !line.isEmpty, line.count <= longestReply, line.lowercased() != fallback.lowercased() else { return nil }
        let codeLike = line.contains("&&") || line.contains("||") || line.contains("$(") || line.contains("`")
            || line.contains(" -") || line.contains("/")
        guard !codeLike, line.split(separator: " ").count >= 2 else { return nil }
        return line
    }
}
