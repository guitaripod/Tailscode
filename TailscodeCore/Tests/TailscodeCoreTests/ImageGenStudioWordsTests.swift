import Foundation
import Testing

@testable import TailscodeCore

@Suite struct ImageGenStudioWordsTests {
    @Test func countNudgesOnlyTheEngineTrainedBehindARewriter() {
        #expect(ImageGenStudioWords.countLine(words: 3, engine: .quality).contains("paragraph"))
        #expect(!ImageGenStudioWords.countLine(words: 3, engine: .fast).contains("paragraph"))
        #expect(!ImageGenStudioWords.countLine(words: 40, engine: .quality).contains("paragraph"))
        #expect(ImageGenStudioWords.countLine(words: 1, engine: .fast) == "1 word")
    }

    @Test func clockReadsMinutesAndTheQueue() {
        let started = Date(timeIntervalSinceNow: -81)
        #expect(ImageGenStudioWords.clockLine(since: started, ahead: 0) == "1:21 · behind nobody")
        #expect(ImageGenStudioWords.clockLine(since: started, ahead: 2).hasSuffix("behind 2 renders"))
        #expect(ImageGenStudioWords.clockLine(since: nil, ahead: nil) == "")
    }

    @Test func seedDetailNamesTheHeldNumber() {
        var seed = ImageGenSeed()
        seed.last = 8_841_093_326_571_422_210
        seed.hold()
        #expect(ImageGenStudioWords.holdSeedDetail(seed: seed).hasPrefix("#8841…2210"))
        seed.release()
        #expect(ImageGenStudioWords.holdSeedDetail(seed: seed) == "Every render rolls a new number")
    }
}
