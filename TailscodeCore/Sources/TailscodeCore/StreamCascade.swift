import Foundation

/// How the pacer spends what it has.
///
/// Text does not leave a model the way it is read. It arrives in lumps — two hundred characters at
/// once, then nothing for four hundred milliseconds, then a single word — so a transcript that
/// paints each lump as it lands reads as a stutter. The answer is the one every media player
/// reached: hold a buffer, and play out of the buffer at a speed that changes slowly. The network
/// fills the buffer; the buffer feeds the eye; the two are never wired to each other directly.
public struct CadenceTuning: Sendable {
    /// How much text the hand tries to keep in front of it, in seconds. This is the whole budget
    /// the smoothing has to spend: the reveal trails what has arrived by about this much.
    public var buffer: Double
    /// How long a change of speed takes to take effect. Long on purpose — the point of a buffer is
    /// that the hand does not react to the network, and a rate that chases every arrival is the
    /// stutter with extra steps.
    public var response: Double
    /// The slowest the hand may write while it still has anything to say.
    public var minimumRate: Double
    /// The fastest it may write. Past this, a cascade stops reading as writing.
    public var maximumRate: Double
    /// The buffer may never be drained faster than this, whatever the rate says. It is what turns
    /// running out into decelerating: the reveal glides toward empty instead of hitting it, so a
    /// model that pauses to think looks like a hand pausing rather than a frame dropping.
    public var floorTime: Double
    /// Once the turn is over there is nothing left to buffer against, so the tail lands.
    public var sealedBuffer: Double
    public var sealedResponse: Double
    /// Past this much unshown text it is not a stream, it is a paste — history arriving, a tool
    /// dumping a wall of output, a reconnect replaying. Nobody wants to watch that type.
    public var flush: Int
    /// How long the reveal may owe the reader text without moving, and how long the renderer may be
    /// held behind a token that has not closed, before the row is handed over whole.
    ///
    /// Both halves of a paced row assume text keeps arriving, and a turn is full of moments where
    /// it stops: a part ends and the agent goes off to run something for four minutes, a frame
    /// clock stops being served, a socket half-dies while heartbeats keep it looking alive. Every
    /// one of those leaves a paragraph sitting mid-sentence with nothing coming to finish it, which
    /// is a worse lie than an unmatched asterisk or a paste. So the debt is timed: past this, the
    /// row is not being written any more, and the rest of it is owed to the reader now.
    public var patience: Double

    public init(
        buffer: Double = 0.42, response: Double = 0.55,
        minimumRate: Double = 26, maximumRate: Double = 380,
        floorTime: Double = 0.10,
        sealedBuffer: Double = 0.16, sealedResponse: Double = 0.22,
        flush: Int = 1600, patience: Double = 1.0
    ) {
        self.buffer = buffer
        self.response = response
        self.minimumRate = minimumRate
        self.maximumRate = maximumRate
        self.floorTime = floorTime
        self.sealedBuffer = sealedBuffer
        self.sealedResponse = sealedResponse
        self.flush = flush
        self.patience = patience
    }

    public static let standard = CadenceTuning()
}

/// The pacer: arrivals in, a monotone reveal out, at a speed that moves like a hand rather than
/// like a network.
public struct StreamCadence: Sendable {
    public private(set) var revealed: Int = 0
    public private(set) var available: Int = 0
    public private(set) var rate: Double = 0
    public private(set) var sealed: Bool = false
    private var carry: Double = 0
    private var clock: Double?
    private let tuning: CadenceTuning

    public init(tuning: CadenceTuning = .standard) {
        self.tuning = tuning
    }

    public var backlog: Int { max(0, available - revealed) }
    public var isSettled: Bool { revealed >= available }

    /// What the stream has produced so far. Text only grows during a turn, but a re-render can
    /// hand over a shorter string — a fence closing moves a segment's boundary — and the reveal
    /// clamps rather than pretending to have shown characters that no longer exist.
    public mutating func observe(available count: Int, sealed: Bool) {
        available = count
        self.sealed = sealed
        if revealed > count {
            revealed = count
            carry = 0
        }
    }

