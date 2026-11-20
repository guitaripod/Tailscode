import CodingAgentKit
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What became of a send that did not go through, read for the one question that decides what to
/// do next: could the server have it?
///
/// A send that never left — the device offline, nothing answering at the machine's address, a name
/// that does not resolve — is the only kind it is safe to send again on its own: the server cannot
/// hold a prompt it was never offered. Anything else that broke on the wire might have landed, so it
/// is checked against the transcript before anybody is offered it again. A server that answered and
/// refused has said so in its own words.
public enum SendFailure: Sendable, Equatable {
    case neverLeft(reason: String)
    case uncertain(reason: String)
    case refused(reason: String)

    public var reason: String {
        switch self {
        case .neverLeft(let reason), .uncertain(let reason), .refused(let reason): return reason
        }
    }

    /// Reads an error thrown by a send. Nil for a cancellation, which is somebody's decision and
    /// not a failure.
    public static func read(_ error: any Error) -> SendFailure? {
        if error is CancellationError { return nil }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return nil }
            let reason = TransportWords.sentence(for: urlError)
            return neverLeftCodes.contains(urlError.code)
                ? .neverLeft(reason: reason) : .uncertain(reason: reason)
        }
        if error is SendBound.Expired {
            return .uncertain(reason: SendBound.Expired().reason)
        }
        guard let agentError = error as? AgentError else {
            return .uncertain(reason: AgentErrorText.readable(error))
        }
        switch agentError {
        case .connection(let sentence):
            return neverLeftSentences.contains(sentence)
                ? .neverLeft(reason: sentence) : .uncertain(reason: sentence)
        case .http, .server, .decoding, .invalidURL, .unsupported:
            return .refused(reason: AgentErrorText.readable(agentError))
        }
    }

    /// The transport failures that happen before a single byte of the request reaches the server.
    private static let neverLeftCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed,
    ]

    /// The Kit hands a transport failure over as its sentence, so the same sentences say which
    /// failures never left. They are written by the same function in the same language, so the
    /// comparison is exact.
    private static var neverLeftSentences: Set<String> {
        Set(neverLeftCodes.map { TransportWords.sentence(for: URLError($0)) })
    }
}

/// How long one send may take before this device stops waiting for its answer.
///
/// Never shorter than the transport's own deadline for the request it races: a bound that gave up
/// first cancelled requests the server had already taken and called them failures. The pictures
/// a send carries are paid for at a conservative link speed on top.
public enum SendBound {
    /// The transport gives a request thirty seconds; a send is a few requests on some backends.
    public static let floor: TimeInterval = 35

    /// What a send's pictures add, in bytes a second, at a link slow enough to be honest about.
    public static let payloadRate: Double = 50_000

    public static func seconds(payloadBytes: Int) -> TimeInterval {
        floor + Double(max(0, payloadBytes)) / payloadRate
    }

    public static func seconds(for attachments: [PromptAttachment]) -> TimeInterval {
        seconds(payloadBytes: attachments.reduce(0) { $0 + ($1.data?.count ?? 0) })
    }

    /// The bound ran out before the server answered, which says nothing about whether it got the
    /// prompt.
    public struct Expired: Error, Sendable {
        public init() {}

        public var reason: String {
            Localized.text("The machine didn't answer in time.")
        }
    }
}

/// When a send held for the connection is tried again. It starts quickly, because a dropped
/// network is usually back in seconds, settles at half a minute so a phone left offline is not
/// kept busy, and is also tried at once whenever the conversation's stream comes back live.
public enum SendWait {
    public static let delays: [TimeInterval] = [2, 4, 8, 15, 30]

    /// How long words are held before the row stops waiting and says they did not go. Past this
    /// the person has very likely moved on, and words going out on their own an hour later would
    /// be a surprise rather than a help.
    public static let window: TimeInterval = 600

    public static func delay(afterAttempts attempts: Int) -> TimeInterval {
        delays[min(max(0, attempts - 1), delays.count - 1)]
    }

    public static func givesUp(heldSince: Date, now: Date) -> Bool {
        now.timeIntervalSince(heldSince) >= window
    }

    /// Why a send waits when a turn is running: it goes when the turn ends, ahead of anything
    /// written after it. Read whole, never with the "sends on its own" ending a network wait has.
    public static var behindTurn: String {
        Localized.text("Held on this device. It goes when this turn ends")
    }

    /// What a row says when the window closes with the machine still out of reach.
    public static func gaveUp(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? Localized.text("The machine didn't answer for ten minutes.")
            : Localized.text("%@ The machine didn't answer for ten minutes.", trimmed)
    }
}

/// How long a send the server took may go without its prompt turning up in the transcript before
/// the stream that should have carried it is redialled. The server said it has the prompt, so a
/// silence this long is this device's view of the conversation going stale, never the message.
public enum SendWitness {
    public static let after: TimeInterval = 30
}

/// What one attempt at a send came to.
public enum SendOutcome: Sendable, Equatable {
    /// The server took it; its turn has not reached this device yet.
    case accepted
    /// The attempt broke on the wire, and the transcript shows the words anyway.
    case arrived
    /// It never left. Hold the words and try again on `SendWait`'s clock.
    case waiting(reason: String)
    /// It did not go, as far as anybody can tell; the reason is the server's or the transport's.
    case failed(reason: String)
    /// Somebody stopped it.
    case cancelled
}

