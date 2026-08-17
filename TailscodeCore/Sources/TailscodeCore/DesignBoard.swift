import CodingAgentKit
import Foundation

/// Where a board lives and what its parts are called. One convention, stated once, because the
/// brief that asks for the files and the reading that finds them again have to agree exactly — an
/// agent told to write somewhere the client never looks produces a turn's work nobody sees.
public enum DesignPaths {
    public static let root = ".tailscode/design"
    public static let manifestName = "board.json"

    public static func directory(for slug: String) -> String { "\(root)/\(slug)" }

    public static func manifest(in directory: String) -> String {
        "\(directory)/\(manifestName)"
    }

    public static func file(_ name: String, in directory: String) -> String {
        name.hasPrefix("/") ? name : "\(directory)/\(name)"
    }

    /// A path that is a board's manifest. Deliberately loose about where the board sits: our own
    /// brief writes under `.tailscode/design`, but a board somebody keeps beside their designs is
    /// still a board, and the file that names it is the one thing every layout shares.
    public static func isManifest(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard normalized.hasSuffix("/\(manifestName)") || normalized == manifestName else {
            return false
        }
        return true
    }

    public static func directory(ofManifest path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard let cut = normalized.range(of: "/\(manifestName)", options: .backwards) else {
            return "."
        }
        return String(normalized[normalized.startIndex..<cut.lowerBound])
    }

    /// The directory's own name, which is what a board is called when its manifest cannot be read.
    public static func title(ofDirectory directory: String) -> String {
        let name = directory.split(separator: "/").last.map(String.init) ?? directory
        return name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(
            of: "_", with: " ")
    }

    /// A directory name from what was asked for, dated so that asking twice keeps both boards —
    /// a second run that overwrote the first would rewrite a card already sitting in the
    /// transcript, and a reader would scroll back to a design that had silently become another.
    public static func slug(for request: String, at moment: Date = Date()) -> String {
        let words = request.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        let joined = String(words).split(separator: " ").prefix(4).joined(separator: "-")
        let stem = joined.isEmpty ? "surface" : String(joined.prefix(32))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMdd-HHmm"
        return "\(stem)-\(formatter.string(from: moment))"
    }
}

/// One alternative on the board: the letter it is picked by, what it is called, the case it makes
/// for itself, and the annotations that would be stuck to it on a wall.
public struct DesignArtboard: Sendable, Equatable, Codable {
    public let letter: String
    public let name: String
    public let rationale: String
    public let file: String
    public let notes: [String]

    public init(letter: String, name: String, rationale: String, file: String, notes: [String] = []) {
        self.letter = letter
        self.name = name
        self.rationale = rationale
        self.file = file
        self.notes = notes
    }

    /// What the caption over a mock reads: `B · Adaptive row`.
    public var caption: String { name.isEmpty ? letter : "\(letter) · \(name)" }

    private enum CodingKeys: String, CodingKey {
        case letter, name, rationale, file, notes, title, summary, description, path, html
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name =
            (try? container.decode(String.self, forKey: .name))
            ?? (try? container.decode(String.self, forKey: .title)) ?? ""
        let file =
            (try? container.decode(String.self, forKey: .file))
            ?? (try? container.decode(String.self, forKey: .path))
            ?? (try? container.decode(String.self, forKey: .html)) ?? ""
        let rationale =
            (try? container.decode(String.self, forKey: .rationale))
            ?? (try? container.decode(String.self, forKey: .summary))
            ?? (try? container.decode(String.self, forKey: .description)) ?? ""
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.file = file.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rationale = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        self.letter =
            ((try? container.decode(String.self, forKey: .letter)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let notes = (try? container.decode([String].self, forKey: .notes)) ?? []
        self.notes = notes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(letter, forKey: .letter)
        try container.encode(name, forKey: .name)
        try container.encode(rationale, forKey: .rationale)
        try container.encode(file, forKey: .file)
        try container.encode(notes, forKey: .notes)
    }

    fileprivate func settled(index: Int) -> DesignArtboard {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let fallbackLetter = index < letters.count
            ? String(Array(letters)[index]) : "\(index + 1)"
        let letter = self.letter.isEmpty ? fallbackLetter : self.letter
        let file = self.file.isEmpty ? "\(letter).html" : self.file
        let name = self.name.isEmpty ? Localized.text("Option %@", letter) : self.name
        return DesignArtboard(
            letter: letter, name: name, rationale: rationale, file: file, notes: notes)
    }
}

/// The board's own account of itself, as the agent wrote it. Parsed leniently on purpose: the file
/// is written by a language model, and a board that renders is worth more than a schema that was
/// obeyed to the letter.
public struct DesignManifest: Sendable, Equatable, Codable {
    public let title: String
    public let brief: String
    public let artboards: [DesignArtboard]

