import CodingAgentKit
import Foundation

/// A turn the machine was pulled out from under, read into words a person can act on.
///
/// This is the one failure that looks exactly like success. The prompt is in the transcript, no
/// answer follows it, the spinner is gone, and nothing anywhere says an answer was ever coming —
/// so the conversation reads as a question that was ignored rather than as work that was cut in
/// half. The agent may have been three files into an edit when the power went.
///
/// Everything here is read off what the server actually recorded. How far the work got comes from
/// the agent's own transcript rather than from anything it claimed about itself, and the card
/// never says what caused the stop, because nobody knows: a bridge that was updated, a machine
/// that slept and a process that was killed all leave the same evidence.
public struct InterruptedTurn: Sendable, Hashable {
    /// Where the card stands.
    ///
    /// A press is a state of its own because its answer travels over a network: between the tap
    /// and the server's word there is a second or two in which a card that looks exactly as it did
    /// before tells the person their tap did nothing. `resumed` is the server's word; `pickingUp`
    /// and `lettingGo` are this device's, and are never mistaken for it.
    public enum State: Sendable, Hashable {
        case waiting
        case pickingUp
        case lettingGo
        case resumed
    }

    /// What was asked, as the person wrote it.
    public let prompt: String
    public let title: String
    /// One sentence: what happened, and when it was noticed.
    public let detail: String
    /// What the turn had already done, one line each, in the order a person triages in. Empty when
    /// the turn was cut off before it did anything, which is a fact worth its own line.
    public let progress: [String]
    /// Prompts that were waiting behind the interrupted turn and never ran.
    public let queued: [String]
    /// The same fact as one sentence, or `nil` when nothing was waiting. Every client draws this
    /// line and no client writes it.
    public let queuedLine: String?
    /// What leaving the card standing costs, or `nil` once a decision has been made.
    ///
    /// While an interruption is unresolved the server will not carry the session on by itself —
    /// the whole unattended-continuation feature is off for as long as the card is undecided. That
    /// is a price the person is paying without being told, so the card tells them.
    public let cost: String?
    /// The whole thing as one sentence, for a screen reader.
    public let spoken: String
    public let state: State

    /// Whether the server itself has said the work is going again — the card stays, saying so,
    /// until the resumed turn produces something, because a card that vanishes on the press leaves
    /// a person with no idea whether it worked.
    public var isResumed: Bool { state == .resumed }
    /// Whether a button may still be pressed. A press already in flight is not a second press.
    public var acceptsPress: Bool { state == .waiting }

    public var resumeTitle: String {
        state == .pickingUp ? Self.pickingUpTitle : Localized.text("Pick it back up")
    }
    public var dismissTitle: String {
        state == .lettingGo ? Self.lettingGoTitle : Localized.text("Let it go")
    }

    /// What each button says from the instant it is pressed until the server answers.
    public static var pickingUpTitle: String { Localized.text("Picking it back up…") }
    public static var lettingGoTitle: String { Localized.text("Letting it go…") }

    /// The face, in the same two alphabets every state in this app is drawn in. A cut-off turn is
    /// settled — nothing is running — so it holds perfectly still, and it wears the attention tone
    /// rather than the danger one: nothing failed, something stopped.
    public static let symbol = "bolt.horizontal.circle"
    public static let glyph = "⚡"
    public static let tone = ActivityTone.attention
}

/// Which button was pressed. The two actions have always existed; what is new is that a client can
/// say one of them is in flight.
public enum InterruptedTurnPress: Sendable, Hashable {
    case pickUp
    case letGo

    var state: InterruptedTurn.State { self == .pickUp ? .pickingUp : .lettingGo }
}

/// Why the server refused a press, as a code rather than a sentence.
///
/// A conflict is the one answer that proves the card is out of date, and the two reasons for it
/// want different things done: nothing interrupted means the card must go, whereas already resumed
/// means the card must stay and start saying so. A client that can only read the sentence has to
/// guess between them, so the server names the reason and this reads the name.
public enum InterruptedTurnConflict: Sendable, Hashable {
    case nothingInterrupted
    case alreadyResumed
    case unknownSession
    case unstated

    /// The key the server answers under.
    public static let key = "reason"