    /// Shows everything at once: the row was not written under our eyes, so there is nothing to
    /// animate. History, a chat switch, a reconnect.
    public mutating func adopt(_ count: Int) {
        available = count
        revealed = count
        carry = 0
        rate = 0
    }

    /// Moves the reveal to where it should be at `time`. Returns true when the visible prefix
    /// actually changed, so a caller can skip re-laying-out text on a frame that would paint the
    /// same glyphs.
    @discardableResult
    public mutating func advance(to time: Double) -> Bool {
        defer { clock = time }
        guard let previous = clock else { return false }
        let elapsed = min(max(time - previous, 0), 0.1)
        guard elapsed > 0 else { return false }
        guard backlog > 0 else {
            carry = 0
            return false
        }
        if backlog > tuning.flush {
            revealed = available
            carry = 0
            rate = 0
            return true
        }
        let want = Double(backlog) / (sealed ? tuning.sealedBuffer : tuning.buffer)
        let goal = min(max(want, tuning.minimumRate), tuning.maximumRate)
        let tau = sealed ? tuning.sealedResponse : tuning.response
        rate += (goal - rate) * (1 - exp(-elapsed / tau))
        let spendable = Double(backlog) / max(tuning.floorTime, 0.001)
        carry += min(rate, spendable) * elapsed
        let step = Int(carry)
        guard step > 0 else { return false }
        carry -= Double(step)
        let before = revealed
        revealed = min(available, revealed + step)
        return revealed != before
    }
}

/// How far the renderer is allowed to get ahead of the closing half of a markdown token.
///
/// Markdown is punctuation that disappears. Render `**bold` while its closer is still in flight
/// and the asterisks show for a few frames and are then swallowed — the sentence twitches as it is
/// written. So the *renderer* is held at the last position where nothing is half-open. The reveal
/// is not held: it keeps playing out of the buffer, and merely stops being topped up until the
/// token closes, which the buffer is there to absorb.
///
/// Parity is counted from the start of the text and only *honoured* within a window. Both halves
/// matter. Counting from the start is not an optimisation to skip: a scan that begins in the
/// middle assumes nothing is open, so the first closer it meets reads as an opener and every
/// marker after it is inverted. Honouring only recent markers is what keeps one unmatched asterisk
/// from stalling an entire answer — a marker that has gone this long without a partner is
/// arithmetic or a bullet, and showing it beats freezing the paragraph behind it.
public enum CascadeGate {
    public static let window = 168

    /// The largest cut at or below `index` that leaves no inline token open. `sealed` means the
    /// turn is over and nothing more is coming — a marker that never found its partner is literal
    /// after all, so the gate stops holding it back.
    public static func safeCut(_ characters: [Character], at index: Int, sealed: Bool = false)
        -> Int
    {
        scan(characters, count: characters.count, at: index, sealed: sealed)
    }

    /// The same gate asked of the text itself.
    ///
    /// The gate runs once per arrival, on the whole answer so far, and an answer arrives a
    /// thousand times. Turning that answer into `[Character]` to read it costs sixteen bytes a
    /// character every time — an answer's worth of garbage per token, which is what a heap that
    /// only ever grows is made of. The walk needs the current character, the one after it and the
    /// one before, and a string can give all three without being taken apart first.
    public static func safeCut(_ source: String, at index: Int, sealed: Bool = false) -> Int {
        scan(source, count: source.count, at: index, sealed: sealed)
    }

    /// A marker is a slot, not a string: seven of them exist, and naming one by building a
    /// `String` at every asterisk is an allocation for a fact the type system already holds.
    private enum Marker: Int {
        case backtick, star, underscore, doubleStar, doubleUnderscore, doubleTilde, bracket

        static let count = 7
    }

