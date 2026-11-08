import Foundation

/// The one microphone a process has, held by at most one take. Opening a take in another pane or
/// window finishes the one already open, which keeps its words; a voice call asks the desk to
/// finish whatever is open before it takes the microphone itself.
public actor DictationDesk {
    public static let shared = DictationDesk()

    private var owner: String?
    private var session: DictationSession?

    public init() {}

    /// Gives the microphone to `owner`'s take, finishing any other surface's take first.
    public func claim(_ owner: String, session: DictationSession) async {
        if let current = self.session, current !== session {
            await current.finish()
        }
        self.owner = owner
        self.session = session
    }

    /// Lets go of `session` if it still holds the microphone.
    public func release(_ session: DictationSession) {
        guard self.session === session else { return }
        self.session = nil
        owner = nil
    }

    /// Finishes whatever take is open, keeping its words. A voice call calls this before it opens
    /// the microphone.
    public func finishAny() async {
        guard let current = session else { return }
        session = nil
        owner = nil
        await current.finish()
    }

    public var holder: String? { owner }
}

/// The person's dictation choices, shared by every client: the language (nil is automatic) and
/// whether the chat's words bias the engine.
public enum DictationPreferences {
    static let languageKey = "tailscode.dictation.language"
    static let chatWordsKey = "tailscode.dictation.chatWords"
    public static let didChange = Notification.Name("tailscode.dictation.didChange")

    public static var language: String? {
        get {
            let value = UserDefaults.standard.string(forKey: languageKey)
            return value?.isEmpty == false ? value : nil
        }
        set {
            UserDefaults.standard.set(newValue ?? "", forKey: languageKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    public static var usesChatWords: Bool {
        get { UserDefaults.standard.object(forKey: chatWordsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: chatWordsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}
