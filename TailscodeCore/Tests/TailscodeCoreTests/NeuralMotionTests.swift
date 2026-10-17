import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural motion")
struct NeuralMotionTests {
    @Test("a breath sits at its floor at phase zero and peaks half a period later")
    func breath() {
        #expect(abs(NeuralMotion.breathLevel(at: 0) - ActivityTuning.breathFloor) < 1e-9)
        #expect(abs(NeuralMotion.breathLevel(at: 0.95) - 1) < 1e-9)
        #expect(abs(NeuralMotion.breathLevel(at: 1.9) - ActivityTuning.breathFloor) < 1e-9)
    }

    @Test("a breath stays between its floor and one, across many periods")
    func breathRange() {
        for step in 0..<400 {
            let value = NeuralMotion.breathLevel(at: Double(step) * 0.037)
            #expect(value >= ActivityTuning.breathFloor - 1e-9 && value <= 1 + 1e-9)
        }
    }

    @Test("the heartbeat peaks at its two beats and rests at its floor between them")
    func heartbeat() {
        #expect(abs(NeuralMotion.heartbeatLevel(at: 0.08 * 1.6) - 1) < 1e-9)
        let second = NeuralMotion.heartbeatLevel(at: 0.25 * 1.6)
        #expect(abs(second - (0.42 + 0.58 * 0.85)) < 1e-9)
        #expect(NeuralMotion.heartbeatLevel(at: 0.7 * 1.6) < 0.4201 + 1e-3)
        #expect(NeuralMotion.heartbeatLevel(at: 0.128) > NeuralMotion.heartbeatLevel(at: 0.4))
    }

    @Test("the heartbeat's maxima are near 0.128 and 0.4 seconds")
    func heartbeatMaxima() {
        let samples = (0..<1600).map { Double($0) / 1000 }
        let values = samples.map { NeuralMotion.heartbeatLevel(at: $0) }
        let peak = values.indices.max { values[$0] < values[$1] }!
        #expect(abs(samples[peak] - 0.128) < 0.005)
        let later = values.indices.filter { samples[$0] > 0.3 && samples[$0] < 0.6 }
            .max { values[$0] < values[$1] }!
        #expect(abs(samples[later] - 0.4) < 0.01)
    }

    @Test("the sweep is the share of the sweep period elapsed, wrapped")
    func sweep() {
        #expect(NeuralMotion.sweepPhase(at: 0) == 0)
        #expect(abs(NeuralMotion.sweepPhase(at: ActivityTuning.sweepPeriod / 2) - 0.5) < 1e-9)
        #expect(abs(NeuralMotion.sweepPhase(at: ActivityTuning.sweepPeriod * 3.25) - 0.25) < 1e-9)
    }

    @Test("reduced motion maps every motion to still")
    func reduced() {
        for motion in [NeuralMotion.breath, .heartbeat, .sweep, .still] {
            #expect(motion.level(at: 0.3, reduceMotion: true) == 1)
            #expect(motion.sweepPhase(at: 0.3, reduceMotion: true) == 0)
            #expect(motion.honoring(reduceMotion: true) == .still)
        }
    }

    @Test("a motion keeps its own level and only a sweep has a phase")
    func levels() {
        #expect(NeuralMotion.still.level(at: 0.3) == 1)
        #expect(NeuralMotion.sweep.level(at: 0.3) == 1)
        #expect(NeuralMotion.breath.level(at: 0.3) == NeuralMotion.breathLevel(at: 0.3))
        #expect(NeuralMotion.breath.sweepPhase(at: 0.3) == 0)
        #expect(NeuralMotion.sweep.sweepPhase(at: 0.3) == NeuralMotion.sweepPhase(at: 0.3))
    }
}
