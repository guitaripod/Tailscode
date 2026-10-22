import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("The status band holds still")
struct StatusBandSlotsTests {
    @Test("A fact's held width only ever grows")
    func monotonic() {
        var slots = StatusBandSlots()
        #expect(slots.widen("phase", to: 80) == 80)
        #expect(slots.widen("phase", to: 60) == 80)
        #expect(slots.widen("phase", to: 95) == 95)
        #expect(slots.width(of: "phase") == 95)
        #expect(slots.width(of: "cost") == 0)
    }

    @Test("Each fact holds its own width")
    func independent() {
        var slots = StatusBandSlots()
        slots.widen("phase", to: 120)
        slots.widen("context", to: 40)
        #expect(slots.width(of: "phase") == 120)
        #expect(slots.width(of: "context") == 40)
    }

    @Test("Reset forgets every width, for a different conversation")
    func reset() {
        var slots = StatusBandSlots()
        slots.widen("phase", to: 120)
        slots.reset()
        #expect(slots == StatusBandSlots())
        #expect(slots.widen("phase", to: 30) == 30)
    }

    @Test("One absurd fact cannot hold more than its share of the band")
    func clamped() {
        var slots = StatusBandSlots()
        let held = slots.widen("phase", to: 900, in: 400)
        #expect(held == 400 * StatusBandSlots.shareLimit)
        #expect(slots.widen("phase", to: 10, in: 400) == held)
        #expect(slots.width(of: "phase", in: 1000) == held)
    }

    @Test("A narrower band lowers what is handed back without forgetting what was held")
    func narrowing() {
        var slots = StatusBandSlots()
        slots.widen("phase", to: 150, in: 800)
        #expect(slots.width(of: "phase", in: 200) == 200 * StatusBandSlots.shareLimit)
        #expect(slots.width(of: "phase", in: 800) == 150)
    }

    @Test("A band whose width is not known yet clamps nothing")
    func unmeasuredBand() {
        var slots = StatusBandSlots()
        #expect(slots.widen("phase", to: 300, in: 0) == 300)
        #expect(slots.widen("phase", to: 300, in: nil) == 300)
    }

    @Test("A width that is not a number holds nothing")
    func junk() {
        var slots = StatusBandSlots()
        #expect(slots.widen("phase", to: .nan) == 0)
        #expect(slots.widen("phase", to: -4) == 0)
        #expect(slots.widen("phase", to: .infinity) == 0)
    }

    @Test("The glyph set lists no mark twice")
    func distinct() {
        let glyphs = StatusBandSlots.leadingGlyphs
        #expect(Set(glyphs).count == glyphs.count)
        #expect(glyphs.count > 15)
    }

    @Test("Every mark a phase can wear is in the slot's glyph set")
    func phasesFit() {
        let slot = Set(StatusBandSlots.leadingGlyphs)
        var phases: [StatusFacts.Phase] = [
            .working, .background(tasks: 2), .stalled(tasks: 1), .compacting, .awaitingApproval,
            .awaitingAnswer, .connecting, .reconnecting, .offline, .failed("it broke"),
        ]
        phases.append(.idle)
        var kinds = ActivityKind.everyState
        kinds += ActivityKind.toolKinds.map { .usingTool(name: "Tool", kind: $0) }
        kinds += [.delegating(active: 1), .retrying(attempt: 1)]
        for phase in phases {
            for kind in kinds {
                var facts = StatusFacts()
                facts.phase = phase
                facts.activity = kind
                facts.queued = 1
                for segment in facts.segments {
                    guard let icon = segment.icon else { continue }
                    #expect(slot.contains(String(segment.text.prefix(1))), "\(phase) \(kind)")
                    #expect(slot.contains(icon.glyph), "\(phase) \(kind)")
                    for frame in icon.cycle { #expect(slot.contains(frame)) }
                }
            }
        }
    }

    @Test("A fan-out's own segment wears a mark from the set")
    func agentsFit() {
        let slot = Set(StatusBandSlots.leadingGlyphs)
        #expect(slot.contains(ActivityKind.delegating(active: 3).icon.glyph))
        #expect(slot.contains("▸"))
    }

    @Test("Every tool kind and every sweep frame is in the set")
    func toolsAndSweeps() {
        let slot = Set(StatusBandSlots.leadingGlyphs)
        for kind in ActivityKind.toolKinds { #expect(slot.contains(ActivityKind.glyph(forTool: kind))) }
        for frame in ActivityIcon.sweepCycle { #expect(slot.contains(frame)) }
    }

    @Test("The rehearsal changes every word the band can change, and nothing else")
    func rehearsal() {
        let steps = StatusFacts.rehearsal
        let ids = steps.map { $0.segments.map(\.id) }
        #expect(ids.allSatisfy { $0 == ["phase", "context", "cost"] })
        let phases = Set(steps.compactMap { $0.segments.first?.text })
        #expect(phases.count == steps.count)
        let clocks = steps.compactMap(\.elapsed).map { StatusFacts.clock($0) }
        #expect(clocks == ["58s", "1m 2s", "9m 59s", "10m 0s", "22m 52s", "22m 53s"])
        #expect(steps.compactMap { $0.context?.fraction != nil ? 1 : nil }.count == 5)
        let counts = steps.compactMap(\.lastTurnTokens).map { StatusFacts.tokens($0) }
        #expect(counts == ["999", "1.0k", "12.4k", "205.2k", "1.0M", "999"])
    }
}
