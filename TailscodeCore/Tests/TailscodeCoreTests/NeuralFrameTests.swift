import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural frame")
struct NeuralFrameTests {
    private let face = NeuralFace(model: "claude-opus-4", effort: "high")

    private func frame(
        _ activity: ActivityKind?, _ outcome: NeuralOutcome? = nil, at time: TimeInterval = 0,
        zone: NeuralZone? = nil, meters: NeuralMeters = .none, reduce: Bool = false,
        hover: NeuralZone? = nil, provenance: Set<NeuralZone>? = nil
    ) -> NeuralFrame {
        NeuralFrame.at(
            time: time,
            state: NeuralState.make(activity: activity, outcome: outcome, waitingZone: zone),
            face: face, meters: meters, reduceMotion: reduce, hover: hover, provenance: provenance)
    }

    private func close(_ value: Float, _ expected: Float) -> Bool { abs(value - expected) < 1e-4 }

    @Test("a failed turn keeps the failing zone at 0.9 and steps everything else back")
    func failed() {
        let result = frame(.failed)
        for zone in NeuralZone.allCases {
            #expect(close(result.intensity[zone.rawValue], zone == .shell ? 0.9 : 0.1))
        }
        #expect(close(result.intensity[NeuralChannel.link.rawValue], 0.2))
        #expect(close(result.intensity[NeuralChannel.star.rawValue], 0.3))
        #expect(close(result.intensity[NeuralChannel.seam.rawValue], 0.15))
        #expect(result.toneOverride[NeuralZone.shell.rawValue] == .danger)
        #expect(result.toneOverride[NeuralChannel.eye.rawValue] == .danger)
        #expect(close(result.intensity[NeuralChannel.eye.rawValue], 1))
        #expect(result.settled)
    }

    @Test("an approval beats the waiting zone to about 1.35 on the first beat")
    func approval() {
        let result = frame(.needsApproval, at: 0.128)
        #expect(close(result.intensity[NeuralZone.shell.rawValue], 1.35))
        #expect(close(result.intensity[NeuralZone.think.rawValue], 0.3))
        #expect(close(result.intensity[NeuralChannel.link.rawValue], 0.7))
        #expect(result.toneOverride[NeuralZone.shell.rawValue] == .attention)
        #expect(result.toneOverride[NeuralChannel.eye.rawValue] == .attention)
        #expect(close(result.intensity[NeuralChannel.eye.rawValue], 1.0))
        #expect(!result.settled)
    }

    @Test("a live zone breathes between 0.5 plus its floor share and 1.35, wearing the accent")
    func thinking() {
        let low = frame(.thinking, at: 0)
        let high = frame(.thinking, at: 0.95)
        let floor = Float(ActivityTuning.breathFloor)
        #expect(close(low.intensity[NeuralZone.think.rawValue], 0.5 + 0.85 * floor))
        #expect(close(high.intensity[NeuralZone.think.rawValue], 1.35))
        #expect(low.toneOverride[NeuralZone.think.rawValue] == nil)
        #expect(close(low.intensity[NeuralChannel.eye.rawValue], 0.35 + 0.65 * floor))
        #expect(low.ripple == 1 && low.active == NeuralZone.think.center)
        #expect(!low.settled)
    }

    @Test("a settled turn's eye wears the identity at full intensity and the frame is settled")
    func settled() {
        let result = frame(nil, .settled, at: 5)
        #expect(result.toneOverride[NeuralChannel.eye.rawValue] == .identity)
        #expect(close(result.intensity[NeuralChannel.eye.rawValue], 1))
        #expect(result.settled && result.ripple == 0 && result.active == nil)
        #expect(result.effort == 3 && !result.hollow && !result.rainbow)
        #expect(result == frame(nil, .settled, at: 9))
    }