    public init(code: String?) {
        switch code {
        case "nothing_interrupted": self = .nothingInterrupted
        case "already_resumed": self = .alreadyResumed
        case "unknown_session": self = .unknownSession
        default: self = .unstated
        }
    }

    public var code: String? {
        switch self {
        case .nothingInterrupted: return "nothing_interrupted"
        case .alreadyResumed: return "already_resumed"
        case .unknownSession: return "unknown_session"
        case .unstated: return nil
        }
    }
}

public enum InterruptedTurnReading {
    /// Reads what the server reported into the card, or `nil` when there is nothing to say.
    public static func read(_ cutOff: TurnInterruption?, now: Date = Date()) -> InterruptedTurn? {
        guard let cutOff else { return nil }
        let state: InterruptedTurn.State = cutOff.resumedAt != nil ? .resumed : .waiting
        return compose(
            prompt: cutOff.prompt,
            detail: detail(for: state)
                ?? Localized.text(
                    "This turn had been running %@ when the machine running it stopped. It was noticed %@, when the server came back — nothing was wrong with what you asked.",
                    span(from: cutOff.startedAt, to: cutOff.detectedAt),
                    elapsed(from: cutOff.detectedAt, to: now)),
            progress: progressLines(cutOff.progress),
            queued: cutOff.queued,
            state: state)
    }

    /// The card as it must be drawn the instant a button is pressed, before the server has said
    /// anything. The press is acknowledged where it happened — on the card — rather than left to a
    /// status line that may never come.
    public static func pressed(_ turn: InterruptedTurn, _ press: InterruptedTurnPress)
        -> InterruptedTurn
    {
        compose(
            prompt: turn.prompt,
            detail: detail(for: press.state) ?? turn.detail,
            progress: turn.progress,
            queued: turn.queued,
            state: press.state)
    }

    /// What to say when the server refused a press, given the body it refused with.
    ///
    /// The server's own sentence is the answer whenever it sent one — it knows why and this does
    /// not — and the second half is the promise the client must then keep: the card is out of date
    /// and is being replaced with whatever the server actually has, so pressing again is never the
    /// person's job.
    public static func refusal(body: String?) -> String {
        refusal(said: value(of: "error", in: body), reason: conflict(body: body))
    }

