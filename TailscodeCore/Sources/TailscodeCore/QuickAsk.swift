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
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func clear() {
        defaults.removeObject(forKey: serverKey)
        NotificationCenter.default.post(name: didChange, object: nil)
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
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func recordEffort(_ level: String?, forProfileID profileID: String) {
        claimOwnAim(forProfileID: profileID)
        EffortPreferenceStore.setGlobalEffort(
            level, forContextID: contextID(forProfileID: profileID))
        NotificationCenter.default.post(name: didChange, object: nil)
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
        NotificationCenter.default.post(name: didChange, object: nil)
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