    public init(title: String, brief: String = "", artboards: [DesignArtboard]) {
        self.title = title
        self.brief = brief
        self.artboards = artboards.enumerated().map { $0.element.settled(index: $0.offset) }
    }

    private enum CodingKeys: String, CodingKey {
        case title, brief, artboards, name, prompt, request, options, variants, designs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title =
            (try? container.decode(String.self, forKey: .title))
            ?? (try? container.decode(String.self, forKey: .name)) ?? ""
        let brief =
            (try? container.decode(String.self, forKey: .brief))
            ?? (try? container.decode(String.self, forKey: .prompt))
            ?? (try? container.decode(String.self, forKey: .request)) ?? ""
        let artboards =
            (try? container.decode([DesignArtboard].self, forKey: .artboards))
            ?? (try? container.decode([DesignArtboard].self, forKey: .options))
            ?? (try? container.decode([DesignArtboard].self, forKey: .variants))
            ?? (try? container.decode([DesignArtboard].self, forKey: .designs)) ?? []
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artboards = artboards.enumerated().map { $0.element.settled(index: $0.offset) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(brief, forKey: .brief)
        try container.encode(artboards, forKey: .artboards)
    }

    /// Reads a manifest out of whatever the file actually holds — a fenced block, a sentence in
    /// front of the JSON, a bare array of artboards. Returns nil only when there is no object with
    /// artboards in it at all.
    public static func parse(_ text: String) -> DesignManifest? {
        let decoder = JSONDecoder()
        for candidate in candidates(text) {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let manifest = try? decoder.decode(DesignManifest.self, from: data),
                !manifest.artboards.isEmpty
            {
                return manifest
            }
            if let artboards = try? decoder.decode([DesignArtboard].self, from: data),
                !artboards.isEmpty
            {
                return DesignManifest(title: "", artboards: artboards)
            }
        }
        return nil
    }

    private static func candidates(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out = [trimmed]
        let unfenced = trimmed.hasPrefix("```")
            ? trimmed.split(separator: "\n").dropFirst().drop(while: { $0.hasPrefix("```") })
                .prefix(while: { !$0.hasPrefix("```") }).joined(separator: "\n")
            : ""
        if !unfenced.isEmpty { out.append(unfenced) }
        for (open, close) in [("{", "}"), ("[", "]")] {
            if let first = trimmed.range(of: open),
                let last = trimmed.range(of: close, options: .backwards),
                first.lowerBound < last.upperBound
            {
                out.append(String(trimmed[first.lowerBound..<last.upperBound]))
            }
        }
        return out
    }
}

/// A board that has been read: where its files are and what it holds.
public struct DesignBoard: Sendable, Equatable {
    public let directory: String
    public let manifest: DesignManifest

    public init(directory: String, manifest: DesignManifest) {
        self.directory = directory
        self.manifest = manifest
    }

    public var artboards: [DesignArtboard] { manifest.artboards }

    public var title: String {
        manifest.title.isEmpty ? DesignPaths.title(ofDirectory: directory) : manifest.title
    }

    public func path(of artboard: DesignArtboard) -> String {
        DesignPaths.file(artboard.file, in: directory)
    }
}

/// Where the design a transcript is pointing at actually is. A board this client can open and
/// render, or an artifact published somewhere else — the server-side design skill hands back a
/// link, and a link is worth naming rather than leaving as blue text in a paragraph.
public enum DesignSource: Sendable, Equatable, Hashable {
    case board(directory: String)
    case artifact(url: String)

