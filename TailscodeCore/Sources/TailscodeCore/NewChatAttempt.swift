import CodingAgentKit
import Foundation

/// A thrown error in the words it was written in, or the type's name when nobody wrote any.
/// One implementation, because three clients printing three different renderings of the same
/// failure is how "\(error)" ends up on a screen.
public enum AgentErrorText {
    public static func readable(_ error: Error) -> String {
        if error is NewChatAttempt.TimedOut {
            return Localized.text("It did not answer in time.")
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// The rules a new chat is minted under, shared so no client waits forever on its own terms.
public enum NewChatAttempt {
    /// How long the mint may take before this app stops waiting and goes to find out what is
    /// wrong. It is not a network timeout: an ordinary request against a server that wants a
    /// password it was not given never comes back at all on Linux, and a person watching a modal
    /// cannot be asked to tell that apart from a slow tailnet. Generous on purpose — minting a
    /// Claude chat spawns a CLI on the other machine, and a deadline tuned to a warm server turns
    /// a slow success into a false accusation.
    public static let deadline: Duration = .seconds(45)

    /// Raised when the deadline passes. Never shown — it is the trigger for the recovery below
    /// and then for the probe that produces the real explanation.
    public struct TimedOut: Error, Sendable {
        public init() {}
    }

    /// How long the mint gets to itself before the machine is asked, in parallel, who is there.
    /// Under a couple of seconds the answer is nearly always already on its way back.
    public static let grace: Duration = .seconds(6)

    /// The whole mint: ask for the chat, and — if it has not arrived quickly — ask the machine
    /// who is there at the same time, so a server that cannot possibly answer is named in seconds
    /// instead of at the end of the deadline. A witness that says the machine is healthy proves
    /// nothing about this one request, so it is ignored and the mint keeps its full deadline;
    /// anything else is a reason the chat can never arrive, and ends the wait immediately.
    ///
    /// Three ways out, and every one of them says something: the session, the session the server
    /// made while the reply was lost, or a failure with the one action that fixes it. There is no
    /// fourth way where nothing happens.
    public static func mint(
        using backend: any CodingAgentBackend, server: NewChatServer, baseURL: URL,
        password: String?, directory: String?
    ) async -> Result<AgentSession, NewChatFailure> {
        let startedAt = Date()
        let settled = FirstAnswer<Result<AgentSession, NewChatFailure>>()

        let work = Task { @Sendable in
            do {
                let session = try await backend.createSession(title: nil, directory: directory)
                settled.offer(.success(.success(session)))
            } catch {
                let witness = await NewChatWitness.gather(
                    baseURL: baseURL, backend: server.backend, password: password)
                settled.offer(
                    .success(
                        .failure(
                            NewChatDiagnosis.failure(
                                server: server, directory: directory,
                                error: AgentErrorText.readable(error), witness: witness))))
            }
        }

        let watchdog = Task { @Sendable in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            let witness = await NewChatWitness.gather(
                baseURL: baseURL, backend: server.backend, password: password)
            guard !Task.isCancelled, witness != .healthy, witness != .unknown else { return }
            settled.offer(
                .success(
                    .failure(
                        NewChatDiagnosis.failure(
                            server: server, directory: directory,
                            error: AgentErrorText.readable(TimedOut()), witness: witness))))
        }

        let timer = Task { @Sendable in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            if let recovered = await recover(using: backend, directory: directory, since: startedAt) {
                settled.offer(.success(.success(recovered)))
                return
            }
            let witness = await NewChatWitness.gather(
                baseURL: baseURL, backend: server.backend, password: password)
            settled.offer(
                .success(
                    .failure(
                        NewChatDiagnosis.failure(
                            server: server, directory: directory,
                            error: AgentErrorText.readable(TimedOut()), witness: witness))))
        }

        defer {
            work.cancel()
            watchdog.cancel()
            timer.cancel()
        }
        return (try? await settled.value.get()) ?? .failure(
            NewChatDiagnosis.failure(
                server: server, directory: directory,
                error: AgentErrorText.readable(TimedOut()), witness: .unknown))
    }

    /// After a deadline, the chat the server may have made anyway.
    ///
    /// A timeout is a lost answer, not proof of failure: the request can land, the session can be
    /// created, and only the reply can go missing. Accusing the server of refusing — and leaving
    /// the person to find an orphan chat in the list later — is the worse of the two mistakes, so
    /// the listing is asked before any diagnosis is written.
    public static func recover(
        using backend: any CodingAgentBackend, directory: String?, since: Date
    ) async -> AgentSession? {
        guard let sessions = try? await run(deadline: .seconds(10), { try await backend.listSessions() })
        else { return nil }
        return
            sessions
            .filter { $0.createdAt >= since.addingTimeInterval(-2) }
            .filter { directory == nil || $0.directory == directory }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Runs `operation` under the deadline and returns the moment either finishes — the loser is
    /// cancelled but never waited on.
    ///
    /// A task group would be the obvious shape and is the wrong one: leaving a group awaits its
    /// children, and the request this deadline exists for is precisely one that never returns —
    /// an ordinary HTTP request against a server that wants a password it was not given hangs on
    /// Linux, cancellation or no cancellation. Waiting for it to notice would hold the modal
    /// exactly as long as having no deadline at all.
    public static func run<T: Sendable>(
        deadline duration: Duration = deadline,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let settled = FirstAnswer<T>()
        let work = Task { @Sendable in
            do { settled.offer(.success(try await operation())) } catch { settled.offer(.failure(error)) }
        }
        let timer = Task { @Sendable in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            settled.offer(.failure(TimedOut()))
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        return try await settled.value.get()
    }

    /// One result, whoever gets there first; every later answer is dropped rather than crashing
    /// on a second resume.
    private final class FirstAnswer<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: Result<T, Error>?
        private var waiter: CheckedContinuation<Result<T, Error>, Never>?

        func offer(_ result: Result<T, Error>) {
            lock.lock()
            guard answer == nil else { return lock.unlock() }
            answer = result
            let waiting = waiter
            waiter = nil
            lock.unlock()
            waiting?.resume(returning: result)
        }

        var value: Result<T, Error> {
            get async {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if let answer {
                        lock.unlock()
                        continuation.resume(returning: answer)
                        return
                    }
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }
}

/// What was learned by asking the machine itself who is there, after a new chat failed to start.
///
/// A thrown error says what this device experienced; it cannot say what is true on the other end.
/// The client goes and finds out — the profile's own address, and the other agent's default port
/// beside it — and hands the fact in here. Core never opens a socket; it turns the fact into
/// words and into the one action that fixes it.
public enum NewChatWitness: Sendable, Equatable {
    /// Nobody asked, or the answer did not arrive in time.
    case unknown
    /// Nothing is listening at that address at all.
    case silent
    /// The agent this profile expects is on the same machine, at another port. The one failure
    /// this app can fix by itself.
    case wrongPort(found: AgentType?, expectedAt: URL)
    /// The other agent answers here, and the expected one is nowhere on this machine.
    case otherAgentHere(AgentType)
    /// Something HTTP answers here and it is not an agent server at all.
    case notAnAgentHere
    /// Something answers and wants a password this device does not have, or has wrong.
    case wantsPassword
    /// The server is up, speaks the right protocol, and took the credentials. The refusal was
    /// about the request, not about the connection.
    case healthy
}

extension NewChatWitness {
    /// Asks the machine who is there: its own address first, then the other agent's default port
    /// on the same host. Two probes, both on the interactive leash, run only after something has
    /// already failed — the cost is paid once, in the moment a person is owed an explanation.
    ///
    /// The alternate port is asked about even when the address carries an explicit one, because
    /// an explicitly wrong port is exactly the mistake that produces a server which answers,
    /// refuses, and looks dead.
    public static func gather(
        baseURL: URL, backend: AgentType, password: String?,
        policy: ConnectionPolicy = ProbeSweep.interactivePolicy
    ) async -> NewChatWitness {
        let here = await ProbeSweep.probe(
            baseURL: baseURL, password: password, preferring: backend, policy: policy,
            retryUnreachable: false)
        switch here {
        case .ok(let agent, _) where agent == backend:
            return .healthy
        case .authFailed:
            if let elsewhere = await expected(backend, near: baseURL, password: password, policy: policy) {
                return .wrongPort(found: nil, expectedAt: elsewhere)
            }
            return .wantsPassword
        case .ok(let agent, _):
            if let elsewhere = await expected(backend, near: baseURL, password: password, policy: policy) {
                return .wrongPort(found: agent, expectedAt: elsewhere)
            }
            return .otherAgentHere(agent)
        case .notAnAgentServer:
            if let elsewhere = await expected(backend, near: baseURL, password: password, policy: policy) {
                return .wrongPort(found: nil, expectedAt: elsewhere)
            }
            return .notAnAgentHere
        case .unreachable:
            if let elsewhere = await expected(backend, near: baseURL, password: password, policy: policy) {
                return .wrongPort(found: nil, expectedAt: elsewhere)
            }
            return .silent
        }
    }

    /// Where the agent this profile is for actually answers on that machine, if it does. Only the
    /// other agent's default port is tried: a port scan of somebody's laptop is not a diagnostic.
    private static func expected(
        _ backend: AgentType, near baseURL: URL, password: String?, policy: ConnectionPolicy
    ) async -> URL? {
        let wanted = HostAddress.port(for: backend)
        guard baseURL.port != wanted,
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.port = wanted
        guard let candidate = components.url else { return nil }
        let outcome = await ProbeSweep.probe(
            baseURL: candidate, password: password, preferring: backend, policy: policy,
            retryUnreachable: false)
        guard case .ok(let agent, _) = outcome, agent == backend else { return nil }
        return candidate
    }
}

/// Why a new conversation did not start, in words a person can act on, with the single action
/// that fixes it.
///
/// Nothing about starting a chat is allowed to fail quietly: every path that can end without a
/// conversation ends here instead, including the ones that never reach the network — no password
/// on this device, no such server. The failure is shown where the attempt was made, with the fix
/// as a button rather than as advice, because the correction is nearly always one field on one
/// screen this app already owns.
public struct NewChatFailure: Sendable, Equatable, Error {
    /// The one thing to do about it. `repoint` is the answer to the mistake this app makes most:
    /// a profile aimed at the other agent's port, which answers, refuses, and looks like a dead
    /// server. It is applied and retried in place — the person never sees a settings screen.
    public enum Fix: Sendable, Equatable {
        case none
        case retry
        case editServer(profileID: String)
        case repoint(profileID: String, url: URL, backend: AgentType)
    }

    public let symbol: String
    public let glyph: String
    public let title: String
    public let detail: String
    public let fix: Fix
    public let actionTitle: String?

    public init(
        symbol: String, glyph: String, title: String, detail: String, fix: Fix,
        actionTitle: String?
    ) {
        self.symbol = symbol
        self.glyph = glyph
        self.title = title
        self.detail = detail
        self.fix = fix
        self.actionTitle = actionTitle
    }

    /// What a screen reader says, and what a client with one line of room shows.
    public var spoken: String { "\(title). \(detail)" }
}

/// The words for every way a new chat can fail to start, decided once for all three clients.
public enum NewChatDiagnosis {
    /// This device cannot even build a connection to that server — the password it saved is gone,
    /// or the profile disappeared between the modal opening and Start being pressed.
    public static func noCredentials(server: NewChatServer) -> NewChatFailure {
        NewChatFailure(
            symbol: "key.slash",
            glyph: "!",
            title: Localized.text("%@ has no password on this device", server.name),
            detail: Localized.text(
                "The server is configured but its password is not in this device's keychain, so nothing can be sent to it. Open its settings and enter the password it was started with."
            ),
            fix: .editServer(profileID: server.profileID),
            actionTitle: Localized.text("Server settings"))
    }

    /// The server is gone from this device's list entirely — the only case with nothing to fix,
    /// because there is no longer a thing to fix.
    public static func noSuchServer() -> NewChatFailure {
        NewChatFailure(
            symbol: "questionmark.folder",
            glyph: "!",
            title: Localized.text("That server is no longer configured"),
            detail: Localized.text(
                "It was removed while this window was open. Choose another server, or add it again."
            ),
            fix: .none,
            actionTitle: nil)
    }

    /// The full diagnosis: what this device saw, checked against what the machine says about
    /// itself.
    ///
    /// - Parameters:
    ///   - error: the server's own words, already made readable. Shown verbatim only when nothing
    ///     better is known, because a `URLError` code is not a sentence.
    ///   - witness: what the machine answered when asked directly.
    public static func failure(
        server: NewChatServer, directory: String?, error: String, witness: NewChatWitness
    ) -> NewChatFailure {
        switch witness {
        case .silent:
            return NewChatFailure(
                symbol: "bolt.horizontal.circle",
                glyph: "×",
                title: Localized.text("%@ is not answering", server.name),
                detail: Localized.text(
                    "Nothing is listening at %@. The agent is probably not running on that machine — or it is, on a different port. Check the address, or start it there.",
                    server.address),
                fix: .editServer(profileID: server.profileID),
                actionTitle: Localized.text("Server settings"))

        case .wrongPort(let found, let expectedAt):
            let expected = ServerLabel.agent(server.backend)
            let here =
                found.map { ServerLabel.agent($0) } ?? Localized.text("something that is not an agent")
            return NewChatFailure(
                symbol: "arrow.uturn.right.circle",
                glyph: "→",
                title: Localized.text("%@ is on a different port", expected),
                detail: Localized.text(
                    "This server points at %@, where %@ answers. %@ is on the same machine at %@.",
                    server.address, here, expected, port(of: expectedAt)),
                fix: .repoint(
                    profileID: server.profileID, url: expectedAt, backend: server.backend),
                actionTitle: Localized.text("Use %@", port(of: expectedAt)))

        case .otherAgentHere(let found):
            return NewChatFailure(
                symbol: "arrow.triangle.branch",
                glyph: "≠",
                title: Localized.text(
                    "%@ is running %@ there, not %@", server.name, ServerLabel.agent(found),
                    ServerLabel.agent(server.backend)),
                detail: Localized.text(
                    "%@ answers at %@, and %@ is not on that machine anywhere this app looked. Change the agent this server is for, or start %@ there.",
                    ServerLabel.agent(found), server.address, ServerLabel.agent(server.backend),
                    ServerLabel.agent(server.backend)),
                fix: .editServer(profileID: server.profileID),
                actionTitle: Localized.text("Server settings"))

        case .notAnAgentHere:
            return NewChatFailure(
                symbol: "questionmark.circle",
                glyph: "?",
                title: Localized.text("%@ is not an agent server", server.address),
                detail: Localized.text(
                    "Something answers there, but it does not speak %@. Check the address — this is usually a port belonging to something else on that machine.",
                    ServerLabel.agent(server.backend)),
                fix: .editServer(profileID: server.profileID),
                actionTitle: Localized.text("Server settings"))

        case .wantsPassword:
            return NewChatFailure(
                symbol: "lock.trianglebadge.exclamationmark",
                glyph: "!",
                title: Localized.text("%@ rejected this device's password", server.name),
                detail: Localized.text(
                    "The address is right — something answered. claude-bridge wants the password it was started with as BRIDGE_PASSWORD; opencode wants none unless you set one."
                ),
                fix: .editServer(profileID: server.profileID),
                actionTitle: Localized.text("Server settings"))

        case .healthy, .unknown:
            return refusal(server: server, directory: directory, error: error, checked: witness == .healthy)
        }
    }

    /// The server is fine and still said no. Its own words are the whole story, so they lead;
    /// the folder is named because a path that does not exist on that machine is the commonest
    /// reason a healthy server refuses.
    private static func refusal(
        server: NewChatServer, directory: String?, error: String, checked: Bool
    ) -> NewChatFailure {
        let words = error.trimmingCharacters(in: .whitespacesAndNewlines)
        let said =
            words.isEmpty ? Localized.text("It gave no reason.") : Localized.text("It said: %@", words)
        guard let directory, !directory.isEmpty else {
            return NewChatFailure(
                symbol: "exclamationmark.triangle",
                glyph: "!",
                title: Localized.text("%@ could not start a chat", server.name),
                detail: said,
                fix: .retry,
                actionTitle: Localized.text("Try again"))
        }
        return NewChatFailure(
            symbol: "folder.badge.questionmark",
            glyph: "!",
            title: Localized.text("%@ could not start a chat in %@", server.name, directory),
            detail: checked
                ? Localized.text("%@ The folder has to exist on that machine, not on this one.", said)
                : said,
            fix: .retry,
            actionTitle: Localized.text("Try again"))
    }

    private static func port(of url: URL) -> String {
        url.port.map { ":\($0)" } ?? url.absoluteString
    }
}

/// What a new chat is doing right now, so the modal that asked for it can say so instead of
/// closing and leaving the person to guess whether anything happened.
///
/// A chat is minted on another machine over a tailnet: it is fast, but it is not instant, and the
/// window that vanishes on Start is indistinguishable from one that failed silently. The modal
/// stays until there is a conversation — or until there is a reason there is not.
public enum NewChatPhase: Sendable, Equatable {
    case asking
    case starting(server: String)
    case failed(NewChatFailure)

    public var isBusy: Bool {
        if case .starting = self { return true }
        return false
    }

    public var failure: NewChatFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}

extension Result where Failure == NewChatFailure {
    /// The failure, when there is one — the shape a client wants when it hands the answer to a
    /// completion that takes an optional.
    public var failureValue: NewChatFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
