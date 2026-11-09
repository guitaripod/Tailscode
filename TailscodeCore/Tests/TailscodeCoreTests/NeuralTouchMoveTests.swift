import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural transition under a finger")
struct NeuralTouchMoveTests {
    typealias T = NeuralTransition

    private let metrics = NeuralStageMetrics.make(width: 390, density: .compact, input: .touch, phone: true)

    private func move(_ direction: T.Direction, level: ShedLevel = .calm, reduceMotion: Bool = false) -> T {
        T.make(
            direction, metrics: metrics, nodeCount: 12, reduceMotion: reduceMotion, level: level,
            feel: .touch)
    }

    @Test("a finger's move runs 360 ms open and 260 closed, and a desk's is untouched")
    func durations() {
        #expect(move(.open).duration == 0.360)
        #expect(move(.close).duration == 0.260)
        #expect(move(.open, level: .strained).duration == 0.180)
        #expect(move(.open, reduceMotion: true).duration == T.crossfadeDuration)
        #expect(T.make(.open, metrics: metrics, nodeCount: 12).duration == 0.320)
        #expect(T.make(.close, metrics: metrics, nodeCount: 12).duration == 0.220)
    }

    @Test("both directions are fast at the start: four fifths of the travel in the first third")
    func frontLoaded() {
        let open = move(.open)
        let close = move(.close)
        #expect(open.gradient(at: 1.0 / 3.0) > 0.8)
        #expect(close.gradient(at: 1.0 / 3.0) < 0.2)
        #expect(close.gradient(at: 0.05) < 0.85, "a closing moves on its first frame, never an ease-in")
        #expect(T.make(.close, metrics: metrics, nodeCount: 12).gradient(at: 0.05) > 0.99)
        #expect(open.frame(at: 0).progress == 0 && open.frame(at: 1).progress == 1)
        #expect(close.frame(at: 0).progress == 1 && close.frame(at: 1).progress == 0)
    }

    @Test("the card's words are gone before the head has covered a quarter, and return only at the end")
    func wordsFollowTheHead() {
        let open = move(.open)
        let close = move(.close)
        for u in stride(from: 0.0, through: 1.0, by: 0.01) {
            for frame in [open.frame(at: u), close.frame(at: u)] where frame.progress >= T.touchWordsReach {
                #expect(frame.cardTextAlpha == 0)
            }
        }
        #expect(open.frame(at: 0).cardTextAlpha == 1)
        #expect(close.frame(at: 1).cardTextAlpha == 1)
    }

    @Test("the backdrop rises as the card's surface fades, and the content leaves early in a closing")
    func groundAndContent() {
        let open = move(.open)
        #expect(open.frame(at: 0).stageBandAlpha == 0 && open.frame(at: 1).stageBandAlpha == 1)
        #expect(open.frame(at: 1).cardSurfaceAlpha == 0)
        let close = move(.close)
        let gone = close.frame(at: T.touchContentLeaves)
        #expect(gone.contentTime == 0 && gone.readoutAlpha == 0 && gone.footerAlpha == 0)
        #expect(close.frame(at: 0.2).contentTime > 0, "the content fades over frames, not in one")
        #expect(T.make(.open, metrics: metrics, nodeCount: 12).frame(at: 0.5).stageBandAlpha == 0)
    }

    @Test("a reversal turns round where it is: geometry and content continue from the same frame")
    func reversal() {
        let open = move(.open)
        for u in [0.1, 0.3, 0.6, 0.9] {
            let here = open.frame(at: u)
            let back = open.reversed(from: u).frame(at: 0)
            #expect(abs(here.progress - back.progress) < 1e-9)
            #expect(abs(here.contentTime - back.contentTime) < 1e-9)
            #expect(abs(here.rowHeight - back.rowHeight) < 1e-9)
        }
        let close = move(.close)
        let back = close.reversed(from: 0.4)
        #expect(abs(close.frame(at: 0.4).contentTime - back.frame(at: 0).contentTime) < 1e-9)
        #expect(back.frame(at: 1).progress == 1 && back.frame(at: 1).contentTime == T.openMs)
    }

    @Test("the head swells as it settles on opening and never on closing")
    func swell() {
        let card = metrics.cardGeometry.picture
        let stage = metrics.stageGeometry.picture
        func swell(_ move: T, _ u: Double) -> Double {
            let frame = move.frame(at: u)
            return frame.traveller.width / card.interpolated(to: stage, frame.progress).width
        }
        let open = move(.open)
        let peak = stride(from: 0.0, through: 1.0, by: 0.005).map { swell(open, $0) }.max() ?? 1
        #expect(abs(peak - (1 + T.touchOverscale)) < 0.002)
        #expect(abs(swell(open, 1) - 1) < 1e-9)
        let close = move(.close)
        #expect(stride(from: 0.0, through: 1.0, by: 0.01).allSatisfy { abs(swell(close, $0) - 1) < 1e-9 })
    }
}
