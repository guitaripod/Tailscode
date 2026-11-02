import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// Where an action asks, when it asks somewhere other than the aim in force: a machine (its saved
/// id, or its name for a hand-written file), a model as `provider/model`, a level. Any half left
/// out is the aim's own.
public struct QuickAskActionAim: Codable, Sendable, Equatable {
    public var server: String?
    public var model: String?
    public var effort: String?

    public init(server: String? = nil, model: String? = nil, effort: String? = nil) {
        self.server = server.flatMap(Self.kept)
        self.model = model.flatMap(Self.kept)
        self.effort = effort.flatMap(Self.kept)
    }

    public var isEmpty: Bool { server == nil && model == nil && effort == nil }

    public var selection: ModelSelection? { model.flatMap(ModelSelection.init(string:)) }

    /// The saved machine this aim names: its id first, then its name, ignoring case, so a file
    /// written by hand can say `arch` and a file written by the app survives a rename. One machine
    /// often runs several agents under the same name, so among those the one whose catalog holds
    /// the model wins.
    public func profileID(
        among profiles: [ConnectionProfile],
        catalog: (String) -> [ModelInfo] = ModelCatalogStore.cached
    ) -> String? {
        guard let server else { return nil }
        if let byID = profiles.first(where: { $0.id == server }) { return byID.id }
        let named = profiles.filter { $0.name.caseInsensitiveCompare(server) == .orderedSame }
        guard let selection, named.count > 1 else { return named.first?.id }
        let running = named.first { profile in
            catalog(profile.id).contains {
                $0.id == selection.modelID && $0.providerID == selection.providerID
            }
        }
        return (running ?? named.first)?.id
    }

