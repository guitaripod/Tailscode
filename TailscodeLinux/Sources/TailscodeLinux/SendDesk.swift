import CodingAgentKit
import Foundation
import TailscodeCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// How a send held for the connection is being waited out: how many times it has been tried and
/// how long the machine has been out of reach for it. Only unreachable time counts toward
/// `SendWait.window` — a send that waited behind a running turn was never failing to go, it was
/// keeping its place.
struct SendWaitClock: Sendable, Equatable {
    var attempts = 0
    /// When the send first started waiting for anything, kept for the record on disk.
    var heldSince: Date
    /// Unreachable time already spent, from stretches that have ended.
    var unreachable: TimeInterval = 0
    /// When the current stretch of being out of reach began, nil while it is not out of reach.
    var unreachableFrom: Date?

    init(heldSince: Date) {
        self.heldSince = heldSince
    }

    /// The machine could not be reached at `now`.
    mutating func outOfReach(at now: Date) {
        if unreachableFrom == nil { unreachableFrom = now }
    }

    /// The send stopped waiting on the network at `now` — it is behind a turn, or on its way.
    mutating func reachable(at now: Date) {
        guard let from = unreachableFrom else { return }
        unreachable += max(0, now.timeIntervalSince(from))
        unreachableFrom = nil
    }

