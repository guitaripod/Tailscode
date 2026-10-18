import Foundation

/// What a running turn's card says while it happens, as data: the verdict in words with its glyph
/// and tone, the counts, the zone that is lit and how it breathes, and the NOW line (the step in
/// flight in plain words with its argument and the last line it printed, a silence, or a note the
/// agent has just written). A client draws it; every word and every number is Core's.
///
/// The live card keeps the settled card's size, so nothing shifts when the turn ends. Time enters
/// only through the arguments of `reading`, `line` and the swell functions, never through the
/// value, so an unchanged turn is an equal card and the client redraws on its own clock.
public struct NeuralLiveCard: Sendable, Equatable {
    /// The glyph before the verdict.
    public enum Glyph: Sendable, Equatable {
        /// Working: a pulse.
        case pulse
        /// Waiting for the person: pause bars.
        case pauseBars
        /// Stuck: a dashed clock.
        case dashedClock
        /// An error in flight: a triangle.
        case triangle
    }

    /// What the third line is about.
    public enum LineKind: Sendable, Equatable {
        /// The step in flight.
        case step
        /// A note the agent just wrote, held for `quoteHold` seconds.
        case quote
    }

    /// What closes the NOW line on the right.
    public enum Trailing: Sendable, Equatable {
        /// The last line the step printed, sliding up as it arrives; `tone` is attention for an
        /// error's output and quiet otherwise.
        case output(text: String, tone: NeuralTone)
        /// "silent for 40s", in attention, in place of the output.
        case silence(String)
        case none
    }

    /// The agent's note: its speaker and its words, whole.
    public struct Quote: Sendable, Equatable {
        /// The step the note is, so a client can tell a new note from the one it already holds.
        public let stepID: String
        public let speaker: String
        public let words: String

        /// "Fable: Building it from the existing film rig\u{2026}", cut at a word to fit.
        public func line(fittingChars characters: Int) -> String {
            let room = max(characters - speaker.count - 2, 8)
            return Localized.text(
                "%1$@: %2$@", speaker, NeuralAccount.quote(of: words, maxChars: room))
        }
    }

    /// The headline at an instant.
    public struct Reading: Sendable, Equatable {
        /// "Working", "Waiting for you", "Stuck for 40s", "Hit an error: trying again".
        public let word: String
        public let tone: NeuralTone
        public let glyph: Glyph
        /// "12 steps \u{00B7} 3 said \u{00B7} 4m 05s", tabular in the client's mono role.
        public let counts: String
        /// How long the turn has run, nil before it has a start.
        public let elapsed: TimeInterval?
        /// How long nothing has arrived, from the client's own clock.
        public let silentFor: TimeInterval
        public let isSilent: Bool
    }

    /// The third line at an instant.
    public struct Line: Sendable, Equatable {
        public let kind: LineKind
        /// "Running the tests", or the agent's quote when `kind` is `.quote`.
        public let title: String
        /// The command, path or pattern, in the mono role; nil when there is none or the line is a
        /// quote.
        public let argument: String?
        public let trailing: Trailing
        public let quote: Quote?
        /// Whether the step in flight is waiting on the person.
        public let isWaiting: Bool
    }

    /// The step in flight.
    public struct Flight: Sendable, Equatable {
        public let stepID: String
        public let number: Int
        /// "Running the tests".
        public let title: String
        public let argument: String?
        public let verdict: NeuralVerdict.Step
        /// The last line it printed, with the tone it is drawn in.
        public let lastLine: NeuralReadout.OutputLine?
        /// Whether the step is a thought rather than a tool.
        public let isThinking: Bool
    }

    /// How long a note holds the third line.
    public static let quoteHold: TimeInterval = 4
    /// How long nothing may arrive before the line says so.
    public static let silenceThreshold: TimeInterval = NeuralAccount.silentAfter
    /// How long a new output line takes to slide into place, and how far it slides.
    public static let outputSlide: TimeInterval = 0.220
    public static let outputSlideDistance = 6.0

    public let turnID: String
    public let verdict: NeuralVerdict.Turn
    /// The zone that is lit; nil for a state that belongs to the whole head.
    public let activeZone: NeuralZone?
    /// The activity's own motion for the lit zone: breath for work, heartbeat for a turn that is
    /// waiting, still for a stuck one.
    public let motion: NeuralMotion
    public let stepCount: Int
    public let saidCount: Int
    public let startedAt: Date?
    public let lastStepAt: Date?
    public let flight: Flight?
    /// The latest note the agent wrote: a client holds it on the line for four seconds from the
    /// moment it first saw this step id. Words still streaming at the end of the turn are the
    /// answer, not a step, and are not quoted here.
    public let quote: Quote?
    /// A step is waiting on the person.
    public let isWaiting: Bool
    /// An error in flight: the card says so, in amber.
    public let hasFreshError: Bool
    /// Whether a retry of that error is already running.
    public let isRetrying: Bool

