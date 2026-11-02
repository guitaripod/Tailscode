import Foundation

/// The actions the app ships. They are written as the first half of a sentence and never send by
/// themselves; the person can hide, reorder or rewrite any of them, and a rewritten one keeps its
/// id so it stays in its place.
public enum QuickAskBuiltIns {
    public static var all: [QuickAskAction] { starters + copied }

    public static func action(id: String) -> QuickAskAction? {
        all.first { $0.id == id }
    }

    public static var starters: [QuickAskAction] {
        [
            QuickAskAction(
                id: "web", title: Localized.text("Search the web"),
                detail: Localized.text("Checked now, not remembered"), glyph: "⊕",
                symbol: "globe", prompt: Localized.text("Search the web for ")),
            QuickAskAction(
                id: "explain", title: Localized.text("Explain something"),
                detail: Localized.text("A straight answer, no project"), glyph: "?",
                symbol: "text.magnifyingglass", prompt: Localized.text("Explain ")),
            QuickAskAction(
                id: "fix", title: Localized.text("Fix something"),
                detail: Localized.text("Found and fixed on the machine it runs on"), glyph: "⚒",
                symbol: "wrench.and.screwdriver",
                prompt: Localized.text("Find out why this isn't working and fix it: ")),
            QuickAskAction(
                id: "find", title: Localized.text("Find and download"),
                detail: Localized.text("Tracked down and saved on the machine"), glyph: "⇣",
                symbol: "arrow.down.circle", prompt: Localized.text("Find and download ")),
            QuickAskAction(
                id: "screen", title: Localized.text("Ask about the screen"),
                detail: Localized.text("Drag over what you mean"), glyph: "⬚",
                symbol: "rectangle.dashed",
                prompt: "{screen}" + Localized.text("What is this? ")),
            QuickAskAction(
                id: "continue", title: Localized.text("Continue a chat"),
                detail: Localized.text("Pick one; it reads it and carries on"), glyph: "↪",
                symbol: "arrow.turn.down.right",
                prompt: Localized.text("Read through %@ and continue where it left off. ", "{session}")),
            QuickAskAction(
                id: "latest", title: Localized.text("Use the newest download"),
                detail: Localized.text("The latest file in Downloads, by its path"), glyph: "⤓",
                symbol: "tray.and.arrow.down",
                prompt: Localized.text("Take %@ and ", "{latest:~/Downloads}")),
            QuickAskAction(
                id: "image", title: Localized.text("Make a picture"),
                detail: Localized.text("It comes back in the transcript"), glyph: "✦",
                symbol: "wand.and.sparkles", prompt: Localized.text("Generate an image of ")),
            QuickAskAction(
                id: "photo", title: Localized.text("Ask about a picture"),
                detail: Localized.text("Attach one and ask what it is"), glyph: "▣",
                symbol: "photo", prompt: "{photo}" + Localized.text("What is in this picture? ")),
            QuickAskAction(
                id: "camera", title: Localized.text("Point the camera at it"),
                detail: Localized.text("Shoot it, then ask"), glyph: "◉", symbol: "camera",
                prompt: "{camera}" + Localized.text("What am I looking at? ")),
            QuickAskAction(
                id: "file", title: Localized.text("Read a file"),
                detail: Localized.text("Sent with the question, or its path on this machine"),
                glyph: "▤", symbol: "doc.text",
                prompt: "{file}" + Localized.text("Read this and tell me ")),
            QuickAskAction(
                id: "draft", title: Localized.text("Draft a message"),
                detail: Localized.text("Words meant for someone else"), glyph: "✎",
                symbol: "square.and.pencil", prompt: Localized.text("Draft a message that ")),
            QuickAskAction(
                id: "translate", title: Localized.text("Translate something"),
                detail: Localized.text("Paste it under the line"), glyph: "⇄",
                symbol: "character.bubble", prompt: Localized.text("Translate this into English:\n")),
            QuickAskAction(
                id: "code", title: Localized.text("Write a snippet"),
                detail: Localized.text("Small enough to read at a glance"), glyph: "{}",
                symbol: "chevron.left.forwardslash.chevron.right",
                prompt: Localized.text("Write a snippet that ")),
        ]
    }