    public var directory: String? {
        if case .board(let directory) = self { return directory }
        return nil
    }
}

/// A design the transcript shows, and where in the transcript it hangs.
public struct DesignSighting: Sendable, Equatable, Hashable {
    public let source: DesignSource
    public let messageID: String
    public let toolUseID: String?
    public let at: Date

    public init(source: DesignSource, messageID: String, toolUseID: String?, at: Date) {
        self.source = source
        self.messageID = messageID
        self.toolUseID = toolUseID
        self.at = at
    }

    public var id: String {
        switch source {
        case .board(let directory): return "design:\(directory)"
        case .artifact(let url): return "design:\(url)"
        }
    }
}

/// Finding the designs in a conversation. A board announces itself by the file that defines it
/// being written, which every backend reports the same way — the tool's own name differs per
/// agent, the path it wrote does not.
public enum DesignReading {
    public static func sightings(in messages: [ChatMessage]) -> [DesignSighting] {
        var out: [DesignSighting] = []
        var seen = Set<DesignSource>()
        for message in messages {
            for part in message.parts {
                switch part.kind {
                case .tool(let call):
                    guard let source = source(of: call) else { continue }
                    guard seen.insert(source).inserted else { continue }
                    out.append(
                        DesignSighting(
                            source: source, messageID: message.id, toolUseID: call.id,
                            at: message.createdAt))
                case .text(let text):
                    for url in artifactURLs(in: text) {
                        let source = DesignSource.artifact(url: url)
                        guard seen.insert(source).inserted else { continue }
                        out.append(
                            DesignSighting(
                                source: source, messageID: message.id, toolUseID: nil,
                                at: message.createdAt))
                    }
                default:
                    continue
                }
            }
        }
        return out
    }

    public static func latest(in messages: [ChatMessage]) -> DesignSighting? {
        sightings(in: messages).last
    }

    /// The sighting one call carries, for clients that build their rows a message at a time. A
    /// board revised later in the conversation writes its manifest again and gets another card
    /// where that happened, which is the truth: the board changed there, and both cards open the
    /// board as it is now.
    public static func sighting(of call: ToolCall, in message: ChatMessage) -> DesignSighting? {
        guard let source = source(of: call) else { return nil }
        return DesignSighting(
            source: source, messageID: message.id, toolUseID: call.id, at: message.createdAt)
    }

    /// The sighting a tool call carries, so a client can dock the card at the call that made the
    /// board rather than at the end of the message it happened to land in.
    public static func sighting(forToolUse id: String, in messages: [ChatMessage])
        -> DesignSighting?
    {
        sightings(in: messages).first { $0.toolUseID == id }
    }

    private static func source(of call: ToolCall) -> DesignSource? {
        switch call.summaryKind {
        case .fileWrite, .fileEdit:
            guard let path = call.summary.filePath, DesignPaths.isManifest(path) else { return nil }
            return .board(directory: DesignPaths.directory(ofManifest: path))
        default:
            return nil
        }
    }

    /// Artifact links the design skill publishes. Only the artifact shape is claimed: a link to
    /// anything else on the same host is somebody's ordinary link and stays ordinary text.
    static func artifactURLs(in text: String) -> [String] {
        let marks = ["https://claude.ai/code/artifact/", "https://claude.ai/public/artifacts/"]
        var out: [String] = []
        for mark in marks {
            var cursor = text.startIndex
            while let found = text.range(of: mark, range: cursor..<text.endIndex) {
                let tail = text[found.upperBound...].prefix {
                    $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
                }
                cursor = found.upperBound
                guard tail.count >= 8 else { continue }
                out.append(mark + tail)
            }
        }
        return out
    }
}

/// What the app asks for when somebody wants alternatives drawn. The whole value is in the
/// instruction being written once, here: three clients that each phrased the request their own way
/// would produce three different conventions on disk and only one of them would render.
public struct DesignBrief: Sendable, Equatable {
    public var request: String
    public var count: Int
    public var reference: String
    public var notes: String
    public var slug: String

    public static let minimumCount = 2
    public static let maximumCount = 5
    public static let defaultCount = 3

