import CodingAgentKit
import Foundation

/// A message this device has written, standing in the transcript before the server's account of
/// the conversation has grown to include it.
///
/// A transcript is the server's account, and it arrives late — a long one arrives very late,
/// because every client rebuilds what it draws from the whole of it. The words somebody just
/// wrote are not in that account yet, so a client that waits for them is a client that thinks
/// about the Send key rather than answering it. The pending send is therefore the client's own
/// row, made from what is already in memory: it exists before the request does, and it is retired
/// only when the account carries the message it stood in for.
///
/// Which makes its state worth saying rather than implying. A row that merely appears is a claim
/// that the message went, and each phase here is a different answer to that question — the one
/// that matters most being the one that had no face at all: a send that failed, whose words this
/// row is still holding and can send again.
public struct PendingSend: Sendable, Hashable, Identifiable {
    public enum Phase: Sendable, Hashable {
        /// On the wire, unacknowledged.
        case sending
        /// The server took it. The turn it starts has not reached this device yet.
        case accepted
        /// It never left, and the reason is the server's own words wherever there were any.
        case failed(reason: String)
        /// It could not leave — the device was offline, nothing answered at the machine's address —
        /// so it is held rather than failed, and goes again on its own when the machine answers.
        /// The reason is the transport's own sentence for what stood in the way.
        case waiting(reason: String)
    }

    /// What a row in a given phase can actually do about itself. Deliberately empty while a send
    /// is in flight: the one thing worse than a slow send is two of them.
    public enum Act: String, Sendable, Hashable, CaseIterable {
        case retry
        case edit
        case discard
    }

    public let id: UUID
    public var text: String
    /// Everything that went with the words, kept whole rather than kept for drawing: a send that
    /// failed is sent again from this row, and a row holding only what it could render would
    /// quietly drop the file somebody clipped to it.
    public var attachments: [PromptAttachment]
    /// What it was sent with, so sending it again sends the same message rather than whatever the
    /// picker happens to say by then.
    public var model: ModelSelection?
    public var effort: String?
    public var startedAt: Date
    public var phase: Phase
    /// How many user messages the server's account held when this was written. Growth past it is
    /// how the row knows the account has caught up — counted rather than matched on the words,
    /// so re-sending "ok" cannot be mistaken for an old message and a server that rewrites a
    /// prompt cannot strand a duplicate.
    public let baselineUserCount: Int

    public init(
        id: UUID = UUID(), text: String, attachments: [PromptAttachment] = [],
        model: ModelSelection? = nil, effort: String? = nil,
        startedAt: Date, phase: Phase = .sending, baselineUserCount: Int
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.model = model
        self.effort = effort
        self.startedAt = startedAt
        self.phase = phase
        self.baselineUserCount = baselineUserCount
    }

    /// The ones a client can draw from the bytes still in memory, so a picture just picked is on
    /// screen before the server has echoed the message that carried it.
    public var pictures: [PromptAttachment] {
        attachments.filter { $0.mime.hasPrefix("image/") && $0.data != nil }
    }

    public var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    public var isWaiting: Bool {
        if case .waiting = phase { return true }
        return false
    }

    /// Whether the row is still on its way — which is what decides whether the conversation reads
    /// as busy on a device whose server has not said so yet. A send held for the connection is not
    /// on its way: nothing is on the wire, and the server's account can never grow past it.
    public var isInFlight: Bool {
        switch phase {
        case .sending, .accepted: return true
        case .failed, .waiting: return false
        }
    }

    /// Whether the row is holding words the server has not been given, and only a transcript that
    /// shows them can retire it.
    public var isUnsent: Bool { isFailed || isWaiting }

    public var acts: [Act] {
        isUnsent ? [.retry, .edit, .discard] : []
    }
}

/// Everything this device is holding for a conversation, in the order it was written.
///
/// A value rather than a controller: a view model owns one, every change to it is a change a
/// client renders from, and nothing in here talks to a server. Reconciling is the whole point of
/// keeping it — a pending row that outlives the message it stood in for is a duplicate, and one
/// retired too early is a message that visibly vanishes on its way out.
public struct PendingSendLedger: Sendable, Hashable {
    public private(set) var sends: [PendingSend] = []