    private static func kept(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One thing the quick ask offers to do, built in or written by the person.
///
/// It is a template and a place: the words that land in the box, with tokens that gather what the
/// question is about (`{clipboard}`, `{link}`, `{session}`, `{screen}`, `{file}`, `{latest:~/Downloads}`,
/// `{date}`, `{cursor}`), when it is offered (always, or for something just copied), and optionally
/// the machine, model and level it runs on. A built-in never sends by itself; an action the person
/// wrote may, because then the words are theirs.
public struct QuickAskAction: Codable, Sendable, Equatable, Identifiable {
    public enum Offer: String, Codable, Sendable, CaseIterable {
        case always
        case text
        case link
        case picture
        case files
    }

    public var id: String
    public var title: String
    public var detail: String
    public var glyph: String
    public var symbol: String
    public var prompt: String
    public var offer: Offer
    /// For a link action, the sites it belongs to (`x.com` also matches `mobile.x.com`); empty
    /// means every link.
    public var hosts: [String]
    public var aim: QuickAskActionAim?
    public var sends: Bool
    public var hidden: Bool

    public init(
        id: String, title: String, detail: String = "", glyph: String = "✦",
        symbol: String = "sparkle", prompt: String, offer: Offer = .always, hosts: [String] = [],
        aim: QuickAskActionAim? = nil, sends: Bool = false, hidden: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.glyph = glyph
        self.symbol = symbol
        self.prompt = prompt
        self.offer = offer
        self.hosts = hosts
        self.aim = aim.flatMap { $0.isEmpty ? nil : $0 }
        self.sends = sends
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, detail, glyph, symbol, prompt, offer, hosts, aim, sends, hidden
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try values.decodeIfPresent(String.self, forKey: .detail) ?? ""
        glyph = try values.decodeIfPresent(String.self, forKey: .glyph) ?? "✦"
        symbol = try values.decodeIfPresent(String.self, forKey: .symbol) ?? "sparkle"
        prompt = try values.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        offer =
            (try? values.decodeIfPresent(Offer.self, forKey: .offer)).flatMap { $0 } ?? .always
        hosts = (try? values.decodeIfPresent([String].self, forKey: .hosts)).flatMap { $0 } ?? []
        aim = (try? values.decodeIfPresent(QuickAskActionAim.self, forKey: .aim))
            .flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
        sends = (try? values.decodeIfPresent(Bool.self, forKey: .sends)).flatMap { $0 } ?? false
        hidden = (try? values.decodeIfPresent(Bool.self, forKey: .hidden)).flatMap { $0 } ?? false
    }

    /// Only what differs from `base` is written — from the defaults for an action the person wrote,
    /// from the app's own for a rewritten built-in — so the file stays short enough to read and a
    /// field nobody touched keeps following the app.
    public func encode(to encoder: Encoder) throws {
        try encode(to: encoder, over: QuickAskBuiltIns.action(id: id))
    }

    func encode(to encoder: Encoder, over base: QuickAskAction?) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        if title != (base?.title ?? "") { try values.encode(title, forKey: .title) }
        if detail != (base?.detail ?? "") { try values.encode(detail, forKey: .detail) }
        if glyph != (base?.glyph ?? "✦") { try values.encode(glyph, forKey: .glyph) }
        if symbol != (base?.symbol ?? "sparkle") { try values.encode(symbol, forKey: .symbol) }
        if prompt != (base?.prompt ?? "") { try values.encode(prompt, forKey: .prompt) }
        if offer != (base?.offer ?? .always) { try values.encode(offer, forKey: .offer) }
        if hosts != (base?.hosts ?? []) { try values.encode(hosts, forKey: .hosts) }
        if aim != base?.aim { try values.encode(aim, forKey: .aim) }
        if sends != (base?.sends ?? false) { try values.encode(sends, forKey: .sends) }
        if hidden { try values.encode(true, forKey: .hidden) }
    }

    public var isBuiltIn: Bool { QuickAskBuiltIns.action(id: id) != nil }

    public var tokens: [QuickAskToken] { QuickAskTemplate.tokens(prompt) }

    /// What has to be fetched, in the order the template names it, before the words can land.
    public var gathers: [QuickAskGather] {
        var seen: [QuickAskGather] = []
        for token in tokens {
            guard let gather = token.gather, !seen.contains(gather) else { continue }
            seen.append(gather)
        }
        return seen
    }

    /// Whether a link with this host is one this action is for.
    public func matches(host: String) -> Bool {
        guard offer == .link else { return false }
        guard !hosts.isEmpty else { return true }
        let lower = host.lowercased()
        return hosts.contains { site in
            let wanted = site.lowercased().trimmingCharacters(in: .whitespaces)
            return !wanted.isEmpty && (lower == wanted || lower.hasSuffix("." + wanted))
        }
    }

    /// Whether this aim and this surface can carry the action out at all: a picture needs a
    /// model that sees, a file one that takes files, the screen a desktop that can grab it, the
    /// newest file in a folder the machine that holds the folder.
    public func isOffered(abilities: ModelAbilities, surface: QuickAskSurfaceAbilities) -> Bool {
        guard !hidden else { return false }
        switch offer {
        case .picture: if !abilities.vision { return false }
        case .files: if !abilities.attachments { return false }
        case .always, .text, .link: break
        }
        return tokens.allSatisfy { token in
            switch token {
            case .clipboard, .link, .cursor, .date: return true
            case .session: return surface.sessions
            case .screen: return surface.screen && abilities.vision
            case .file: return surface.files && abilities.attachments
            case .photo: return surface.photos && abilities.vision
            case .camera: return surface.camera && abilities.camera
            case .latest: return surface.localFiles
            }
        }
    }
}

/// What the surface drawing the quick ask can fetch for a template, beside what the model can take.
public struct QuickAskSurfaceAbilities: Sendable, Equatable {
    public var files: Bool
    public var photos: Bool
    public var camera: Bool
    public var screen: Bool
    public var sessions: Bool
    /// The aimed machine is the one the surface runs on, so a path on this disk means something
    /// to the agent that reads it.
    public var localFiles: Bool

    public init(
        files: Bool = true, photos: Bool = false, camera: Bool = false, screen: Bool = false,
        sessions: Bool = false, localFiles: Bool = false
    ) {
        self.files = files
        self.photos = photos
        self.camera = camera
        self.screen = screen
        self.sessions = sessions
        self.localFiles = localFiles
    }