    @Test("the compaction crunches on a 2.6 second cosine, with the sweep and the ribs dropping")
    func compacting() {
        let meters = NeuralMeters(contextFill: 0.6)
        let start = frame(.compacting, at: 0, meters: meters)
        #expect(close(start.crunch, 0))
        #expect(close(start.intensity[NeuralChannel.seam.rawValue], 0.3))
        #expect(close(start.ribs, 3.6))
        let middle = frame(.compacting, at: 1.3, meters: meters)
        #expect(close(middle.crunch, 1))
        #expect(close(middle.intensity[NeuralChannel.seam.rawValue], 1.0))
        #expect(close(middle.ribs, 3.6 * 0.45))
        #expect(close(middle.sweepAmount, 0.9) && middle.sweepTone == .attention)
        #expect(!middle.settled)
    }

    @Test("sweeps carry the phase and an amount by tone and dimness")
    func sweeps() {
        let retrying = frame(.retrying(attempt: 1), at: ActivityTuning.sweepPeriod / 4)
        #expect(close(retrying.sweep, 0.25) && close(retrying.sweepAmount, 0.9))
        let reconnecting = frame(.reconnecting)
        #expect(close(reconnecting.sweepAmount, 0.55))
        #expect(close(reconnecting.intensity[NeuralZone.sense.rawValue], 0.4))
        #expect(close(reconnecting.intensity[NeuralChannel.eye.rawValue], 0.35))
        let connecting = frame(.connecting)
        #expect(close(connecting.sweepAmount, 0.5) && connecting.sweepTone == .quiet)
        #expect(connecting.toneOverride[NeuralChannel.eye.rawValue] == .quiet)
    }

