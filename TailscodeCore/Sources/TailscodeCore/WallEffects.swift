import Foundation

/// One timed gesture on the wall, hung on a tile (and a worker), drawn by the client under the words.
public struct WallEffect: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case spark, thread, dissolve, exhale, groundRipple, knock, fracture, pulse, approved, drain
        case gather, scatter, fade
    }

    /// The colour role an effect is drawn in; `tile` is the tile's own current state colour.
    public enum Ink: Sendable {
        case working, thinking, needs, overdue, failed, finished, quiet, dim, tile
    }

    public let kind: Kind
    public let tile: String
    public let worker: String?
    /// Seconds on the client's clock.
    public let start: TimeInterval
    public let duration: TimeInterval
    public let ink: Ink
    public let amplitude: Double
    public let seed: UInt32
    /// For a drain, the context share it falls from and to.
    public let from: Double?
    public let to: Double?
    /// An ask's or a failure's effect, which the budget never drops.
    public let isProtected: Bool

    public init(
        kind: Kind, tile: String, worker: String? = nil, start: TimeInterval, duration: TimeInterval,
        ink: Ink, amplitude: Double = 1, seed: UInt32 = 0, from: Double? = nil, to: Double? = nil,
        isProtected: Bool? = nil
    ) {
        self.kind = kind
        self.tile = tile
        self.worker = worker
        self.start = start
        self.duration = duration
        self.ink = ink
        self.amplitude = amplitude
        self.seed = seed
        self.from = from
        self.to = to
        self.isProtected =
            isProtected ?? (kind == .knock || kind == .fracture || (kind == .groundRipple && ink == .failed))
    }

    public var end: TimeInterval { start + duration }

    public func isStarted(at t: TimeInterval) -> Bool { t >= start }

    public func isEnded(at t: TimeInterval) -> Bool { t >= end }

    /// How far through the effect `t` is, `0...1`; 0 before it starts.
    public func progress(at t: TimeInterval) -> Double {
        guard t > start else { return 0 }
        guard duration > 0 else { return 1 }
        return min(1, (t - start) / duration)
    }
}

/// The effects playing now, kept within the budget: at most 40 live and 3 on a tile, and an ask's or a
/// failure's is never the one dropped.
public struct WallEffectQueue: Sendable {
    public static let maxLive = 40
    public static let maxPerTile = 3
    static let sparkGap: TimeInterval = 0.5
    static let stillDuration: TimeInterval = 0.8
    static let secondKnock: TimeInterval = 0.34

    public private(set) var live: [WallEffect] = []

    public init() {}

    public var isEmpty: Bool { live.isEmpty }

    public func isActive(at t: TimeInterval) -> Bool {
        live.contains { !$0.isEnded(at: t) }
    }

    public mutating func prune(at t: TimeInterval) {
        live.removeAll { $0.isEnded(at: t) }
    }

    public mutating func add(
        _ events: [WallEvent], at t: TimeInterval, style: WallStyle,
        contexts: [String: (from: Double, to: Double)] = [:]
    ) {
        for event in events {
            if event.kind == .step, sparked(event.tile, at: t) { continue }
            for effect in Self.effects(for: event, at: t, style: style, contexts: contexts) {
                add(effect)
            }
        }
    }

    public mutating func add(_ effect: WallEffect) {
        var next = live
        let onTile = { (list: [WallEffect]) in list.filter { $0.tile == effect.tile }.count }
        while onTile(next) >= Self.maxPerTile {
            guard let victim = next.firstIndex(where: { $0.tile == effect.tile && !$0.isProtected }) else {
                if effect.isProtected { break }
                return
            }
            next.remove(at: victim)
        }
        while next.count >= Self.maxLive {
            guard let victim = next.firstIndex(where: { !$0.isProtected }) else {
                if effect.isProtected { break }
                return
            }
            next.remove(at: victim)
        }
        next.append(effect)
        live = next
    }

    private func sparked(_ tile: String, at t: TimeInterval) -> Bool {
        live.contains { $0.kind == .spark && $0.tile == tile && t - $0.start < Self.sparkGap }
    }