    public init(sends: [PendingSend] = []) {
        self.sends = sends
    }

    public var isEmpty: Bool { sends.isEmpty }
    public var count: Int { sends.count }

    /// Whether anything here is still on its way, which is not the same as being non-empty: a
    /// ledger holding nothing but failures is a ledger with nothing in flight.
    public var hasInFlight: Bool { sends.contains { $0.isInFlight } }

    /// Whether a prompt this device sent is still missing from the server's account. Until it
    /// lands, the transcript's last turn is the one *before* it, finished — and the server may
    /// already say it is running, because a backend marks a conversation busy the moment it takes
    /// a prompt, before it has written the prompt down.
    public var awaitsEcho: Bool { hasInFlight }

    /// Whether the transcript's last turn is open: running, and not merely the turn before a
    /// prompt that has not landed yet. A client that read the server's word alone took the
    /// finished answer above the question just asked as the one being written — rebuilt it as an
    /// open turn and replayed its last paragraph from the first letter while the prompt rose.
    public func turnIsOpen(running: Bool) -> Bool { running && !awaitsEcho }

    /// The highest baseline among the sends still on their way: the transcript holds every prompt
    /// this device sent once its user messages outnumber it. Nil when nothing is on its way.
    public var echoBaseline: Int? {
        sends.lazy.filter(\.isInFlight).map(\.baselineUserCount).max()
    }

    /// `turnIsOpen(running:)` asked of a state the ledger has not been reconciled against yet,
    /// which is what a row build made away from the main thread holds: the turn is open when the
    /// server says it is running and the transcript already carries every prompt this device sent.
    public static func turnIsOpen(
        running: Bool, messages: [ChatMessage], echoBaseline: Int?
    ) -> Bool {
        guard running else { return false }
        guard let echoBaseline else { return true }
        return messages.count { $0.role == .user } > echoBaseline
    }

    /// Whether anything is holding words the server has not been given: a failure, or a send
    /// waiting for the connection. Messages queued behind such a row wait with it, because the
    /// order somebody wrote things in outranks the row they were written on.
    public var hasUnsent: Bool { sends.contains { $0.isUnsent } }

    /// The sends held for the connection, oldest first.
    public var waiting: [PendingSend] { sends.filter(\.isWaiting) }

    /// Sends the server took that the transcript still does not carry after `SendWitness.after`:
    /// the stream that should have shown them is the thing to doubt, never the server.
    public func unwitnessed(now: Date) -> [PendingSend] {
        sends.filter {
            $0.phase == .accepted && now.timeIntervalSince($0.startedAt) >= SendWitness.after
        }
    }

    public func send(id: UUID) -> PendingSend? { sends.first { $0.id == id } }

    @discardableResult
    public mutating func begin(
        text: String, attachments: [PromptAttachment] = [], model: ModelSelection? = nil,
        effort: String? = nil, userMessages: Int, now: Date = Date(), id: UUID = UUID()
    ) -> PendingSend {
        let send = PendingSend(
            id: id, text: text, attachments: attachments, model: model, effort: effort,
            startedAt: now, baselineUserCount: userMessages)
        sends.append(send)
        return send
    }

    @discardableResult
    public mutating func mark(id: UUID, _ phase: PendingSend.Phase) -> Bool {
        guard let index = sends.firstIndex(where: { $0.id == id }) else { return false }
        guard sends[index].phase != phase else { return false }
        sends[index].phase = phase
        return true
    }

    /// A failed row sent again is the same row, not a second one: it keeps its place in what was
    /// written, and takes a fresh clock and a fresh baseline because it is a fresh attempt.
    @discardableResult
    public mutating func restart(id: UUID, userMessages: Int, now: Date = Date()) -> PendingSend? {
        guard let index = sends.firstIndex(where: { $0.id == id }) else { return nil }
        let old = sends[index]
        let restarted = PendingSend(
            id: old.id, text: old.text, attachments: old.attachments, model: old.model,
            effort: old.effort, startedAt: now, phase: .sending, baselineUserCount: userMessages)
        sends[index] = restarted
        return restarted
    }