    public init(
        request: String, count: Int = DesignBrief.defaultCount, reference: String = "",
        notes: String = "", slug: String? = nil, at moment: Date = Date()
    ) {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        self.request = request
        self.count = max(Self.minimumCount, min(Self.maximumCount, count))
        self.reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.slug = slug ?? DesignPaths.slug(for: request, at: moment)
    }

    public var directory: String { DesignPaths.directory(for: slug) }
    public var isReady: Bool { !request.isEmpty }

    /// The turn this brief becomes. It states the file convention rather than a command name so
    /// that any agent on the other end can honour it — the two this app talks to have different
    /// skills, different tools and different opinions about slash commands, and neither of them
    /// has to have heard of this feature for the board to arrive.
    public var prompt: String {
        var lines: [String] = []
        lines.append(
            "Design \(count) alternative artboards for: \(request)")
        if !reference.isEmpty {
            lines.append("")
            lines.append("Start from what is already there: \(reference)")
        }
        if !notes.isEmpty {
            lines.append("")
            lines.append("Constraints: \(notes)")
        }
        lines.append("")
        lines.append(
            """
            Work as a designer this turn, not as an implementer: do not change the app's own source. \
            Read enough of the real code to know what the surface is made of, then write static mocks \
            of each alternative into \(directory)/ and stop.

            Each artboard is one self-contained HTML file at \(directory)/<LETTER>.html:
            - everything inline — no external CSS, JS, fonts or images; data: URIs only
            - <meta name="viewport" content="width=device-width, initial-scale=1"> and legible at 390px wide
            - real content from the real product, never lorem ipsum or placeholder boxes
            - readable in light and dark via prefers-color-scheme
            - a body background of its own, because it is rendered on its own and not on a page

            The alternatives must differ in a way you can name in one line — a different arrangement, a \
            different order of priority, a different thing made easy. Three colour variations of one \
            layout is one artboard, not three.

            Then write \(directory)/\(DesignPaths.manifestName), this shape and nothing else:

            {"title": "<the board, 2-5 words>", "brief": "<what was asked, one line>", "artboards": \
            [{"letter": "A", "name": "<2-4 words>", "rationale": "<what it optimizes for and what \
            it gives up>", "file": "A.html", "notes": ["<a specific decision worth pointing at>"]}]}

            Write the manifest last, after every artboard file exists. Reply with one short line \
            naming the board — the artboards are read from the files, not from the message.
            """)
        return lines.joined(separator: "\n")
    }
}

/// Every word the screen that composes a brief says. A design costs a whole turn on somebody
/// else's machine, so the screen states what it will do and where the result will land before it
/// spends it.
public struct DesignPreflight: Sendable, Hashable {
    public let headline: String
    public let subtitle: String
    public let paragraphs: [String]
    public let requestCaption: String
    public let requestPlaceholder: String
    public let referenceCaption: String
    public let referencePlaceholder: String
    public let notesCaption: String
    public let notesPlaceholder: String
    public let countCaption: String
    public let confirmTitle: String
    public let wait: String

    public static func make(directory: String, count: Int = DesignBrief.defaultCount)
        -> DesignPreflight
    {
        DesignPreflight(
            headline: Localized.text("Draw it before building it"),
            subtitle: Localized.text("%@ artboards, side by side", "\(count)"),
            paragraphs: [
                Localized.text(
                    "The agent reads the surface as it is now, then draws each alternative as a mock you can look at — no source is changed."
                ),
                Localized.text(
                    "Pick one here, say what to change about it, and only then have it built for real."
                ),
            ],
            requestCaption: Localized.text("What should it design?"),
            requestPlaceholder: Localized.text("e.g. the composer, for what people actually use it for"),
            referenceCaption: Localized.text("Where is it now?"),
            referencePlaceholder: Localized.text("Optional — a file, a screen, a component"),
            notesCaption: Localized.text("Anything it must respect?"),
            notesPlaceholder: Localized.text("Optional — constraints, must-keeps, a direction"),
            countCaption: Localized.text("How many alternatives?"),
            confirmTitle: Localized.text("Design it"),
            wait: Localized.text(
                "Takes a few minutes, and lands in %@ on the server.", directory))
    }
}

/// The two things you do with an artboard once you have one, and the one that adds another. The
/// wording is the whole point: an implement that did not say the mock is a picture rather than the
/// code gets the mock's markup pasted into the app.
public enum DesignFollowUp {
    /// The artboard named the way a confirmation names what it is about to act on.
    public static func summary(_ artboard: DesignArtboard) -> String {
        artboard.rationale.isEmpty
            ? artboard.caption : "\(artboard.caption) — \(artboard.rationale)"
    }