    private struct Beat {
        let kind: WallEffect.Kind
        let duration: TimeInterval
        let ink: WallEffect.Ink
        var delay: TimeInterval = 0
        var isProtected = false
    }

    private static let vanishing: Set<WallEffect.Kind> = [.spark, .thread, .dissolve, .gather, .scatter]

    static func effects(
        for event: WallEvent, at t: TimeInterval, style: WallStyle,
        contexts: [String: (from: Double, to: Double)]
    ) -> [WallEffect] {
        if event.kind == .compacted { return drain(event, at: t, style: style, contexts: contexts) }
        let amplitude = style.amplitude
        guard amplitude > 0, style.moves(event.kind) else { return [] }
        var beats = plan(event.kind)
        if style.still {
            guard let first = beats.first, !vanishing.contains(first.kind) else { return [] }
            beats = [Beat(kind: .fade, duration: stillDuration, ink: first.ink, isProtected: first.isProtected)]
        }
        return beats.map { beat in
            let start = t + beat.delay
            return WallEffect(
                kind: beat.kind, tile: event.tile, worker: event.worker, start: start,
                duration: beat.duration, ink: beat.ink, amplitude: amplitude,
                seed: seed(tile: event.tile, kind: beat.kind, at: start), isProtected: beat.isProtected)
        }
    }

    private static func drain(
        _ event: WallEvent, at t: TimeInterval, style: WallStyle,
        contexts: [String: (from: Double, to: Double)]
    ) -> [WallEffect] {
        guard let context = contexts[event.tile] else { return [] }
        let amplitude = style.moves(.compacted) ? style.amplitude : 0
        return [
            WallEffect(
                kind: .drain, tile: event.tile, start: t, duration: 2.6, ink: .tile,
                amplitude: amplitude, seed: seed(tile: event.tile, kind: .drain, at: t),
                from: context.from, to: context.to)
        ]
    }

    private static func plan(_ kind: WallEvent.Kind) -> [Beat] {
        switch kind {
        case .step: return [Beat(kind: .spark, duration: 0.45, ink: .tile)]
        case .workerStarted: return [Beat(kind: .thread, duration: 1.1, ink: .working)]
        case .workerEnded: return [Beat(kind: .dissolve, duration: 1.5, ink: .dim)]
        case .finished:
            return [
                Beat(kind: .exhale, duration: 1.8, ink: .finished),
                Beat(kind: .groundRipple, duration: 2.2, ink: .finished),
            ]
        case .stopped: return [Beat(kind: .pulse, duration: 1.0, ink: .dim)]
        case .asked:
            return [
                Beat(kind: .knock, duration: 1.3, ink: .needs, isProtected: true),
                Beat(kind: .knock, duration: 1.3, ink: .needs, delay: secondKnock, isProtected: true),
            ]
        case .answered: return [Beat(kind: .approved, duration: 1.4, ink: .working)]
        case .failed:
            return [
                Beat(kind: .fracture, duration: 1.6, ink: .failed, isProtected: true),
                Beat(kind: .groundRipple, duration: 2.4, ink: .failed, isProtected: true),
            ]
        case .retried: return [Beat(kind: .pulse, duration: 1.2, ink: .needs)]
        case .resumed, .back: return [Beat(kind: .pulse, duration: 1.0, ink: .working)]
        case .joined: return [Beat(kind: .gather, duration: 1.3, ink: .tile)]
        case .left: return [Beat(kind: .scatter, duration: 1.2, ink: .tile)]
        case .compacted, .quiet, .away, .workerQuiet, .workerStuck: return []
        }
    }

    /// A stable 32-bit hash (FNV-1a) of the tile, the kind and the moment, so the same event always
    /// scatters the same way; `hashValue` is randomised per process and cannot do that.
    static func seed(tile: String, kind: WallEffect.Kind, at t: TimeInterval) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        let bytes = Array(tile.utf8) + [0] + Array(kind.rawValue.utf8) + [0]
            + withUnsafeBytes(of: t.bitPattern.littleEndian) { Array($0) }
        for byte in bytes {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}