/// What the server holds from a conversation's people, read to settle whether a send arrived: the
/// transcript, and the prompts it is holding in its queue, where a send taken behind a running turn
/// waits before it is written down.
public struct SendAccount: Sendable {
    public var messages: [ChatMessage]
    public var queued: [String]

    public init(messages: [ChatMessage], queued: [String] = []) {
        self.messages = messages
        self.queued = queued
    }

    public init(_ state: ConversationState) {
        self.init(messages: state.messages, queued: state.queue.map(\.text))
    }

    func holds(_ text: String, attachments: Int, baselineUserCount: Int) -> Bool {
        if SendArrival.arrived(
            text, attachments: attachments, baselineUserCount: baselineUserCount, in: messages)
        {
            return true
        }
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !wanted.isEmpty
            && queued.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == wanted }
    }
}

/// One attempt at a send, the same on every client: a bound that never undercuts the transport,
/// a device with no network held before anything is posted, a failure read for whether the server
/// could have the prompt, and the server asked before anything that might have arrived is called a
/// failure or sent again.
///
/// Toolkit-free and never main-actor: a client awaits it from its own task and applies the outcome
/// on its own main thread.
public struct SendCourier: Sendable {
    public var post: @Sendable () async throws -> Void
    public var reread: @Sendable () async throws -> SendAccount
    public var bound: TimeInterval
    /// How long the server may take to answer whether a prompt arrived.
    public var rereadBound: TimeInterval
    /// Whether the device has a network to send on (`DevicePath`), asked before every attempt.
    public var online: @Sendable () -> Bool

    public init(
        bound: TimeInterval, rereadBound: TimeInterval = 12,
        online: @escaping @Sendable () -> Bool = { DevicePath.isUsable },
        post: @escaping @Sendable () async throws -> Void,
        reread: @escaping @Sendable () async throws -> SendAccount
    ) {
        self.post = post
        self.reread = reread
        self.bound = bound
        self.rereadBound = rereadBound
        self.online = online
    }

    /// The same, for a reader that has only the transcript to offer.
    public init(
        bound: TimeInterval, rereadBound: TimeInterval = 12,
        online: @escaping @Sendable () -> Bool = { DevicePath.isUsable },
        post: @escaping @Sendable () async throws -> Void,
        reread: @escaping @Sendable () async throws -> [ChatMessage]
    ) {
        self.init(
            bound: bound, rereadBound: rereadBound, online: online, post: post,
            reread: { SendAccount(messages: try await reread()) })
    }

    /// A courier for `send` through a conversation, with the model and level it goes with.
    public static func through(
        _ conversation: AgentConversation, text: String, model: ModelSelection?, effort: String?,
        attachments: [PromptAttachment]
    ) -> SendCourier {
        SendCourier(
            bound: SendBound.seconds(for: attachments),
            post: {
                try await conversation.send(
                    text, model: model, reasoningEffort: effort, attachments: attachments)
            },
            reread: {
                try await conversation.refresh()
                return SendAccount(await conversation.state)
            })
    }

    /// Sends once. `checkFirst` asks the server before posting — what every attempt after the
    /// first does, a person's Send again and the clock's alike, because the row being sent again
    /// may be standing in for words the server already has. A server that cannot be reached to
    /// ask is a send that is held rather than one that goes blind.
    public func run(
        text: String, attachments: Int, baselineUserCount: Int, checkFirst: Bool = false
    ) async -> SendOutcome {
        guard online() else { return .waiting(reason: DevicePath.offlineReason) }
        if checkFirst {
            switch await look(text: text, attachments: attachments, baseline: baselineUserCount) {
            case .arrived: return .arrived
            case .unreachable(let reason): return .waiting(reason: reason)
            case .missing, .unread: break
            }
        }
        if Task.isCancelled { return .cancelled }
        do {
            try await Self.within(bound, post)
            return .accepted
        } catch {
            guard !Task.isCancelled, let failure = SendFailure.read(error) else {
                return .cancelled
            }
            switch failure {
            case .neverLeft(let reason):
                return .waiting(reason: reason)
            case .refused(let reason):
                return .failed(reason: reason)
            case .uncertain(let reason):
                if !online() { return .waiting(reason: DevicePath.offlineReason) }
                switch await look(
                    text: text, attachments: attachments, baseline: baselineUserCount)
                {
                case .arrived: return .arrived
                case .unreachable: return .waiting(reason: reason)
                case .missing, .unread: return .failed(reason: reason)
                }
            }
        }
    }

    /// What asking the server came to.
    enum Look: Equatable {
        case arrived
        case missing
        /// The server could not be reached to ask, which says the link is down rather than that
        /// the words did not arrive.
        case unreachable(String)
        /// The server answered with something other than its account.
        case unread
    }

    func look(text: String, attachments: Int, baseline: Int) async -> Look {
        do {
            let account = try await Self.within(rereadBound, reread)
            if Task.isCancelled { return .unread }
            return account.holds(text, attachments: attachments, baselineUserCount: baseline)
                ? .arrived : .missing
        } catch {
            switch SendFailure.read(error) {
            case .neverLeft(let reason)?, .uncertain(let reason)?: return .unreachable(reason)
            case .refused?, nil: return .unread
            }
        }
    }

    /// Runs `work` under a deadline, throwing `SendBound.Expired` when the deadline wins.
    static func within<T: Sendable>(
        _ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw SendBound.Expired() }
            guard let value = first else { throw SendBound.Expired() }
            return value
        }
    }
}
