import Foundation
import Testing

@testable import TailscodeCore

@Suite struct PresenceTests {
    private let colors = PresenceColors(
        live: PresenceRGB(red: 0.2, green: 0.8, blue: 0.4),
        attention: PresenceRGB(red: 0.9, green: 0.7, blue: 0.1),
        danger: PresenceRGB(red: 0.9, green: 0.2, blue: 0.2),
        quiet: PresenceRGB(red: 0.5, green: 0.5, blue: 0.55))

    @Test("Waiting on the person outranks everything and knocks")
    func attentionLeads() {
        let signal = PresenceSignal.aggregate([
            .working, .needsAnswer, .failed, .usingTool(name: "Bash", kind: .shell),
        ])
        #expect(signal.tone == .attention)
        #expect(signal.motion == .attention)
        #expect(signal.satellites == 3)
    }

    @Test("Work in flight breathes with one satellite per open turn")
    func workBreathes() {
        let signal = PresenceSignal.aggregate([.working, .thinking, nil, .offline])
        #expect(signal.tone == .live)
        #expect(signal.motion == .working)
        #expect(signal.satellites == 2)
    }

    @Test("A failure holds the danger colour perfectly still")
    func failureHoldsStill() {
        let signal = PresenceSignal.aggregate([nil, .failed])
        #expect(signal.tone == .danger)
        #expect(signal.motion == .still)
        #expect(signal.satellites == 0)
    }

    @Test("An unreachable server rests quiet; nothing at all rests idle")
    func settledStates() {
        #expect(PresenceSignal.aggregate([nil, .offline]).tone == .quiet)
        let idle = PresenceSignal.aggregate([nil, nil])
        #expect(idle.tone == nil)
        #expect(idle.motion == .still)
    }

    @Test("The satellite count is capped at what a body can carry")
    func satellitesCap() {
        let signal = PresenceSignal.aggregate(Array(repeating: .working, count: 20))
        #expect(signal.satellites == PresenceTuning.maxSatellites)
    }

    @Test("The spoken line carries the whole state in words")
    func spokenCarriesState() {
        #expect(!PresenceSignal.aggregate([.needsApproval]).spoken.isEmpty)
        #expect(
            PresenceSignal.aggregate([.working]).spoken
                != PresenceSignal.aggregate([.failed]).spoken)
    }

    @Test("The body arrives at its target instead of teleporting")
    func fieldConverges() {
        var field = PresenceField(colors: colors)
        field.set(signal: PresenceSignal.aggregate([.working, .working]))
        let first = field.frame(at: 0)
        #expect(first.blobs.count == 1)
        #expect(!first.settled)
        var last = first
        for tick in 1...600 { last = field.frame(at: Double(tick) / 60) }
        #expect(last.blobs.count == 3)
        #expect(abs(last.energy - 1) < 0.01)
        #expect(last.color.distance(to: colors.live) < 0.01)
        #expect(last.blobs.dropFirst().allSatisfy { $0.weight > 0.99 })
    }

    @Test("Stillness settles, and a settled frame says so")
    func stillnessSettles() {
        var field = PresenceField(colors: colors)
        field.set(signal: PresenceSignal.aggregate([.failed]))
        var frame = field.frame(at: 0)
        for tick in 1...900 { frame = field.frame(at: Double(tick) / 60) }
        #expect(frame.settled)
        #expect(frame.intensity == 1)
        let next = field.frame(at: 15.5)
        #expect(next.blobs == frame.blobs)
    }

    @Test("A breathing signal never settles")
    func breathNeverSettles() {
        var field = PresenceField(colors: colors)
        field.set(signal: PresenceSignal.aggregate([.working]))
        var frame = field.frame(at: 0)
        for tick in 1...900 { frame = field.frame(at: Double(tick) / 60) }
        #expect(!frame.settled)
        #expect(frame.intensity < 1)
        #expect(frame.intensity >= ActivityTuning.breathFloor)
    }

    @Test("Reduced motion shows the resting arrangement and loses nothing else")
    func reducedMotionRests() {
        var field = PresenceField(colors: colors)
        field.set(signal: PresenceSignal.aggregate([.working, .working], ultracode: true))
        var frame = field.frame(at: 0, reduceMotion: true)
        for tick in 1...900 { frame = field.frame(at: Double(tick) / 60, reduceMotion: true) }
        #expect(frame.settled)
        #expect(frame.intensity == 1)
        #expect(frame.rainbow > 0.99)
        #expect(frame.blobs.count == 3)
        let later = field.frame(at: 60, reduceMotion: true)
        #expect(later.blobs == frame.blobs)
    }

    @Test("Ultracode keeps the frame awake for its rainbow")
    func ultracodeStaysAwake() {
        var field = PresenceField(colors: colors)
        field.set(signal: PresenceSignal(ultracode: true))
        var frame = field.frame(at: 0)
        for tick in 1...900 { frame = field.frame(at: Double(tick) / 60) }
        #expect(!frame.settled)
        #expect(frame.rainbow > 0.99)
    }

    @Test("Every blob stays inside the unit canvas")
    func blobsStayInBounds() {
        var field = PresenceField(colors: colors)
        field.set(
            signal: PresenceSignal.aggregate(
                Array(repeating: .working, count: PresenceTuning.maxSatellites)))
        for tick in 0...2400 {
            let frame = field.frame(at: Double(tick) / 60)
            for blob in frame.blobs {
                let reach = (blob.x * blob.x + blob.y * blob.y).squareRoot() + blob.radius
                #expect(reach < 1)
            }
        }
    }

    @Test("Two fields given the same clock draw the same creature")
    func determinism() {
        var one = PresenceField(colors: colors)
        var two = PresenceField(colors: colors)
        let signal = PresenceSignal.aggregate([.working, .needsApproval], ultracode: true)
        one.set(signal: signal)
        two.set(signal: signal)
        for tick in 0...300 {
            let time = Double(tick) / 60
            #expect(one.frame(at: time) == two.frame(at: time))
        }
    }

    @Test("A theme change glides the ink without rebuilding the body")
    func inkGlides() {
        var field = PresenceField(colors: colors)
        field.set(signal: PresenceSignal.aggregate([.working]))
        for tick in 0...600 { _ = field.frame(at: Double(tick) / 60) }
        let swapped = PresenceColors(
            live: PresenceRGB(red: 0.1, green: 0.4, blue: 0.9), attention: colors.attention,
            danger: colors.danger, quiet: colors.quiet)
        field.set(colors: swapped)
        let before = field.frame(at: 10.02)
        #expect(before.color.distance(to: swapped.live) > 0.1)
        var after = before
        for tick in 1...600 { after = field.frame(at: 10.02 + Double(tick) / 60) }
        #expect(after.color.distance(to: swapped.live) < 0.01)
    }

    @Test("The capability's spec exists and says alpha")
    func capabilityIsSpecified() {
        let definition = CapabilityRegistry.definition(for: .presenceOrb)
        #expect(definition.spec.contains("alpha"))
        #expect(definition.spec.contains("PresenceField"))
    }
}
