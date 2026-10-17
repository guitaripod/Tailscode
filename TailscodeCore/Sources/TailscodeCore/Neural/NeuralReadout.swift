import CodingAgentKit
import Foundation

/// What the readout beside an open brain says, as plain values a client draws: the step under the
/// pointer read out in full, the turn's digest, the step that is happening now, a zone's steps, or
/// a replay's log. The readout is one component with several subjects; `mode(for:hover:)` picks
/// the subject and `make` reads it.
///
/// Every word comes from `NeuralReading` or the catalogue. There is no duration anywhere: a tool
/// call carries none, and nothing here infers one. The whole of an output and the strings of an
/// edit are never copied into these values; the first lines are, and `fullOutput(of:)` and
/// `fullDiff(of:)` read the rest from the step's own call when somebody asks to see it.
public struct NeuralReadout: Sendable, Equatable {
    /// What the panel is about.
    public enum Mode: Sendable, Equatable {
        /// A step the pointer rests on, the focus is on, or the person pinned.
        case step(String)
        /// The settled turn, nothing chosen.
        case digest
        /// The running turn, following the step that is happening.
        case now
        /// A zone's steps, after a zone name or chip was pressed.
        case zone(NeuralZone)
        /// The replay, driven by its playhead.
        case replay
        /// A running turn that stopped to ask the person something: the step that waits.
        case ask(String)
    }

    /// The content for the mode.
    public enum Body: Sendable, Equatable {
        case step(Step)
        case digest(Digest)
        case now(Now)
        case zone(ZoneList)
        case replay(Replay)
        case ask(Ask)
    }

    public enum ChipKind: Sendable, Hashable {
        case done
        case failed
        case running
        case waiting
        case stalled
        case stopped
        /// A failure a later step cleared.
        case retried
    }

    /// The status word of a step in its tone.
    public struct Chip: Sendable, Equatable {
        public let kind: ChipKind
        public let word: String
        public let tone: NeuralTone

        /// A chip sits on the canvas: the theme's corrected palette.
        public var toneSet: NeuralToneSet { NeuralToneSet.set(for: .chip) }
    }

    /// The row at the top of a step: the zone, the status, where the step stands in the turn.
    public struct Header: Sendable, Equatable {
        public let zone: NeuralZone
        public let label: String
        public let chip: Chip
        /// "18 of 29".
        public let counter: String
        public let number: Int
        public let total: Int
        public let isPinned: Bool
        /// A glyph the waiting node wears: a pause, a question mark.
        public let mark: Character?
    }

