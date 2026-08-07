import CodingAgentKit
import Foundation

/// The tempo everything that is not idle moves at, in one place so three clients breathe together.
///
/// A period and a floor are design, not implementation: a running turn swells slowly and never
/// goes dark, because a badge that reaches zero reads as a dropped frame rather than a heartbeat.
/// The numbers are shared so the same state moves at the same speed on a phone, a GTK desk and a
/// Mac — a list of live rows that pulse at three different rates reads as three different states.
public enum ActivityTuning {
    public static let breathPeriod: TimeInterval = 1.9
    public static let breathFloor: Double = 0.34
    public static let heartbeatPeriod: TimeInterval = 1.6
    public static let heartbeatFloor: Double = 0.42
    public static let sweepPeriod: TimeInterval = 1.05
    /// How much a breathing badge grows at the top of its swell. Small on purpose: scale is the
    /// second voice of the same fact, and a badge that visibly jumps steals the eye from the row.
    public static let lift: Double = 0.08
}

/// A repeating swell, evaluated from a clock rather than stepped from a frame count, so a badge
/// that misses frames stays in time instead of falling behind.
///
/// `beats` is how many times the swell peaks inside one period: one is breathing, two is a
/// heartbeat. Everything comes back inside `floor...1`, so a caller can hand it straight to an
/// opacity without clamping.
public struct ActivityPulse: Sendable, Equatable {
    public let period: TimeInterval
    public let floor: Double
    public let beats: Int

    public init(period: TimeInterval, floor: Double, beats: Int = 1) {
        self.period = max(0.05, period)
        self.floor = min(max(0, floor), 1)
        self.beats = max(1, beats)
    }

    public func phase(at time: TimeInterval) -> Double {
        let turns = time / period
        return turns - turns.rounded(.down)
    }

    public func intensity(at time: TimeInterval) -> Double {
        let p = phase(at: time)
        let swell = beats == 1 ? Self.breath(p) : Self.beat(p, count: beats)
        return floor + (1 - floor) * swell
    }

    /// One slow raised cosine: brightest at the top of the period, dimmest halfway through, and
    /// smooth across the seam — a swell that stepped at the wrap would tick.
    private static func breath(_ phase: Double) -> Double {
        0.5 + 0.5 * cos(2 * Double.pi * phase)
    }

    /// Two quick beats and then a rest, which is what attention sounds like. Each beat is a
    /// cosine bump that reaches zero at its own edges, so the gap between them is real silence
    /// rather than a shallower swell.
    private static func beat(_ phase: Double, count: Int) -> Double {
        let width = 0.09
        let spacing = 0.17
        var peak = 0.0
        for index in 0..<count {
            let centre = 0.08 + Double(index) * spacing
            let distance = abs(phase - centre) / width
            guard distance < 1 else { continue }
            peak = max(peak, 0.5 + 0.5 * cos(Double.pi * distance))
        }
        return peak
    }
}

/// How a state moves. The motion is part of the meaning: work breathes, a question that is waiting
/// on you knocks twice, something being turned over sweeps, and anything settled — failed, offline,
/// idle — holds perfectly still, because stillness is how a reader tells "stopped" from "slow".
public enum ActivityMotion: Sendable, Equatable {
    case still
    case breath(ActivityPulse)
    case heartbeat(ActivityPulse)
    case sweep(period: TimeInterval)

    public static let working = ActivityMotion.breath(
        ActivityPulse(period: ActivityTuning.breathPeriod, floor: ActivityTuning.breathFloor))
    public static let attention = ActivityMotion.heartbeat(
        ActivityPulse(
            period: ActivityTuning.heartbeatPeriod, floor: ActivityTuning.heartbeatFloor, beats: 2))
    public static let turning = ActivityMotion.sweep(period: ActivityTuning.sweepPeriod)

    public var isAnimated: Bool { self != .still }

