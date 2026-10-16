import Foundation
import Testing

@testable import TailscodeCore

@Suite("Preview light")
struct PreviewLightTests {

    private let all: [PreviewLight] = [
        .dark, .waking, .needsYou, .live, .updating, .broken, .stale, .offline,
    ]

    @Test("Tone says how much the light matters")
    func tones() {
        let expected: [(PreviewLight, ActivityTone)] = [
            (.dark, .quiet), (.waking, .quiet), (.stale, .quiet), (.needsYou, .attention),
            (.live, .live), (.updating, .live), (.broken, .danger), (.offline, .danger),
        ]
        for (light, tone) in expected { #expect(light.tone == tone, "\(light)") }
    }

    @Test("Starting and reconnecting sweep, a change breathes, a question knocks")
    func motionsThatMove() {
        #expect(PreviewLight.waking.motion == .turning)
        #expect(PreviewLight.stale.motion == .turning)
        #expect(PreviewLight.needsYou.motion == .attention)
        #expect(PreviewLight.updating.motion == .working)
    }

    @Test("Anything settled holds perfectly still")
    func motionsThatHold() {
        for light: PreviewLight in [.dark, .live, .broken, .offline] {
            #expect(light.motion == .still, "\(light)")
            #expect(!light.motion.isAnimated)
        }
    }

    @Test("Only the dark light is unlit")
    func lit() {
        for light in all { #expect(light.isLit == (light != .dark), "\(light)") }
    }

    @Test("Only the dark light has nothing to say, in a word or in a sentence")
    func words() {
        #expect(PreviewLight.dark.line.isEmpty)
        #expect(PreviewLight.dark.spoken == nil)
        for light in all where light != .dark {
            #expect(!light.line.isEmpty, "\(light)")
            #expect(light.spoken?.isEmpty == false, "\(light)")
        }
    }

    @Test("Each light wears its own word")
    func distinctWords() {
        let lines = all.filter { $0 != .dark }.map(\.line)
        #expect(Set(lines).count == lines.count)
    }
}