    public static func refusal(said: String?, reason: InterruptedTurnConflict) -> String {
        let given = (said ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (given.isEmpty ? fallback(reason) : given) + " " + refreshedNote
    }

    /// The reason a refusal names, or `unstated` when the server named none.
    public static func conflict(body: String?) -> InterruptedTurnConflict {
        InterruptedTurnConflict(code: value(of: InterruptedTurnConflict.key, in: body))
    }

    /// What to say about a press that failed, whatever came back.
    ///
    /// Only a conflict is a refusal this side has already acted on — the record is re-read before
    /// one is rethrown, so the card has corrected itself or come down by the time anybody reads
    /// this — and only a conflict may therefore carry the promise that it has. A machine that
    /// could not be reached refused nothing, and is reported in the words the failure arrived
    /// with. Deciding which of the two happened is exactly the kind of rule three clients would
    /// otherwise each write once and each get slightly differently, so it is decided here.
    public static func refusal(for error: Error) -> String {
        guard case AgentError.http(let status, let body) = error, refused(status, body) else {
            return AgentErrorText.readable(error)
        }
        return refusal(body: body)
    }

    /// Whether the server itself refused the press.
    ///
    /// A conflict says so outright. A 404 is two answers wearing one status — a bridge too old to
    /// have the route at all, and this bridge saying it no longer knows the session — told apart
    /// by whether the body names a reason, because only the second was written by code that knew
    /// what had been asked of it.
    private static func refused(_ status: Int, _ body: String) -> Bool {
        switch status {
        case 409: return true
        case 404: return conflict(body: body) != .unstated
        default: return false
        }
    }

    /// The half of a refusal that is a promise rather than a report.
    public static var refreshedNote: String {
        Localized.text("The card has been refreshed to what the server actually has.")
    }

    /// The sentence for a refusal the server did not explain — a fallback, never a paraphrase of
    /// something it did say.
    private static func fallback(_ reason: InterruptedTurnConflict) -> String {
        switch reason {
        case .nothingInterrupted:
            return Localized.text("The server has no interrupted turn in this session any more.")
        case .alreadyResumed:
            return Localized.text("That turn is already being picked back up.")
        case .unknownSession:
            return Localized.text("The server does not know this session any more.")
        case .unstated:
            return Localized.text(
                "The server would not pick that turn back up, and did not say why.")
        }
    }

    /// One string out of a JSON object, without asking a client to parse the body three times over.
    private static func value(of key: String, in body: String?) -> String? {
        guard let body, let data = body.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let found = object[key] as? String
        else { return nil }
        return found
    }

    /// Everything a card carries that is derived rather than reported, in one place, so the read
    /// and the press cannot drift apart.
    private static func compose(
        prompt: String, detail: String, progress: [String], queued: [String],
        state: InterruptedTurn.State
    ) -> InterruptedTurn {
        let line = queuedLine(queued)
        let price = cost(for: state)
        let title = title(for: state)
        return InterruptedTurn(
            prompt: prompt,
            title: title,
            detail: detail,
            progress: progress,
            queued: queued,
            queuedLine: line,
            cost: price,
            spoken: ([title, detail] + progress + [line, price].compactMap { $0 })
                .joined(separator: " "),
            state: state)
    }

    private static func title(for state: InterruptedTurn.State) -> String {
        switch state {
        case .waiting: return Localized.text("The server stopped mid-answer")
        case .pickingUp, .resumed: return Localized.text("Picking the turn back up")
        case .lettingGo: return Localized.text("Letting the turn go")
        }
    }

    /// The sentence under the title for every state whose story does not depend on the clock;
    /// `nil` for the one that does, which the reader writes from the record's own dates.
    private static func detail(for state: InterruptedTurn.State) -> String? {
        switch state {
        case .waiting:
            return nil
        case .pickingUp:
            return Localized.text(
                "Asked the server to pick this back up — waiting for it to say it has.")
        case .lettingGo:
            return Localized.text(
                "Asked the server to set this aside — waiting for it to say it has.")
        case .resumed:
            return Localized.text(
                "The work is being continued from where it stopped. Everything above is still this same conversation.")
        }
    }

    /// The price of leaving the card standing, which only an undecided card pays.
    private static func cost(for state: InterruptedTurn.State) -> String? {
        guard state == .waiting else { return nil }
        return Localized.text(
            "Until this is answered, the server will not carry this session on by itself — picking it up or letting it go both end that.")
    }

    /// What never ran behind the cut-off turn, as one sentence.
    static func queuedLine(_ queued: [String]) -> String? {
        guard !queued.isEmpty else { return nil }
        return queued.count == 1
            ? Localized.text("One prompt was waiting behind it and never ran.")
            : Localized.text("%@ prompts were waiting behind it and never ran.", "\(queued.count)")
    }

    /// What the turn had actually done. Counted rather than characterised: a client shows the
    /// account, and the person decides whether continuing or starting over is the safer move.
    static func progressLines(_ progress: TurnInterruption.Progress) -> [String] {
        guard !progress.isEmpty else {
            return [Localized.text("It had not done anything yet — nothing on the machine changed.")]
        }
        var lines: [String] = []
        if progress.toolCount > 0 {
            lines.append(
                progress.toolCount == 1
                    ? Localized.text("Ran 1 tool")
                    : Localized.text("Ran %@ tools", "\(progress.toolCount)"))
        }
        if let last = progress.lastTool, !last.isEmpty {
            lines.append(Localized.text("Was in the middle of %@", last))
        }
        if !progress.filesTouched.isEmpty {
            lines.append(
                Localized.text(
                    "Wrote to %@", list(progress.filesTouched.map { name(of: $0) })))
        }
        if !progress.commands.isEmpty {
            lines.append(Localized.text("Ran %@", list(progress.commands)))
        }
        if let partial = progress.partialAnswer, !partial.isEmpty {
            lines.append(Localized.text("Had started answering: “%@”", partial))
        }
        return lines
    }

    /// At most three, named, with the rest counted — a list that runs off the card tells nobody
    /// anything.
    static func list(_ items: [String], limit: Int = 3) -> String {
        let shown = items.prefix(limit).joined(separator: ", ")
        guard items.count > limit else { return shown }
        return Localized.text("%@ and %@ more", shown, "\(items.count - limit)")
    }

    static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// How long the turn ran before it was cut off.
    static func span(from: Date, to: Date) -> String {
        duration(max(0, to.timeIntervalSince(from)))
    }

    /// How long ago something was noticed, in the same words.
    static func elapsed(from: Date, to: Date) -> String {
        let seconds = max(0, to.timeIntervalSince(from))
        guard seconds >= 60 else { return Localized.text("just now") }
        return Localized.text("%@ ago", duration(seconds))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return Localized.text("%@s", "\(Int(seconds.rounded()))")
        }
        if seconds < 3_600 {
            return Localized.text("%@m", "\(Int((seconds / 60).rounded()))")
        }
        let hours = seconds / 3_600
        return hours < 10
            ? Localized.text("%@h", String(format: "%.1f", hours))
            : Localized.text("%@h", "\(Int(hours.rounded()))")
    }
}

