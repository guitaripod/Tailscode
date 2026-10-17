import Foundation

/// What a collapsed turn says about itself, as data: the numbers, the zones it used, the sentence
/// that sums it up, and the head's lights. A card is recognisable by which parts of the head are
/// lit, so the lights are the same rule the small glyph draws with (radius `44 + 12 x min(n, 4)`
/// design units at opacity `.62 + .1 x min(n, 4)`), and a zone with no steps has no light at all.
///
/// Every word comes from `NeuralReading` and the catalogue; a client decides only how a chip, a
/// light or the edge is painted.
public struct NeuralBrainCard: Sendable, Equatable {
    /// The parts of a card a narrow row may drop. The picture, the headline, Replay and Rows stay.
    public enum Part: Sendable, Hashable, CaseIterable {
        case picture
        case headline
        case zoneStrip
        case digest
        case replay
        case rows
    }

    /// What the left edge of the card wears.
    public enum Edge: Sendable, Equatable {
        case settled
        case failed
        case waiting
        case stopped
        case running
    }

    /// One thing the headline says, in the tone of what it means; a nil tone is the ordinary ink.
    public struct Piece: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case count
            case duration
            case tally
            case failure
        }

        public let kind: Kind
        public let text: String
        public let tone: NeuralTone?
    }

    /// The count as the display number, then duration, tally and failure.
    public struct Headline: Sendable, Equatable {
        /// The tool count, or the step count for a turn that only thought or spoke.
        public let number: Int
        public let pieces: [Piece]

        public var count: String { pieces.first?.text ?? "" }
        public func piece(_ kind: Piece.Kind) -> Piece? { pieces.first { $0.kind == kind } }
    }

    /// A zone the turn used. `tone` is `.zone` unless the zone holds a failure nobody recovered
    /// or a step waiting on the person.
    public struct ZoneChip: Sendable, Equatable {
        public let zone: NeuralZone
        public let label: String
        public let count: Int
        public let tone: NeuralNodeTone
    }

    /// A soft light centred on a zone's well.
    public struct Light: Sendable, Equatable {
        public let zone: NeuralZone
        public let center: NeuralPoint
        public let radius: Double
        public let strength: Double
        public let count: Int
        /// The ring on a zone with a failure nobody recovered.
        public let failureRing: NeuralGlyph.Ring?

        /// The strength with the pointer on the card: 15 percent more, never past full.
        public func strength(hovered: Bool) -> Double {
            hovered ? min(1, strength * NeuralBrainCard.hoverLift) : strength
        }
    }

    /// The lights rise by this much while the pointer is on the card.
    public static let hoverLift = 1.15

    public let turnID: String
    public let headline: Headline
    public let chips: [ZoneChip]
    /// One clause per thing the work did: "Ran 18 commands", "Read 3 files".
    public let digestClauses: [String]
    public let lights: [Light]
    /// The tone the eye wears: the state's, or `.identity` for a turn that ended well.
    public let eyeTone: NeuralTone
    public let edge: Edge
    /// What the sentence a screen reader says for the whole card.
    public let spoken: String

    /// The tone of the 3 pt edge: accent for a settled turn, danger for a failed one, attention
    /// for one waiting on the person, quiet for one that was stopped.
    public var edgeTone: NeuralTone {
        switch edge {
        case .settled, .running: return .live
        case .failed: return .danger
        case .waiting: return .attention
        case .stopped: return .quiet
        }
    }

    /// The zones that carry a failure ring.
    public var ringZones: [NeuralZone] { lights.filter { $0.failureRing != nil }.map(\.zone) }

    public var hasFailure: Bool { edge == .failed }

    /// The sentence in full: the clauses joined and closed.
    public var digest: String { digest(fitting: Int.max) }

    /// The sentence cut by whole clauses to fit `characters`, never mid-word. The first clause is
    /// always kept, because a line that says nothing is worse than one that overflows and is
    /// ellipsised by the client.
    public func digest(fitting characters: Int) -> String {
        guard !digestClauses.isEmpty else { return "" }
        var kept: [String] = [digestClauses[0]]
        while kept.count < digestClauses.count {
            let next = Self.sentence(kept + [digestClauses[kept.count]])
            guard next.count <= characters else { break }
            kept.append(digestClauses[kept.count])
        }
        return Self.sentence(kept)
    }

    /// Which parts a card shows at this row width: the zone strip goes first, below 460, then the
    /// digest, below 380; a part the card has nothing for is not shown at any width.
    public func fit(width: Double) -> Set<Part> {
        var parts: Set<Part> = [.picture, .headline, .replay, .rows]
        if width >= NeuralStageMetrics.cardZoneStripMinWidth, !chips.isEmpty { parts.insert(.zoneStrip) }
        if width >= NeuralStageMetrics.cardDigestMinWidth, !digestClauses.isEmpty {
            parts.insert(.digest)
        }
        return parts
    }

    public init(turn: NeuralTurn, glyph: NeuralGlyph, eyeTone: NeuralTone, now: Date = Date()) {
        let census = NeuralReading.Census(turn.steps)
        let line = NeuralReading.line(for: turn, now: now)
        turnID = turn.id
        headline = Self.makeHeadline(line, census: census, steps: turn.steps.count)
        chips = Self.makeChips(turn.steps)
        digestClauses = Self.makeClauses(census, steps: turn.steps.count)
        lights = glyph.dots.map { dot in
            Light(
                zone: dot.zone, center: dot.center, radius: dot.radius, strength: dot.opacity,
                count: dot.count, failureRing: dot.failureRing)
        }
        self.eyeTone = eyeTone
        edge = Self.makeEdge(turn, census: census)
        spoken = NeuralReading.spoken(turn, now: now)
    }

    private static func sentence(_ clauses: [String]) -> String {
        let joined = clauses.dropFirst().reduce(clauses.first ?? "") {
            Localized.text("%1$@, %2$@", $0, $1)
        }
        return Localized.text("%@.", capitalised(joined))
    }

    private static func capitalised(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func makeHeadline(
        _ line: NeuralReading.Line, census: NeuralReading.Census, steps: Int
    ) -> Headline {
        var pieces = [Piece(kind: .count, text: line.count, tone: nil)]
        if let duration = line.duration {
            pieces.append(Piece(kind: .duration, text: duration, tone: .quiet))
        }
        if let tally = line.tally {
            pieces.append(Piece(kind: .tally, text: tally, tone: .live))
        }
        if let failure = line.failure {
            pieces.append(
                Piece(kind: .failure, text: failure, tone: census.failed > 0 ? .danger : .attention))
        }
        return Headline(number: census.tools > 0 ? census.tools : steps, pieces: pieces)
    }

    private static func makeChips(_ steps: [NeuralStep]) -> [ZoneChip] {
        var counts = [Int](repeating: 0, count: NeuralZone.allCases.count)
        var failed = Set<NeuralZone>()
        var waiting = Set<NeuralZone>()
        for step in steps {
            counts[step.zone.rawValue] += 1
            switch step.status {
            case .failed where !step.recovered: failed.insert(step.zone)
            case .waitingApproval, .waitingAnswer, .stalled: waiting.insert(step.zone)
            default: break
            }
        }
        return NeuralZone.allCases.compactMap { zone in
            let count = counts[zone.rawValue]
            guard count > 0 else { return nil }
            let tone: NeuralNodeTone =
                failed.contains(zone) ? .danger : waiting.contains(zone) ? .attention : .zone
            return ZoneChip(zone: zone, label: zone.label, count: count, tone: tone)
        }
    }

    private static func makeClauses(_ census: NeuralReading.Census, steps: Int) -> [String] {
        NeuralNoticeLine.clauseParts(NeuralNoticeCounts(census, steps: steps))
    }

    private static func makeEdge(_ turn: NeuralTurn, census: NeuralReading.Census) -> Edge {
        let waiting = turn.steps.contains { step in
            switch step.status {
            case .waitingApproval, .waitingAnswer, .stalled: return true
            case .ok, .running, .failed, .stopped: return false
            }
        }
        if waiting { return .waiting }
        switch turn.outcome {
        case .running: return .running
        case .failed: return .failed
        case .stopped, .interrupted, .answerless: return .stopped
        case .settled: return census.failed > 0 ? .failed : .settled
        }
    }
}

extension NeuralBrainModel {
    /// The card this turn is drawn as when it is collapsed.
    public func brainCard(now: Date) -> NeuralBrainCard {
        NeuralBrainCard(turn: turn, glyph: glyph, eyeTone: state.tone, now: now)
    }

    /// The card as of now.
    public var brainCard: NeuralBrainCard { brainCard(now: Date()) }
}
