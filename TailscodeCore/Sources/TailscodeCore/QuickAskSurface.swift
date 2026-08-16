import CodingAgentKit
import Foundation

/// One errand the empty surface offers. It is not a canned prompt so much as the first half of a
/// sentence: the words land in the composer with the caret at their end, and the person finishes
/// them. Nothing is ever sent by touching one — a question the app wrote and sent on its own
/// behalf is the one thing a quick ask must never do.
public struct QuickAskStarter: Sendable, Equatable, Identifiable {
    /// What a row opens before the words are the person's again.
    public enum Opening: String, Sendable, Equatable {
        case none
        case photos
        case camera
        case files
    }

    /// What the aim must be able to do for the row to be offered at all.
    public enum Need: String, Sendable, Equatable {
        case nothing
        case attachments
        case vision
        case camera
    }

    public let id: String
    public let symbol: String
    public let glyph: String
    public let title: String
    public let detail: String
    public let prompt: String
    public let opens: Opening
    public let needs: Need

    public init(
        id: String, symbol: String, glyph: String, title: String, detail: String, prompt: String,
        opens: Opening = .none, needs: Need = .nothing
    ) {
        self.id = id
        self.symbol = symbol
        self.glyph = glyph
        self.title = title
        self.detail = detail
        self.prompt = prompt
        self.opens = opens
        self.needs = needs
    }
}

/// The empty surface's argument for itself. A composer with nothing in it and no explanation is a
/// text box; these rows are what say that the thing on the other end reads pictures, makes them,
/// searches, drafts and translates — that a quick ask is a way into everything the agent can do
/// and not only a place to type a question. They are offered against what the current aim can
/// take, so the list is never a menu of disappointments, and what this device reaches for floats
/// to the top without ever hiding the rest.
public enum QuickAskStarters {
    public static let all: [QuickAskStarter] = [
        QuickAskStarter(
            id: "explain", symbol: "text.magnifyingglass", glyph: "?",
            title: Localized.text("Explain something"),
            detail: Localized.text("A straight answer, no project"),
            prompt: Localized.text("Explain ")),
        QuickAskStarter(
            id: "web", symbol: "globe", glyph: "@",
            title: Localized.text("Search the web"),
            detail: Localized.text("Checked now, not remembered"),
            prompt: Localized.text("Search the web for ")),
        QuickAskStarter(
            id: "image", symbol: "wand.and.sparkles", glyph: "*",
            title: Localized.text("Make a picture"),
            detail: Localized.text("It comes back in the transcript"),
            prompt: Localized.text("Generate an image of ")),
        QuickAskStarter(
            id: "photo", symbol: "photo", glyph: "[",
            title: Localized.text("Ask about a picture"),
            detail: Localized.text("Attach one and ask what it is"),
            prompt: Localized.text("What is in this picture? "),
            opens: .photos, needs: .vision),
        QuickAskStarter(
            id: "camera", symbol: "camera", glyph: "(",
            title: Localized.text("Point the camera at it"),
            detail: Localized.text("Shoot it, then ask"),
            prompt: Localized.text("What am I looking at? "),
            opens: .camera, needs: .camera),
        QuickAskStarter(
            id: "file", symbol: "doc.text", glyph: "#",
            title: Localized.text("Read a file"),
            detail: Localized.text("Up to 8 MB, sent with the question"),
            prompt: Localized.text("Read this and tell me "),
            opens: .files, needs: .attachments),
        QuickAskStarter(
            id: "draft", symbol: "square.and.pencil", glyph: "~",
            title: Localized.text("Draft a message"),
            detail: Localized.text("Words meant for someone else"),
            prompt: Localized.text("Draft a message that ")),
        QuickAskStarter(
            id: "translate", symbol: "character.bubble", glyph: "&",
            title: Localized.text("Translate something"),
            detail: Localized.text("Paste it under the line"),
            prompt: Localized.text("Translate this into English:\n")),
        QuickAskStarter(
            id: "code", symbol: "chevron.left.forwardslash.chevron.right", glyph: "$",
            title: Localized.text("Write a snippet"),
            detail: Localized.text("Small enough to read at a glance"),
            prompt: Localized.text("Write a snippet that ")),
    ]

    /// The rows this aim can honour, most recently used first and the catalog's own order behind
    /// them. A recent row that the current aim cannot carry out is dropped like any other: what
    /// this device reached for last is a preference, never a promise the model has to keep.
    public static func offered(
        for abilities: ModelAbilities, recents: [String] = QuickAskStarterRecents.recent()
    ) -> [QuickAskStarter] {
        let capable = all.filter { starter in
            switch starter.needs {
            case .nothing: return true
            case .attachments: return abilities.attachments
            case .vision: return abilities.vision
            case .camera: return abilities.camera
            }
        }
        let ranked = recents.compactMap { id in capable.first { $0.id == id } }
        return ranked + capable.filter { starter in !ranked.contains { $0.id == starter.id } }
    }

