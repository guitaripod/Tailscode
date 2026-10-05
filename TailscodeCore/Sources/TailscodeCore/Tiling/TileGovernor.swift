import Foundation

/// How much the window is shedding to stay responsive, from calm to critical.
public enum ShedLevel: Int, Sendable, Comparable, Codable, CaseIterable {
    case calm = 0
    case busy = 1
    case loaded = 2
    case strained = 3
    case critical = 4

    public static func < (lhs: ShedLevel, rhs: ShedLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The recorder's and the log's spelling.
    public var code: String {
        switch self {
        case .calm: return "calm"
        case .busy: return "busy"
        case .loaded: return "loaded"
        case .strained: return "strained"
        case .critical: return "critical"
        }
    }

    /// At strained and above, safety outranks preference: pins, "keep all live" and animations
    /// are ignored, and the UI says why.
    public var overridesPreference: Bool { self >= .strained }

    func raised(by steps: Int) -> ShedLevel {
        ShedLevel(rawValue: min(ShedLevel.critical.rawValue, rawValue + steps)) ?? .critical
    }

    func lowered() -> ShedLevel {
        ShedLevel(rawValue: max(0, rawValue - 1)) ?? .calm
    }
}

/// How the cascade reveal behaves at a level.
public enum CascadeMode: Sendable, Equatable {
    /// The written-not-pasted reveal, in the focused pane only.
    case focusedOnly
    /// Text appears at arrival granularity everywhere.
    case instant
    /// No reveal machinery at all.
    case off
}

/// What a window may spend on motion at the current level.
public struct AnimationBudget: Sendable, Equatable {
    public var cascade: CascadeMode
    /// Whether activity faces breathe. Off at strained and above and under reduced motion; a
    /// settled face holds still either way.
    public var pulses: Bool
    /// The most frames per second any pane clock may run; 0 means no clocks at all.
    public var tickCap: Double
    /// How often a glance tile may refresh, in hertz; 0 means frozen, woken only by needs-you.
    public var glanceRate: Double

    public init(cascade: CascadeMode, pulses: Bool, tickCap: Double, glanceRate: Double) {
        self.cascade = cascade
        self.pulses = pulses
        self.tickCap = tickCap
        self.glanceRate = glanceRate
    }

    /// The glance rate as a drain slot's minimum interval; infinite when frozen.
    public var glanceInterval: TimeInterval {
        glanceRate > 0 ? 1 / glanceRate : .infinity
    }
}

/// How many panes may be full at once, as the person set it. `count` and `all` replace the
/// automatic budget below strained; at strained and above the level's cap of one wins.
public enum LiveBudget: Sendable, Equatable, Codable {
    case auto
    case count(Int)
    case all
}

/// What a pane is asking of the person, most urgent last.
public enum PaneAttention: Int, Sendable, Comparable, Codable {
    case quiet = 0
    case running = 1
    case failed = 2
    case needsYou = 3

    public static func < (lhs: PaneAttention, rhs: PaneAttention) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var isNews: Bool { self >= .failed }
}

/// Why the window is at the level it is, or why it moved.
public enum ShedReason: Sendable, Equatable {
    case loopBusy(Double)
    case stall(TimeInterval)
    case watchdog
    case hostMemory(HostPressure)
    case ownMemory(Double)
    case thermal(ThermalState)
    case lowPower
    case unclean
    case relaxed

    /// The recorder's spelling: `busy`, `stall 320ms`, `memory`, ….
    public var code: String {
        switch self {
        case .loopBusy: return "busy"
        case .stall(let seconds): return "stall \(Int((seconds * 1000).rounded()))ms"
        case .watchdog: return "watchdog"
        case .hostMemory: return "memory"
        case .ownMemory: return "own"
        case .thermal: return "warm"
        case .lowPower: return "lowpower"
        case .unclean: return "unclean"
        case .relaxed: return "relax"
        }
    }

    /// The word the live chip adds after the count: busy, memory or warm.
    public var chipWord: String {
        switch self {
        case .loopBusy, .stall, .watchdog, .relaxed, .unclean: return Localized.text("busy")
        case .hostMemory, .ownMemory: return Localized.text("memory")
        case .thermal: return Localized.text("warm")
        case .lowPower: return Localized.text("busy")
        }
    }