    public static var copied: [QuickAskAction] {
        links + [
            QuickAskAction(
                id: "copied.explain", title: Localized.text("Explain"), glyph: "?",
                symbol: "text.magnifyingglass", prompt: Localized.text("Explain this:"),
                offer: .text),
            QuickAskAction(
                id: "copied.summarize", title: Localized.text("Summarize"), glyph: "≡",
                symbol: "list.bullet", prompt: Localized.text("Summarize this:"), offer: .text),
            QuickAskAction(
                id: "copied.translate", title: Localized.text("Translate"), glyph: "⇄",
                symbol: "character.bubble",
                prompt: Localized.text("Translate this into English:"), offer: .text),
            QuickAskAction(
                id: "copied.improve", title: Localized.text("Improve"), glyph: "✎",
                symbol: "pencil",
                prompt: Localized.text("Improve the writing of this, keeping its meaning:"),
                offer: .text),
            QuickAskAction(
                id: "copied.reply", title: Localized.text("Reply"), glyph: "↩",
                symbol: "arrowshape.turn.up.left", prompt: Localized.text("Draft a reply to this:"),
                offer: .text),
            QuickAskAction(
                id: "copied.describe", title: Localized.text("Describe"), glyph: "◉",
                symbol: "eye", prompt: Localized.text("What is in this picture?"), offer: .picture),
            QuickAskAction(
                id: "copied.transcribe", title: Localized.text("Read the text"), glyph: "¶",
                symbol: "text.viewfinder",
                prompt: Localized.text("Transcribe the text in this picture."), offer: .picture),
            QuickAskAction(
                id: "copied.explainPicture", title: Localized.text("Explain"), glyph: "?",
                symbol: "questionmark.circle", prompt: Localized.text("Explain what this shows."),
                offer: .picture),
            QuickAskAction(
                id: "copied.summarizeFile", title: Localized.text("Summarize"), glyph: "≡",
                symbol: "list.bullet", prompt: Localized.text("Summarize this."), offer: .files),
            QuickAskAction(
                id: "copied.explainFile", title: Localized.text("Explain"), glyph: "?",
                symbol: "text.magnifyingglass", prompt: Localized.text("Explain this."),
                offer: .files),
            QuickAskAction(
                id: "copied.reviewFile", title: Localized.text("Review"), glyph: "✓",
                symbol: "checkmark.circle",
                prompt: Localized.text("Review this and point out anything wrong."), offer: .files),
        ]
    }

    /// A copied link is a page somebody wants something from, and what they want depends on the
    /// site: a thread is read, a video is watched for them, a repository is judged, a model is
    /// weighed against the card it would run on. The site's own errands lead, the two that fit any
    /// page follow.
    static var links: [QuickAskAction] {
        let social = ["x.com", "twitter.com"]
        let video = ["youtube.com", "youtu.be", "vimeo.com", "twitch.tv"]
        let clips = video + social + ["reddit.com", "redd.it", "tiktok.com", "instagram.com"]
        return [
            QuickAskAction(
                id: "link.thread", title: Localized.text("Read the thread"), glyph: "≡",
                symbol: "text.bubble",
                prompt: Localized.text("Read this thread, replies included, and tell me what it says:"),
                offer: .link, hosts: social),
            QuickAskAction(
                id: "link.watch", title: Localized.text("TL;DR the video"), glyph: "▶",
                symbol: "play.rectangle",
                prompt: Localized.text("Read this video's transcript and give me the TL;DR:"),
                offer: .link, hosts: video),
            QuickAskAction(
                id: "link.repo", title: Localized.text("Can I use this?"), glyph: "⑂",
                symbol: "chevron.left.forwardslash.chevron.right",
                prompt: Localized.text(
                    "Read this repository: what it does, whether it is legit, and how I would use it:"),
                offer: .link, hosts: ["github.com", "gitlab.com", "codeberg.org"]),
            QuickAskAction(
                id: "link.model", title: Localized.text("Will it run here?"), glyph: "▦",
                symbol: "cpu",
                prompt: Localized.text(
                    "Which variants of this model fit my GPU, and how fast would they run?"),
                offer: .link, hosts: ["huggingface.co", "hf.co", "ollama.com"]),
            QuickAskAction(
                id: "link.source", title: Localized.text("Find the source"), glyph: "⌕",
                symbol: "magnifyingglass",
                prompt: Localized.text("Find the original source or project behind this:"),
                offer: .link, hosts: social + ["reddit.com", "youtube.com", "youtu.be"]),
            QuickAskAction(
                id: "link.download", title: Localized.text("Download it"), glyph: "⇣",
                symbol: "arrow.down.circle",
                prompt: Localized.text("Download this at the best quality there is:"),
                offer: .link, hosts: clips),
            QuickAskAction(
                id: "link.summarize", title: Localized.text("Summarize"), glyph: "≡",
                symbol: "list.bullet", prompt: Localized.text("Read this and give me the short version:"),
                offer: .link),
            QuickAskAction(
                id: "link.what", title: Localized.text("What is this?"), glyph: "?",
                symbol: "questionmark.circle",
                prompt: Localized.text("What is this, and is it legit?"), offer: .link),
        ]
    }
}