    @discardableResult
    public mutating func remove(id: UUID) -> PendingSend? {
        guard let index = sends.firstIndex(where: { $0.id == id }) else { return nil }
        return sends.remove(at: index)
    }

    public mutating func removeAll() {
        sends.removeAll()
    }

    /// Stop takes back what is on its way and nothing else: a failure or a send waiting for the
    /// connection is holding words nobody else has, and a Stop meant for the send in flight must
    /// not take them with it.
    @discardableResult
    public mutating func removeInFlight() -> [PendingSend] {
        let gone = sends.filter(\.isInFlight)
        sends.removeAll { $0.isInFlight }
        return gone
    }

    /// Retires every row the server's account has caught up with.
    ///
    /// A failed send is never retired by a count: it did not arrive, so nothing in the transcript
    /// is standing in for it, and a later message growing the count must not sweep away the one
    /// row still holding words nobody else has.
    ///
    /// - Returns: whether anything changed, so a caller can decide not to redraw.
    @discardableResult
    public mutating func reconcile(userMessages: Int) -> Bool {
        let before = sends.count
        sends.removeAll { $0.isInFlight && userMessages > $0.baselineUserCount }
        return sends.count != before
    }
}

/// What a client says about a message on its way out, written once so three clients say the same.
///
/// The phases carry the same four tones and the same motions as every other not-idle state in this
/// app: work breathes, and anything settled — sent, failed — holds perfectly still, because
/// stillness is how a reader tells a stopped thing from a slow one.
public enum PendingSendReading {
    /// How long a send may be merely on its way before the row admits the wait. Below it the
    /// caption is a formality nobody reads; past it, it is the only place the app can say that
    /// the hold-up is the network rather than the model.
    public static let slowAfter: TimeInterval = 4

    /// The same, for a send the server has taken. Longer, because a machine picking a turn up is
    /// ordinary and only becomes news when it does not happen.
    public static let quietAfter: TimeInterval = 8

    /// The face, in the same two alphabets and on the same clock as every other state in this
    /// app — so a client draws it with the badge it already has rather than one written for here.
    /// Only a send still on the wire moves; everything else has already happened.
    public static func icon(_ send: PendingSend) -> ActivityIcon {
        switch send.phase {
        case .sending:
            return ActivityIcon(
                symbol: "arrow.up.circle", glyph: "↑", tone: .live,
                motion: .breath(ActivityPulse(period: 1.8, floor: 0.45)))
        case .accepted:
            return ActivityIcon(
                symbol: "checkmark.circle", glyph: "✓", tone: .quiet, motion: .still)
        case .failed:
            return ActivityIcon(
                symbol: "exclamationmark.triangle", glyph: "!", tone: .danger, motion: .still)
        case .waiting:
            return ActivityIcon(
                symbol: "clock.arrow.circlepath", glyph: "↻", tone: .quiet,
                motion: .breath(ActivityPulse(period: 2.6, floor: 0.4)))
        }
    }

    public static func symbol(_ send: PendingSend) -> String { icon(send).symbol }
    public static func glyph(_ send: PendingSend) -> String { icon(send).glyph }
    public static func tone(_ send: PendingSend) -> ActivityTone { icon(send).tone }
    public static func motion(_ send: PendingSend) -> ActivityMotion { icon(send).motion }

    /// How the bubble itself is drawn. A message is yours from the keystroke and it is drawn the
    /// way every sent message is drawn — full strength, on the wire or accepted — because a bubble
    /// that fades in as the server takes it is a state nobody asked to watch: the words are what
    /// matter, and they never change. Only a failure changes the ink, taking the danger tone so a
    /// message that did not go can never be mistaken for one that did.
    public enum Ink: Sendable, Equatable {
        case full
        case failed

