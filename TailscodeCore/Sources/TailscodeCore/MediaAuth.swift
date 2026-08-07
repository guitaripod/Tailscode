import CodingAgentKit
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What a signed-in account is worth remembering as: who it is, not what it can do. The scopes and
/// the tokens live in the secret store; this is the part a settings row prints.
public struct MediaAccount: Sendable, Codable, Hashable {
    public let source: MediaSource
    public let name: String
    public let handle: String
    public let avatar: String?

    public init(source: MediaSource, name: String, handle: String, avatar: String? = nil) {
        self.source = source
        self.name = name
        self.handle = handle
        self.avatar = avatar
    }
}

/// One account's keys, kept together. `SecretStore` is a flat string-to-string map with no
/// transaction across two writes, so the access token, the refresh token and the moment the first
/// stops working are one blob under one key — a half-written pair would be an account that looks
/// signed in and answers nothing.
public struct OAuthTokens: Sendable, Codable, Hashable {
    public let access: String
    public let refresh: String?
    public let expiresAt: Date?
    public let scope: String

    public init(access: String, refresh: String? = nil, expiresAt: Date? = nil, scope: String = "") {
        self.access = access
        self.refresh = refresh
        self.expiresAt = expiresAt
        self.scope = scope
    }

    /// True a minute before the token actually dies, because a request that starts valid and
    /// arrives expired reads to the user as a random sign-out.
    public func isStale(at moment: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return moment.addingTimeInterval(60) >= expiresAt
    }
}

/// What the person is told to do, and where. The device flow exists precisely because a desktop
/// pane is a bad place to host somebody's password: the site is opened in their own browser, they
/// confirm a short code there, and this app never sees a credential.
public struct DevicePrompt: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: String
    public let interval: TimeInterval
    public let expiresAt: Date

    public init(
        deviceCode: String, userCode: String, verificationURL: String, interval: TimeInterval,
        expiresAt: Date
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.interval = interval
        self.expiresAt = expiresAt
    }
}

/// What one poll of the token endpoint means. `slowDown` is not a failure — it is the site asking
/// to be asked less often, and a client that treats it as one signs nobody in.
public enum DevicePoll: Sendable, Equatable {
    case pending
    case slowDown
    case granted(OAuthTokens)
    case denied(String)
    case expired
}

/// A site somebody can sign into. Both of the two do the same dance in slightly different words, so
/// the dance lives here once and each site answers only for its own endpoints and its own idea of
/// who you are.
public protocol DeviceAuthority: Sendable {
    var source: MediaSource { get }
    /// False when the site needs something this build was not given — a client id it cannot ship.
    /// A row that cannot sign in says why rather than offering a button that fails.
    var isConfigured: Bool { get }
    var requirement: String? { get }
    func begin() async throws -> DevicePrompt
    func poll(_ deviceCode: String) async throws -> DevicePoll
    func refreshed(_ tokens: OAuthTokens) async throws -> OAuthTokens
    func account(_ tokens: OAuthTokens) async throws -> MediaAccount
}

/// Twitch's device flow, which its own web client uses and which therefore needs no application
/// registered by anybody: the same client id the directory already reads with is accepted here,
/// and the verification link it hands back carries the code, so signing in is one click and one
/// confirmation rather than a code somebody has to retype.
public struct TwitchAuthority: DeviceAuthority {
    public let source = MediaSource.twitch
    public static let deviceEndpoint = "https://id.twitch.tv/oauth2/device"
    public static let tokenEndpoint = "https://id.twitch.tv/oauth2/token"
    public static let scopes = "user:read:follows"

    public init() {}

    public var isConfigured: Bool { true }
    public var requirement: String? { nil }

    public func begin() async throws -> DevicePrompt {
        let answer = try await MediaForm.post(
            Self.deviceEndpoint,
            fields: ["client_id": TwitchDirectory.clientID, "scopes": Self.scopes],
            source: .twitch)
        guard let deviceCode = answer["device_code"] as? String,
            let userCode = answer["user_code"] as? String,
            let url = answer["verification_uri"] as? String
        else { throw MediaFailure.refused(.twitch, Self.reason(answer)) }
        return DevicePrompt(
            deviceCode: deviceCode, userCode: userCode, verificationURL: url,
            interval: (answer["interval"] as? Double) ?? 5,
            expiresAt: Date().addingTimeInterval((answer["expires_in"] as? Double) ?? 1800))
    }