/// A built-in rewritten in a file by hand: only the fields written replace the app's own.
struct QuickAskActionPatch: Decodable {
    var title: String?
    var detail: String?
    var glyph: String?
    var symbol: String?
    var prompt: String?
    var offer: QuickAskAction.Offer?
    var hosts: [String]?
    var aim: QuickAskActionAim?
    var sends: Bool?

    func applied(to builtIn: QuickAskAction) -> QuickAskAction {
        var action = builtIn
        if let title, !title.isEmpty { action.title = title }
        if let detail { action.detail = detail }
        if let glyph, !glyph.isEmpty { action.glyph = glyph }
        if let symbol, !symbol.isEmpty { action.symbol = symbol }
        if let prompt, !prompt.isEmpty { action.prompt = prompt }
        if let offer { action.offer = offer }
        if let hosts { action.hosts = hosts }
        if let aim { action.aim = aim.isEmpty ? nil : aim }
        if let sends { action.sends = sends }
        return action
    }
}

/// The person's actions, on this device: one small JSON file beside the app's other settings,
/// readable and writable by hand or by an agent. Built-ins are named by id and drawn from the app,
/// so a translation or a reworded built-in reaches them; a built-in written out in full is the
/// person's rewrite and wins. A built-in the file does not mention is appended, so a new one
/// arrives after an update without undoing anything the person arranged.
public enum QuickAskActions {
    public static let didChange = Notification.Name("tailscode.quickask.actions.didChange")

    nonisolated(unsafe) public static var fileURL: URL = defaultURL