    public static func implement(
        board: DesignBoard, artboard: DesignArtboard, notes: String = ""
    ) -> String {
        var text =
            """
            Implement artboard \(artboard.letter) — "\(artboard.name)" — from \
            \(board.path(of: artboard)).

            Read that file and its entry in \(DesignPaths.manifest(in: board.directory)) first. The mock \
            is a picture of the result, not the code for it: match its arrangement, hierarchy, spacing \
            and behaviour using the app's own components, tokens and conventions.
            """
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            text += "\n\nChange this about it as you build it: \(trimmed)"
        }
        text += "\n\nLeave the board files where they are."
        return text
    }

    public static func tweak(
        board: DesignBoard, artboard: DesignArtboard, instruction: String
    ) -> String {
        """
        Revise artboard \(artboard.letter) — "\(artboard.name)" — in \(board.directory)/: \
        \(instruction.trimmingCharacters(in: .whitespacesAndNewlines))

        Rewrite \(board.path(of: artboard)) in place, keeping it self-contained, and update that \
        artboard's entry in \(DesignPaths.manifest(in: board.directory)) so its name, rationale and \
        notes still describe it. Change nothing else, and do not touch the app's source.
        """
    }

    public static func another(board: DesignBoard, instruction: String) -> String {
        let taken = board.artboards.map(\.letter).joined(separator: ", ")
        return """
            Add one more artboard to \(board.directory)/: \
            \(instruction.trimmingCharacters(in: .whitespacesAndNewlines))

            Give it the next free letter after \(taken), write it the same way as the others — one \
            self-contained HTML file — and append its entry to \
            \(DesignPaths.manifest(in: board.directory)). Leave the existing artboards alone.
            """
    }
}

/// What the surface showing a board is doing. A board is two reads on another machine — the
/// manifest, then every mock it names — and both can fail while the transcript row that offered it
/// stays perfectly true, so the phases are named rather than collapsed into "no board".
public enum DesignPhase: Sendable, Equatable {
    case loading
    case ready
    case empty
    case failed(String)
}

/// The board surface's model, toolkit-free: what has been read, which artboard is picked, and
/// every word drawn around it. The engine differs per platform — three web views, three ways to
/// dock a sheet — and the surface behaves identically, which is what parity judges.
public struct DesignBoardState: Sendable, Equatable {
    public let directory: String
    public private(set) var phase: DesignPhase
    public private(set) var board: DesignBoard?
    public private(set) var pages: [String: String]
    public private(set) var selection: Int
    public var showsNotes: Bool

    public init(directory: String) {
        self.directory = directory
        phase = .loading
        board = nil
        pages = [:]
        selection = 0
        showsNotes = true
    }

    public mutating func arrived(_ board: DesignBoard) {
        self.board = board
        phase = board.artboards.isEmpty ? .empty : .ready
        selection = min(selection, max(0, board.artboards.count - 1))
    }

    public mutating func failed(_ reason: String) {
        phase = .failed(reason)
    }

    /// A mock's markup, keyed by the letter it belongs to, so an artboard that has not been read
    /// yet is drawn as itself waiting rather than as an empty page.
    public mutating func loaded(_ html: String, for letter: String) {
        pages[letter] = html
    }

    public mutating func select(_ index: Int) {
        guard let board, !board.artboards.isEmpty else { return }
        selection = max(0, min(board.artboards.count - 1, index))
    }

    public mutating func step(_ delta: Int) {
        guard let board, !board.artboards.isEmpty else { return }
        let count = board.artboards.count
        selection = ((selection + delta) % count + count) % count
    }

    public var artboards: [DesignArtboard] { board?.artboards ?? [] }

    public var current: DesignArtboard? {
        guard selection < artboards.count else { return nil }
        return artboards[selection]
    }

    public func page(for artboard: DesignArtboard) -> String? { pages[artboard.letter] }