    public static let phone = QuickAskSurfaceAbilities(files: true, photos: true, camera: true)

    public static func desktop(screen: Bool, localFiles: Bool) -> QuickAskSurfaceAbilities {
        QuickAskSurfaceAbilities(
            files: true, photos: true, camera: false, screen: screen, sessions: true,
            localFiles: localFiles)
    }
}

/// Something a template asks the surface to fetch before the words land.
public enum QuickAskGather: Sendable, Equatable {
    case session
    case screen
    case file
    case photo
    case camera
}

public enum QuickAskToken: Sendable, Equatable {
    case clipboard
    case link
    case cursor
    case date
    case session
    case screen
    case file
    case photo
    case camera
    case latest(String)

    var gather: QuickAskGather? {
        switch self {
        case .session: return .session
        case .screen: return .screen
        case .file: return .file
        case .photo: return .photo
        case .camera: return .camera
        case .clipboard, .link, .cursor, .date, .latest: return nil
        }
    }

    init?(name: String, argument: String?) {
        switch (name.lowercased(), argument) {
        case ("clipboard", nil): self = .clipboard
        case ("link", nil): self = .link
        case ("cursor", nil): self = .cursor
        case ("date", nil): self = .date
        case ("session", nil): self = .session
        case ("screen", nil): self = .screen
        case ("file", nil): self = .file
        case ("photo", nil): self = .photo
        case ("camera", nil): self = .camera
        case ("latest", let folder?) where !folder.isEmpty: self = .latest(folder)
        default: return nil
        }
    }
}

/// What the gathering found, handed back to be written into the words.
public struct QuickAskFill: Sendable, Equatable {
    /// The copied words or link, set where `{clipboard}`/`{link}` stands, or under the words when
    /// a copied-thing action names neither. Nil when the clipboard travels as attachments.
    public var clipboard: String?
    /// The sentence that names a picked conversation.
    public var session: String?
    /// Paths a `{file}` or `{photo}` picked on this machine, set where the token stands.
    public var files: String?
    public var date: Date

    public init(
        clipboard: String? = nil, session: String? = nil, files: String? = nil, date: Date = Date()
    ) {
        self.clipboard = clipboard
        self.session = session
        self.files = files
        self.date = date
    }
}

/// The words an action writes, and where the caret goes in them.
public struct QuickAskComposed: Sendable, Equatable {
    public let text: String
    public let caret: Int
}

public enum QuickAskTemplate {
    public enum Piece: Sendable, Equatable {
        case words(String)
        case token(QuickAskToken)
    }

    /// A brace that does not hold a known token is words: a template full of code or JSON keeps
    /// every brace it was written with.
    public static func pieces(_ prompt: String) -> [Piece] {
        var pieces: [Piece] = []
        var words = ""
        var rest = Substring(prompt)
        while let open = rest.firstIndex(of: "{") {
            words += rest[..<open]
            let inner = rest[rest.index(after: open)...]
            guard let close = inner.firstIndex(of: "}"),
                let token = token(String(inner[..<close]))
            else {
                words += "{"
                rest = inner
                continue
            }
            if !words.isEmpty { pieces.append(.words(words)) }
            words = ""
            pieces.append(.token(token))
            rest = inner[inner.index(after: close)...]
        }
        words += rest
        if !words.isEmpty { pieces.append(.words(words)) }
        return pieces
    }

    public static func tokens(_ prompt: String) -> [QuickAskToken] {
        pieces(prompt).compactMap {
            if case .token(let token) = $0 { return token }
            return nil
        }
    }

