import Foundation

/// What the clipboard is holding, said only as far as the surface may read it. A desktop summoned
/// from anywhere is most often summoned *about* something (the paragraph just copied out of a
/// mail, the screenshot just taken, the file just copied in a file manager), and the surface can
/// only offer to work on it if it can say what it is. Words read are carried so they can be shown;
/// words a platform can only detect (a pasteboard that alerts on every read) arrive as `nil`, which
/// is a real answer: there is text, and nobody has looked at it yet.
public enum QuickAskClipboardHolding: Sendable, Equatable {
    case text(String?)
    /// Copied words that are one web address and nothing else: a page somebody wants something
    /// from, which is a different errand from words somebody wants explained.
    case link(String)
    case picture
    case files([String])

    /// The site a copied link is on, without a leading `www.`.
    public var host: String? {
        guard case .link(let address) = self, let host = URL(string: address)?.host?.lowercased()
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// One thing the surface offers to do with what was copied. Like a starter, it is the first half of
/// a sentence: picking it writes the words into the composer and hands the clipboard over through
/// the composer's own paste, so the person still reads the whole question and presses send — unless
/// it is an action the person wrote to send at once.
public struct QuickAskClipboardErrand: Sendable, Equatable, Identifiable {
    public enum Takes: String, Sendable, Equatable {
        case text
        case link
        case picture
        case files
    }

    public let action: QuickAskAction

    public init(action: QuickAskAction) {
        self.action = action
    }

    public var id: String { action.id }
    public var symbol: String { action.symbol }
    public var glyph: String { action.glyph }
    public var title: String { action.title }
    public var prompt: String { action.prompt }

    public var takes: Takes {
        switch action.offer {
        case .link: return .link
        case .picture: return .picture
        case .files: return .files
        case .text, .always: return .text
        }
    }

    /// The words left in the composer before the clipboard is pasted after them. Copied words are
    /// set a blank line under the instruction so the two read as a heading over a quotation; a
    /// picture or a file rides as a chip, so the instruction is the whole of what is typed.
    public var opening: String {
        takes == .text || takes == .link ? prompt + "\n\n" : prompt
    }
}

/// The copied thing as the surface draws it: what it is, a glimpse of it where the words were
/// read, and what can be done with it on the aimed model. Nil from `reading` means there is nothing
/// to offer: nothing copied, nothing new, or nothing this model can take.
public struct QuickAskCopied: Sendable, Equatable {
    public let fingerprint: String
    public let holding: QuickAskClipboardHolding
    public let headline: String
    public let preview: String?
    public let errands: [QuickAskClipboardErrand]
}

public enum QuickAskClipboard {
    public static let previewLimit = 220

    /// The app's own errands, whatever the person has done with them.
    public static var all: [QuickAskClipboardErrand] {
        QuickAskBuiltIns.copied.map(QuickAskClipboardErrand.init(action:))
    }

    /// The errands this holding can be worked with on this aim, in the person's order. Words go to
    /// any model, because a paste is words; a picture needs a model that sees, and a file one that
    /// can be handed files. A link is offered its site's errands first and the ones for any page
    /// after them.
    public static func errands(
        for holding: QuickAskClipboardHolding, abilities: ModelAbilities,
        surface: QuickAskSurfaceAbilities = .phone,
        actions: [QuickAskAction] = QuickAskActions.visible()
    ) -> [QuickAskClipboardErrand] {
        let able = actions.filter { $0.isOffered(abilities: abilities, surface: surface) }
        let chosen: [QuickAskAction]
        switch holding {
        case .text(let text):
            guard text.map({ !isBlank($0) }) ?? true else { return [] }
            chosen = able.filter { $0.offer == .text }
        case .link:
            let host = holding.host ?? ""
            let links = able.filter { $0.matches(host: host) }
            chosen = links.filter { !$0.hosts.isEmpty } + links.filter { $0.hosts.isEmpty }
        case .picture:
            chosen = able.filter { $0.offer == .picture }
        case .files(let names):
            guard names.isEmpty || !names.allSatisfy(isBlank) else { return [] }
            chosen = able.filter { $0.offer == .files }
        }
        return chosen.map(QuickAskClipboardErrand.init(action:))
    }

    /// The card's name for what was copied, specific where it was read and plain where it was
    /// only detected.
    public static func headline(for holding: QuickAskClipboardHolding) -> String {
        switch holding {
        case .text(let text):
            guard let text else { return Localized.text("Copied text") }
            let words = wordCount(text)
            return words == 1
                ? Localized.text("Copied text · 1 word")
                : Localized.text("Copied text · %@ words", "\(words)")
        case .link:
            guard let host = holding.host else { return Localized.text("Copied link") }
            return Localized.text("Copied link · %@", host)
        case .picture:
            return Localized.text("Copied picture")
        case .files(let names):
            switch names.count {
            case 0: return Localized.text("Copied files")
            case 1:
                return Localized.text(
                    "Copied file · %@", (names[0] as NSString).lastPathComponent)
            default: return Localized.text("Copied %@ files", "\(names.count)")
            }
        }
    }

    /// A glimpse of copied words: every run of whitespace one space, so a paragraph, a stack trace
    /// and a column of code all spend their two lines on words rather than on indentation, and cut
    /// at a word with an ellipsis once it is longer than a glance.
    public static func preview(for holding: QuickAskClipboardHolding, limit: Int = previewLimit)
        -> String?
    {
        let read: String
        switch holding {
        case .text(let text?): read = text
        case .link(let address): read = address
        default: return nil
        }
        let flat = read.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return String(atWord) + "…"
    }

    /// What a clipboard read whole is holding, and the name it is remembered by. Copied files
    /// outrank a picture and a picture outranks words, the same order a paste takes them in, and a
    /// clipboard of whitespace holds nothing.
    public static func holding(of offer: ClipboardOffer)
        -> (holding: QuickAskClipboardHolding, fingerprint: String)?
    {
        if !offer.paths.isEmpty {
            return (
                .files(offer.paths),
                fingerprint(kind: "files", bytes: Data(offer.paths.joined(separator: "\n").utf8))
            )
        }
        if let image = offer.image, !image.isEmpty {
            return (.picture, fingerprint(kind: "picture", bytes: image))
        }
        if let text = offer.text, !isBlank(text) {
            if let address = link(in: text) { return (.link(address), fingerprint(text: text)) }
            return (.text(text), fingerprint(text: text))
        }
        return nil
    }

    /// The card, or nil when there is nothing worth offering: nothing copied, the same thing the
    /// surface already offered and somebody used or set aside, or a holding this model cannot take.
    public static func reading(
        holding: QuickAskClipboardHolding, fingerprint: String, abilities: ModelAbilities,
        surface: QuickAskSurfaceAbilities = .phone
    ) -> QuickAskCopied? {
        guard QuickAskClipboardMemory.isNews(fingerprint) else { return nil }
        let offered = errands(for: holding, abilities: abilities, surface: surface)
        guard !offered.isEmpty else { return nil }
        return QuickAskCopied(
            fingerprint: fingerprint, holding: holding, headline: headline(for: holding),
            preview: preview(for: holding), errands: offered)
    }

    /// A stable name for what was copied, the same in every process: a 64-bit FNV-1a over the
    /// bytes. `Hasher` is seeded per launch, so it cannot remember anything across a restart.
    public static func fingerprint(kind: String, bytes: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return kind + ":" + String(hash, radix: 16) + ":" + String(bytes.count)
    }

    public static func fingerprint(text: String) -> String {
        fingerprint(kind: "text", bytes: Data(text.utf8))
    }

    /// Copied words that are a single http(s) address and nothing else.
    public static func link(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host, host.contains(".")
        else { return nil }
        return trimmed
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

/// Whether what is on the clipboard is still news. Almost every clipboard holds *something*, and
/// most of it was copied hours ago for some other reason, so a card offered on every summon would
/// be a card nobody reads. The thing copied is news until it has been worked with (an errand
/// picked, a question sent while it was on offer, or the card set aside), and copying anything else
/// makes it news again. Closing the surface without doing anything is not reading it.
public enum QuickAskClipboardMemory {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    private static let key = "tailscode.quickask.copied"

    public static func isNews(_ fingerprint: String) -> Bool {
        defaults.string(forKey: key) != fingerprint
    }

    public static func settle(_ fingerprint: String) {
        defaults.set(fingerprint, forKey: key)
    }

    public static func clear() {
        defaults.removeObject(forKey: key)
    }
}