    private static func scan<C: Collection>(
        _ characters: C, count: Int, at index: Int, sealed: Bool
    ) -> Int where C.Element == Character {
        let limit = min(index, count)
        guard limit > 0, !sealed else { return max(0, limit) }
        var pending = [Int?](repeating: nil, count: Marker.count)

        func toggle(_ marker: Marker, at position: Int) {
            pending[marker.rawValue] = pending[marker.rawValue] == nil ? position : nil
        }

        var cursor = characters.startIndex
        var position = 0
        var previous: Character?
        while position < limit {
            let character = characters[cursor]
            let next: Character? =
                position + 1 < limit ? characters[characters.index(after: cursor)] : nil
            var step = 1
            switch character {
            case "`":
                toggle(.backtick, at: position)
            case "*", "_":
                let doubled = next == character
                if !doubled, character == "_",
                    previous?.isLetter == true || previous?.isNumber == true
                {
                    break
                }
                if !doubled, next == " " || next == nil { break }
                let marker: Marker
                switch (character, doubled) {
                case ("*", false): marker = .star
                case ("*", true): marker = .doubleStar
                case (_, false): marker = .underscore
                default: marker = .doubleUnderscore
                }
                toggle(marker, at: position)
                step = doubled ? 2 : 1
            case "~":
                guard next == "~" else { break }
                toggle(.doubleTilde, at: position)
                step = 2
            case "[":
                pending[Marker.bracket.rawValue] = position
            case ")":
                pending[Marker.bracket.rawValue] = nil
            default:
                break
            }
            for _ in 0..<step {
                previous = characters[cursor]
                cursor = characters.index(after: cursor)
                position += 1
                if position >= limit { break }
            }
        }
        var earliest: Int?
        for open in pending {
            guard let open, open >= limit - window else { continue }
            if earliest == nil || open < earliest! { earliest = open }
        }
        return earliest ?? limit
    }
}

/// One frame of the wave, at one character's distance behind the leading edge.
public struct CascadeSample: Sendable, Equatable {
    /// How hot this glyph still is: 1 at the edge, 0 once the wave has passed. Clients spend it as
    /// a blend from the settled text colour toward the theme's leading-edge colour.
    public let heat: Double
    /// The travelling specular band, independent of the reveal, so a turn that stalls on a tool
    /// still breathes instead of freezing mid-sentence.
    public let shimmer: Double
    /// Glyph entry: a character arrives faint and lands within a few positions, so the edge
    /// dissolves into the page rather than ending in a hard chop.
    public let alpha: Double

    public init(heat: Double, shimmer: Double, alpha: Double) {
        self.heat = heat
        self.shimmer = shimmer
        self.alpha = alpha
    }

    /// How far toward the leading-edge colour this glyph should be pulled, heat and shimmer
    /// resolved into the single number every client blends with. One effect, three toolkits: the
    /// arithmetic lives here so a phone and two desktops cannot drift apart on what it looks like.
    public var pull: Double { min(1, heat * 0.86 + shimmer * 0.55) }

    public static let settled = CascadeSample(heat: 0, shimmer: 0, alpha: 1)
}

/// The look of the reveal: a wave of the theme's own colour trailing the last written character,
/// with a specular band running back through it.
///
/// The wave is defined in characters behind the edge rather than in seconds since a glyph landed.
/// That is deliberate: the cadence already smooths speed, so distance is proportional to age, and
/// a distance-based wave needs no per-character timestamps, survives a re-render, and looks
/// identical at 60 and 120 Hz.
public enum StreamCascade {
    /// How many characters the colour wave covers.
    public static let span = 26
    /// How many characters a glyph takes to go from faint to solid. Short: a long fade is a
    /// paragraph with a blurry edge, which reads as bad rendering rather than as motion.
    public static let entry = 2.2
    /// How faint a glyph is allowed to be on arrival. Never zero — a character that appears from
    /// nothing pops, one that appears from a whisper is written.
    public static let entryFloor = 0.28
    /// The specular band's width, in characters.
    public static let shimmerWidth = 8.5
    /// How far back the band travels before it starts again.
    public static let shimmerReach = 78.0
    /// How long one pass of the band takes.
    public static let shimmerPeriod = 2.4
    /// How brightly the band burns at its centre.
    public static let shimmerPeak = 0.5