    var isFloor: Bool {
        switch self {
        case .hostMemory, .ownMemory, .thermal, .lowPower, .unclean: return true
        case .loopBusy, .stall, .watchdog, .relaxed: return false
        }
    }
}

/// One move of the level, for the recorder: `shed 1→2 busy`.
public struct ShedTransition: Sendable, Equatable {
    public var from: ShedLevel
    public var to: ShedLevel
    public var reason: ShedReason

    public var event: String { "shed \(from.rawValue)→\(to.rawValue) \(reason.code)" }
}

/// What the sensors said this tick.
public struct GovernorSample: Sendable, Equatable {
    /// The loop's 2 s busy average.
    public var loopBusy: Double
    /// The worst slice since the last sample.
    public var worstStall: TimeInterval
    public var host: HostPressure
    /// The app's memory as a share of its memory-high limit.
    public var ownMemory: Double?
    public var thermal: ThermalState
    public var lowPower: Bool
    public var reducedMotion: Bool
    /// The window is minimized or suspended: every chat parks.
    public var occluded: Bool
    /// The stall watchdog's hint: the loop just came back from a stall of 3 s or more.
    public var watchdog: Bool

    public init(
        loopBusy: Double = 0, worstStall: TimeInterval = 0, host: HostPressure = .nominal,
        ownMemory: Double? = nil, thermal: ThermalState = .nominal, lowPower: Bool = false,
        reducedMotion: Bool = false, occluded: Bool = false, watchdog: Bool = false
    ) {
        self.loopBusy = loopBusy
        self.worstStall = worstStall
        self.host = host
        self.ownMemory = ownMemory
        self.thermal = thermal
        self.lowPower = lowPower
        self.reducedMotion = reducedMotion
        self.occluded = occluded
        self.watchdog = watchdog
    }
}

/// One pane as the governor sees it.
public struct PaneFacts: Sendable, Equatable {
    public var id: PaneID
    public var kind: PaneKind
    public var focused: Bool
    /// False for hidden, zoomed-away and overflow panes.
    public var placed: Bool
    public var width: Double
    public var height: Double
    public var attention: PaneAttention
    /// When the person last focused, typed in or scrolled the pane, on the governor's clock.
    public var lastTouched: TimeInterval
    public var pinned: Bool

    public init(
        id: PaneID, kind: PaneKind, focused: Bool = false, placed: Bool = true,
        width: Double, height: Double, attention: PaneAttention = .quiet,
        lastTouched: TimeInterval = 0, pinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.focused = focused
        self.placed = placed
        self.width = width
        self.height = height
        self.attention = attention
        self.lastTouched = lastTouched
        self.pinned = pinned
    }
}

/// The size a chat pane needs to be full, and the margin it must clear to become full again so a
/// drag across the line does not flicker. The host connects it to `PaneSizing` (4.2).
public struct FullDensityRule: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var hysteresis: Double

    public init(width: Double = 280, height: Double = 200, hysteresis: Double = 16) {
        self.width = width
        self.height = height
        self.hysteresis = hysteresis
    }

    /// Whether a pane of this size may be full, given whether it could be last time.
    public func allowsFull(width: Double, height: Double, wasAllowed: Bool) -> Bool {
        let margin = wasAllowed ? 0 : hysteresis
        return width >= self.width + margin && height >= self.height + margin
    }
}

/// What the window should do now.
public struct GovernorDecision: Sendable, Equatable {
    public var level: ShedLevel
    public var densities: [PaneID: PaneDensity]
    public var animation: AnimationBudget
    /// Row windows for full peers. The focused pane is absent: it uses the person's preference.
    public var rowWindows: [PaneID: Int]
    /// What is holding the level where it is; empty when calm.
    public var reasons: [ShedReason]
    /// The move this evaluation made, if any.
    public var transition: ShedTransition?
    /// How many chat panes may be full, and how many are; with `chats` it is the `Live 2 of 5` chip.
    public var fullBudget: Int
    public var liveChats: Int
    public var chats: Int
    /// The person asked for more than the level allows, and the chip must say it was ignored.
    public var preferenceOverridden: Bool
}

