import Foundation

/// Where a sign-in is. The whole flow is four states because that is all it has: asking the site
/// for a code, waiting for the person to confirm it in their own browser, done, or a stated reason
/// it is not.
public enum WatchSignInStep: Sendable, Equatable {
    case starting
    case waiting(DevicePrompt)
    case granted(MediaAccount)
    case failed(String)
}

/// The device flow, as something to render. Signing into a video site from a coding client is a
/// small thing that has to feel small: no password field, no browser embedded in a pane, no secret
/// crossing this app at all — a short code, the person's own browser, and a row that changes.
///
/// Toolkit-free like every other model here, so the three clients show the same two steps in the
/// same words and the polling loop is written once.
public struct WatchSignIn: Sendable, Equatable {
    public let source: MediaSource
    public private(set) var step: WatchSignInStep

    public init(source: MediaSource, step: WatchSignInStep = .starting) {
        self.source = source
        self.step = step
    }

    public mutating func began(_ prompt: DevicePrompt) { step = .waiting(prompt) }
    public mutating func granted(_ account: MediaAccount) { step = .granted(account) }
    public mutating func failed(_ reason: String) { step = .failed(reason) }

    public var prompt: DevicePrompt? {
        if case .waiting(let prompt) = step { return prompt }
        return nil
    }

    public var isFinished: Bool {
        switch step {
        case .granted, .failed: return true
        case .starting, .waiting: return false
        }
    }

    public var heading: String {
        switch step {
        case .starting, .waiting:
            return Localized.text("Sign in to %@", source.label)
        case .granted(let account):
            return Localized.text("Signed in as %@", account.name)
        case .failed:
            return Localized.text("That didn't sign in")
        }
    }

    public var detail: String {
        switch step {
        case .starting, .waiting:
            return Localized.text(
                "Your browser confirms it, not this app — no password is typed here and none is kept."
            )
        case .granted:
            return Localized.text("The board now knows who you follow.")
        case .failed(let reason):
            return reason
        }
    }

    /// The one thing to do next, said as an instruction rather than a label.
    public var instruction: String? {
        switch step {
        case .starting: return Localized.text("Asking %@ for a code…", source.label)
        case .waiting:
            return Localized.text("Open the page, check the code matches, and confirm it.")
        case .granted, .failed: return nil
        }
    }

    /// The short code the site shows back, which is the only thing a person has to compare.
    public var code: String? { prompt?.userCode }

    public var link: String? { prompt?.verificationURL }

    public var actionTitle: String {
        switch step {
        case .starting: return Localized.text("Opening…")
        case .waiting: return Localized.text("Open %@", source.label)
        case .granted: return Localized.text("Done")
        case .failed: return Localized.text("Try again")
        }
    }

    /// Runs the flow to its end, calling back on every state change. The client owns presentation
    /// and cancellation; the waiting, the interval the site asked for and the deadline it set are
    /// all handled here so no client re-derives them.
    public static func run(
        source: MediaSource, onChange: @escaping @Sendable (WatchSignIn) -> Void
    ) async {
        var flow = WatchSignIn(source: source)
        onChange(flow)
        let authority = MediaAccounts.authority(for: source)
        guard authority.isConfigured else {
            flow.failed(authority.requirement ?? MediaFailure.unconfigured(source).description)
            onChange(flow)
            return
        }
        let prompt: DevicePrompt
        do {
            prompt = try await authority.begin()
        } catch {
            flow.failed(MediaDirectory.reason(error, source))
            onChange(flow)
            return
        }
        flow.began(prompt)
        onChange(flow)

        var wait = prompt.interval
        while Date() < prompt.expiresAt {
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            if Task.isCancelled { return }
            let answer: DevicePoll
            do {
                answer = try await authority.poll(prompt.deviceCode)
            } catch {
                flow.failed(MediaDirectory.reason(error, source))
                onChange(flow)
                return
            }
            switch answer {
            case .pending:
                continue
            case .slowDown:
                wait += 2
            case .expired:
                flow.failed(Localized.text("That code expired before it was confirmed"))
                onChange(flow)
                return
            case .denied(let reason):
                flow.failed(reason)
                onChange(flow)
                return
            case .granted(let tokens):
                do {
                    let account = try await authority.account(tokens)
                    MediaAccounts.remember(tokens, account)
                    flow.granted(account)
                } catch {
                    flow.failed(MediaDirectory.reason(error, source))
                }
                onChange(flow)
                return
            }
        }
        flow.failed(Localized.text("That code expired before it was confirmed"))
        onChange(flow)
    }
}