    /// The tone edge pulses with the swell while the turn works, and knocks twice in amber while it
    /// waits; every other state holds still.
    public var edgePulses: Bool { motion.isAnimated }

    /// Whether this card breathes at all: reduced motion and a settled state stop it.
    public func isAnimated(reduceMotion: Bool) -> Bool { !reduceMotion && motion.isAnimated }

    public init(model: NeuralBrainModel) {
        let turn = model.turn
        let readings = model.verdicts
        let steps = turn.steps
        let at = NeuralAccount.liveIndex(in: steps)
        turnID = turn.id
        verdict = readings.verdict
        activeZone = model.state.zone ?? at.map { steps[$0].zone }
        motion = Self.motion(for: readings.verdict, state: model.state)
        stepCount = steps.count
        saidCount = steps.filter { NeuralReading.isNote($0) }.count
        startedAt = turn.startedAt
        lastStepAt = steps.last?.at
        isWaiting = readings.verdict == .needsYou
        var fresh = false
        var retrying = false
        for (index, reading) in readings.steps.enumerated() where reading.verdict == .tryingAgain {
            fresh = true
            if let at, at > index, steps[at].status == .running { retrying = true }
        }
        hasFreshError = fresh
        isRetrying = retrying
        flight = at.map { Self.flight(of: steps[$0], at: $0, steps: steps, readings: readings) }
        quote =
            steps.last { NeuralReading.isNote($0) && !$0.text.isEmpty }.map {
                Quote(
                    stepID: $0.id, speaker: NeuralAccount.speakerName(modelID: turn.modelID),
                    words: NeuralReadoutText.oneLine($0.text, limit: 240))
            }
    }

    private static func motion(for verdict: NeuralVerdict.Turn, state: NeuralState) -> NeuralMotion {
        switch verdict {
        case .needsYou: return .heartbeat
        case .stuck: return .still
        case .working: return state.motion.isAnimated ? state.motion : .breath
        case .done, .doneAfterRetries, .failed, .stopped, .didntAnswer: return .still
        }
    }

    private static func flight(
        of step: NeuralStep, at index: Int, steps: [NeuralStep], readings: NeuralVerdict.TurnReading
    ) -> Flight {
        let thinking = NeuralReading.isThought(step)
        let subject = NeuralReadoutBuilder.subject(of: step)
        let argument = thinking || NeuralReading.isNote(step) ? nil : subject.primary
        let lines = NeuralReading.isTool(step) ? NeuralReadoutBuilder.tail(of: step).lines : []
        return Flight(
            stepID: step.id, number: index + 1,
            title: NeuralHuman.presentTitle(at: index, in: steps),
            argument: argument.map { NeuralReadoutText.oneLine($0, limit: 160) }.flatMap {
                $0.isEmpty ? nil : $0
            },
            verdict: readings.steps[index].verdict, lastLine: lines.last, isThinking: thinking)
    }

    /// The counts in the card's order: steps, then what it said, then how long.
    static func countsWords(steps: Int, said: Int, elapsed: TimeInterval?) -> String {
        var parts = [NeuralNoticeLine.countText(tools: 0, steps: steps)]
        if said > 0 { parts.append(Localized.text("%lld said", said)) }
        if let elapsed { parts.append(clock(elapsed)) }
        return parts.dropFirst().reduce(parts[0]) { Localized.text("%1$@ · %2$@", $0, $1) }
    }

    /// A running clock: "42s", "4m 05s", "1h 04m".
    public static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        let hours = whole / 3_600
        let minutes = whole % 3_600 / 60
        let rest = whole % 60
        func padded(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        if hours > 0 {
            return Localized.text("%@h", "\(hours)") + " " + Localized.text("%@m", padded(minutes))
        }
        if minutes > 0 {
            return Localized.text("%@m", "\(minutes)") + " " + Localized.text("%@s", padded(rest))
        }
        return Localized.text("%@s", "\(rest)")
    }

    /// How long nothing has arrived: since the client last saw anything, else since the last
    /// step's message.
    public func silentFor(now: Date, lastActivity: Date? = nil) -> TimeInterval {
        guard let since = lastActivity ?? lastStepAt else { return 0 }
        return max(0, now.timeIntervalSince(since))
    }