    /// The band's position within its pass, from a monotonic clock. Clients hand over their own
    /// frame time; the phase is the only thing that has to agree between them.
    public static func phase(at time: Double) -> Double {
        let cycle = time.truncatingRemainder(dividingBy: shimmerPeriod)
        return (cycle < 0 ? cycle + shimmerPeriod : cycle) / shimmerPeriod
    }

    public static func sample(distance: Int, phase: Double, span: Int = span) -> CascadeSample {
        guard distance >= 0 else { return .settled }
        let reach = max(1, span)
        let normalized = min(1, Double(distance) / Double(reach))
        let heat = pow(1 - normalized, 2.2)
        let centre = shimmerReach * phase
        let offset = (Double(distance) - centre) / shimmerWidth
        let band = exp(-0.5 * offset * offset)
        let fade = 1 - min(1, Double(distance) / shimmerReach)
        let shimmer = band * fade * fade * shimmerPeak
        let entered = min(1, pow((Double(distance) + 0.6) / entry, 0.8))
        return CascadeSample(
            heat: heat, shimmer: shimmer, alpha: entryFloor + (1 - entryFloor) * entered)
    }

    /// The leading edge's colour while ultracode is on: the shared rainbow, sampled by phase, so
    /// the special powers are legible in the writing and not only around the prompt box.
    public static func rainbow(at phase: Double) -> (red: Double, green: Double, blue: Double) {
        let stops = Ultracode.rainbowStops
        let span = Double(stops.count - 1)
        let position = min(max(phase, 0), 1) * span
        let index = min(stops.count - 2, Int(position))
        let mix = position - Double(index)
        let start = stops[index]
        let end = stops[index + 1]
        return (
            start.red + (end.red - start.red) * mix,
            start.green + (end.green - start.green) * mix,
            start.blue + (end.blue - start.blue) * mix
        )
    }

    /// A row's share of the entrance stagger. New rows do not all appear at once — a tool row, its
    /// picture and the prose after it arrive as a run — so they land in order, a beat apart, and
    /// the transcript grows in one direction instead of blinking.
    public static func entranceDelay(index: Int, of count: Int, step: Double = 0.045) -> Double {
        guard count > 1 else { return 0 }
        return min(0.34, Double(max(0, index)) * step)
    }

    /// Ease-out for entrances and for the empty-to-first-row handoff, shared so the whole product
    /// moves with one curve.
    public static func ease(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }
}

/// The single row the stream is writing into, paced and painted.
///
/// The reveal is counted in *rendered* characters, not source characters. That is the difference
/// between this and the obvious implementation: rendering a growing prefix of markdown re-parses
/// the paragraph on every frame, changes length unevenly as punctuation is eaten, and flashes the
/// markers of every token as it closes. Rendering the whole safe prefix once and revealing through
/// it costs one parse per arrival, moves at a genuinely constant rate, and can never show a
/// marker — the renderer has already eaten them all.
public struct LiveCascade: Sendable {
    /// A row first seen already this long was not written under our eyes: history, a chat switch,
    /// a reconnect replaying a finished answer. It is adopted whole rather than replayed.
    public static let adoptLimit = 260

