import CodingAgentKit
import Foundation

/// A question is not a project, so a quick ask owes no form: the surface offers one composer,
/// aims itself, and sending is the whole ceremony. The aim is this device's memory of where the
/// last quick ask went and what it ran on — a preference, not a fact about any server — and the
/// conversation it mints is ordinary in every way except that it carries no project directory.
public enum QuickAskDefaults {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    private static let serverKey = "tailscode.quickask.server"
    private static let ownAimPrefix = "tailscode.quickask.aimed."
    public static let didChange = Notification.Name("tailscode.quickask.didChange")

    public static var lastProfileID: String? {
        defaults.string(forKey: serverKey)
    }

    public static func record(profileID: String) {
        defaults.set(profileID, forKey: serverKey)
        StoreNotice.post(didChange)
    }

    public static func clear() {
        defaults.removeObject(forKey: serverKey)
        StoreNotice.post(didChange)
    }

    /// Which server answers a quick ask: the one the last quick ask used while it is still
    /// among the servers offered, else the caller's own fallback (the composer's aim, the only
    /// server), else the first server offered. Nil only when there are no servers at all — the
    /// surface's cue to offer setup instead of a dead text box.
    public static func target(among profileIDs: [String], fallback: String? = nil) -> String? {
        if let last = lastProfileID, profileIDs.contains(last) { return last }
        if let fallback, profileIDs.contains(fallback) { return fallback }
        return profileIDs.first
    }

    /// Where a quick ask keeps its own model and effort on a given server — a context beside the
    /// server's own, never inside it, so a lookup and a project chat on the same machine can run
    /// on different models without either one moving the other.
    public static func contextID(forProfileID profileID: String) -> String {
        "ask:" + profileID
    }

    /// True once a quick ask has been aimed at a model on this server by hand.
    public static func hasOwnAim(forProfileID profileID: String) -> Bool {
        defaults.bool(forKey: ownAimPrefix + profileID)
    }

    /// Which memory a quick ask reads: its own once one exists, the server's until then, so the
    /// first question runs on the model a new chat there would have used rather than on nothing.
    public static func aimContext(forProfileID profileID: String) -> String {
        hasOwnAim(forProfileID: profileID) ? contextID(forProfileID: profileID) : profileID
    }

    /// The model a quick ask on this server will run on. Nil means the server decides — which is
    /// a real answer once the aim is the quick ask's own, and a lack of one before that.
    public static func model(forProfileID profileID: String) -> ModelSelection? {
        ModelPreferenceStore.globalModel(forContextID: aimContext(forProfileID: profileID))
    }

    public static func effort(forProfileID profileID: String) -> String? {
        EffortPreferenceStore.globalEffort(forContextID: aimContext(forProfileID: profileID))
    }

    /// A pick claims the quick ask's own context and stays there. The server's memory is left
    /// exactly as it was: picking a cheap model for lookups may never re-aim the project chats.
    public static func recordModel(_ model: ModelSelection?, forProfileID profileID: String) {
        claimOwnAim(forProfileID: profileID)
        ModelPreferenceStore.setGlobalModel(
            model, forContextID: contextID(forProfileID: profileID))
        if let model { RecentModelsStore.record(model) }
        StoreNotice.post(didChange)
    }

    public static func recordEffort(_ level: String?, forProfileID profileID: String) {
        claimOwnAim(forProfileID: profileID)
        EffortPreferenceStore.setGlobalEffort(
            level, forContextID: contextID(forProfileID: profileID))
        StoreNotice.post(didChange)
    }

    /// A model picked on another machine re-aims the whole question at that machine — the same
    /// move `ModelFleet.adopt` makes for a chat, except the pick is filed as the quick ask's own
    /// so the other server's composer keeps whatever it was working with.
    public static func adopt(_ pick: ModelPick) {
        recordModel(pick.selection, forProfileID: pick.profileID)
    }

    /// Hands the aim back to the server's own memory, so a quick ask follows the machine again.
    public static func clearOwnAim(forProfileID profileID: String) {
        defaults.removeObject(forKey: ownAimPrefix + profileID)
        ModelPreferenceStore.setGlobalModel(nil, forContextID: contextID(forProfileID: profileID))
        EffortPreferenceStore.setGlobalEffort(nil, forContextID: contextID(forProfileID: profileID))
        StoreNotice.post(didChange)
    }

