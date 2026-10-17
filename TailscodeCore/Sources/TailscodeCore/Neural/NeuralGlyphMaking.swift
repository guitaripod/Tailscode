import CodingAgentKit
import Foundation

/// Steps per zone and which zones hold a failure nobody recovered: the two things a glyph is
/// drawn from, counted once in a single pass over a turn's steps.
struct NeuralGlyphCounts: Sendable, Equatable {
    var zones = [Int](repeating: 0, count: NeuralGlyphGeometry.zoneCount)
    var failed = 0

    init(_ steps: [NeuralStep]) {
        for step in steps {
            zones[step.zone.rawValue] += 1
            if step.status == .failed && !step.recovered { failed |= 1 << step.zone.rawValue }
        }
    }

    func plan(
        eyeTone: NeuralTone, active: NeuralZone?, live: NeuralZone?, dim: Bool
    ) -> NeuralGlyphPlan {
        NeuralGlyphPlan(
            counts: zones, failed: failed, active: active?.rawValue, live: live?.rawValue,
            eyeTone: eyeTone, dim: dim)
    }
}

extension NeuralGlyphWire {
    /// The head a turn leaves behind, for the places that are away from the transcript.
    ///
    /// The tone, the ring and the eye are the state the chat's own head would wear for the same
    /// turn and activity (`NeuralState`), so the Lock Screen, a notification and the stage cannot
    /// disagree about the same second: a turn that ended well has no tone and its eye wears who
    /// answered, a turn that is waiting rings the zone of what it waits on, a failure rings the
    /// zone that failed. `outcome` replaces the turn's own where the caller knows better.
    public init(turn: NeuralTurn, activity: ActivityKind?, outcome: NeuralOutcome? = nil) {
        let counts = NeuralGlyphCounts(turn.steps)
        let waiting = turn.steps.first { step in
            switch step.status {
            case .waitingApproval, .waitingAnswer, .stalled: return true
            case .ok, .running, .failed, .stopped: return false
            }
        }?.zone
        let ended = outcome ?? turn.outcome
        let failing = ended == .failed || activity == .failed
        let failureZone =
            turn.steps.last { $0.status == .failed && !$0.recovered }?.zone ?? turn.steps.last?.zone
        let state = NeuralState.make(
            activity: activity, outcome: ended,
            waitingZone: waiting ?? (failing ? failureZone : nil))
        let census = NeuralReading.Census(turn.steps)
        var tone = state.tone
        var hue: String?
        var hueLight: String?
        if tone == .identity {
            if let model = turn.modelID, !model.isEmpty {
                let face = NeuralFace(model: model, effort: turn.effort)
                hue = face.hueHex(isDark: true)
                hueLight = face.hueHex(isDark: false)
            } else {
                tone = .quiet
            }
        }
        let reads = census.buckets[.read]?.calls ?? 0
        let edited = census.buckets[.edit]
        self.init(
            zones: counts.zones, failed: counts.failed == 0 ? nil : counts.failed,
            active: state.zone?.rawValue, eye: tone.rawValue, hue: hue, hueLight: hueLight,
            reads: reads > 0 ? reads : nil,
            files: edited.map { $0.distinct < $0.calls ? $0.distinct : nil } ?? nil)
    }
}

extension NeuralBrainModel {
    /// The head as it travels to the Lock Screen and into a notification.
    public var glyphWire: NeuralGlyphWire { NeuralGlyphWire(turn: turn, activity: context.activity) }
}

extension NeuralNoticeCounts {
    init(_ census: NeuralReading.Census, steps: Int) {
        self.init(
            steps: steps, tools: census.tools, shell: census.buckets[.shell]?.calls ?? 0,
            read: census.buckets[.read]?.calls ?? 0, search: census.buckets[.search]?.calls ?? 0,
            edited: census.buckets[.edit]?.distinct ?? 0,
            delegated: census.buckets[.delegate]?.calls ?? 0, added: census.added,
            removed: census.removed)
    }
}