    public struct Subject: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case command
            case path
            case pattern
            case url
            case agent
            case thought
            case note
            case other
        }

        public let kind: Kind
        /// The tool's name, "Thinking" or "Said".
        public let title: String
        /// The thing you came to read, whole: the command with its line breaks, the path, the
        /// pattern, the address, the agent's task, the gist of a thought.
        public let primary: String
        /// A pattern's scope, a command's description, an agent's type, a skill's arguments.
        public let secondary: String?
        /// For a path, everything up to and including the last slash, which is dimmed.
        public let directory: String?
        /// For a path, the file name, which is emphasised.
        public let fileName: String?
        /// The lines `primary` has by its own breaks.
        public let lineCount: Int
        /// How many lines to show before "Show all".
        public let collapsedLines: Int
        /// What the keyboard's `c` and the Copy button put on the pasteboard, nil where there is
        /// nothing worth copying.
        public let copyText: String?

        public var hasMore: Bool { lineCount > collapsedLines }
    }

    /// The narration that came immediately before a call: the line that turns mechanics into
    /// intent.
    public struct Why: Sendable, Equatable {
        public let label: String
        /// Up to 240 characters, cut at a word boundary.
        public let text: String
        /// What was said, whole, which "Show more" expands in place.
        public let full: String
        public let isTruncated: Bool
        /// The thought or note it was read from.
        public let sourceStepID: String
    }

    public enum LineTone: Sendable, Equatable {
        /// The ordinary dim ink.
        case dim
        /// The output of a call that failed.
        case danger
        /// The line that says what went wrong, in full ink.
        case emphasis
    }

    public struct OutputLine: Sendable, Equatable {
        public let text: String
        public let tone: LineTone
    }

    /// A shell step's output, or the output of any call that has no better shape.
    public struct Output: Sendable, Equatable {
        /// The first lines: eight.
        public let lines: [OutputLine]
        /// How many lines the output has in all.
        public let total: Int
        /// "N more lines" where there are more than shown.
        public let moreLabel: String?

        public var hiddenCount: Int { max(0, total - lines.count) }
        /// More lies below: the readout fades the foot of the block by 16 points.
        public var fades: Bool { hiddenCount > 0 }
    }

    public enum DiffKind: Sendable, Equatable {
        case add
        case remove
        /// Reserved: the tally the app writes counts every line of both strings an edit carries,
        /// so a diff built from them has no unchanged line to show.
        case context
    }

    public struct DiffLine: Sendable, Equatable {
        public let kind: DiffKind
        public let text: String
    }

    public struct Edit: Sendable, Equatable {
        public let path: String
        public let directory: String
        public let fileName: String
        public let added: Int
        public let removed: Int
        /// "+5 \u{2212}2".
        public let tally: String?
        /// Up to 14 lines, the removed ones first.
        public let lines: [DiffLine]
        public let total: Int
        public let moreLabel: String?

        public var hiddenCount: Int { max(0, total - lines.count) }
    }

    public struct Read: Sendable, Equatable {
        public let path: String
        public let directory: String
        public let fileName: String
        /// The lines the call returned, where it said.
        public let lines: Int?
    }

    public struct Search: Sendable, Equatable {
        public let pattern: String
        public let scope: String?
        public let matches: [String]
        public let total: Int
        public let moreLabel: String?
    }

    public struct Subagent: Sendable, Equatable {
        public let summary: [String]
        public let total: Int
        /// The call also draws a card of its own, which the "Open agent" action reveals.
        public let canOpen: Bool
        public let openLabel: String
    }

    public struct Text: Sendable, Equatable {
        public let text: String
        public let lineCount: Int
    }

    public enum Result: Sendable, Equatable {
        case shell(Output)
        case edit(Edit)
        case read(Read)
        case search(Search)
        case subagent(Subagent)
        case text(Text)
    }

    public enum RelationKind: Sendable, Equatable {
        case sameFile
        case sameCommand
        case retriedAt
    }

    /// A chip that lights the steps it names on hover and pins one on press.
    public struct Relation: Sendable, Equatable {
        public let kind: RelationKind
        public let label: String
        public let stepIDs: [String]
        /// One-based, in the order of `stepIDs`.
        public let numbers: [Int]
    }

    /// The footer facts: where the step stands in the transcript. No duration.
    public struct Facts: Sendable, Equatable {
        /// "message 4", or "3 calls in one message".
        public let message: String
        /// The message's clock, "21:52:22".
        public let clock: String?
        /// "started 21:52:22".
        public let started: String?
        /// "turn began 21:52:02": an extra a client may drop, since the footer is short and the
        /// clock of the message already says when.
        public let turnBegan: String?
    }

    /// The sections of a step, top to bottom: the relations sit directly under the subject, above
    /// WHY, so "retried at 9" is never below the fold on the step it is for.
    public enum StepSection: Sendable, CaseIterable {
        case header
        case subject
        case relations
        case why
        case result
        case facts
    }

    public struct Step: Sendable, Equatable {
        public let stepID: String
        public let header: Header
        public let subject: Subject
        public let relations: [Relation]
        public let why: Why?
        public let result: Result?
        public let facts: Facts
        /// The steps a ganglion gathers, when the node is one; empty for any other.
        public let gathered: [String]
    }

    public struct ZoneBar: Sendable, Equatable {
        public let zone: NeuralZone
        public let label: String
        public let count: Int
        /// The length of the bar: the zone's count over the busiest zone's.
        public let fraction: Double
    }

    public struct Tick: Sendable, Equatable {
        public let index: Int
        public let stepID: String
        public let zone: NeuralZone
        public let status: NeuralStatus
        /// A failed step, taller and in danger on the strip.
        public let isFailure: Bool
        public let isRecovered: Bool
        /// The answer begins after this tick.
        public let answerFollows: Bool
    }

    public struct Changed: Sendable, Equatable {
        /// The first step that changed the file; the others are in `stepIDs`.
        public let stepID: String
        public let stepIDs: [String]
        public let path: String
        public let directory: String
        public let fileName: String
        /// The last directory after an ellipsis, dimmed: "\u{2026}/Chat/".
        public let shortDirectory: String
        public let added: Int
        public let removed: Int
        public let tally: String?
    }

    public struct Failure: Sendable, Equatable {
        public let stepID: String
        public let number: Int
        public let title: String
        public let firstLine: String
        /// The later step that ran the same command and passed.
        public let retriedAt: String?
        public let retriedNumber: Int?
        /// "retried at 11", or "never retried".
        public let label: String
    }

    /// The digest's sections, top to bottom: the zone bars with the timeline strip fused under them
    /// as one block, then Failures (the thing a person came to find), then Changed, then Answer.
    public enum DigestSection: Sendable, CaseIterable {
        case headline
        case barsAndTimeline
        case failures
        case changed
        case answer
    }

    public struct Digest: Sendable, Equatable {
        public let headline: String
        public let zoneBars: [ZoneBar]
        /// One per step, in order, fused under the bars.
        public let ticks: [Tick]
        /// Where the answer begins on the strip: the number of ticks, nil for a turn with none.
        public let answerBegins: Int?
        public let failures: [Failure]
        public let changed: [Changed]
        /// The final message's first line, when the client passed the text.
        public let answer: String?
    }

    /// The "So far" under Now: the headline and one row of the card's zone chips.
    public struct SoFar: Sendable, Equatable {
        public let headline: String
        public let chips: [NeuralBrainCard.ZoneChip]
    }

    /// What the running turn's output has printed lately.
    public struct Tail: Sendable, Equatable {
        public let lines: [OutputLine]
        public let total: Int
    }

    public struct Now: Sendable, Equatable {
        public let label: String
        public let tone: NeuralTone
        /// The step that is happening; nil before the first one.
        public let step: Step?
        /// The last eight lines the step's call printed.
        public let tail: Tail
        public let soFar: SoFar
    }

    public struct Ask: Sendable, Equatable {
        public let step: Step
        /// "Waiting for your approval", "Waiting for your answer".
        public let sentence: String
        /// "Go to approval", "Go to question": scrolls to the card that carries the real ask.
        public let actionLabel: String
        public let isApproval: Bool
        public let tone: NeuralTone
    }

    public struct ZoneRow: Sendable, Equatable {
        public let number: Int
        public let stepID: String
        public let title: String
        /// The command, path, pattern or words, on one line.
        public let argument: String
        public let status: NeuralStatus
        public let tone: NeuralTone
    }

    public struct ZoneList: Sendable, Equatable {
        public let zone: NeuralZone
        public let label: String
        public let rows: [ZoneRow]
    }

    public struct Replay: Sendable, Equatable {
        /// The step firing at the playhead.
        public let current: Step?
        /// The steps before it, newest first, capped at `replayLogLimit`.
        public let log: [ZoneRow]
        /// How many earlier steps the cap left out.
        public let hiddenBefore: Int
        public let fraction: Double
    }

    public let mode: Mode
    public let body: Body
    /// What a screen reader says when the panel changes: `NeuralReading.announcement` for a step.
    public let announcement: String

    /// The step the panel shows, if it shows one.
    public var step: Step? {
        switch body {
        case .step(let step): return step
        case .now(let now): return now.step
        case .ask(let ask): return ask.step
        case .replay(let replay): return replay.current
        case .digest, .zone: return nil
        }
    }

    public var digest: Digest? {
        if case .digest(let digest) = body { return digest }
        return nil
    }

    /// The step the leader line is drawn to: the one the panel shows, which in Now is the running
    /// node, and nothing for the digest or a zone list.
    public var leaderStepID: String? { step?.stepID }

    public static let outputShown = NeuralStageMetrics.outputLinesWide
    public static let diffShown = 14
    public static let tailShown = 8
    public static let whyLimit = 240
    public static let commandLines = 4
    public static let replayLogLimit = 120
    public static let matchesShown = 8
    public static let summaryShown = 6
    public static let argumentLimit = 120

    /// The subject the panel takes: a pinned step, then the step the pointer was entered on, then
    /// a replay, a dived zone, and last what the turn itself calls for, which is Now while it runs
    /// (the ask when a step waits on the person) and the digest once it settled. `hover` is the
    /// node `NeuralBrainModel.hoverIntent` resolved; a client that never drove the hover grace
    /// gets the model's own hovered node.
    public static func mode(for model: NeuralBrainModel, hover: String?) -> Mode {
        if let id = model.pinnedStep, model.step(id: id) != nil { return .step(id) }
        let followed = hover ?? (model.hoverGrace.isDriven ? nil : model.hovered)
        if let id = followed, model.step(id: id) != nil { return .step(id) }
        if model.isReplaying { return .replay }
        if let zone = model.divedZone { return .zone(zone) }
        if model.turn.outcome == .running {
            if let waiting = waitingStep(in: model.steps) { return .ask(waiting.id) }
            return .now
        }
        return .digest
    }

    /// The first step that is stopped on the person.
    static func waitingStep(in steps: [NeuralStep]) -> NeuralStep? {
        steps.first { $0.status == .waitingApproval || $0.status == .waitingAnswer }
    }

    /// Reads the panel's content for `subject`. A step the turn does not hold falls back to what
    /// the turn itself calls for. `clock` is the client's monotonic seconds, which a replay's
    /// playhead is read against; `answer` is the final message's text.
    public static func make(
        model: NeuralBrainModel, subject: Mode, now: Date = Date(), tz: TimeZone = .current,
        clock: Double = 0, answer: String? = nil, outputLines: Int = NeuralReadout.outputShown
    ) -> NeuralReadout {
        let builder = NeuralReadoutBuilder(
            model: model, now: now, tz: tz, answer: answer, outputShown: max(outputLines, 1))
        let steps = model.steps
        switch subject {
        case .step(let id):
            guard let index = model.indexOf(id) else {
                return make(
                    model: model, subject: defaultMode(for: model), now: now, tz: tz, clock: clock,
                    answer: answer, outputLines: outputLines)
            }
            let step = builder.step(at: index)
            return NeuralReadout(
                mode: .step(id), body: .step(step),
                announcement: NeuralReading.announcement(for: steps[index], of: steps.count))
        case .digest:
            let digest = builder.digest()
            return NeuralReadout(
                mode: .digest, body: .digest(digest),
                announcement: NeuralReading.spoken(model.turn, now: now))
        case .now:
            let current = builder.now(tone: model.state.tone)
            let said = steps.last.map { NeuralReading.announcement(for: $0, of: steps.count) }
            return NeuralReadout(
                mode: .now, body: .now(current),
                announcement: said ?? NeuralReading.nowLabel)
        case .zone(let zone):
            return NeuralReadout(
                mode: .zone(zone), body: .zone(builder.zone(zone)),
                announcement: zone.label)
        case .replay:
            let replay = builder.replay(clock: clock)
            let said = replay.current.flatMap { current in
                model.indexOf(current.stepID).map {
                    NeuralReading.announcement(for: steps[$0], of: steps.count)
                }
            }
            return NeuralReadout(
                mode: .replay, body: .replay(replay), announcement: said ?? NeuralReading.replayLabel)
        case .ask(let id):
            guard let index = model.indexOf(id), let ask = builder.ask(at: index) else {
                return make(
                    model: model, subject: defaultMode(for: model), now: now, tz: tz, clock: clock,
                    answer: answer, outputLines: outputLines)
            }
            return NeuralReadout(
                mode: .ask(id), body: .ask(ask), announcement: ask.sentence)
        }
    }

    private static func defaultMode(for model: NeuralBrainModel) -> Mode {
        model.turn.outcome == .running ? .now : .digest
    }

    /// Every line the step's call printed, tone by tone: what "N more lines" expands to.
    public static func fullOutput(of step: NeuralStep) -> [OutputLine] {
        NeuralReadoutBuilder.outputLines(of: step, limit: Int.max)
    }

    /// Every line the edit's strings hold, the removed ones first.
    public static func fullDiff(of step: NeuralStep) -> [DiffLine] {
        NeuralReadoutBuilder.diffLines(of: step, limit: Int.max).lines
    }

    /// The command, path, pattern or address of a step, whole.
    public static func fullSubject(of step: NeuralStep) -> String {
        NeuralReadoutBuilder.subject(of: step).primary
    }
}

extension NeuralBrainModel {
    func indexOf(_ id: String) -> Int? { indexByID[id] }
}

extension NeuralReadout {
    /// A path split for the Changed list: the last directory dimmed after an ellipsis, then the file
    /// name emphasised, as "\u{2026}/Chat/" and "TranscriptRows.swift".
    public static func shortPath(_ path: String) -> (directory: String, fileName: String) {
        let parts = NeuralReadoutText.split(path: path)
        return (NeuralReadoutText.shortDirectory(parts.directory), parts.file)
    }
}