    /// What the badge's ink is worth at this instant, in `0...1`. A sweep keeps full opacity — it
    /// says what it has to say by turning — and stillness is always fully lit.
    public func intensity(at time: TimeInterval) -> Double {
        switch self {
        case .still, .sweep: return 1
        case .breath(let pulse), .heartbeat(let pulse): return pulse.intensity(at: time)
        }
    }

    /// The swell expressed as size rather than light, for clients that can afford to scale a
    /// layer. Anchored at 1 so a still badge is exactly its own size and nothing reflows.
    public func scale(at time: TimeInterval) -> Double {
        guard case .breath(let pulse) = self else { return 1 }
        let swell = (pulse.intensity(at: time) - pulse.floor) / max(0.0001, 1 - pulse.floor)
        return 1 + ActivityTuning.lift * swell
    }

    /// Radians, for a client that can rotate. Only a sweep turns; everything else would spin a
    /// meaning it does not have.
    public func rotation(at time: TimeInterval) -> Double {
        guard case .sweep(let period) = self else { return 0 }
        let turns = time / max(0.05, period)
        return 2 * Double.pi * (turns - turns.rounded(.down))
    }

    /// The frame a text client draws this instant. A cycle of glyphs is how a terminal-shaped
    /// widget sweeps; every cycle in this file is one advance wide, so the label never re-measures.
    public func frame(at time: TimeInterval, of cycle: [String]) -> String? {
        guard !cycle.isEmpty, case .sweep(let period) = self else { return nil }
        let turns = time / max(0.05, period)
        let phase = turns - turns.rounded(.down)
        return cycle[min(cycle.count - 1, Int(phase * Double(cycle.count)))]
    }

    /// Motion is an amplifier of a fact, never the fact itself, so switching it off must lose
    /// nothing: the glyph, the word and the colour all still say what is happening.
    public func honoring(reduceMotion: Bool) -> ActivityMotion {
        reduceMotion ? .still : self
    }
}

/// The four things a non-idle state can mean, which is fewer than the states themselves: work in
/// flight, something waiting on the person, something that broke, and something merely noted.
/// Every client resolves these to its own palette slot, and no client invents a fifth.
public enum ActivityTone: String, Sendable, CaseIterable {
    case live
    case attention
    case danger
    case quiet

    /// The class the glyph column wears on the GTK client.
    public var glyphCSS: String {
        switch self {
        case .live: return "glyph-running"
        case .attention: return "glyph-needs"
        case .danger: return "glyph-error"
        case .quiet: return "glyph-pending"
        }
    }

    /// The class the status band wears on the GTK client.
    public var bandCSS: String {
        switch self {
        case .live: return "seg-live"
        case .attention: return "seg-warn"
        case .danger: return "seg-error"
        case .quiet: return "seg-dim"
        }
    }
}

/// One state's whole visual identity: the symbol an Apple client draws, the glyph a text client
/// draws, the frames it sweeps through if it sweeps, the class it wears, its meaning and its
/// motion. Authored once here so a running turn looks like a running turn on every desk.
public struct ActivityIcon: Sendable, Equatable {
    public let symbol: String
    public let glyph: String
    public let cycle: [String]
    public let tone: ActivityTone
    public let motion: ActivityMotion
    public let glyphCSS: String
    public let bandCSS: String

    public init(
        symbol: String, glyph: String, cycle: [String] = [], tone: ActivityTone,
        motion: ActivityMotion, glyphCSS: String? = nil, bandCSS: String? = nil
    ) {
        self.symbol = symbol
        self.glyph = glyph
        self.cycle = cycle
        self.tone = tone
        self.motion = motion
        self.glyphCSS = glyphCSS ?? tone.glyphCSS
        self.bandCSS = bandCSS ?? tone.bandCSS
    }

    /// The glyph to draw at this instant: a sweeping icon hands back its current frame, everything
    /// else its one still glyph.
    public func glyph(at time: TimeInterval, reduceMotion: Bool = false) -> String {
        guard !reduceMotion else { return glyph }
        return motion.frame(at: time, of: cycle) ?? glyph
    }