/// What the settings surface offers, one row per site. A row is a fact first and a control second:
/// it names the account when there is one, says what signing in would add when there is not, and
/// says what is missing when the site will not answer this build at all.
public struct WatchAccountRow: Sendable, Equatable, Identifiable {
    public enum Action: Sendable, Equatable {
        case signIn(MediaSource)
        case signOut(MediaSource)
        case configure(MediaSource)
    }

    public let source: MediaSource
    public let title: String
    public let detail: String
    public let action: Action
    public let actionTitle: String
    /// A line under the detail, for the one case that needs explaining at length — a site this
    /// build was given no application for.
    public let note: String?
    public let isSignedIn: Bool

    public var id: String { source.rawValue }
}

/// The Watch accounts section, decided once for all three clients. An account is device-local, like
/// the channel list it fills in — which is why it lives in settings rather than on a server screen:
/// no server knows or cares who is signed into Twitch here.
public enum WatchAccounts {
    public static var heading: String { Localized.text("Watch accounts") }

    public static var description: String {
        Localized.text(
            "Signing in lets the board list the channels you already follow. Everything else works signed out."
        )
    }

    public static func rows() -> [WatchAccountRow] {
        MediaSource.allCases.map { source in
            let authority = MediaAccounts.authority(for: source)
            if let account = MediaAccounts.account(for: source) {
                return WatchAccountRow(
                    source: source, title: source.label,
                    detail: Localized.text("Signed in as %@", account.name),
                    action: .signOut(source), actionTitle: Localized.text("Sign out"),
                    note: nil, isSignedIn: true)
            }
            guard authority.isConfigured else {
                return WatchAccountRow(
                    source: source, title: source.label,
                    detail: Localized.text("Needs an app of your own before it will answer"),
                    action: .configure(source), actionTitle: Localized.text("Set up…"),
                    note: authority.requirement, isSignedIn: false)
            }
            return WatchAccountRow(
                source: source, title: source.label,
                detail: Localized.text("Signed out — the board can still show what's on"),
                action: .signIn(source), actionTitle: Localized.text("Sign in"),
                note: nil, isSignedIn: false)
        }
    }

    /// One line for a status surface: who is signed in, or that nobody is. Never a warning — being
    /// signed out of a video site is not a problem this app has.
    public static var summary: String {
        let named = MediaSource.allCases.compactMap { MediaAccounts.account(for: $0)?.name }
        guard !named.isEmpty else { return Localized.text("Not signed in to either site") }
        return named.joined(separator: " · ")
    }
}

/// What a person has to be told, and told to paste, to make YouTube answer at all. Google will only
/// run its device flow for an application somebody registered, so this is the one place in the app
/// where a step happens outside it — said as a numbered list rather than a paragraph, because it is
/// followed on another screen and half-remembered instructions are how people give up.
public enum YouTubeSetup {
    public static var heading: String {
        Localized.text("Make a YouTube app of your own")
    }

    public static var why: String {
        Localized.text(
            "Twitch lends its own app to every client, so signing in there needs nothing. Google does not: it answers only an application registered to somebody, and that somebody has to be you. It is free and takes about two minutes."
        )
    }

    public static var steps: [String] {
        [
            Localized.text("Open console.cloud.google.com and make a project, or pick one you have."),
            Localized.text("Under APIs & Services, enable the YouTube Data API v3."),
            Localized.text(
                "Under Credentials, create an OAuth client ID of type TV and Limited Input device."
            ),
            Localized.text("Paste the client id and secret it gives you below."),
        ]
    }

    public static var consoleURL: String { "https://console.cloud.google.com/apis/credentials" }