/// Decides each pane's density and the window's shed level from what the sensors say.
///
/// A mutating value type on an injected clock, like `StreamCadence` and `ActivityWatch`: the host
/// samples its sensors, calls `evaluate`, and applies the decision; the governor keeps only the
/// timestamps it needs to tell sustained load from a blip and a relax from an oscillation.
public struct TileGovernor: Sendable {
    public struct Tuning: Sendable, Equatable {
        public var escalateBusy = 0.65
        public var escalateFor: TimeInterval = 3
        public var criticalBusy = 0.85
        public var criticalFor: TimeInterval = 1.5
        public var stallJump: TimeInterval = 0.25
        public var escalationGap: TimeInterval = 2
        public var relaxBusy = 0.30
        public var relaxFor: TimeInterval = 20
        public var relaxGap: TimeInterval = 15
        public var relaxCeiling: TimeInterval = 120
        public var oscillationWindow: TimeInterval = 120
        /// A run this long with no escalation forgets the doubled relax delay.
        public var relaxReset: TimeInterval = 600
        public var dwell: TimeInterval = 8
        public var touchedRecently: TimeInterval = 60
        public var ownMemoryLoaded = 0.70
        public var ownMemoryCritical = 0.90

        public init() {}
    }

    public let cores: Int
    public let tuning: Tuning
    public let rule: FullDensityRule

    private var dynamic: ShedLevel = .calm
    private var lastLevel: ShedLevel = .calm
    private var busySince: TimeInterval?
    private var criticalSince: TimeInterval?
    private var quietSince: TimeInterval?
    private var lastEscalation: TimeInterval = -.infinity
    private var lastRelax: TimeInterval = -.infinity
    private var escalations: [TimeInterval] = []
    private var relaxDelay: TimeInterval
    private var floorUntil: (level: ShedLevel, until: TimeInterval)?
    private var fullSince: [PaneID: TimeInterval] = [:]
    private var allowedBySize: [PaneID: Bool] = [:]
    private var lastBudget: Int?

    public init(
        cores: Int = ProcessInfo.processInfo.activeProcessorCount,
        rule: FullDensityRule = FullDensityRule(),
        tuning: Tuning = Tuning()
    ) {
        self.cores = cores
        self.rule = rule
        self.tuning = tuning
        self.relaxDelay = tuning.relaxFor
    }

    /// `clamp(cores / 4, 2, 4)`.
    public var base: Int { min(4, max(2, cores / 4)) }

    public var level: ShedLevel { lastLevel }

    /// The relax delay in force, which doubles after two escalations inside two minutes.
    public var currentRelaxDelay: TimeInterval { relaxDelay }

    /// Holds the level at or above `level` until `until`: the safe restore's floor after two
    /// unclean exits in a row.
    public mutating func hold(atLeast level: ShedLevel, until: TimeInterval) {
        floorUntil = (level, until)
    }

    /// The full budget at a level for a setting.
    public func fullBudget(level: ShedLevel, setting: LiveBudget) -> Int {
        if level.overridesPreference { return 1 }
        switch setting {
        case .count(let count): return max(1, count)
        case .all: return Int.max
        case .auto:
            switch level {
            case .calm: return base
            case .busy: return max(2, base - 1)
            case .loaded, .strained, .critical: return 1
            }
        }
    }

    /// The motion allowed at a level, before reduced motion.
    public static func animation(level: ShedLevel, reducedMotion: Bool) -> AnimationBudget {
        var budget: AnimationBudget
        switch level {
        case .calm: budget = AnimationBudget(cascade: .focusedOnly, pulses: true, tickCap: 30, glanceRate: 4)
        case .busy: budget = AnimationBudget(cascade: .focusedOnly, pulses: true, tickCap: 30, glanceRate: 2)
        case .loaded: budget = AnimationBudget(cascade: .instant, pulses: true, tickCap: 20, glanceRate: 1)
        case .strained: budget = AnimationBudget(cascade: .off, pulses: false, tickCap: 10, glanceRate: 0.5)
        case .critical: budget = AnimationBudget(cascade: .off, pulses: false, tickCap: 0, glanceRate: 0)
        }
        if reducedMotion {
            budget.pulses = false
            if budget.cascade == .focusedOnly { budget.cascade = .instant }
        }
        return budget
    }

    /// The peer row window at a level.
    public static func peerRowWindow(level: ShedLevel) -> Int {
        switch level {
        case .calm: return 150
        case .busy: return 100
        case .loaded: return 60
        case .strained, .critical: return 0
        }
    }

