import Testing

@testable import TailscodeCore

@Suite("Neural geometry")
struct NeuralGeometryTests {
    @Test("a zone offers only the slots whose node fits inside the dome")
    func capacities() {
        let capacities = Dictionary(uniqueKeysWithValues: NeuralZone.allCases.map { ($0, $0.capacity) })
        #expect(capacities[.think] == 19)
        #expect(capacities[.sense] == 19)
        #expect(capacities[.act] == 16)
        #expect(capacities[.shell] == 12)
        #expect(capacities[.delegate] == 13)
        #expect(capacities[.say] == 7)
    }

    @Test("the first slot of every zone is its centre")
    func firstSlotIsCentre() {
        for zone in NeuralZone.allCases {
            #expect(zone.slots.first == zone.center)
        }
    }

    @Test("the dome outline closes on a bean of the expected size")
    func domeOutline() {
        #expect(NeuralDome.outline.count > 100)
        #expect(NeuralDome.contains(NeuralPoint(320, 170)))
        #expect(!NeuralDome.contains(NeuralPoint(40, 40)))
        #expect(NeuralDome.triangleFan.count == NeuralDome.outline.count * 3)
    }

    @Test("tool kinds land in the zone the header names")
    func kinds() {
        #expect(NeuralZone.zone(for: .shell) == .shell)
        #expect(NeuralZone.zone(for: .fileRead) == .sense)
        #expect(NeuralZone.zone(for: .fileEdit) == .act)
        #expect(NeuralZone.zone(for: .subagent) == .delegate)
        #expect(NeuralZone.zone(for: .question) == .think)
    }
}