/// The rules, checked headlessly so all three clients are proved against one set of answers.
public enum InterruptedTurnCheck {
    public static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        expect(InterruptedTurnReading.read(nil) == nil, "nothing interrupted says nothing")

        let started = Date(timeIntervalSince1970: 1_000_000)
        let detected = started.addingTimeInterval(340)
        let now = detected.addingTimeInterval(120)
        let busy = TurnInterruption(
            turnID: "t1", prompt: "port the toggles", startedAt: started, detectedAt: detected,
            progress: TurnInterruption.Progress(
                toolCount: 7, lastTool: "Edit", filesTouched: ["/a/b/Theme.swift", "/a/b/Row.swift"],
                commands: ["swift build"], partialAnswer: "I have started by"),
            queued: ["and then the mac"])
        guard let card = InterruptedTurnReading.read(busy, now: now) else {
            failures.append("an interrupted turn reads as a card")
            return failures
        }
        expect(card.prompt == "port the toggles", "the card carries what was asked")
        expect(!card.isResumed, "and knows it has not been picked up")
        expect(card.state == .waiting, "an undecided card says it is undecided")
        expect(card.acceptsPress, "and takes a press")
        expect(card.detail.contains("6m"), "it says how long the turn had been running")
        expect(card.detail.contains("2m ago"), "and when it was noticed")
        expect(card.progress.contains { $0.contains("7") }, "the tools are counted")
        expect(
            card.progress.contains { $0.contains("Theme.swift") && !$0.contains("/a/b") },
            "files are named, not pathed")
        expect(card.queued == ["and then the mac"], "and what never ran is kept")
        expect(
            card.queuedLine == Localized.text("One prompt was waiting behind it and never ran."),
            "what never ran gets its own sentence, from here, not from a client")
        expect(card.spoken.contains("One prompt was waiting"), "read out whole")

        expect(
            card.cost?.contains("will not carry this session on by itself") == true,
            "an undecided card says the session will not continue on its own until it is answered")
        expect(
            card.cost?.contains("picking it up or letting it go both end that") == true,
            "and says what ends that")
        expect(card.spoken.contains("will not carry this session"), "the cost is read out too")

        let pickingUp = InterruptedTurnReading.pressed(card, .pickUp)
        expect(pickingUp.state == .pickingUp, "a press is a state of its own")
        expect(!pickingUp.acceptsPress, "a press in flight takes no second press")
        expect(!pickingUp.isResumed, "and is never mistaken for the server's word")
        expect(
            pickingUp.resumeTitle == InterruptedTurn.pickingUpTitle
                && pickingUp.resumeTitle != card.resumeTitle,
            "the button visibly changes the instant it is pressed")
        expect(
            pickingUp.detail.contains("waiting for it to say it has"),
            "and the card says what it is waiting on")
        expect(pickingUp.cost == nil, "a decided card charges nothing for standing")
        expect(pickingUp.queuedLine == card.queuedLine, "a press keeps what the card already said")

        let lettingGo = InterruptedTurnReading.pressed(card, .letGo)
        expect(lettingGo.state == .lettingGo, "letting go is in flight too")
        expect(
            lettingGo.dismissTitle == InterruptedTurn.lettingGoTitle
                && lettingGo.dismissTitle != card.dismissTitle,
            "and its button changes on the press as well")
        expect(!lettingGo.acceptsPress, "one press at a time")