    public static var idPrompt: String { Localized.text("Client ID") }
    public static var secretPrompt: String { Localized.text("Client secret") }

    /// True once the pasted pair is the shape Google issues. Checked rather than trusted so a
    /// half-pasted id fails here, where it can be corrected, rather than at the end of a flow.
    public static func looksValid(id: String, secret: String) -> Bool {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedID.hasSuffix(".apps.googleusercontent.com") && trimmedID.count > 30
            && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static var rejection: String {
        Localized.text("That is not a client id — Google's end in .apps.googleusercontent.com")
    }
}

/// The accounts model's rules, checked headlessly in the Kit so both desktops prove them from their
/// own `--selftest` and neither client re-derives what a row should say.
public enum WatchAccountsCheck {
    public static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let rows = WatchAccounts.rows()
        expect(rows.count == 2, "one row per site")
        expect(rows.map(\.source) == [.twitch, .youtube], "in a stable order")

        let twitch = rows.first { $0.source == .twitch }
        expect(twitch?.action == .signIn(.twitch), "Twitch can be signed into with no setup")
        expect(twitch?.note == nil, "and owes no explanation")
        expect(TwitchAuthority().isConfigured, "because its device flow needs no application")

        let youtube = rows.first { $0.source == .youtube }
        if MediaClientConfig.youtube == nil {
            expect(youtube?.action == .configure(.youtube), "YouTube says what it needs first")
            expect(youtube?.note?.isEmpty == false, "and says it at length")
            expect(!YouTubeAuthority().isConfigured, "because Google will not answer an unregistered app")
        } else {
            expect(youtube?.action == .signIn(.youtube), "a configured YouTube offers to sign in")
        }

        var flow = WatchSignIn(source: .twitch)
        expect(flow.step == .starting, "a flow starts by asking")
        expect(flow.code == nil, "with no code to show yet")
        expect(!flow.isFinished, "and is not finished")
        let prompt = DevicePrompt(
            deviceCode: "d", userCode: "ABCD1234",
            verificationURL: "https://www.twitch.tv/activate?device-code=ABCD1234", interval: 5,
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        flow.began(prompt)
        expect(flow.code == "ABCD1234", "then shows the code the site will ask for")
        expect(flow.link == prompt.verificationURL, "and where to confirm it")
        expect(flow.actionTitle == Localized.text("Open %@", MediaSource.twitch.label), "one button")
        flow.granted(MediaAccount(source: .twitch, name: "Marcus", handle: "marcus"))
        expect(flow.isFinished, "granting finishes it")
        expect(flow.heading == Localized.text("Signed in as %@", "Marcus"), "and names the account")
        var refused = WatchSignIn(source: .youtube)
        refused.failed("nope")
        expect(refused.detail == "nope", "a failure states its own reason")
        expect(refused.actionTitle == Localized.text("Try again"), "and offers another go")

        expect(YouTubeSetup.steps.count == 4, "the setup somebody has to do elsewhere is four steps")
        expect(
            YouTubeSetup.looksValid(id: "123-abc.apps.googleusercontent.com", secret: "s"),
            "a real client id is accepted")
        expect(
            !YouTubeSetup.looksValid(id: "123-abc.apps.googleusercontent.com", secret: " "),
            "and a missing secret is not")
        expect(!YouTubeSetup.looksValid(id: "nonsense", secret: "s"), "nor is a pasted mistake")

        let tokens = OAuthTokens(
            access: "a", refresh: "r", expiresAt: Date().addingTimeInterval(3600), scope: "s")
        expect(!tokens.isStale(), "a fresh token is usable")
        expect(
            tokens.isStale(at: Date().addingTimeInterval(3600)),
            "and is replaced a minute before it dies rather than after")
        expect(
            OAuthTokens(access: "a").isStale() == false,
            "a token with no stated life is taken at its word")

        expect(
            MediaFailure.signedOut(.twitch).description
                == Localized.text("Your %@ account needs signing in again", MediaSource.twitch.label),
            "a dead account says what to do")
        expect(
            MediaFailure.unconfigured(.youtube).source == .youtube,
            "and every failure names its own site")
        return failures
    }
}