    public static var defaultURL: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Tailscode", isDirectory: true)
            .appendingPathComponent("quick-actions.json")
    }

    private struct Entry: Codable {
        var action: QuickAskAction?
        var reference: String?
        var hidden: Bool

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            let id = try values.decode(String.self, forKey: .id)
            hidden = (try? values.decodeIfPresent(Bool.self, forKey: .hidden)).flatMap { $0 } ?? false
            let keys = Set(try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue))
                .subtracting(["id", "hidden"])
            if let builtIn = QuickAskBuiltIns.action(id: id) {
                if keys.isEmpty {
                    reference = id
                    action = nil
                } else {
                    reference = nil
                    action = try QuickAskActionPatch(from: decoder).applied(to: builtIn)
                }
            } else {
                reference = nil
                action = try QuickAskAction(from: decoder)
            }
        }

        init(action: QuickAskAction) {
            if let builtIn = QuickAskBuiltIns.action(id: action.id),
                Self.same(builtIn, action)
            {
                self.reference = action.id
                self.action = nil
            } else {
                self.reference = nil
                self.action = action
            }
            hidden = action.hidden
        }

        private static func same(_ builtIn: QuickAskAction, _ action: QuickAskAction) -> Bool {
            var shown = action
            shown.hidden = builtIn.hidden
            return shown == builtIn
        }

        func encode(to encoder: Encoder) throws {
            if let reference {
                var values = encoder.container(keyedBy: Keys.self)
                try values.encode(reference, forKey: .id)
                if hidden { try values.encode(true, forKey: .hidden) }
            } else if let action {
                try action.encode(to: encoder)
            }
        }

        private enum Keys: String, CodingKey {
            case id, hidden
        }

        private struct AnyKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }

    private struct File: Codable {
        var version: Int
        var actions: [Lenient]

        init(version: Int, actions: [Lenient]) {
            self.version = version
            self.actions = actions
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            actions = try values.decode([Lenient].self, forKey: .actions)
        }
    }

    private struct Lenient: Codable {
        let entry: Entry?

        init(from decoder: Decoder) throws {
            entry = try? Entry(from: decoder)
        }

        init(_ entry: Entry) { self.entry = entry }

        func encode(to encoder: Encoder) throws { try entry?.encode(to: encoder) }
    }

    nonisolated(unsafe) private static var cache: (stamp: Date?, actions: [QuickAskAction], unread: Int)?

    /// Every action in the person's order, hidden ones included, so an editor can bring one back.
    public static func all() -> [QuickAskAction] { read().actions }

    /// Entries in the file that could not be read: a hand edit that broke one is said, not lost.
    public static var unreadable: Int { read().unread }

    public static func visible() -> [QuickAskAction] { all().filter { !$0.hidden } }

    public static func action(id: String) -> QuickAskAction? {
        all().first { $0.id == id }
    }

    private static func read() -> (actions: [QuickAskAction], unread: Int) {
        let stamp = modified()
        if let cache, cache.stamp == stamp { return (cache.actions, cache.unread) }
        var actions: [QuickAskAction] = []
        var unread = 0
        if let data = try? Data(contentsOf: fileURL) {
            if let file = try? JSONDecoder().decode(File.self, from: data) {
                for lenient in file.actions {
                    guard let entry = lenient.entry, let action = resolve(entry),
                        !actions.contains(where: { $0.id == action.id })
                    else {
                        unread += 1
                        continue
                    }
                    actions.append(action)
                }
            } else {
                unread = 1
            }
        }
        for builtIn in QuickAskBuiltIns.all where !actions.contains(where: { $0.id == builtIn.id }) {
            actions.append(builtIn)
        }
        cache = (stamp, actions, unread)
        return (actions, unread)
    }

    private static func resolve(_ entry: Entry) -> QuickAskAction? {
        if let reference = entry.reference, var builtIn = QuickAskBuiltIns.action(id: reference) {
            builtIn.hidden = entry.hidden
            return builtIn
        }
        guard var action = entry.action, !action.prompt.isEmpty else { return nil }
        if action.title.isEmpty { action.title = action.prompt }
        action.hidden = entry.hidden
        return action
    }

    private static func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate]
            as? Date
    }

    /// Writes the whole list in the order given. Built-ins the person never changed are written as
    /// a bare id, so the file stays short enough to edit by hand.
    public static func write(_ actions: [QuickAskAction]) {
        let file = File(version: 1, actions: actions.map { Lenient(Entry(action: $0)) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(file) else { return }
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        keepUnreadableFile()
        try? data.write(to: fileURL, options: .atomic)
        cache = nil
        StoreNotice.post(didChange)
    }

    /// Saves an action in place, or after the last one when it is new.
    public static func save(_ action: QuickAskAction) {
        var actions = all()
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index] = action
        } else {
            actions.append(action)
        }
        write(actions)
    }

    /// A built-in is hidden rather than deleted, so it can come back; a written one is gone.
    public static func remove(id: String) {
        var actions = all()
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        if actions[index].isBuiltIn {
            actions[index].hidden = true
        } else {
            actions.remove(at: index)
        }
        write(actions)
    }

    public static func setHidden(_ hidden: Bool, id: String) {
        var actions = all()
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[index].hidden = hidden
        write(actions)
    }

    /// Moves an action past its visible neighbours of the same kind, which is the order the
    /// surface draws: hidden ones and the other kind are stepped over.
    public static func move(id: String, by steps: Int) {
        var actions = all()
        guard let from = actions.firstIndex(where: { $0.id == id }), steps != 0 else { return }
        let starter = actions[from].offer == .always
        let peers = actions.indices.filter {
            !actions[$0].hidden && (actions[$0].offer == .always) == starter
        }
        guard let place = peers.firstIndex(of: from) else { return }
        let target = max(0, min(peers.count - 1, place + steps))
        guard target != place else { return }
        let moved = actions.remove(at: from)
        actions.insert(moved, at: min(peers[target], actions.count))
        write(actions)
    }

    /// Back to the app's own list: rewrites and hidden built-ins undone, written actions kept.
    public static func restoreBuiltIns() {
        let written = all().filter { !$0.isBuiltIn }
        write(QuickAskBuiltIns.all + written)
    }

    /// A file that does not parse as a whole is somebody's hand edit gone wrong; it is set aside
    /// beside itself before anything overwrites it.
    private static func keepUnreadableFile() {
        guard let data = try? Data(contentsOf: fileURL),
            (try? JSONDecoder().decode(File.self, from: data)) == nil
        else { return }
        let aside = fileURL.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: fileURL, to: aside)
    }

    public static func newID() -> String {
        "custom." + UUID().uuidString.prefix(8).lowercased()
    }

    /// Drops what was read, for a file changed behind the cache's back within one clock tick.
    public static func forget() {
        cache = nil
    }
}