    public mutating func evaluate(
        now: TimeInterval, sample: GovernorSample, panes: [PaneFacts], setting: LiveBudget
    ) -> GovernorDecision {
        let dynamicMove = step(now: now, sample: sample)
        let floors = floorReasons(now: now, sample: sample)
        let floorLevel = floors.map(\.1).max() ?? .calm
        let level = max(dynamic, floorLevel)
        var transition: ShedTransition?
        if level != lastLevel {
            let floorReason = floors.first { $0.1 == floorLevel }?.0
            let reason: ShedReason
            if level < lastLevel {
                reason = .relaxed
            } else if floorLevel > dynamic, let floorReason {
                reason = floorReason
            } else {
                reason = dynamicMove ?? dynamicHolding(sample)
            }
            transition = ShedTransition(from: lastLevel, to: level, reason: reason)
            lastLevel = level
        }
        var reasons = floors.filter { $0.1 >= .busy }.map(\.0)
        if dynamic > .calm { reasons.insert(dynamicHolding(sample), at: 0) }
        if level == .calm { reasons = [] }
        let budget = fullBudget(level: level, setting: setting)
        let assignment = assign(
            now: now, panes: panes, level: level, budget: budget, occluded: sample.occluded)
        lastBudget = budget
        var rowWindows: [PaneID: Int] = [:]
        for pane in panes where !pane.focused && assignment[pane.id] == .full && pane.kind == .chat {
            rowWindows[pane.id] = Self.peerRowWindow(level: level)
        }
        let chats = panes.filter { $0.kind == .chat }
        let wantsMore =
            setting != .auto || panes.contains { $0.pinned && $0.kind == .chat && !$0.focused }
        return GovernorDecision(
            level: level, densities: assignment,
            animation: Self.animation(level: level, reducedMotion: sample.reducedMotion),
            rowWindows: rowWindows, reasons: reasons, transition: transition,
            fullBudget: budget,
            liveChats: chats.filter { assignment[$0.id] == .full }.count,
            chats: chats.count,
            preferenceOverridden: level.overridesPreference && wantsMore)
    }

    private func dynamicHolding(_ sample: GovernorSample) -> ShedReason {
        if sample.watchdog { return .watchdog }
        if sample.worstStall >= tuning.stallJump { return .stall(sample.worstStall) }
        return .loopBusy(sample.loopBusy)
    }

    /// Moves the dynamic level by sustained load, returning why it rose this tick.
    private mutating func step(now: TimeInterval, sample: GovernorSample) -> ShedReason? {
        let busy = sample.loopBusy
        busySince = busy >= tuning.escalateBusy ? (busySince ?? now) : nil
        criticalSince = busy >= tuning.criticalBusy ? (criticalSince ?? now) : nil
        quietSince = busy < tuning.relaxBusy ? (quietSince ?? now) : nil
        if now - lastEscalation >= tuning.relaxReset { relaxDelay = tuning.relaxFor }

        if sample.watchdog, dynamic < .critical {
            escalate(to: .critical, now: now)
            return .watchdog
        }
        if now - lastEscalation >= tuning.escalationGap, dynamic < .critical {
            var steps = 0
            var reason: ShedReason?
            if sample.worstStall >= tuning.stallJump {
                steps = 2
                reason = .stall(sample.worstStall)
            } else if let since = criticalSince, now - since >= tuning.criticalFor {
                steps = 2
                reason = .loopBusy(busy)
            } else if let since = busySince, now - since >= tuning.escalateFor {
                steps = 1
                reason = .loopBusy(busy)
            }
            if steps > 0 {
                escalate(to: dynamic.raised(by: steps), now: now)
                return reason
            }
        }
        if dynamic > .calm, let since = quietSince, now - since >= relaxDelay,
            now - lastRelax >= tuning.relaxGap
        {
            dynamic = dynamic.lowered()
            lastRelax = now
        }
        return nil
    }

    private mutating func escalate(to level: ShedLevel, now: TimeInterval) {
        dynamic = level
        lastEscalation = now
        busySince = nil
        criticalSince = nil
        quietSince = nil
        escalations = escalations.filter { now - $0 < tuning.oscillationWindow } + [now]
        if escalations.count >= 2 {
            relaxDelay = min(tuning.relaxCeiling, relaxDelay * 2)
        }
    }