    public var title: String { board?.title ?? DesignPaths.title(ofDirectory: directory) }

    public var subtitle: String {
        switch phase {
        case .loading: return Localized.text("Reading the board…")
        case .empty: return Localized.text("This board has no artboards in it")
        case .failed(let reason): return reason
        case .ready:
            guard let current else { return directory }
            return Localized.text(
                "%@ of %@ · %@", "\(selection + 1)", "\(artboards.count)", current.caption)
        }
    }

    public var isReady: Bool { phase == .ready }

    /// Said on the surface itself, once, rather than discovered when a mock turns out not to be the
    /// app: a board is a picture of a decision and nothing here has been built.
    public var footnote: String {
        Localized.text("Mock-ups only — nothing in the app has changed yet.")
    }

    public var implementTitle: String {
        guard let current else { return Localized.text("Build this") }
        return Localized.text("Build %@", current.letter)
    }

    public var tweakTitle: String { Localized.text("Change it…") }
    public var anotherTitle: String { Localized.text("One more…") }
    public var notesTitle: String { Localized.text("Notes") }
    public var browserTitle: String { Localized.text("Open in browser") }

    /// A mock is a web page, and where the app has no engine to draw one the desktop it is running
    /// on does. Said as a fact with the way forward in it rather than as a missing feature: the
    /// turn that drew the board was spent either way.
    public var noEngineLine: String {
        Localized.text(
            "This build has no in-app web engine, so a mock opens in your browser instead.")
    }

    public var tweakPrompt: String {
        guard let current else { return Localized.text("What should change?") }
        return Localized.text("What should change about %@?", current.caption)
    }

    public var anotherPrompt: String { Localized.text("What should the extra one try?") }

    public var implementPrompt: String {
        Localized.text("Anything to change as it is built? Optional.")
    }

    public var emptyLine: String {
        Localized.text("The manifest is there, but it names no artboards.")
    }

    public var hint: String {
        Localized.text("←→ or 1-9 picks · n notes · enter builds · esc closes")
    }
}

/// The transcript row a board becomes, in the same spirit as a question or a subagent: the design
/// is a thing to open, not a file the reader is told about in passing.
public struct DesignCardReading: Sendable, Equatable {
    public let symbol: String
    public let title: String
    public let detail: String
    public let action: String
    public let letters: [String]

    public static func make(sighting: DesignSighting, board: DesignBoard?) -> DesignCardReading {
        switch sighting.source {
        case .board(let directory):
            guard let board, !board.artboards.isEmpty else {
                return DesignCardReading(
                    symbol: "rectangle.3.group",
                    title: DesignPaths.title(ofDirectory: directory),
                    detail: Localized.text("A board of artboards, on the server"),
                    action: Localized.text("Open board"),
                    letters: [])
            }
            return DesignCardReading(
                symbol: "rectangle.3.group",
                title: board.title,
                detail: board.artboards.count == 1
                    ? Localized.text("One artboard")
                    : Localized.text("%@ artboards to choose from", "\(board.artboards.count)"),
                action: Localized.text("Open board"),
                letters: board.artboards.map(\.letter))
        case .artifact(let url):
            return DesignCardReading(
                symbol: "link",
                title: Localized.text("Design published"),
                detail: url,
                action: Localized.text("Open"),
                letters: [])
        }
    }
}

/// A mock is written to be looked at on a phone as readily as on a monitor, and an agent that
/// forgot the one tag that makes that true should not cost a turn. Nothing else is touched: the
/// markup rendered is the markup on the server.
public enum DesignRender {
    public static func prepared(_ html: String) -> String {
        let lowered = html.lowercased()
        guard !lowered.contains("name=\"viewport\"") && !lowered.contains("name='viewport'") else {
            return html
        }
        let tag = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        if let head = lowered.range(of: "<head>") {
            return html.replacingCharacters(in: head, with: "<head>" + tag)
        }
        if let html5 = lowered.range(of: "<html") {
            let after = html.range(of: ">", range: html5.upperBound..<html.endIndex)
            if let after {
                return html.replacingCharacters(in: after, with: "><head>" + tag + "</head>")
            }
        }
        return tag + html
    }
}
