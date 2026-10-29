import Foundation

/// How the wall looks and behaves on one device: read by all three walls under the same names,
/// stored per device and never synced.
public struct WallStyle: Codable, Sendable, Equatable {
    public enum Preset: String, Codable, Sendable, CaseIterable {
        case studio, nightDesk, showcase, custom
    }

    public enum Effects: String, Codable, Sendable, CaseIterable {
        case off, subtle, lively
    }

    public enum Field: String, Codable, Sendable, CaseIterable {
        case motes, currents, aurora, none
    }

    public enum Night: String, Codable, Sendable, CaseIterable {
        case off, scheduled, always
    }

    public enum KeepAwake: String, Codable, Sendable, CaseIterable {
        case whileCharging, always, never
    }

    public enum Approvals: String, Codable, Sendable, CaseIterable {
        case hold, openChat
    }

    /// Which kinds of event get a gesture.
    public struct Moves: Codable, Sendable, Equatable {
        public var steps: Bool
        public var agents: Bool
        public var endings: Bool
        public var asks: Bool
        public var failures: Bool
        public var retries: Bool
        public var compaction: Bool
        public var arrivals: Bool

        public init(
            steps: Bool = true, agents: Bool = true, endings: Bool = true, asks: Bool = true,
            failures: Bool = true, retries: Bool = true, compaction: Bool = true,
            arrivals: Bool = true
        ) {
            self.steps = steps
            self.agents = agents
            self.endings = endings
            self.asks = asks
            self.failures = failures
            self.retries = retries
            self.compaction = compaction
            self.arrivals = arrivals
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            steps = (try? values.decodeIfPresent(Bool.self, forKey: .steps)) ?? true
            agents = (try? values.decodeIfPresent(Bool.self, forKey: .agents)) ?? true
            endings = (try? values.decodeIfPresent(Bool.self, forKey: .endings)) ?? true
            asks = (try? values.decodeIfPresent(Bool.self, forKey: .asks)) ?? true
            failures = (try? values.decodeIfPresent(Bool.self, forKey: .failures)) ?? true
            retries = (try? values.decodeIfPresent(Bool.self, forKey: .retries)) ?? true
            compaction = (try? values.decodeIfPresent(Bool.self, forKey: .compaction)) ?? true
            arrivals = (try? values.decodeIfPresent(Bool.self, forKey: .arrivals)) ?? true
        }
    }

    public var preset: Preset
    public var effects: Effects
    public var field: Field
    public var light: Bool
    public var moves: Moves
    /// How long a calm wall waits before it dims; nil never dims.
    public var dimAfter: TimeInterval?
    public var night: Night
    public var keepAwake: KeepAwake
    public var still: Bool
    public var showsClock: Bool
    public var showsHour: Bool
    public var showsRails: Bool
    public var showsSquads: Bool
    public var approvals: Approvals

    public static let dimChoices: [TimeInterval?] = [300, 600, 1800, nil]

    public static let studio = WallStyle(
        preset: .studio, effects: .subtle, field: .motes, light: true, moves: Moves(),
        dimAfter: 600, night: .off, keepAwake: .whileCharging, still: false, showsClock: true,
        showsHour: true, showsRails: true, showsSquads: true, approvals: .hold)

    public static let nightDesk: WallStyle = {
        var style = studio
        style.preset = .nightDesk
        style.field = .none
        style.light = false
        style.moves = Moves(
            steps: false, agents: false, endings: true, asks: true, failures: true, retries: false,
            compaction: false, arrivals: false)
        style.dimAfter = 300
        style.night = .scheduled
        style.showsRails = false
        style.showsSquads = false
        return style
    }()

    public static let showcase: WallStyle = {
        var style = studio
        style.preset = .showcase
        style.effects = .lively
        style.field = .aurora
        style.dimAfter = nil
        return style
    }()

    public static func preset(_ preset: Preset) -> WallStyle {
        switch preset {
        case .studio, .custom: return studio
        case .nightDesk: return nightDesk
        case .showcase: return showcase
        }
    }

    public init(
        preset: Preset, effects: Effects, field: Field, light: Bool, moves: Moves,
        dimAfter: TimeInterval?, night: Night, keepAwake: KeepAwake, still: Bool, showsClock: Bool,
        showsHour: Bool, showsRails: Bool, showsSquads: Bool, approvals: Approvals
    ) {
        self.preset = preset
        self.effects = effects
        self.field = field
        self.light = light
        self.moves = moves
        self.dimAfter = dimAfter
        self.night = night
        self.keepAwake = keepAwake
        self.still = still
        self.showsClock = showsClock
        self.showsHour = showsHour
        self.showsRails = showsRails
        self.showsSquads = showsSquads
        self.approvals = approvals
    }