    /// Where a sweep is drawn rather than cycled: the ring a client paints for `.turning`.
    public static let sweepCycle = ["◐", "◓", "◑", "◒"]

    /// The mark a row wears while the work it names is still open — a tool call out on the
    /// machine, an agent still out on its errand. It turns rather than breathes: a row in a
    /// transcript is a record of something, and a record that pulsed would compete with the answer
    /// being written above it.
    public static let openWork = ActivityIcon(
        symbol: "circle.dotted", glyph: "◐", cycle: sweepCycle, tone: .live, motion: .turning)

    /// The mark of nothing happening. A row doing nothing still holds its column, so idle has a
    /// face here rather than each list inventing its own dot.
    public static let idle = ActivityIcon(symbol: "circle", glyph: "·", tone: .quiet, motion: .still)
}

/// The one-column marks written into prose — a goal met, an agent finished, a thing still being
/// worked at. Authored beside the icons so a ✓ inside a sentence is the ✓ the inbox row wears.
public enum StatusMark {
    public static let done = "✓"
    public static let failed = "✗"
    public static let pursued = "⦿"
    public static let idle = "·"
    public static let open = "◐"
}

extension ToolStatus {
    /// What the row's mark is doing. Only a running call has an activity: a finished one is a
    /// record, and a record that keeps moving reads as work that never ended.
    public var activityIcon: ActivityIcon? {
        self == .running ? .openWork : nil
    }
}

/// What a session that is not idle is doing, named once so no client has to guess from a boolean.
///
/// The list is deliberately longer than "busy": the difference between a turn that is thinking, a
/// turn whose tool is out on the machine, and a turn that stopped to ask you something is the
/// difference between waiting, watching and being needed — and a UI that renders all three as one
/// spinner has thrown away the only thing the reader wanted to know.
public enum ActivityKind: Sendable, Equatable {
    /// A turn is open and this device cannot see inside it — the answer a listing gives about
    /// another machine's conversation, and the only honest one until a stream is watching it.
    case working
    case thinking
    case writing
    case usingTool(name: String, kind: ToolCallSummary.Kind)
    case delegating(active: Int)
    case compacting
    case needsApproval
    case needsAnswer
    case queued(Int)
    case connecting
    case reconnecting
    case failed
    case offline

    /// One of each, for anything that has to prove it has an answer for every state — a client's
    /// stylesheet, a test, a screenshot of the whole vocabulary. Carries sample numbers where a
    /// state has one, because a count of zero is not a state anybody sees.
    public static let everyState: [ActivityKind] = [
        .working, .thinking, .writing, .usingTool(name: "Bash", kind: .shell),
        .delegating(active: 3), .compacting, .needsApproval, .needsAnswer, .queued(2),
        .connecting, .reconnecting, .failed, .offline,
    ]

    public var icon: ActivityIcon {
        switch self {
        case .working:
            return ActivityIcon(symbol: "circle.fill", glyph: "●", tone: .live, motion: .working)
        case .thinking:
            return ActivityIcon(symbol: "brain", glyph: "●", tone: .live, motion: .working)
        case .writing:
            return ActivityIcon(
                symbol: "text.alignleft", glyph: "▮", tone: .live, motion: .working)
        case .usingTool(_, let kind):
            return ActivityIcon(
                symbol: Self.symbol(forTool: kind), glyph: Self.glyph(forTool: kind), tone: .live,
                motion: .working)
        case .delegating:
            return ActivityIcon(symbol: "person.2", glyph: "▸", tone: .live, motion: .working)
        case .compacting:
            return ActivityIcon(
                symbol: "rectangle.compress.vertical", glyph: "◐", cycle: ActivityIcon.sweepCycle,
                tone: .attention, motion: .turning)
        case .needsApproval:
            return ActivityIcon(
                symbol: "hand.raised", glyph: "⏸", tone: .attention, motion: .attention)
        case .needsAnswer:
            return ActivityIcon(
                symbol: "questionmark.bubble", glyph: "?", tone: .attention, motion: .attention)
        case .queued:
            return ActivityIcon(symbol: "hourglass", glyph: "⋯", tone: .quiet, motion: .still)
        case .connecting:
            return ActivityIcon(
                symbol: "antenna.radiowaves.left.and.right", glyph: "◐",
                cycle: ActivityIcon.sweepCycle, tone: .quiet, motion: .turning)
        case .reconnecting:
            return ActivityIcon(
                symbol: "arrow.clockwise", glyph: "◐", cycle: ActivityIcon.sweepCycle,
                tone: .attention, motion: .turning)
        case .failed:
            return ActivityIcon(
                symbol: "exclamationmark.triangle", glyph: "✗", tone: .danger, motion: .still)
        case .offline:
            return ActivityIcon(
                symbol: "wifi.slash", glyph: "⚠", tone: .quiet, motion: .still,
                bandCSS: "seg-offline")
        }
    }

