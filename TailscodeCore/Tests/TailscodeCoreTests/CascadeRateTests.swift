import Foundation
import Testing
@testable import TailscodeCore

@Suite("Cascade rate")
struct CascadeRateTests {
    @Test("a lone streaming pane gets the display's full rate")
    func lonePane() {
        for streaming in [0, 1] {
            #expect(CascadeRate.ceiling(streaming: streaming, level: .calm) == 120)
        }
        let range = CascadeRate.range(streaming: 1, level: .calm)
        #expect(range == CascadeRate.Range(minimum: 60, maximum: 120, preferred: 120))
    }

    @Test("the rate steps down with the number of panes streaming")
    func stepsDown() {
        #expect(CascadeRate.ceiling(streaming: 2, level: .calm) == 60)
        #expect(CascadeRate.ceiling(streaming: 3, level: .calm) == 30)
        #expect(CascadeRate.ceiling(streaming: 4, level: .calm) == 30)
        #expect(CascadeRate.ceiling(streaming: 9, level: .calm) == 30)
    }

    @Test("a count never raises the rate")
    func monotonic() {
        for level in ShedLevel.allCases {
            var last = Double.infinity
            for streaming in 0...12 {
                let rate = CascadeRate.ceiling(streaming: streaming, level: level)
                #expect(rate <= last)
                last = rate
            }
        }
    }

    @Test("a peer never exceeds thirty, even when two panes stream")
    func peers() {
        for streaming in 0...6 {
            #expect(CascadeRate.ceiling(streaming: streaming, level: .calm, focused: false) <= 30)
        }
    }

    @Test("the governor's level caps the rate from busy up")
    func levelCaps() {
        #expect(CascadeRate.ceiling(streaming: 1, level: .busy) == 30)
        #expect(CascadeRate.ceiling(streaming: 1, level: .loaded) == 20)
        #expect(CascadeRate.ceiling(streaming: 1, level: .strained) == 10)
        #expect(CascadeRate.ceiling(streaming: 1, level: .critical) == 0)
        for level in ShedLevel.allCases where level >= .loaded {
            for streaming in 0...6 {
                #expect(CascadeRate.ceiling(streaming: streaming, level: level) <= 30)
            }
        }
    }

    @Test("the range always holds its ceiling")
    func rangeHoldsCeiling() {
        for level in ShedLevel.allCases {
            for streaming in 0...5 {
                let range = CascadeRate.range(streaming: streaming, level: level)
                #expect(range.maximum == CascadeRate.ceiling(streaming: streaming, level: level))
                #expect(range.preferred == range.maximum)
                #expect(range.minimum <= range.maximum)
            }
        }
        #expect(CascadeRate.range(streaming: 2, level: .calm).minimum == 30)
        #expect(CascadeRate.range(streaming: 4, level: .calm).minimum == 10)
    }

    @Test("only the focused pane reveals, and only where the budget writes text")
    func reveals() {
        #expect(CascadeRate.reveals(focused: true, level: .calm))
        #expect(CascadeRate.reveals(focused: true, level: .busy))
        #expect(!CascadeRate.reveals(focused: false, level: .calm))
        for level in ShedLevel.allCases where level >= .loaded {
            #expect(!CascadeRate.reveals(focused: true, level: level))
            #expect(!CascadeRate.reveals(focused: false, level: level))
        }
        #expect(!CascadeRate.reveals(focused: true, level: .calm, reducedMotion: true))
    }
}