    public private(set) var id: String?
    /// How many rendered characters are shown. Everything after them is laid out and drawn at zero
    /// alpha rather than cut off, which is the whole reason this reads as writing: the paragraph
    /// is measured once when it arrives and never again, so no glyph ever moves after it lands and
    /// no line ever re-wraps under the reader. A frame changes colours, never layout.
    public private(set) var revealed = 0
    /// How many rendered characters a client has *proved* are on screen.
    ///
    /// The reveal is arithmetic, and arithmetic paints nothing. Every client hands its live row's
    /// widget to the wave and stops diffing it, so a paint that quietly did not happen — the row is
    /// no longer the last one rendered, its widget was rebuilt between frames, the label is not
    /// where a row of that kind keeps its words — leaves the reader looking at a prefix while the
    /// pacer counts happily up to the end and reports nothing owed. So the debt is counted against
    /// what landed, never against what was computed: a reveal nobody can see is a reveal that never
    /// happened.
    public private(set) var landed = 0
    public private(set) var total = 0
    public private(set) var phase: Double = 0
    private var cadence: StreamCadence
    private let tuning: CadenceTuning
    private var gateCut: Int?
    private var gateSince: Double = 0
    private var gateGaveUp = false
    private var owedSince: Double?
    private var owedAt = -1

    public init(tuning: CadenceTuning = .standard) {
        self.tuning = tuning
        self.cadence = StreamCadence(tuning: tuning)
    }

    public var isActive: Bool { id != nil }
    public var isSettled: Bool { cadence.isSettled }
    public var rate: Double { cadence.rate }

    /// Whether the reader is still owed words: fewer characters are on screen than the row has, or
    /// the renderer is being held behind a markdown token that has not closed yet. The second half
    /// is the one a settled reveal hides — a row can have caught up with every character it was
    /// given and still be a sentence short, because the gate never handed the last clause over.
    ///
    /// Measured against `landed` rather than `revealed`, so the one failure a pacer cannot see —
    /// a frame that painted nothing — reads as the debt it is instead of as a finished row.
    public var owes: Bool { landed < total || (gateCut != nil && !gateGaveUp) }

    /// Whether the debt has gone unpaid long enough that nothing is going to pay it.
    ///
    /// Asked *at* a time rather than remembered from the last frame, because the failure this
    /// exists to catch is the frame never coming: a clock that stopped cannot notice that it
    /// stopped. A client that keeps its own slow second hand can ask this from there and know,
    /// without watching the reveal move, whether the row is still being written.
    public func stalled(at time: Double) -> Bool {
        guard owes, let owedSince else { return false }
        return time - owedSince >= tuning.patience
    }

    /// What the client should render: the markdown-safe prefix of the source. Held at the last
    /// position where no inline token is half-open, so the renderer never sees `**bold` without
    /// its closer and no answer ever flashes its punctuation.
    public static func renderable(_ source: String, sealed: Bool) -> String {
        guard !sealed else { return source }
        let count = source.count
        let cut = CascadeGate.safeCut(source, at: count)
        guard cut < count else { return source }
        return String(source.prefix(cut))
    }

    /// The same gate, asked by the row that is being written, which is the only one that can tell
    /// waiting from stopping.
    ///
    /// The gate holds the renderer at a half-open token because the closer is a few characters
    /// behind — a wait the buffer is there to absorb. But a part ends where it ends: the agent
    /// stops writing and goes off to run something, and a marker that was going to close never
    /// does. `CascadeGate`'s window can only forgive a marker once enough *further* text arrives to
    /// push it out, and no further text is coming, so the clause behind it would sit unwritten for
    /// the rest of the turn. So the hold is timed from the cut rather than counted in characters:
    /// a cut that has not moved for `patience` is not a token waiting for its partner, it is the
    /// end of what the agent had to say, and the rest of the row is handed over as it stands.
    ///
    /// Given up is remembered against the cut it was given up at, and that is not bookkeeping: a
    /// gate that forgot would re-hold the same marker on the very next arrival, and the tail of the
    /// paragraph would appear and disappear once a second for the rest of the turn. The marker has
    /// been judged literal; it stays judged until the cut moves somewhere else.
    public mutating func renderable(_ source: String, sealed: Bool, at time: Double) -> String {
        guard !sealed else {
            openGate()
            return source
        }
        let count = source.count
        let cut = CascadeGate.safeCut(source, at: count)
        guard cut < count else {
            openGate()
            return source
        }
        if gateCut != cut {
            gateCut = cut
            gateSince = time
            gateGaveUp = false
        }
        if !gateGaveUp, time - gateSince < tuning.patience {
            return String(source.prefix(cut))
        }
        gateGaveUp = true
        return source
    }