    /// The shortest true thing to write next to the icon. A tool says its own name, because
    /// "Bash" tells the reader more in four characters than "Working" does in seven.
    public var title: String {
        switch self {
        case .working: return Localized.text("Live")
        case .thinking: return Localized.text("Thinking")
        case .writing: return Localized.text("Writing")
        case .usingTool(let name, _): return name
        case .delegating(let active): return Localized.text("%@ agents", "\(active)")
        case .compacting: return Localized.text("Compacting")
        case .needsApproval: return Localized.text("Needs you")
        case .needsAnswer: return Localized.text("Needs an answer")
        case .queued(let count): return Localized.text("%@ queued", "\(count)")
        case .connecting: return Localized.text("Connecting")
        case .reconnecting: return Localized.text("Reconnecting")
        case .failed: return Localized.text("Failed")
        case .offline: return Localized.text("Offline")
        }
    }

    /// How a status band writes it. The band is a row of instruments rather than a sentence, so it
    /// speaks in lower case — except a tool, which keeps the name the machine actually ran. A
    /// fan-out says only "agents", because the band's own agents counter is the next fact along and
    /// two counts of the same number read as two different numbers at a glance.
    public var bandWord: String {
        switch self {
        case .working: return Localized.text("live")
        case .thinking: return Localized.text("thinking")
        case .writing: return Localized.text("writing")
        case .usingTool(let name, _): return name
        case .delegating: return Localized.text("agents")
        case .compacting: return Localized.text("compacting")
        case .needsApproval: return Localized.text("y / a / n")
        case .needsAnswer: return Localized.text("answer")
        case .queued(let count): return Localized.text("%@ queued", "\(count)")
        case .connecting: return Localized.text("connecting")
        case .reconnecting: return Localized.text("reconnecting")
        case .failed: return Localized.text("failed")
        case .offline: return Localized.text("offline")
        }
    }

    /// The sentence a screen reader says. Motion and colour are both invisible to it, so this
    /// carries the whole state in words — including who the turn is waiting on.
    public var spoken: String {
        switch self {
        case .working: return Localized.text("A turn is running")
        case .thinking: return Localized.text("Thinking")
        case .writing: return Localized.text("Writing the answer")
        case .usingTool(let name, _): return Localized.text("Running %@", name)
        case .delegating(let active): return Localized.text("%@ agents working", "\(active)")
        case .compacting: return Localized.text("Compacting the conversation")
        case .needsApproval: return Localized.text("Waiting for your approval")
        case .needsAnswer: return Localized.text("Waiting for your answer")
        case .queued(let count): return Localized.text("%@ messages queued", "\(count)")
        case .connecting: return Localized.text("Connecting")
        case .reconnecting: return Localized.text("Reconnecting")
        case .failed: return Localized.text("The last turn failed")
        case .offline: return Localized.text("The server is not answering")
        }
    }