    /// The minted conversation is stamped with the aim before it opens: the session carries the
    /// model the question was asked with, so whichever composer picks the chat up runs it there
    /// rather than re-deriving it from the server's memory, which the aim deliberately left
    /// alone. An aim the quick ask never claimed stamps nothing — the chat then resolves exactly
    /// the way any other new chat on that server does.
    public static func stamp(profileID: String, sessionID: String) {
        guard hasOwnAim(forProfileID: profileID) else { return }
        let key = sessionPreferenceKey(profileID: profileID, sessionID: sessionID)
        ModelPreferenceStore.setModel(model(forProfileID: profileID), forKey: key)
        EffortPreferenceStore.setEffort(effort(forProfileID: profileID), forKey: key)
    }

    /// A conversation asked of one party slot among several is stamped with that slot's model and
    /// level, whatever the quick ask's own aim says.
    public static func stamp(
        profileID: String, sessionID: String, model: ModelSelection?, effort: String?
    ) {
        let key = sessionPreferenceKey(profileID: profileID, sessionID: sessionID)
        ModelPreferenceStore.setModel(model, forKey: key)
        EffortPreferenceStore.setEffort(effort, forKey: key)
    }

    /// The key a conversation's own model and effort are filed under, spelled the same way on
    /// every client so a stamp made by one surface is read by any other.
    public static func sessionPreferenceKey(profileID: String, sessionID: String) -> String {
        "\(profileID)/\(sessionID)"
    }

    private static func claimOwnAim(forProfileID profileID: String) {
        guard !hasOwnAim(forProfileID: profileID) else { return }
        defaults.set(true, forKey: ownAimPrefix + profileID)
    }
}

/// An action's machine, model and level hold for one question. The aim the person had is read before
/// the action moves it and put back after the question leaves — unless the person moved the aim
/// again in between, in which case what they picked by hand is theirs and stays.
public struct QuickAskAimHold: Sendable, Equatable {
    struct Reading: Sendable, Equatable {
        let server: String?
        let ownAim: Bool
        let model: ModelSelection?
        let effort: String?

        static func read(profileID: String) -> Reading {
            let context = QuickAskDefaults.contextID(forProfileID: profileID)
            return Reading(
                server: QuickAskDefaults.lastProfileID,
                ownAim: QuickAskDefaults.hasOwnAim(forProfileID: profileID),
                model: ModelPreferenceStore.globalModel(forContextID: context),
                effort: EffortPreferenceStore.globalEffort(forContextID: context))
        }
    }

    let before: [String: Reading]
    let server: String?
    var after: [String: Reading] = [:]

    /// Reads the aim on every machine the action may touch, before it touches any.
    public static func begin(profileIDs: [String]) -> QuickAskAimHold {
        var before: [String: Reading] = [:]
        for id in Set(profileIDs) { before[id] = Reading.read(profileID: id) }
        return QuickAskAimHold(before: before, server: QuickAskDefaults.lastProfileID)
    }

    /// Notes what the action set, which is what a later release compares against.
    public mutating func settle() {
        var after: [String: Reading] = [:]
        for id in before.keys { after[id] = Reading.read(profileID: id) }
        self.after = after
    }

    /// Whether the machine and model are still what the action left. The level is not compared:
    /// a catalog arriving late can hand a level the model does not take back to the machine, and
    /// that is the surface tidying up, not the person choosing.
    public var isUntouched: Bool {
        before.keys.allSatisfy { id in
            let now = Reading.read(profileID: id)
            guard let then = after[id] else { return false }
            return now.server == then.server && now.ownAim == then.ownAim && now.model == then.model
        }
    }

    /// Puts the person's aim back, once, if nobody moved it since the action did.
    public func release() {
        guard !after.isEmpty, isUntouched else { return }
        for (id, reading) in before {
            if reading.ownAim {
                QuickAskDefaults.recordModel(reading.model, forProfileID: id)
                QuickAskDefaults.recordEffort(reading.effort, forProfileID: id)
            } else if QuickAskDefaults.hasOwnAim(forProfileID: id) {
                QuickAskDefaults.clearOwnAim(forProfileID: id)
            }
        }
        if let server { QuickAskDefaults.record(profileID: server) } else { QuickAskDefaults.clear() }
    }
}

/// The question asked of the whole party at once: every filled slot that can answer, each its own
/// conversation on the machine that runs it, so the answers can be read side by side.
public enum QuickAskParty {
    public struct Target: Sendable, Equatable {
        public let profileID: String
        public let preset: ModelPreset
        public let word: String
    }

