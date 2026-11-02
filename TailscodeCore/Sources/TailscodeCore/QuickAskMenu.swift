import CodingAgentKit
import Foundation

/// One line of the quick ask's list: an action, a question waiting for later, a question already
/// asked, a chat to hand on, or the way to write a new action. Every client draws the same lines
/// in the same order with the same words, so what a key picks is never a per-toolkit guess.
public struct QuickAskMenuItem: Sendable, Identifiable {
    public enum Kind: Sendable {
        case errand(QuickAskClipboardErrand)
        case starter(QuickAskStarter)
        case later(QuickAskLater)
        case recent(SessionEntry)
        case session(SessionEntry)
        case newAction
    }

    public let kind: Kind
    public let id: String
    public let glyph: String
    public let symbol: String
    public let title: String
    /// The quieter words after the title.
    public let detail: String
    /// What stands at the far end: where an action asks, when a question is asked, how long ago.
    public let badge: String?
    /// The digit that picks it with the modifier, 1 to 9, where it has one.
    public let digit: Int?

    /// The action the line runs, for its menu of changes.
    public var action: QuickAskAction? {
        switch kind {
        case .starter(let starter): return starter.action
        case .errand(let errand): return errand.action
        case .later, .recent, .session, .newAction: return nil
        }
    }
}

public struct QuickAskMenuSection: Sendable, Identifiable {
    public let id: String
    public let title: String
    /// A glimpse under the title: what was copied, where it was read.
    public let note: String?
    public let items: [QuickAskMenuItem]

    public init(id: String, title: String, note: String? = nil, items: [QuickAskMenuItem]) {
        self.id = id
        self.title = title
        self.note = note
        self.items = items
    }

    /// The section can be set aside: what was copied is not what this question is about.
    public var isCopied: Bool { id == "copied" }
}

/// What the empty quick ask lists and what a typed question is offered, decided once.
///
/// The list reads top to bottom as the order of likelihood: the actions the person reaches for,
/// then what is waiting for later, then what was asked here before. Digits go to the copied card's
/// errands first and then to the actions, so the nine fastest keys are always the nine most likely
/// things.
public enum QuickAskMenu {
    public static let suggestionLimit = 3

    public static func sections(
        copied: QuickAskCopied? = nil, starters: [QuickAskStarter], later: [QuickAskLater],
        recents: [SessionEntry], aimWords: (QuickAskActionAim) -> String? = { _ in nil },
        now: Date = Date()
    ) -> [QuickAskMenuSection] {
        var sections: [QuickAskMenuSection] = []
        let errands = copied?.errands ?? []
        if let copied, !errands.isEmpty {
            sections.append(
                QuickAskMenuSection(
                    id: "copied", title: copied.headline, note: copied.preview,
                    items: errands.enumerated().map { index, errand in
                        QuickAskMenuItem(
                            kind: .errand(errand), id: "errand:" + errand.id, glyph: errand.glyph,
                            symbol: errand.symbol, title: errand.title, detail: "",
                            badge: errand.action.aim.flatMap(aimWords), digit: digit(at: index))
                    }))
        }
        let digitsTaken = errands.count
        var actions = starters.enumerated().map { index, starter in
            QuickAskMenuItem(
                kind: .starter(starter), id: "action:" + starter.id, glyph: starter.glyph,
                symbol: starter.symbol, title: starter.title, detail: starter.detail,
                badge: starter.action.aim.flatMap(aimWords),
                digit: digit(at: digitsTaken + index))
        }
        actions.append(
            QuickAskMenuItem(
                kind: .newAction, id: "new-action", glyph: "+", symbol: "plus",
                title: QuickAskMenuWords.newAction, detail: QuickAskMenuWords.newActionDetail,
                badge: nil, digit: nil))
        sections.append(
            QuickAskMenuSection(id: "actions", title: QuickAskMenuWords.actions, items: actions))
        if !later.isEmpty {
            sections.append(
                QuickAskMenuSection(
                    id: "later", title: QuickAskLaterWords.section,
                    items: later.map { waiting in
                        QuickAskMenuItem(
                            kind: .later(waiting), id: "later:" + waiting.id, glyph: "◷",
                            symbol: "clock", title: waiting.headline, detail: "",
                            badge: QuickAskLaterWords.when(waiting, now: now), digit: nil)
                    }))
        }
        if !recents.isEmpty {
            sections.append(
                QuickAskMenuSection(
                    id: "recent", title: QuickAskWords.asked,
                    items: recents.map { entry in
                        QuickAskMenuItem(
                            kind: .recent(entry), id: "recent:" + entry.session.id, glyph: "↻",
                            symbol: "arrow.counterclockwise", title: title(of: entry), detail: "",
                            badge: SessionRowModel.age(of: entry.session.updatedAt), digit: nil)
                    }))
        }
        return sections
    }