    public func poll(_ deviceCode: String) async throws -> DevicePoll {
        let answer = try await MediaForm.post(
            Self.tokenEndpoint,
            fields: [
                "client_id": TwitchDirectory.clientID, "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ], source: .twitch)
        if let token = answer["access_token"] as? String {
            return .granted(Self.tokens(from: answer, access: token))
        }
        switch (answer["message"] as? String) ?? (answer["error"] as? String) ?? "" {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "expired_token", "device code expired": return .expired
        case let other where other.isEmpty:
            return .denied(Localized.text("Twitch refused the question"))
        case let other: return .denied(other)
        }
    }

    public func refreshed(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refresh = tokens.refresh else { throw MediaFailure.signedOut(.twitch) }
        let answer = try await MediaForm.post(
            Self.tokenEndpoint,
            fields: [
                "client_id": TwitchDirectory.clientID, "refresh_token": refresh,
                "grant_type": "refresh_token",
            ], source: .twitch)
        guard let token = answer["access_token"] as? String else {
            throw MediaFailure.signedOut(.twitch)
        }
        return Self.tokens(from: answer, access: token, fallbackRefresh: refresh)
    }

    public func account(_ tokens: OAuthTokens) async throws -> MediaAccount {
        let answer = try await MediaHelix.get("users", tokens: tokens, query: [:])
        guard let user = (answer["data"] as? [[String: Any]])?.first,
            let login = user["login"] as? String
        else { throw MediaFailure.signedOut(.twitch) }
        return MediaAccount(
            source: .twitch, name: user["display_name"] as? String ?? login, handle: login,
            avatar: user["profile_image_url"] as? String)
    }

    private static func tokens(
        from answer: [String: Any], access: String, fallbackRefresh: String? = nil
    ) -> OAuthTokens {
        let scope = (answer["scope"] as? [String])?.joined(separator: " ")
            ?? (answer["scope"] as? String) ?? scopes
        return OAuthTokens(
            access: access, refresh: answer["refresh_token"] as? String ?? fallbackRefresh,
            expiresAt: (answer["expires_in"] as? Double).map { Date().addingTimeInterval($0) },
            scope: scope)
    }

    private static func reason(_ answer: [String: Any]) -> String {
        (answer["message"] as? String) ?? Localized.text("Twitch refused the question")
    }
}

/// YouTube's device flow, which Google will only run for an application somebody registered. There
/// is no public client to borrow the way Twitch's web player lends one, so this build carries none
/// and says so: a client id and secret handed in through `MediaClientConfig` turn the row on, and
/// without them it explains what is missing instead of failing at the end of a flow.
public struct YouTubeAuthority: DeviceAuthority {
    public let source = MediaSource.youtube
    public static let deviceEndpoint = "https://oauth2.googleapis.com/device/code"
    public static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    public static let scopes = "https://www.googleapis.com/auth/youtube.readonly"

    public init() {}

    public var isConfigured: Bool { MediaClientConfig.youtube != nil }

    public var requirement: String? {
        isConfigured
            ? nil
            : Localized.text(
                "Google only runs this for a registered app. Make an OAuth client of type TV and Limited Input at console.cloud.google.com, then set TAILSCODE_YOUTUBE_CLIENT_ID and TAILSCODE_YOUTUBE_CLIENT_SECRET."
            )
    }

    public func begin() async throws -> DevicePrompt {
        guard let client = MediaClientConfig.youtube else { throw MediaFailure.unconfigured(.youtube) }
        let answer = try await MediaForm.post(
            Self.deviceEndpoint, fields: ["client_id": client.id, "scope": Self.scopes],
            source: .youtube)
        guard let deviceCode = answer["device_code"] as? String,
            let userCode = answer["user_code"] as? String,
            let url = answer["verification_url"] as? String ?? answer["verification_uri"] as? String
        else { throw MediaFailure.refused(.youtube, Self.reason(answer)) }
        return DevicePrompt(
            deviceCode: deviceCode, userCode: userCode, verificationURL: url,
            interval: (answer["interval"] as? Double) ?? 5,
            expiresAt: Date().addingTimeInterval((answer["expires_in"] as? Double) ?? 1800))
    }

    public func poll(_ deviceCode: String) async throws -> DevicePoll {
        guard let client = MediaClientConfig.youtube else { throw MediaFailure.unconfigured(.youtube) }
        let answer = try await MediaForm.post(
            Self.tokenEndpoint,
            fields: [
                "client_id": client.id, "client_secret": client.secret, "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ], source: .youtube)
        if let token = answer["access_token"] as? String {
            return .granted(Self.tokens(from: answer, access: token))
        }
        switch (answer["error"] as? String) ?? "" {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "expired_token": return .expired
        case "access_denied": return .denied(Localized.text("That was declined"))
        case let other where other.isEmpty:
            return .denied(Localized.text("Google refused the question"))
        case let other: return .denied(Self.reason(answer, fallback: other))
        }
    }

    public func refreshed(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let client = MediaClientConfig.youtube else { throw MediaFailure.unconfigured(.youtube) }
        guard let refresh = tokens.refresh else { throw MediaFailure.signedOut(.youtube) }
        let answer = try await MediaForm.post(
            Self.tokenEndpoint,
            fields: [
                "client_id": client.id, "client_secret": client.secret, "refresh_token": refresh,
                "grant_type": "refresh_token",
            ], source: .youtube)
        guard let token = answer["access_token"] as? String else {
            throw MediaFailure.signedOut(.youtube)
        }
        return Self.tokens(from: answer, access: token, fallbackRefresh: refresh)
    }

    public func account(_ tokens: OAuthTokens) async throws -> MediaAccount {
        let answer = try await MediaGoogle.get(
            "channels", tokens: tokens, query: ["part": "snippet", "mine": "true"])
        guard let channel = (answer["items"] as? [[String: Any]])?.first,
            let snippet = channel["snippet"] as? [String: Any]
        else { throw MediaFailure.signedOut(.youtube) }
        let handle = (snippet["customUrl"] as? String) ?? (channel["id"] as? String) ?? ""
        let thumbnails = (snippet["thumbnails"] as? [String: Any])?["default"] as? [String: Any]
        return MediaAccount(
            source: .youtube, name: snippet["title"] as? String ?? handle, handle: handle,
            avatar: thumbnails?["url"] as? String)
    }

    private static func tokens(
        from answer: [String: Any], access: String, fallbackRefresh: String? = nil
    ) -> OAuthTokens {
        OAuthTokens(
            access: access, refresh: answer["refresh_token"] as? String ?? fallbackRefresh,
            expiresAt: (answer["expires_in"] as? Double).map { Date().addingTimeInterval($0) },
            scope: answer["scope"] as? String ?? scopes)
    }

    private static func reason(_ answer: [String: Any], fallback: String? = nil) -> String {
        (answer["error_description"] as? String) ?? fallback
            ?? Localized.text("Google refused the question")
    }
}

/// The registered application a site insists on, when one insists. Read from the environment first
/// so a build can be handed credentials without a settings screen, then from this device's own
/// settings so somebody can paste their own — neither is a secret in the sense the token is, since
/// every copy of a desktop app ships the same one.
public enum MediaClientConfig {
    public struct Client: Sendable, Equatable {
        public let id: String
        public let secret: String
    }

    static let youtubeKey = "tailscode.watch.youtube.client"

    public static var youtube: Client? {
        let environment = ProcessInfo.processInfo.environment
        if let id = environment["TAILSCODE_YOUTUBE_CLIENT_ID"], !id.isEmpty {
            return Client(id: id, secret: environment["TAILSCODE_YOUTUBE_CLIENT_SECRET"] ?? "")
        }
        guard let stored = UserDefaults.standard.string(forKey: youtubeKey) else { return nil }
        let parts = stored.split(separator: "\u{1}", maxSplits: 1).map(String.init)
        guard let id = parts.first, !id.isEmpty else { return nil }
        return Client(id: id, secret: parts.count > 1 ? parts[1] : "")
    }

    /// Records a client somebody pasted in. Empty clears it, which is the only way back to the
    /// state the build shipped in.
    public static func setYouTube(id: String, secret: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            UserDefaults.standard.removeObject(forKey: youtubeKey)
            return
        }
        UserDefaults.standard.set(
            "\(trimmed)\u{1}\(secret.trimmingCharacters(in: .whitespacesAndNewlines))",
            forKey: youtubeKey)
    }
}

/// Where the two accounts live on this device. Tokens go to whatever the platform gave the app for
/// secrets — the Keychain on Apple, a 0600 file on a Linux box with no keyring — and the name the
/// row prints goes to ordinary settings, because a display name is not a credential and a settings
/// row that has to unlock a keychain to draw itself is a settings row that stalls.
public enum MediaAccounts {
    /// The store and the tokens read out of it, behind one lock. A sign-in finishes on whichever
    /// thread was polling the site, the board asks who is followed from two background fetches at
    /// once, and a settings row draws on the main one — a bare static dictionary shared by all
    /// three is a crash waiting for a busy afternoon, and `nonisolated(unsafe)` only silences the
    /// compiler about it.
    private final class Held: @unchecked Sendable {
        let lock = NSLock()
        var secrets: (any SecretStore)?
        var cache: [MediaSource: OAuthTokens] = [:]
        var refreshes: [MediaSource: Task<OAuthTokens?, Never>] = [:]
    }

    private static let held = Held()
    static let accountPrefix = "tailscode.watch.account."
    public static let didChange = Notification.Name("tailscode.watch.accountsDidChange")

    /// Handed the platform's secret store once at launch, the way the connection stores are. Until
    /// it is, every account reads as signed out rather than crashing — a client that forgot to
    /// install one loses a feature, not a launch.
    public static func install(_ store: any SecretStore) {
        held.lock.lock()
        defer { held.lock.unlock() }
        held.secrets = store
        held.cache = [:]
    }

    public static var isInstalled: Bool {
        held.lock.lock()
        defer { held.lock.unlock() }
        return held.secrets != nil
    }

    public static func authority(for source: MediaSource) -> any DeviceAuthority {
        switch source {
        case .twitch: return TwitchAuthority()
        case .youtube: return YouTubeAuthority()
        }
    }

    public static func account(for source: MediaSource) -> MediaAccount? {
        guard let data = UserDefaults.standard.data(forKey: accountPrefix + source.rawValue) else {
            return nil
        }
        return try? JSONDecoder().decode(MediaAccount.self, from: data)
    }

    public static func isSignedIn(_ source: MediaSource) -> Bool {
        account(for: source) != nil && tokens(for: source) != nil
    }

    /// The lock is never held across the platform's own secret store: a Keychain call can block on
    /// an unlock prompt, and a lock held through one would stop every board and every settings row
    /// on the app until somebody typed a password.
    public static func tokens(for source: MediaSource) -> OAuthTokens? {
        held.lock.lock()
        if let cached = held.cache[source] {
            held.lock.unlock()
            return cached
        }
        let store = held.secrets
        held.lock.unlock()

        guard let store, let raw = try? store.value(for: key(source)),
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(OAuthTokens.self, from: data)
        else { return nil }
        held.lock.lock()
        held.cache[source] = decoded
        held.lock.unlock()
        return decoded
    }

    public static func remember(_ tokens: OAuthTokens, _ account: MediaAccount) {
        held.lock.lock()
        held.cache[account.source] = tokens
        let store = held.secrets
        held.lock.unlock()

        if let store, let data = try? JSONEncoder().encode(tokens),
            let raw = String(data: data, encoding: .utf8)
        {
            try? store.setValue(raw, for: key(account.source))
        }
        if let data = try? JSONEncoder().encode(account) {
            UserDefaults.standard.set(data, forKey: accountPrefix + account.source.rawValue)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func signOut(_ source: MediaSource) {
        held.lock.lock()
        held.cache[source] = nil
        let store = held.secrets
        held.lock.unlock()

        try? store?.removeValue(for: key(source))
        UserDefaults.standard.removeObject(forKey: accountPrefix + source.rawValue)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// A token good enough to send, refreshing it first if it is about to stop being one. A refresh
    /// that fails signs the account out rather than leaving a row claiming an account that answers
    /// nothing.
    public static func usable(for source: MediaSource) async -> OAuthTokens? {
        guard let current = tokens(for: source) else { return nil }
        guard current.isStale() else { return current }
        return await refreshing(source, from: current).value
    }

    /// One refresh per site at a time, joined rather than repeated. Both sources hand back a new
    /// refresh token and retire the old one, so two fetches noticing the same stale token at the
    /// same moment would race: whichever lost would spend a token the site had already replaced,
    /// be told the grant is invalid, and sign a perfectly good account out.
    private static func refreshing(_ source: MediaSource, from stale: OAuthTokens) -> Task<
        OAuthTokens?, Never
    > {
        held.lock.lock()
        if let running = held.refreshes[source] {
            held.lock.unlock()
            return running
        }
        let task = Task<OAuthTokens?, Never> {
            defer { finishedRefreshing(source) }
            do {
                let fresh = try await authority(for: source).refreshed(stale)
                if let account = account(for: source) { remember(fresh, account) }
                return fresh
            } catch {
                signOut(source)
                return nil
            }
        }
        held.refreshes[source] = task
        held.lock.unlock()
        return task
    }

    /// Taking a lock is not something an `async` body may do, so the one line a finished refresh
    /// owes the map is a plain function it calls rather than a lock it holds itself.
    private static func finishedRefreshing(_ source: MediaSource) {
        held.lock.lock()
        held.refreshes[source] = nil
        held.lock.unlock()
    }

    private static func key(_ source: MediaSource) -> String {
        "tailscode.watch.oauth.\(source.rawValue)"
    }
}

/// A form-encoded POST that answers JSON, which is what every OAuth endpoint in this file speaks.
/// A non-2xx is not an error here: both sites report `authorization_pending` with a 400 and a body
/// worth reading, so the body always comes back and the caller decides what it means.
enum MediaForm {
    static func post(
        _ address: String, fields: [String: String], source: MediaSource
    ) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw MediaFailure.unreachable(source) }
        var request = URLRequest(url: url, timeoutInterval: MediaFetch.timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            fields.map { "\(escape($0.key))=\(escape($0.value))" }.joined(separator: "&").utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else {
            throw MediaFailure.unreachable(source)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaFailure.unreachable(source)
        }
        return object
    }

    static func escape(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

/// Twitch's authenticated API, which is a different host and a different shape from the GraphQL the
/// signed-out board reads. Only the signed-in half goes through here.
enum MediaHelix {
    static let base = "https://api.twitch.tv/helix/"

    static func get(
        _ path: String, tokens: OAuthTokens, query: [String: String]
    ) async throws -> [String: Any] {
        var components = URLComponents(string: base + path)
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw MediaFailure.unreachable(.twitch) }
        var request = URLRequest(url: url, timeoutInterval: MediaFetch.timeout)
        request.setValue("Bearer \(tokens.access)", forHTTPHeaderField: "Authorization")
        request.setValue(TwitchDirectory.clientID, forHTTPHeaderField: "Client-Id")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            throw MediaFailure.unreachable(.twitch)
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw MediaFailure.signedOut(.twitch)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaFailure.unreachable(.twitch)
        }
        if let message = object["message"] as? String, object["data"] == nil {
            throw MediaFailure.refused(.twitch, message)
        }
        return object
    }
}

/// YouTube's Data API, which is the only way to learn what somebody subscribed to. It is asked for
/// the list and nothing else: which of those channels is live comes from the same free path the
/// signed-out board already uses, because asking this API costs quota per channel and the answer is
/// the same.
enum MediaGoogle {
    static let base = "https://www.googleapis.com/youtube/v3/"

    static func get(
        _ path: String, tokens: OAuthTokens, query: [String: String]
    ) async throws -> [String: Any] {
        var components = URLComponents(string: base + path)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw MediaFailure.unreachable(.youtube) }
        var request = URLRequest(url: url, timeoutInterval: MediaFetch.timeout)
        request.setValue("Bearer \(tokens.access)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            throw MediaFailure.unreachable(.youtube)
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw MediaFailure.signedOut(.youtube)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaFailure.unreachable(.youtube)
        }
        if let error = object["error"] as? [String: Any] {
            throw MediaFailure.refused(
                .youtube, error["message"] as? String ?? Localized.text("YouTube refused the question"))
        }
        return object
    }
}
