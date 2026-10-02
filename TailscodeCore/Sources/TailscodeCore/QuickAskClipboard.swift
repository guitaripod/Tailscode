import Foundation

/// What the clipboard is holding, said only as far as the surface may read it. A desktop summoned
/// from anywhere is most often summoned *about* something (the paragraph just copied out of a
/// mail, the screenshot just taken, the file just copied in a file manager), and the surface can
/// only offer to work on it if it can say what it is. Words read are carried so they can be shown;
/// words a platform can only detect (a pasteboard that alerts on every read) arrive as `nil`, which
/// is a real answer: there is text, and nobody has looked at it yet.
public enum QuickAskClipboardHolding: Sendable, Equatable {
    case text(String?)
    case picture
    case files([String])
}

/// One thing the surface offers to do with what was copied. Like a starter, it is the first half of
/// a sentence: picking it writes the words into the composer and hands the clipboard over through
/// the composer's own paste, so the person still reads the whole question and presses send. A
/// copied thing is never sent by touching it.
public struct QuickAskClipboardErrand: Sendable, Equatable, Identifiable {
    public enum Takes: String, Sendable, Equatable {
        case text
        case picture
        case files
    }

    public let id: String
    public let symbol: String
    public let glyph: String
    public let title: String
    public let prompt: String
    public let takes: Takes

    public init(
        id: String, symbol: String, glyph: String, title: String, prompt: String, takes: Takes
    ) {
        self.id = id
        self.symbol = symbol
        self.glyph = glyph
        self.title = title
        self.prompt = prompt
        self.takes = takes
    }

    /// The words left in the composer before the clipboard is pasted after them. Copied words are
    /// set a blank line under the instruction so the two read as a heading over a quotation; a
    /// picture or a file rides as a chip, so the instruction is the whole of what is typed.
    public var opening: String {
        takes == .text ? prompt + "\n\n" : prompt
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

    public static let all: [QuickAskClipboardErrand] = [
        QuickAskClipboardErrand(
            id: "copied.explain", symbol: "text.magnifyingglass", glyph: "?",
            title: Localized.text("Explain"), prompt: Localized.text("Explain this:"),
            takes: .text),
        QuickAskClipboardErrand(
            id: "copied.summarize", symbol: "list.bullet", glyph: "≡",
            title: Localized.text("Summarize"), prompt: Localized.text("Summarize this:"),
            takes: .text),
        QuickAskClipboardErrand(
            id: "copied.translate", symbol: "character.bubble", glyph: "⇄",
            title: Localized.text("Translate"),
            prompt: Localized.text("Translate this into English:"), takes: .text),
        QuickAskClipboardErrand(
            id: "copied.improve", symbol: "pencil", glyph: "✎",
            title: Localized.text("Improve"),
            prompt: Localized.text("Improve the writing of this, keeping its meaning:"),
            takes: .text),
        QuickAskClipboardErrand(
            id: "copied.reply", symbol: "arrowshape.turn.up.left", glyph: "↩",
            title: Localized.text("Reply"), prompt: Localized.text("Draft a reply to this:"),
            takes: .text),
        QuickAskClipboardErrand(
            id: "copied.describe", symbol: "eye", glyph: "◉",
            title: Localized.text("Describe"), prompt: Localized.text("What is in this picture?"),
            takes: .picture),
        QuickAskClipboardErrand(
            id: "copied.transcribe", symbol: "text.viewfinder", glyph: "¶",
            title: Localized.text("Read the text"),
            prompt: Localized.text("Transcribe the text in this picture."), takes: .picture),
        QuickAskClipboardErrand(
            id: "copied.explainPicture", symbol: "questionmark.circle", glyph: "?",
            title: Localized.text("Explain"), prompt: Localized.text("Explain what this shows."),
            takes: .picture),
        QuickAskClipboardErrand(
            id: "copied.summarizeFile", symbol: "list.bullet", glyph: "≡",
            title: Localized.text("Summarize"), prompt: Localized.text("Summarize this."),
            takes: .files),
        QuickAskClipboardErrand(
            id: "copied.explainFile", symbol: "text.magnifyingglass", glyph: "?",
            title: Localized.text("Explain"), prompt: Localized.text("Explain this."),
            takes: .files),
        QuickAskClipboardErrand(
            id: "copied.reviewFile", symbol: "checkmark.circle", glyph: "✓",
            title: Localized.text("Review"),
            prompt: Localized.text("Review this and point out anything wrong."), takes: .files),
    ]

    /// The errands this holding can be worked with on this aim. Words go to any model, because a
    /// paste is words; a picture needs a model that sees, and a file one that can be handed files.
    public static func errands(
        for holding: QuickAskClipboardHolding, abilities: ModelAbilities
    ) -> [QuickAskClipboardErrand] {
        switch holding {
        case .text(let text):
            guard text.map({ !isBlank($0) }) ?? true else { return [] }
            return all.filter { $0.takes == .text }
        case .picture:
            return abilities.vision ? all.filter { $0.takes == .picture } : []
        case .files(let names):
            guard abilities.attachments, names.isEmpty || !names.allSatisfy(isBlank) else {
                return []
            }
            return all.filter { $0.takes == .files }
        }
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
        guard case .text(let text?) = holding else { return nil }
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
            return (.text(text), fingerprint(text: text))
        }
        return nil
    }

    /// The card, or nil when there is nothing worth offering: nothing copied, the same thing the
    /// surface already offered and somebody used or set aside, or a holding this model cannot take.
    public static func reading(
        holding: QuickAskClipboardHolding, fingerprint: String, abilities: ModelAbilities
    ) -> QuickAskCopied? {
        guard QuickAskClipboardMemory.isNews(fingerprint) else { return nil }
        let offered = errands(for: holding, abilities: abilities)
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