    public static func starter(id: String) -> QuickAskStarter? {
        all.first { $0.id == id }
    }
}

/// Which errands this device reaches for. Ordinary recency, kept small: the point is that the two
/// or three things somebody actually does with a quick ask stop being the two or three rows they
/// have to look for.
public enum QuickAskStarterRecents {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    private static let key = "tailscode.quickask.starters"
    public static let capacity = 3

    public static func recent() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    public static func record(_ id: String) {
        var kept = recent().filter { $0 != id }
        kept.insert(id, at: 0)
        defaults.set(Array(kept.prefix(capacity)), forKey: key)
    }

    public static func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// The questions already asked here. A quick ask mints an ordinary conversation with no project
/// directory, which is exactly what makes it findable again: the surface can offer the last few
/// back without a listing of its own, so a lookup that turned into something worth continuing is
/// one touch away instead of somewhere in the chat list.
public enum QuickAskRecents {
    public static let capacity = 3

    /// The recent asks on one server: newest first, project chats and subagent transcripts left
    /// out, and nothing invented for a server that has never been asked anything.
    public static func asks(
        among entries: [SessionEntry], profileID: String, limit: Int = capacity
    ) -> [SessionEntry] {
        entries
            .filter {
                $0.profileID == profileID && $0.session.directory == nil
                    && !$0.session.isSubagent
            }
            .sorted { $0.session.updatedAt > $1.session.updatedAt }
            .prefix(limit)
            .map { $0 }
    }
}

/// What the one prompt box on a client's front door is aimed at.
///
/// A desktop takes a key from the whole machine, so its quick ask is a window that arrives over
/// whatever was in front. A phone has no key to take and no window to arrive in — but it already
/// has a prompt box sitting at the bottom of its front door, and a question differs from the thing
/// typed there in exactly one way: it has no project. So the phone's quick ask is that same box in
/// its other lane, and the switch between them is the whole gesture: no sheet to summon, no second
/// composer to learn, and the words survive the flip because each lane keeps its own draft.
///
/// The two lanes are told apart by what they aim at rather than by what they can do: `chat` starts
/// a conversation in a project, `ask` starts one on a machine with the ask's own model — and both
/// send pictures, files and slash commands, because a lookup and an errand are the same gesture.
public enum QuickAskLane: String, Sendable, CaseIterable {
    case chat
    case ask

    public var toggled: QuickAskLane { self == .ask ? .chat : .ask }

    /// The one word on the switch. It names the lane being offered rather than the one in force,
    /// which is why it does not change when the switch is thrown — a control whose label moves
    /// under the finger is a control nobody can aim at twice.
    public static var switchTitle: String { Localized.text("Ask") }

    public var placeholder: String {
        switch self {
        case .chat: return Localized.text("Start a new chat…")
        case .ask: return Localized.text("Ask anything — no project, no setup")
        }
    }

    /// What a screen reader is told the switch is, said as the state it is in. A toggle that reads
    /// out its verb instead of its state leaves the one fact a blind reader came for unsaid.
    public var spoken: String {
        switch self {
        case .chat:
            return Localized.text(
                "Quick ask off. Sending starts a chat in the project named beside this switch.")
        case .ask:
            return Localized.text(
                "Quick ask on. Sending asks the named machine with no project, on the model this ask remembers."
            )
        }
    }
}

/// The words the empty ask lane argues for itself with, and the ones its recents wear. Held here
/// rather than in a client so the offer and the memory are described the same way wherever the
/// lane is drawn — a strip of chips above a docked bar, or rows down a summoned panel.
public enum QuickAskWords {
    public static var offer: String { Localized.text("Try") }
    public static var asked: String { Localized.text("Asked here") }
    public static var untitled: String { Localized.text("Untitled question") }
    public static var noServers: String { Localized.text("Add a server to ask anything") }
}

/// What the surface is doing with the question in it. The words are the whole point: a quick ask
/// that is waiting says which machine it is waiting on, and one that failed says so where the
/// asking happened rather than as an alert on whatever screen a dismissal revealed.
public enum QuickAskComposition {
    /// Whether there is anything to send. Attachments alone are a send — a picture handed over
    /// with no words is a question, and the agent can be trusted to see it.
    public static func canSend(text: String, attachments: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments > 0
    }

    /// What a picture or file waiting in the composer is called once the aim can no longer take
    /// it, said as the thing that happened rather than as an error somebody made.
    public static func droppedNotice(count: Int) -> String {
        count == 1
            ? Localized.text("The attachment was removed — this model can't read it.")
            : Localized.text("%@ attachments were removed — this model can't read them.", "\(count)")
    }

    public static func waitingTitle(server: String) -> String {
        Localized.text("Asking %@…", server)
    }
}