    /// The slots a party send reaches, in slot order. A slot nobody can run, a machine that is not
    /// answering and an account whose window is spent are passed over rather than failed.
    public static func targets(_ cards: [PartyCard]) -> [Target] {
        var seen: [Target] = []
        for card in cards {
            guard let preset = card.resolved, let profileID = card.profileID, !card.isAway,
                !card.isSpent
            else { continue }
            let target = Target(profileID: profileID, preset: preset, word: card.modelWord)
            guard !seen.contains(target) else { continue }
            seen.append(target)
        }
        return seen
    }
}

/// One question on its way to several party slots: where each copy goes, on what, and what rides
/// with every one of them.
public struct QuickAskPartySend: Sendable {
    public struct Seat: Sendable, Equatable {
        public let profileID: String
        public let model: ModelSelection
        public let effort: String?
        public let word: String

        public init(profileID: String, model: ModelSelection, effort: String?, word: String) {
            self.profileID = profileID
            self.model = model
            self.effort = effort
            self.word = word
        }
    }

    public let seats: [Seat]
    public let send: QuickAskSend
    public let attachments: [PendingAttachment]

    public init(seats: [Seat], send: QuickAskSend, attachments: [PendingAttachment]) {
        self.seats = seats
        self.send = send
        self.attachments = attachments
    }
}

/// An action part way through: what it still has to fetch and what it has found so far. The
/// surface walks `remaining` in order, one gather at a time, and composes once nothing is left.
public struct QuickAskGathering: Sendable {
    public let action: QuickAskAction
    public var fill: QuickAskFill
    public var remaining: [QuickAskGather]
    public var attachments: [PendingAttachment]
    /// Paths named by `{file}` while the aim is this machine, set where the token stands.
    public var mentions: [String]
    /// The clipboard's own attachments and notices, for an action picked from the copied card.
    public var copiedAttachments: [PendingAttachment]
    public var fingerprint: String?

    public init(action: QuickAskAction, fill: QuickAskFill = QuickAskFill()) {
        self.action = action
        self.fill = fill
        self.remaining = action.gathers
        self.attachments = []
        self.mentions = []
        self.copiedAttachments = []
        self.fingerprint = nil
    }

    public var awaiting: QuickAskGather? { remaining.first }

    public mutating func advance() {
        if !remaining.isEmpty { remaining.removeFirst() }
    }

    /// The words, with `{file}` paths set where the token stands.
    public func composed(latest: (String) -> String? = QuickAskLocal.latestFile(in:))
        -> QuickAskComposed
    {
        var fill = fill
        if !mentions.isEmpty { fill.files = QuickAskLocal.mention(mentions) }
        return QuickAskTemplate.compose(action, fill: fill, latest: latest)
    }
}

/// What a quick ask's words turn out to be when they are sent.
///
/// A quick ask is a composer, so `/` means there what it means in a chat — but the decision has to
/// be made *here*, before the mint, because the conversation it will run in does not exist yet and
/// its catalog has not been fetched. The words travel with the decision so a failure can hand them
/// back, and a command that is only a command on the server it was typed for stays that way.
public struct QuickAskSend: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case prompt
        case command(AgentCommand, arguments: String?)
    }

    public let text: String
    public let kind: Kind

    public init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    /// The shared grammar, asked once. On an agent that resolves its own slash words from the
    /// prompt text this collapses to `.prompt` — which is correct rather than a shortfall: the
    /// server is the authority on its own grammar and the words go to it as written.
    ///
    /// Compaction is deliberately not a case here. A conversation minted by this send has no turns
    /// to trade, so the words that read a transcript are dropped from the catalog before the
    /// decision rather than after it — a surface that forgot to filter what it *offered* still
    /// cannot run one by hand.
    public static func decide(
        text: String, commands: [AgentCommand], resolvesFromPromptText: Bool
    ) -> QuickAskSend {
        switch SlashDispatch.decide(
            text: text, commands: CommandCatalogStore.forQuickAsk(commands),
            supportsCompaction: false, resolvesFromPromptText: resolvesFromPromptText)
        {
        case .run(let command, let arguments):
            return QuickAskSend(text: text, kind: .command(command, arguments: arguments))
        case .compactPreflight, .designPreflight, .delegatePreflight, .plainText:
            return QuickAskSend(text: text, kind: .prompt)
        }
    }
}