    enum CodingKeys: String, CodingKey {
        case preset, effects, field, light, moves, dimAfter, night, keepAwake, still
        case showsClock, showsHour, showsRails, showsSquads, approvals
    }

    public init(from decoder: Decoder) throws {
        let base = WallStyle.studio
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preset = Self.word(values, .preset, base.preset)
        effects = Self.word(values, .effects, base.effects)
        field = Self.word(values, .field, base.field)
        light = Self.flag(values, .light, base.light)
        moves = (try? values.decodeIfPresent(Moves.self, forKey: .moves)) ?? base.moves
        if (try? values.decodeNil(forKey: .dimAfter)) == true {
            dimAfter = nil
        } else {
            dimAfter = (try? values.decodeIfPresent(TimeInterval.self, forKey: .dimAfter)) ?? base.dimAfter
        }
        night = Self.word(values, .night, base.night)
        keepAwake = Self.word(values, .keepAwake, base.keepAwake)
        still = Self.flag(values, .still, base.still)
        showsClock = Self.flag(values, .showsClock, base.showsClock)
        showsHour = Self.flag(values, .showsHour, base.showsHour)
        showsRails = Self.flag(values, .showsRails, base.showsRails)
        showsSquads = Self.flag(values, .showsSquads, base.showsSquads)
        approvals = Self.word(values, .approvals, base.approvals)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(preset, forKey: .preset)
        try values.encode(effects, forKey: .effects)
        try values.encode(field, forKey: .field)
        try values.encode(light, forKey: .light)
        try values.encode(moves, forKey: .moves)
        try values.encode(dimAfter, forKey: .dimAfter)
        try values.encode(night, forKey: .night)
        try values.encode(keepAwake, forKey: .keepAwake)
        try values.encode(still, forKey: .still)
        try values.encode(showsClock, forKey: .showsClock)
        try values.encode(showsHour, forKey: .showsHour)
        try values.encode(showsRails, forKey: .showsRails)
        try values.encode(showsSquads, forKey: .showsSquads)
        try values.encode(approvals, forKey: .approvals)
    }

    /// An enum read from its raw text, or `fallback` when the key is missing or the word unknown.
    private static func word<Value: RawRepresentable>(
        _ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, _ fallback: Value
    ) -> Value where Value.RawValue == String {
        guard let raw = (try? values.decodeIfPresent(String.self, forKey: key)) ?? nil else { return fallback }
        return Value(rawValue: raw) ?? fallback
    }

    private static func flag(
        _ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, _ fallback: Bool
    ) -> Bool {
        (try? values.decodeIfPresent(Bool.self, forKey: key)) ?? fallback
    }

    /// How much the gestures are drawn at: 0 for off, 1 for subtle, 1.6 for lively.
    public var amplitude: Double {
        switch effects {
        case .off: return 0
        case .subtle: return 1
        case .lively: return 1.6
        }
    }

    /// Whether the person wants a gesture for this kind of event.
    public func moves(_ kind: WallEvent.Kind) -> Bool {
        switch kind {
        case .step: return moves.steps
        case .workerStarted, .workerEnded, .workerQuiet, .workerStuck: return moves.agents
        case .finished, .stopped: return moves.endings
        case .asked, .answered: return moves.asks
        case .failed: return moves.failures
        case .retried, .resumed, .quiet: return moves.retries
        case .compacted: return moves.compaction
        case .joined, .left, .away, .back: return moves.arrivals
        }
    }

    public func isNight(at date: Date, calendar: Calendar = .current) -> Bool {
        switch night {
        case .always: return true
        case .off: return false
        case .scheduled:
            let hour = calendar.component(.hour, from: date)
            return hour >= 22 || hour < 7
        }
    }

    /// The style after `change`; it becomes `.custom` unless the change chose a preset itself.
    public func with(_ change: (inout WallStyle) -> Void) -> WallStyle {
        var next = self
        change(&next)
        if next == self { return self }
        if next.preset == preset { next.preset = .custom }
        return next
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// The style a stored text holds; nothing or garbage is the Studio style.
    public static func decoded(_ text: String?) -> WallStyle {
        guard let text, let data = text.data(using: .utf8),
            let style = try? JSONDecoder().decode(WallStyle.self, from: data)
        else { return .studio }
        return style
    }
}