    /// The headline at `now`.
    public func reading(now: Date, lastActivity: Date? = nil) -> Reading {
        let silent = silentFor(now: now, lastActivity: lastActivity)
        let elapsed = startedAt.map { max(0, now.timeIntervalSince($0)) }
        let word: String
        let tone: NeuralTone
        let glyph: Glyph
        switch verdict {
        case .needsYou:
            (word, tone, glyph) = (NeuralReading.verdictWaiting, .attention, .pauseBars)
        case .stuck:
            (word, tone, glyph) = (
                Localized.text("Stuck for %@", NeuralReading.duration(silent)), .attention, .dashedClock
            )
        case .working where hasFreshError:
            (word, tone, glyph) = (
                isRetrying ? NeuralReading.verdictHitErrorTrying : NeuralReading.verdictHitError,
                .attention, .triangle
            )
        case .working, .done, .doneAfterRetries, .failed, .stopped, .didntAnswer:
            (word, tone, glyph) = (verdict.word, verdict.tone, .pulse)
        }
        return Reading(
            word: word, tone: tone, glyph: glyph,
            counts: Self.countsWords(steps: stepCount, said: saidCount, elapsed: elapsed),
            elapsed: elapsed, silentFor: silent, isSilent: silent >= Self.silenceThreshold)
    }

    /// Whether a note that arrived at `arrivedAt` (on the client's clock) still holds the line.
    public func holdsQuote(arrivedAt: Date, now: Date) -> Bool {
        quote != nil && now.timeIntervalSince(arrivedAt) < Self.quoteHold
    }

    /// The third line at `now`. `quoteArrivedAt` is when the client first saw the current note; a
    /// held note replaces the step for four seconds. `compact` drops the output, leaving the title
    /// and the argument; a silence stays, because it is the only evidence of a stuck line.
    public func line(
        now: Date, lastActivity: Date? = nil, quoteArrivedAt: Date? = nil, compact: Bool = false
    ) -> Line {
        if let quote, let arrived = quoteArrivedAt, holdsQuote(arrivedAt: arrived, now: now) {
            return Line(
                kind: .quote, title: quote.words, argument: nil, trailing: .none, quote: quote,
                isWaiting: isWaiting)
        }
        let silent = silentFor(now: now, lastActivity: lastActivity)
        let trailing: Trailing
        if silent >= Self.silenceThreshold, !isWaiting {
            trailing = .silence(Localized.text("silent for %@", NeuralReading.duration(silent)))
        } else if !compact, let line = flight?.lastLine {
            trailing = .output(text: line.text, tone: line.tone == .dim ? .quiet : .attention)
        } else {
            trailing = .none
        }
        return Line(
            kind: .step, title: flight?.title ?? NeuralReading.verdictWorking,
            argument: flight?.argument, trailing: trailing, quote: nil, isWaiting: isWaiting)
    }

    /// How lit the active zone is at the display clock: the shared breath for work, two beats
    /// and a rest for a wait, full for a state that holds still. Every live card on screen reads
    /// the same clock, so no two beat apart.
    public func swell(at clock: TimeInterval, reduceMotion: Bool = false) -> Double {
        motion.level(at: clock, reduceMotion: reduceMotion)
    }

    /// The tone edge's strength: it pulses with the swell while the turn works.
    public func edgeLevel(at clock: TimeInterval, reduceMotion: Bool = false) -> Double {
        edgePulses ? swell(at: clock, reduceMotion: reduceMotion) : 1
    }
}

extension NeuralReading {
    /// "Hit an error: trying again".
    public static var verdictHitErrorTrying: String {
        Localized.text("Hit an error: trying again")
    }
}

extension NeuralBrainModel {
    /// The live card of a turn still running; nil for a settled one.
    public var liveCard: NeuralLiveCard? {
        turn.outcome == .running ? NeuralLiveCard(model: self) : nil
    }

    /// Whether a running turn's card has anything that moves by itself, which is distinct from
    /// `needsClock` (the open stage): the client runs one shared tick for every visible live card
    /// and none for settled ones.
    public func needsLiveCardClock(reduceMotion: Bool = false) -> Bool {
        guard turn.outcome == .running, !reduceMotion else { return false }
        return liveCard?.motion.isAnimated ?? false
    }

    public var needsLiveCardClock: Bool { needsLiveCardClock(reduceMotion: false) }

    /// How often a live card is drawn: at the activity tempo while it breathes, never otherwise.
    public func liveCardTempo(reduceMotion: Bool = false) -> NeuralTempo {
        needsLiveCardClock(reduceMotion: reduceMotion) ? .activity : .stopped
    }

    public var liveCardTempo: NeuralTempo { liveCardTempo(reduceMotion: false) }
}