    @Test("queued holds the head dim and still")
    func queued() {
        let result = frame(.queued(2))
        for zone in NeuralZone.allCases { #expect(close(result.intensity[zone.rawValue], 0.35)) }
        #expect(close(result.intensity[NeuralChannel.link.rawValue], 0.35))
        #expect(close(result.intensity[NeuralChannel.eye.rawValue], 0.35))
        #expect(result.settled)
    }

    @Test("offline is dark")
    func offline() {
        let result = frame(.offline)
        #expect(close(result.intensity[NeuralChannel.eye.rawValue], 0))
        #expect(close(result.intensity[NeuralChannel.seam.rawValue], 0.06))
        for zone in NeuralZone.allCases { #expect(close(result.intensity[zone.rawValue], 0.05)) }
        #expect(result.settled)
    }

    @Test("background steps the zones back and orbits, breathing the live eye")
    func background() {
        let result = frame(.inBackground(tasks: 1), at: 0.95)
        for zone in NeuralZone.allCases { #expect(close(result.intensity[zone.rawValue], 0.28)) }
        #expect(result.toneOverride[NeuralChannel.eye.rawValue] == .live)
        #expect(close(result.intensity[NeuralChannel.eye.rawValue], 1.0))
        #expect(result.ripple == 0 && !result.settled)
    }

    @Test("stopped and the idle head hold the quiet eye")
    func quiet() {
        let stopped = frame(nil, .stopped)
        for zone in NeuralZone.allCases { #expect(close(stopped.intensity[zone.rawValue], 0.4)) }
        #expect(close(stopped.intensity[NeuralChannel.eye.rawValue], 0.35))
        let idle = frame(nil)
        #expect(close(idle.intensity[NeuralChannel.eye.rawValue], 0.4))
        #expect(close(idle.intensity[NeuralZone.think.rawValue], 0.5))
        #expect(idle.settled)
    }

    @Test("settled is true exactly when nothing will change on its own")
    func settledSemantics() {
        for kind in ActivityKind.everyState {
            let state = NeuralState.make(activity: kind)
            let live = NeuralFrame.at(time: 0.2, state: state, face: face)
            #expect(live.settled == !state.isAnimated(), "\(kind)")
            let held = NeuralFrame.at(time: 0.2, state: state, face: face, reduceMotion: true)
            #expect(held.settled, "\(kind)")
            #expect(held.sweepAmount == 0 && held.ripple == 0, "\(kind)")
        }
    }

    @Test("reduced motion keeps the tone and holds a compaction halfway")
    func reduced() {
        let result = frame(.compacting, at: 1.3, meters: NeuralMeters(contextFill: 1), reduce: true)
        #expect(close(result.crunch, 0.5) && result.sweep == 0)
        #expect(result.toneOverride[NeuralChannel.eye.rawValue] == .attention)
        let breathing = frame(.thinking, at: 0, reduce: true)
        #expect(close(breathing.intensity[NeuralZone.think.rawValue], 1.0))
        #expect(close(breathing.intensity[NeuralChannel.eye.rawValue], 1))
    }

    @Test("ribs carry the tone of the fill and an estimate halves them")
    func ribs() {
        let measured = frame(nil, .settled, meters: NeuralMeters(contextFill: 0.85))
        #expect(close(measured.ribs, 5.1))
        #expect(measured.toneOverride[NeuralChannel.rib.rawValue] == .danger)
        #expect(close(measured.intensity[NeuralChannel.rib.rawValue], 1))
        let estimated = frame(
            nil, .settled, meters: NeuralMeters(contextFill: 0.55, isEstimate: true))
        #expect(estimated.toneOverride[NeuralChannel.rib.rawValue] == .attention)
        #expect(close(estimated.intensity[NeuralChannel.rib.rawValue], 0.5))
        #expect(close(frame(nil, .settled).intensity[NeuralChannel.visor.rawValue], 0.25))
    }

    @Test("a call's ear takes the tone and motion of its face")
    func ear() {
        let ear = NeuralChannel.ear.rawValue
        let listening = frame(nil, .settled, at: 0.95, meters: NeuralMeters(call: .listening))
        #expect(listening.toneOverride[ear] == .live)
        #expect(close(listening.intensity[ear], 1.1))
        #expect(!listening.settled)
        let hearing = frame(nil, .settled, meters: NeuralMeters(call: .hearing))
        #expect(hearing.toneOverride[ear] == .live && close(hearing.intensity[ear], 1))
        #expect(hearing.settled)
        let degraded = frame(nil, .settled, meters: NeuralMeters(call: .degraded))
        #expect(degraded.toneOverride[ear] == .danger && degraded.settled)
        let connecting = frame(nil, .settled, at: 0, meters: NeuralMeters(call: .connecting))
        #expect(connecting.toneOverride[ear] == .quiet && close(connecting.intensity[ear], 0.55))
        #expect(!connecting.settled)
        let still = frame(
            nil, .settled, meters: NeuralMeters(call: .listening), reduce: true)
        #expect(still.settled && close(still.intensity[ear], 1))
        #expect(close(frame(nil, .settled).intensity[ear], 0.15))
    }

    @Test("hover lights one zone and steps the others back, on a head at rest only")
    func hover() {
        let result = frame(nil, .settled, hover: .act)
        #expect(close(result.intensity[NeuralZone.act.rawValue], 1.2))
        #expect(close(result.intensity[NeuralZone.say.rawValue], 0.3))
        #expect(close(result.intensity[NeuralChannel.link.rawValue], 0.6))
        let working = frame(.thinking, at: 0.95, hover: .act)
        #expect(close(working.intensity[NeuralZone.act.rawValue], 0.3))
        #expect(close(working.intensity[NeuralZone.think.rawValue], 1.35))
    }

    @Test("provenance lights the quoted zones and dims the rest")
    func provenance() {
        let result = frame(nil, .settled, provenance: [.shell, .act])
        #expect(close(result.intensity[NeuralZone.shell.rawValue], 1.15))
        #expect(close(result.intensity[NeuralZone.act.rawValue], 1.15))
        #expect(close(result.intensity[NeuralZone.think.rawValue], 0.22))
        #expect(close(result.intensity[NeuralChannel.link.rawValue], 0.5))
    }

    @Test("the face sets the visor")
    func visor() {
        let power = NeuralFrame.at(
            time: 0, state: .settled, face: NeuralFace(model: "claude-fable", effort: "ultracode"))
        #expect(power.effort == 5 && power.rainbow && !power.hollow)
        let server = NeuralFrame.at(time: 0, state: .settled, face: NeuralFace(model: "x", effort: nil))
        #expect(server.effort == 0 && server.hollow && !server.rainbow)
    }
}