    private mutating func floorReasons(
        now: TimeInterval, sample: GovernorSample
    ) -> [(ShedReason, ShedLevel)] {
        var floors: [(ShedReason, ShedLevel)] = []
        switch sample.host {
        case .critical: floors.append((.hostMemory(.critical), .critical))
        case .strained: floors.append((.hostMemory(.strained), .loaded))
        case .nominal: break
        }
        if let own = sample.ownMemory {
            if own >= tuning.ownMemoryCritical {
                floors.append((.ownMemory(own), .critical))
            } else if own >= tuning.ownMemoryLoaded {
                floors.append((.ownMemory(own), .loaded))
            }
        }
        switch sample.thermal {
        case .critical: floors.append((.thermal(.critical), .critical))
        case .serious: floors.append((.thermal(.serious), .loaded))
        case .nominal, .fair: break
        }
        if sample.lowPower { floors.append((.lowPower, .busy)) }
        if let held = floorUntil {
            if now < held.until {
                floors.append((.unclean, held.level))
            } else {
                floorUntil = nil
            }
        }
        return floors
    }

    /// The density order of 5.4: parked when not placed or occluded, glance when too small, the
    /// focused pane full, the remaining budget to pinned (below strained), dwelling, needs-you or
    /// failed, recently touched running, then most recent; every other chat glance.
    private mutating func assign(
        now: TimeInterval, panes: [PaneFacts], level: ShedLevel, budget: Int, occluded: Bool
    ) -> [PaneID: PaneDensity] {
        var densities: [PaneID: PaneDensity] = [:]
        var eligible: [PaneFacts] = []
        let present = Set(panes.map(\.id))
        allowedBySize = allowedBySize.filter { present.contains($0.key) }
        let budgetDropped = lastBudget.map { budget < $0 } ?? false
        let videos = panes.filter { $0.kind == .video && $0.placed && !occluded }

        for pane in panes {
            let allowed = rule.allowsFull(
                width: pane.width, height: pane.height,
                wasAllowed: allowedBySize[pane.id] ?? true)
            if pane.placed { allowedBySize[pane.id] = allowed }
            guard pane.placed, !(occluded && (pane.kind == .chat || pane.kind == .video)) else {
                densities[pane.id] = .parked
                continue
            }
            switch pane.kind {
            case .empty, .web, .draw:
                densities[pane.id] = .full
            case .video:
                densities[pane.id] = pane.focused || videos.count == 1 ? .full : .parked
            case .chat:
                if !allowed {
                    densities[pane.id] = .glance
                } else if pane.focused {
                    densities[pane.id] = .full
                } else {
                    densities[pane.id] = .glance
                    eligible.append(pane)
                }
            }
        }

        let focusedFull = panes.contains { $0.focused && $0.kind == .chat && densities[$0.id] == .full }
        var remaining = budget == Int.max ? Int.max : max(0, budget - (focusedFull ? 1 : 0))
        let honourPins = !level.overridesPreference
        let ranked = eligible.sorted { lhs, rhs in
            let left = rank(lhs, now: now, honourPins: honourPins, budgetDropped: budgetDropped)
            let right = rank(rhs, now: now, honourPins: honourPins, budgetDropped: budgetDropped)
            if left != right { return left < right }
            if lhs.lastTouched != rhs.lastTouched { return lhs.lastTouched > rhs.lastTouched }
            return lhs.id.raw < rhs.id.raw
        }
        for pane in ranked where remaining > 0 {
            densities[pane.id] = .full
            if remaining != Int.max { remaining -= 1 }
        }

        var since: [PaneID: TimeInterval] = [:]
        for pane in panes where densities[pane.id] == .full {
            since[pane.id] = fullSince[pane.id] ?? now
        }
        fullSince = since
        return densities
    }

    /// Lower ranks are promoted first.
    private func rank(
        _ pane: PaneFacts, now: TimeInterval, honourPins: Bool, budgetDropped: Bool
    ) -> Int {
        if honourPins, pane.pinned { return 0 }
        if !budgetDropped, let since = fullSince[pane.id], now - since < tuning.dwell { return 1 }
        if pane.attention.isNews { return 2 }
        if pane.attention == .running, now - pane.lastTouched <= tuning.touchedRecently { return 3 }
        return 4
    }
}