    func unreachableTime(at now: Date) -> TimeInterval {
        unreachable + (unreachableFrom.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    func givesUp(at now: Date) -> Bool {
        SendWait.givesUp(heldSince: now.addingTimeInterval(-unreachableTime(at: now)), now: now)
    }
}

/// One attempt at a send on the wire: the task, the token that names it, and the send as it was
/// when it left, so an answer that lands on no row can put the words back.
struct SendAttempt: @unchecked Sendable {
    let token: Int
    let task: Task<Void, Never>
    let sent: PendingSend
}

/// The rules of the attempts on the wire, written once so the pane and the shelf keep the same
/// ones: never two attempts at one send, and an answer counts only while its attempt is still the
/// registered one — Stop, a discard or a send found in the transcript call an attempt back by
/// taking it out, and whatever it says after that changes nothing.
enum SendAttempts {
    static func mayStart(_ attempts: [UUID: SendAttempt], _ id: UUID) -> Bool {
        attempts[id] == nil
    }

    /// Takes an answered attempt out, answering whether it was still the current one.
    static func finish(_ attempts: inout [UUID: SendAttempt], id: UUID, token: Int) -> Bool {
        guard attempts[id]?.token == token else { return false }
        attempts[id] = nil
        return true
    }

    /// Calls every attempt back, so none of their answers will count.
    static func callBackAll(_ attempts: inout [UUID: SendAttempt]) {
        for attempt in attempts.values { attempt.task.cancel() }
        attempts = [:]
    }
}

/// Whether an attempt may go now.
enum SendGate {
    enum Verdict: Equatable {
        case post
        /// The transcript has not loaded, so no count it could be reconciled against exists yet.
        case awaitLoad
        /// A turn is running, or the last send has not shown its turn yet: the send keeps its
        /// place and goes first when the turn ends.
        case behindTurn
    }

    static func attempt(loaded: Bool, busy: Bool) -> Verdict {
        guard loaded else { return .awaitLoad }
        return busy ? .behindTurn : .post
    }

    /// Whether a newly written prompt waits in the queue rather than going now: a turn running, a
    /// send still being handed over, messages already waiting, or a send held for the connection
    /// ahead of it — the order somebody wrote things in is the order they go.
    static func holdsNewSend(
        busy: Bool, queueEmpty: Bool, waitingAhead: Bool
    ) -> Bool {
        busy || !queueEmpty || waitingAhead
    }
}

/// What an attempt's answer does to the ledger it belongs to.
enum SendLanding {
    /// Applies an outcome to `ledger`. A send the ledger let go of while its attempt was out — the
    /// account grew past it with someone else's message — is put back when the answer says the
    /// words did not go, so they are never dropped on the floor. Returns whether the send still
    /// has a row afterwards.
    @discardableResult
    static func settle(
        _ outcome: SendOutcome, of sent: PendingSend, in ledger: inout PendingSendLedger
    ) -> Bool {
        switch outcome {
        case .accepted:
            return ledger.mark(id: sent.id, .accepted) || ledger.send(id: sent.id) != nil
        case .arrived, .cancelled:
            ledger.remove(id: sent.id)
            return false
        case .waiting(let reason):
            if ledger.send(id: sent.id) == nil {
                ledger.reinstate(sent, as: .waiting(reason: reason))
            } else {
                ledger.mark(id: sent.id, .waiting(reason: reason))
            }
            return true
        case .failed(let reason):
            if ledger.send(id: sent.id) == nil {
                ledger.reinstate(sent, as: .failed(reason: reason))
            } else {
                ledger.mark(id: sent.id, .failed(reason: reason))
            }
            return true
        }
    }
}

/// What a pane was holding for a conversation it stopped showing: the sends not yet in the
/// server's account, the clocks of the ones held for the connection, and the attempts still on the
/// wire. A send outlives the pane's attention — its answer lands here when the pane has moved on,
/// and the chat opened again, in this pane or another, picks them back up with the attempts still
/// running rather than sending them a second time. Main thread only.
enum SendShelf {
    struct Shelved {
        var ledger = PendingSendLedger()
        var waits: [UUID: SendWaitClock] = [:]
        var attempts: [UUID: SendAttempt] = [:]
    }

    nonisolated(unsafe) private static var held: [LiveKey: Shelved] = [:]
    nonisolated(unsafe) private static var lastToken = 0

    /// A token no other attempt in this process has had.
    static func nextToken() -> Int {
        lastToken += 1
        return lastToken
    }

    static func put(_ shelved: Shelved, for key: LiveKey) {
        held[key] = shelved.ledger.isEmpty && shelved.attempts.isEmpty ? nil : shelved
    }

    static func take(_ key: LiveKey) -> Shelved {
        held.removeValue(forKey: key) ?? Shelved()
    }

    static func hasUnsent(_ key: LiveKey) -> Bool {
        held[key]?.ledger.hasUnsent ?? false
    }

    /// Changes a shelved conversation's sends, answering whether it held any.
    @discardableResult
    static func change(_ key: LiveKey, _ edit: (inout Shelved) -> Void) -> Bool {
        guard var shelved = held[key] else { return false }
        edit(&shelved)
        put(shelved, for: key)
        return true
    }
}

/// The record on disk of every send held for the connection (`HeldSendStore`), kept in step with
/// the rows: written when a send starts waiting, let go the moment it stops for any reason.
enum HeldSends {
    static func hold(
        _ send: PendingSend, key: LiveKey, heldSince: Date, reason: String
    ) {
        let records = HeldSendStore.records(profileID: key.profileID, sessionID: key.sessionID)
        if let kept = records.first(where: { $0.id == send.id }), kept.reason == reason {
            return
        }
        HeldSendStore.hold(
            HeldSend(
                send, profileID: key.profileID, sessionID: key.sessionID, heldSince: heldSince,
                reason: reason))
    }

    static func release(_ id: UUID) {
        HeldSendStore.release(id)
    }

    /// Puts what a conversation was holding when the app last ran back into its ledger, skipping
    /// any row the ledger already has, and answers the clocks to wait them out on. Each row counts
    /// the person's messages from the moment it started waiting, so words that reached the server
    /// before the app went are found in the transcript rather than sent a second time.
    static func restore(
        _ key: LiveKey, into ledger: inout PendingSendLedger, messages: [ChatMessage]
    ) -> [UUID: SendWaitClock] {
        var clocks: [UUID: SendWaitClock] = [:]
        for record in HeldSendStore.records(profileID: key.profileID, sessionID: key.sessionID) {
            let before = messages.count { $0.role == .user && $0.createdAt < record.heldSince }
            guard ledger.restore(record, userMessages: before) != nil else { continue }
            clocks[record.id] = SendWaitClock(heldSince: record.heldSince)
        }
        return clocks
    }
}

/// Faults a harness asks the next sends to meet on the wire, so a send held for the connection and
/// one that broke after leaving can be driven and photographed without pulling a cable.
struct SendFault: Sendable {
    var offline = 0
    var dropped = 0
    /// How long each attempt is held on the wire before it answers, so an attempt can be caught
    /// mid-flight.
    var slow: TimeInterval = 0

    var isArmed: Bool { offline > 0 || dropped > 0 || slow > 0 }

    mutating func next() -> (any Error)? {
        if offline > 0 {
            offline -= 1
            return AgentError.connection(
                TransportWords.sentence(for: URLError(.notConnectedToInternet)))
        }
        if dropped > 0 {
            dropped -= 1
            return AgentError.connection(
                TransportWords.sentence(for: URLError(.networkConnectionLost)))
        }
        return nil
    }
}