    /// `{session}` waiting for a chat: the recent ones on every machine, each with the agent and
    /// the machine that ran it, the first nine on digits.
    public static func sessions(_ candidates: [SessionEntry]) -> [QuickAskMenuSection] {
        [
            QuickAskMenuSection(
                id: "sessions", title: QuickAskMenuWords.whichChat,
                items: candidates.enumerated().map { index, entry in
                    QuickAskMenuItem(
                        kind: .session(entry), id: "session:" + entry.session.id, glyph: "↪",
                        symbol: "arrow.turn.down.right", title: title(of: entry),
                        detail: entry.backendType.displayName + " · " + entry.profileName,
                        badge: SessionRowModel.age(of: entry.session.updatedAt),
                        digit: digit(at: index))
                })
        ]
    }

    public static func items(_ sections: [QuickAskMenuSection]) -> [QuickAskMenuItem] {
        sections.flatMap(\.items)
    }

    /// The actions a typed question is offered, as verbs for it: the first few of the person's own
    /// order, which recency already leads with. Actions that ask for a chat to hand on are left
    /// out, since the words typed are the question, not the chat.
    public static func suggestions(_ starters: [QuickAskStarter], limit: Int = suggestionLimit)
        -> [QuickAskStarter]
    {
        Array(starters.filter { !$0.action.gathers.contains(.session) }.prefix(limit))
    }

    static func digit(at index: Int) -> Int? {
        index < 9 ? index + 1 : nil
    }

    private static func title(of entry: SessionEntry) -> String {
        AgentSession.isPlaceholderTitle(entry.session.title)
            ? QuickAskWords.untitled : entry.session.title
    }
}

/// Where the keyboard stands in the list. Nothing is selected until an arrow asks for it, so a
/// question typed and sent never runs a line by accident; moving past either end stays at the end
/// rather than wrapping, because a list read top to bottom has a top.
public struct QuickAskMenuCursor: Sendable, Equatable {
    public private(set) var index: Int?

    public init(index: Int? = nil) {
        self.index = index
    }

    public mutating func move(by delta: Int, count: Int) {
        guard count > 0 else {
            index = nil
            return
        }
        guard let current = index else {
            index = delta >= 0 ? 0 : count - 1
            return
        }
        let next = current + delta
        index = next < 0 ? nil : min(next, count - 1)
    }

    public mutating func clear() {
        index = nil
    }

    /// Keeps the selection on the same line after the list was redrawn, or drops it.
    public mutating func follow(id: String?, in items: [QuickAskMenuItem]) {
        guard let id else {
            index = nil
            return
        }
        index = items.firstIndex { $0.id == id }
    }
}

/// The one line of keys at the foot of the surface, said for the platform it is drawn on. It
/// changes with what the box holds: an empty box is a list to walk, a typed question is a send.
public enum QuickAskFooter {
    public struct Key: Sendable, Equatable {
        public let keys: String
        public let word: String

        public init(keys: String, word: String) {
            self.keys = keys
            self.word = word
        }
    }

    public static func keys(
        platform: SummonPlatform, typing: Bool, party: Bool, screen: Bool, suggestions: Int
    ) -> [Key] {
        let apple = platform == .apple
        var keys: [Key] = []
        if typing {
            keys.append(Key(keys: apple ? "↩" : "↵", word: Localized.text("ask")))
            if suggestions > 0 {
                keys.append(
                    Key(
                        keys: (apple ? "⌥" : "alt+") + "1–\(suggestions)",
                        word: Localized.text("with an action")))
            }
            if party { keys.append(Key(keys: apple ? "⌥↩" : "alt+↵", word: Localized.text("party"))) }
            keys.append(Key(keys: apple ? "⌘L" : "alt+L", word: Localized.text("later")))
        } else {
            keys.append(Key(keys: "↑↓", word: Localized.text("choose")))
            keys.append(Key(keys: apple ? "↩" : "↵", word: Localized.text("run")))
            keys.append(Key(keys: apple ? "⌘1–9" : "alt+1–9", word: Localized.text("pick")))
            keys.append(Key(keys: apple ? "⇥" : "tab", word: Localized.text("machine")))
        }
        if screen { keys.append(Key(keys: apple ? "⌘⇧S" : "alt+S", word: Localized.text("screen"))) }
        return keys
    }
}

public enum QuickAskMenuWords {
    public static var actions: String { Localized.text("Actions") }
    public static var whichChat: String { Localized.text("Which chat?") }
    public static var newAction: String { Localized.text("New action") }
    public static var newActionDetail: String { Localized.text("Right-click any action to change it") }
    public static var suggest: String { Localized.text("With") }
}