    /// Whether a turn is actually open on the other machine. A failure and an unreachable server
    /// are states worth drawing, but nothing is running in either.
    public var isInFlight: Bool {
        switch self {
        case .working, .thinking, .writing, .usingTool, .delegating, .compacting, .needsApproval,
            .needsAnswer:
            return true
        case .queued, .connecting, .reconnecting, .failed, .offline:
            return false
        }
    }

    /// Whether the turn has stopped and is waiting on the person at this device — the one state
    /// the app exists to surface quickly.
    public var wantsYou: Bool {
        self == .needsApproval || self == .needsAnswer
    }

    /// What the agent reached out and touched, as a symbol. Apple clients draw it; the tone is
    /// deliberately not per-kind, because under a theme everything a tool does is one meaning.
    public static func symbol(forTool kind: ToolCallSummary.Kind) -> String {
        switch kind {
        case .shell: return "terminal"
        case .fileEdit, .fileWrite: return "pencil.line"
        case .fileRead: return "doc.text"
        case .fileSearch: return "magnifyingglass"
        case .webSearch, .webFetch: return "globe"
        case .taskTracking: return "checklist"
        case .subagent, .workflow: return "person.2"
        case .skill: return "wand.and.stars"
        case .question: return "questionmark.bubble"
        case .other: return "wrench.and.screwdriver"
        }
    }

    /// The slot a tool's colour comes from, named here so the meaning is decided once: everything
    /// the agent reached out and touched is `info`, a standing capability is `accent`, a question
    /// is `attention`, and a tool nobody classified stays muted rather than borrowing a meaning.
    public enum ToolTintSlot: Sendable, Equatable {
        case info
        case accent
        case attention
        case muted
    }

    public static func tintSlot(forTool kind: ToolCallSummary.Kind) -> ToolTintSlot {
        switch kind {
        case .shell, .fileEdit, .fileWrite, .fileRead, .fileSearch, .webSearch, .webFetch,
            .subagent, .workflow:
            return .info
        case .taskTracking, .skill: return .accent
        case .question: return .attention
        case .other: return .muted
        }
    }

    /// The same reading for a client that draws text: one column wide, so a band that swaps tools
    /// mid-turn never shifts the words beside it.
    public static func glyph(forTool kind: ToolCallSummary.Kind) -> String {
        switch kind {
        case .shell: return "❯"
        case .fileEdit, .fileWrite: return "✎"
        case .fileRead: return "▤"
        case .fileSearch: return "⌕"
        case .webSearch, .webFetch: return "⊕"
        case .taskTracking: return "☑"
        case .subagent, .workflow: return "▸"
        case .skill: return "✦"
        case .question: return "?"
        case .other: return "⚒"
        }
    }

    /// What the turn is doing right now, read from the conversation itself rather than from a
    /// boolean the caller kept. Order is the order a reader cares about: a turn that stopped to
    /// ask is the headline, then the tool that is out on the machine, then whether the answer has
    /// started arriving. Nil when nothing is running — a settled conversation has no activity, and
    /// saying "idle" in a badge is worse than saying nothing.
    public static func inFlight(in state: ConversationState) -> ActivityKind? {
        if state.compaction?.isRunning == true { return .compacting }
        if !state.pendingPermissions.isEmpty { return .needsApproval }
        if !state.pendingQuestions.isEmpty { return .needsAnswer }
        guard state.status == .running else { return nil }
        if let call = runningCall(in: state) {
            return .usingTool(name: call.name, kind: call.summary.kind)
        }
        if let last = state.messages.last, last.role == .assistant, last.completedAt == nil,
            case .text(let text)? = last.parts.last?.kind, !text.isEmpty
        {
            return .writing
        }
        return .thinking
    }

    /// The tool that is open at this moment, searched back only as far as the last thing the
    /// person said — a call still marked running from three turns ago is a stale record, not work.
    private static func runningCall(in state: ConversationState) -> ToolCall? {
        for message in state.messages.reversed() {
            for part in message.parts.reversed() {
                if case .tool(let call) = part.kind, call.status == .running { return call }
            }
            if message.role == .user { return nil }
        }
        return nil
    }
}