    private static func token(_ body: String) -> QuickAskToken? {
        guard !body.contains("{"), !body.contains("\n") else { return nil }
        let parts = body.split(separator: ":", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let name = parts.first, !name.isEmpty else { return nil }
        return QuickAskToken(name: name, argument: parts.count > 1 ? parts[1] : nil)
    }

    /// The words an action writes. Copied words — or copied files' paths, on the machine that holds
    /// them — go where the template says, or a blank line under the instruction when it does not
    /// say, so a heading reads over its quotation; the caret goes to `{cursor}`, or the end.
    public static func compose(
        _ action: QuickAskAction, fill: QuickAskFill,
        latest: (String) -> String? = QuickAskLocal.latestFile(in:)
    ) -> QuickAskComposed {
        var text = ""
        var caret: Int?
        var placedClipboard = false
        for piece in pieces(action.prompt) {
            switch piece {
            case .words(let words): text += words
            case .token(let token):
                switch token {
                case .clipboard, .link:
                    text += fill.clipboard ?? ""
                    placedClipboard = true
                case .cursor: caret = text.count
                case .date: text += day(fill.date)
                case .session: text += fill.session ?? ""
                case .latest(let folder): text += latest(folder) ?? ""
                case .file, .photo: text += fill.files.map { $0 + "\n" } ?? ""
                case .screen, .camera: break
                }
            }
        }
        if !placedClipboard, let copied = fill.clipboard, !copied.isEmpty, action.offer != .always {
            text += text.isEmpty ? copied : "\n\n" + copied
        }
        return QuickAskComposed(text: text, caret: min(caret ?? text.count, text.count))
    }

    private static func day(_ date: Date) -> String {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date)
    }
}

/// The sentence that names a conversation so an agent can find it and read it: which agent, what
/// it is called, its id, where it ran. An agent on the same machine reads the transcript from
/// there, which is how a chat is handed on without copying it.
public enum QuickAskSessionReference {
    public static func words(for entry: SessionEntry) -> String {
        let session = entry.session
        let title =
            AgentSession.isPlaceholderTitle(session.title) ? nil : session.title
        var details = ["id \(session.id)"]
        if let directory = session.directory, !directory.isEmpty {
            details.append(Localized.text("in %@", directory))
        }
        details.append(Localized.text("on %@", entry.profileName))
        let named = title.map { " “\($0)”" } ?? ""
        return Localized.text(
            "the Tailscode %@ session%@ (%@)", entry.backendType.displayName, named,
            details.joined(separator: ", "))
    }

    /// The chats worth offering to hand on: newest first across every machine, subagents left
    /// out, project chats and questions alike.
    public static func candidates(among entries: [SessionEntry], limit: Int = 12)
        -> [SessionEntry]
    {
        entries
            .filter { !$0.session.isSubagent }
            .sorted { $0.session.updatedAt > $1.session.updatedAt }
            .prefix(limit)
            .map { $0 }
    }
}

/// The aimed machine is the one the surface runs on: a file there is a path the agent can open,
/// so nothing is copied over the wire and nothing is capped at 8 MB.
public enum QuickAskLocal {
    public static func isThisMachine(_ profile: ConnectionProfile) -> Bool {
        guard let host = profile.baseURL.host, !host.isEmpty else { return false }
        return MediaHost.isThisMachine(host)
    }

    /// The paths, one per line, set off the way a path is written in a message.
    public static func mention(_ paths: [String]) -> String {
        paths.map { "`\($0)`" }.joined(separator: "\n")
    }

    /// The newest file directly in a folder (`~` is home), hidden and partial downloads left out.
    public static func latestFile(in folder: String) -> String? {
        let path = (folder as NSString).expandingTildeInPath
        let manager = FileManager.default
        guard
            let names = try? manager.contentsOfDirectory(atPath: path)
        else { return nil }
        var newest: (path: String, date: Date)?
        for name in names where !name.hasPrefix(".") && !partial(name) {
            let full = (path as NSString).appendingPathComponent(name)
            guard let attributes = try? manager.attributesOfItem(atPath: full),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let date = attributes[.modificationDate] as? Date
            else { continue }
            if newest.map({ date > $0.date }) ?? true { newest = (full, date) }
        }
        return newest?.path
    }

    private static func partial(_ name: String) -> Bool {
        let lower = name.lowercased()
        return [".part", ".crdownload", ".download", ".tmp"].contains { lower.hasSuffix($0) }
    }
}