        let refused = InterruptedTurnReading.refusal(
            body:
                "{\"error\":\"Nothing to pick up — no turn in this session was interrupted.\",\"reason\":\"nothing_interrupted\",\"interruption\":null}"
        )
        expect(
            refused.contains("Nothing to pick up — no turn in this session was interrupted."),
            "the server said why, so the server's words are what is shown")
        expect(
            refused.contains(InterruptedTurnReading.refreshedNote),
            "and a refusal always promises the card is being corrected")
        expect(
            InterruptedTurnReading.conflict(
                body: "{\"error\":\"x\",\"reason\":\"already_resumed\"}") == .alreadyResumed,
            "already resumed is told apart from nothing interrupted")
        expect(
            InterruptedTurnReading.conflict(body: "{\"error\":\"x\"}") == .unstated,
            "a server that names no reason is not guessed at")
        expect(InterruptedTurnReading.conflict(body: nil) == .unstated, "nor is no body at all")
        expect(
            InterruptedTurnConflict(code: InterruptedTurnConflict.alreadyResumed.code)
                == .alreadyResumed,
            "the codes are the ones the bridge writes")
        expect(
            InterruptedTurnReading.refusal(said: "  ", reason: .alreadyResumed)
                .hasPrefix(Localized.text("That turn is already being picked back up.")),
            "a silent server gets this side's sentence, one per reason")
        expect(
            InterruptedTurnReading.refusal(said: nil, reason: .unstated).contains("did not say why"),
            "and an unexplained refusal admits that it is unexplained")

        let conflicted = AgentError.http(
            status: 409,
            body:
                "{\"error\":\"That turn is already being picked back up.\",\"reason\":\"already_resumed\"}"
        )
        expect(
            InterruptedTurnReading.refusal(for: conflicted)
                .contains("That turn is already being picked back up."),
            "a conflict is reported in the server's own sentence")
        expect(
            InterruptedTurnReading.refusal(for: conflicted).contains(
                InterruptedTurnReading.refreshedNote),
            "and only a conflict promises the card was corrected")
        expect(
            InterruptedTurnReading.refusal(
                for: AgentError.http(
                    status: 404, body: "{\"error\":\"not found\",\"reason\":\"unknown_session\"}")
            ).contains(InterruptedTurnReading.refreshedNote),
            "a 404 that names a reason is the server refusing, not a route it lacks")
        expect(
            !InterruptedTurnReading.refusal(for: AgentError.http(status: 404, body: ""))
                .contains(InterruptedTurnReading.refreshedNote),
            "a bare 404 is a route this bridge lacks and promises nothing")
        expect(
            !InterruptedTurnReading.refusal(for: AgentError.connection("nothing answered"))
                .contains(InterruptedTurnReading.refreshedNote),
            "a machine that could not be reached refused nothing")
        expect(
            InterruptedTurnReading.refusal(for: AgentError.connection("nothing answered"))
                == AgentErrorText.readable(AgentError.connection("nothing answered")),
            "and is reported in the words it arrived with")

        let untouched = TurnInterruption(
            turnID: "t2", prompt: "hello", startedAt: started, detectedAt: detected)
        let quiet = InterruptedTurnReading.read(untouched, now: now)
        expect(
            quiet?.progress.first?.contains("nothing") == true,
            "a turn that did nothing says so rather than listing nothing")
        expect(quiet?.queuedLine == nil, "and nothing waiting behind it says nothing at all")

        let resumed = TurnInterruption(
            turnID: "t3", prompt: "hello", startedAt: started, detectedAt: detected,
            resumedAt: now)
        let going = InterruptedTurnReading.read(resumed, now: now)
        expect(going?.isResumed == true, "a resumed turn still shows, saying so")
        expect(going?.state == .resumed, "in the state the server put it in")
        expect(going?.acceptsPress == false, "which takes no further press")
        expect(going?.cost == nil, "and no longer charges for standing")

        expect(
            InterruptedTurnReading.list(["a", "b", "c", "d"]).contains("1 more"),
            "a long list counts its tail")
        expect(InterruptedTurnReading.duration(45).contains("45"), "seconds under a minute")
        expect(InterruptedTurnReading.duration(3_600 * 3).contains("3.0"), "hours past an hour")
        expect(
            InterruptedTurnReading.elapsed(from: started, to: started) == Localized.text("just now"),
            "no time at all is just now")
        return failures
    }
}