    private mutating func openGate() {
        gateCut = nil
        gateGaveUp = false
    }

    /// Points the wave at the row the stream is writing into, with that row's rendered text.
    /// Passing nil lets go of it.
    /// Points the wave at a row whose length the client has measured in the units its own painter
    /// indexes by.
    ///
    /// "How long is this text" has three answers and every client needs a different one: UIKit and
    /// AppKit slice an `NSAttributedString` by UTF-16 code unit, Pango walks UTF-8 by code point,
    /// and Swift's `String.count` is grapheme clusters — which is none of them. A single emoji is
    /// one cluster, two UTF-16 units and one code point, so a reveal counted in clusters and
    /// painted in UTF-16 saturates before the end of the paragraph and leaves the last characters
    /// painted at zero alpha for good, reporting a settled row all the while. The count belongs to
    /// whoever does the indexing.
    public mutating func focus(_ id: String?, length: Int, sealed: Bool, at time: Double) {
        focus(id, rendered: nil, length: length, sealed: sealed, at: time)
    }

    public mutating func focus(_ id: String?, rendered: String, sealed: Bool, at time: Double) {
        focus(id, rendered: rendered, length: rendered.count, sealed: sealed, at: time)
    }

    private mutating func focus(
        _ id: String?, rendered _: String?, length: Int, sealed: Bool, at time: Double
    ) {
        guard let id else {
            self.id = nil
            revealed = 0
            landed = 0
            total = 0
            cadence = StreamCadence(tuning: tuning)
            openGate()
            owedSince = nil
            owedAt = -1
            return
        }
        if id != self.id {
            self.id = id
            total = length
            cadence = StreamCadence(tuning: tuning)
            if total > Self.adoptLimit || sealed {
                cadence.adopt(total)
            } else {
                cadence.observe(available: total, sealed: sealed)
            }
            revealed = cadence.revealed
            landed = 0
            phase = StreamCascade.phase(at: time)
            markDebt(at: time)
            return
        }
        total = length
        cadence.observe(available: total, sealed: sealed)
        revealed = min(revealed, total)
        landed = min(landed, total)
        markDebt(at: time)
    }

    /// What the client just proved it put on screen, which is the only number the debt is timed
    /// against. A client that painted nothing says nothing, and the clock keeps running.
    public mutating func lands(_ shown: Int, at time: Double) {
        guard id != nil else { return }
        landed = min(max(shown, 0), total)
        markDebt(at: time)
    }

    /// When the reader was last paid. The clock restarts every time a character actually reaches
    /// the screen and every time the debt is cleared; it keeps running while the same characters
    /// stay owed, which is the only state that means nothing is writing this row any more.
    private mutating func markDebt(at time: Double) {
        guard owes else {
            owedSince = nil
            owedAt = -1
            return
        }
        if owedSince == nil || landed != owedAt {
            owedSince = time
            owedAt = landed
        }
    }

    /// Advances one frame. Returns true when the row needs repainting — either the reveal moved,
    /// or the band did.
    @discardableResult
    public mutating func advance(to time: Double) -> Bool {
        guard id != nil else { return false }
        let moved = cadence.advance(to: time)
        if moved { revealed = cadence.revealed }
        markDebt(at: time)
        let previous = phase
        phase = StreamCascade.phase(at: time)
        return moved || abs(phase - previous) > 0.002 || phase < previous
    }

    /// The wave over the rendered tail, measured back from the last visible glyph.
    public func sample(distance: Int) -> CascadeSample {
        StreamCascade.sample(distance: distance, phase: phase)
    }
}
