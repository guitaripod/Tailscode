import Foundation

/// An address written as prose is still an address. Agents paste bare URLs constantly — a published
/// page, a PR, a doc — and a transcript that renders one as grey text makes the reader retype it by
/// hand off a screen they cannot select on a phone. This finds the addresses inside a run of text so
/// every client can make them touchable, and it is deliberately conservative: a false link in the
/// middle of prose is worse than a missed one, so a match must carry a scheme or a `www.` host, must
/// have a dot inside its host, and gives back trailing punctuation that belongs to the sentence.
public enum Autolink: Sendable {
    public struct Span: Sendable, Equatable {
        /// Where the address sits in the text it was found in.
        public let range: Range<String.Index>
        /// The address to open, with a scheme filled in for a bare `www.` host.
        public let url: String
        /// The address exactly as it was written, which is what a client shows.
        public let text: String

        public init(range: Range<String.Index>, url: String, text: String) {
            self.range = range
            self.url = url
            self.text = text
        }
    }

    private static let schemes = ["https://", "http://"]
    private static let bareHostPrefix = "www."

    /// Characters an address may be built from. `&` and `;` are in the set so a query string
    /// survives being scanned after the text was escaped for markup — the entity comes back out the
    /// other side of the client's own unescaping.
    private static func isURLCharacter(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber { return true }
        return "-._~:/?#[]@!$&'()*+,;=%".contains(character)
    }

    /// Every address in the text, in the order they were written.
    public static func spans(in text: String) -> [Span] {
        guard text.contains("://") || text.contains(bareHostPrefix) else { return [] }
        var spans: [Span] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard let start = nextStart(in: text, from: index) else { break }
            var end = start.index
            while end < text.endIndex, isURLCharacter(text[end]) { end = text.index(after: end) }
            let trimmed = trimTrailing(in: text, from: start.index, to: end)
            let written = String(text[start.index..<trimmed])
            if isPlausible(written, scheme: start.hasScheme) {
                spans.append(
                    Span(
                        range: start.index..<trimmed,
                        url: start.hasScheme ? written : "https://" + written,
                        text: written))
                index = trimmed
            } else {
                index = text.index(after: start.index)
            }
        }
        return spans
    }

    /// Whether the text carries at least one address, without paying for the spans.
    public static func hasLink(_ text: String) -> Bool { !spans(in: text).isEmpty }

    private static func nextStart(in text: String, from: String.Index)
        -> (index: String.Index, hasScheme: Bool)?
    {
        var best: (index: String.Index, hasScheme: Bool)?
        for scheme in schemes {
            if let found = text.range(of: scheme, range: from..<text.endIndex),
                startsWord(text, at: found.lowerBound),
                best.map({ found.lowerBound < $0.index }) ?? true
            {
                best = (found.lowerBound, true)
            }
        }
        var search = from
        while let found = text.range(of: bareHostPrefix, range: search..<text.endIndex) {
            if startsWord(text, at: found.lowerBound) {
                if best.map({ found.lowerBound < $0.index }) ?? true {
                    best = (found.lowerBound, false)
                }
                break
            }
            search = found.upperBound
        }
        return best
    }

    /// An address begins where a word does. Without this, the tail of `mailto:you@www.example.com`
    /// or of an already-formed link would start a second one inside the first.
    private static func startsWord(_ text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        if previous.isLetter || previous.isNumber { return false }
        return !"-._~:/?#@&=%".contains(previous)
    }

    /// Punctuation at the end of a sentence is the sentence's, not the address's. A closing bracket
    /// is only kept when the address opened one, which is what keeps parenthesised references whole.
    private static func trimTrailing(in text: String, from start: String.Index, to end: String.Index)
        -> String.Index
    {
        var last = end
        while last > start {
            let previous = text.index(before: last)
            let character = text[previous]
            if character == ")" || character == "]" {
                let opener: Character = character == ")" ? "(" : "["
                let body = text[start..<last]
                if body.filter({ $0 == opener }).count >= body.filter({ $0 == character }).count {
                    break
                }
                last = previous
                continue
            }
            guard ".,;:!?'\"*_>".contains(character) else { break }
            last = previous
        }
        /// A trimmed `;` that ends an escaped entity belongs to the address, not to the prose.
        if text[start..<last].hasSuffix("&amp"), last < end, text[last] == ";" {
            last = text.index(after: last)
        }
        return last
    }

    private static func isPlausible(_ written: String, scheme: Bool) -> Bool {
        let host: Substring
        if scheme {
            guard let range = written.range(of: "://") else { return false }
            host = written[range.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        } else {
            host = written.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        }
        guard host.count >= 4, host.contains(".") else { return false }
        guard let tld = host.split(separator: ".").last, tld.count >= 2,
            tld.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return false }
        return true
    }
}

/// A page Claude published for this conversation. The CLI can render a result as a hosted page and
/// answers with nothing but its address, so the transcript's only evidence that a deliverable exists
/// is a URL in a sentence — this recognises one so a client can give it the affordance it deserves
/// instead of leaving it as grey prose. The page itself is private to the account that published it,
/// which is why opening one belongs to the browser the person is already signed in to rather than to
/// a webview with an empty cookie jar.
public struct ArtifactLink: Sendable, Equatable {
    public let id: String
    public let url: String

    public init(id: String, url: String) {
        self.id = id
        self.url = url
    }

    private static let markers = ["/code/artifact/", "/public/artifacts/"]

    public static func parse(_ url: String) -> ArtifactLink? {
        guard url.contains("claude.ai") else { return nil }
        for marker in markers {
            guard let range = url.range(of: marker) else { continue }
            let tail = url[range.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            guard tail.count >= 8 else { continue }
            return ArtifactLink(id: String(tail), url: url)
        }
        return nil
    }

    /// The shortest thing that still identifies which page this is, for a row that has no room for
    /// a whole identifier and no way to know the page's title without being signed in to fetch it.
    public var shortID: String { String(id.prefix(8)) }

    public var label: String { "Artifact · \(shortID)" }
}