        public var opacity: Double { 1 }

        public var tone: ActivityTone {
            switch self {
            case .full: return .quiet
            case .failed: return .danger
            }
        }
    }

    /// A send waiting for the connection keeps full ink: it has not failed, it is going, and the
    /// words are the person's exactly as they will arrive.
    public static func ink(_ send: PendingSend) -> Ink {
        switch send.phase {
        case .sending, .accepted, .waiting: return .full
        case .failed: return .failed
        }
    }

    /// The line under the words, and only when it has something to say. A send on its way and a
    /// send the server took are told by the ink alone; the line appears when the wait has become
    /// news — a send still on the wire past `slowAfter`, a machine that has not started past
    /// `quietAfter` — and for a failure, which carries the server's own reason.
    public static func caption(_ send: PendingSend, now: Date) -> String? {
        let elapsed = now.timeIntervalSince(send.startedAt)
        switch send.phase {
        case .sending:
            return elapsed >= slowAfter ? Localized.text("Still sending…") : nil
        case .accepted:
            return elapsed >= quietAfter
                ? Localized.text("Waiting for the machine to start") : nil
        case .failed(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? Localized.text("Not sent")
                : Localized.text("Not sent — %@", trimmed)
        case .waiting(let reason):
            if reason == SendWait.behindTurn { return reason }
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? Localized.text("Sends on its own when the machine answers")
                : Localized.text("%@ Sends on its own when the machine answers.", trimmed)
        }
    }

    /// When the caption strip next changes on its own, so a client can wake its clock for that
    /// moment rather than tick every second under a row that has nothing to say.
    public static func nextCaptionChange(_ send: PendingSend, now: Date) -> Date? {
        switch send.phase {
        case .sending:
            let at = send.startedAt.addingTimeInterval(slowAfter)
            return at > now ? at : nil
        case .accepted:
            let at = send.startedAt.addingTimeInterval(quietAfter)
            return at > now ? at : nil
        case .failed, .waiting:
            return nil
        }
    }

    /// What a row too narrow for the sentence wears instead — a failure, and a send held for the
    /// connection, which is the other state a reader has to be told rather than shown.
    public static func badge(_ send: PendingSend) -> String? {
        switch send.phase {
        case .sending, .accepted: return nil
        case .failed: return Localized.text("not sent")
        case .waiting: return Localized.text("waiting")
        }
    }

    /// The state in words, for a screen reader, which cannot read ink.
    public static func state(_ send: PendingSend, now: Date) -> String {
        if let caption = caption(send, now: now) { return caption }
        switch send.phase {
        case .sending: return Localized.text("Sending")
        case .accepted: return Localized.text("Sent")
        case .failed: return Localized.text("Not sent")
        case .waiting: return Localized.text("Waiting to send")
        }
    }

    /// The whole of it, for a screen reader: what was written, and what became of it.
    public static func spoken(_ send: PendingSend, now: Date) -> String {
        let words = send.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pictures = send.attachments.count { $0.mime.hasPrefix("image/") }
        var line = state(send, now: now)
        if pictures > 0 {
            line += ". "
            line += pictures == 1
                ? Localized.text("With one picture.")
                : Localized.text("With %d pictures.", pictures)
        }
        return words.isEmpty ? line : "\(words). \(line)"
    }

    public static func title(_ act: PendingSend.Act) -> String {
        switch act {
        case .retry: return Localized.text("Send again")
        case .edit: return Localized.text("Edit")
        case .discard: return Localized.text("Discard")
        }
    }

    /// The act as this row offers it: a send held for the connection is not sent *again*, it is
    /// sent now instead of on its own.
    public static func title(_ act: PendingSend.Act, for send: PendingSend) -> String {
        if act == .retry, send.isWaiting { return Localized.text("Send now") }
        return title(act)
    }

    public static func symbol(_ act: PendingSend.Act) -> String {
        switch act {
        case .retry: return "arrow.clockwise"
        case .edit: return "pencil"
        case .discard: return "trash"
        }
    }
}
