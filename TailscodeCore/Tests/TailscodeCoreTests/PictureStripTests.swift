import Foundation
import Testing

@testable import TailscodeCore

@Suite struct PictureStripTests {
    private let compact = ChatMetrics.metrics(for: .compact, input: .touch)
    private let comfortable = ChatMetrics.metrics(for: .comfortable, input: .touch)

    @Test func aLoneLandscapePictureIsAsTallAsTheMetricsAllow() {
        let result = PictureStripLayout.layout(aspects: [1.5], width: 370, metrics: compact)
        #expect(result.frames.count == 1)
        #expect(result.frames[0].height == 180)
        #expect(result.frames[0].width == 270)
        #expect(result.height == 180)
        #expect(result.lineCount == 1)
    }

    @Test func aPictureTooWideForTheLineShrinksToIt() {
        let result = PictureStripLayout.layout(aspects: [2.4], width: 300, metrics: compact)
        #expect(result.frames[0].width == 300)
        #expect(abs(result.frames[0].height - 125) < 0.001)
        #expect(abs(result.height - 125) < 0.001)
    }

    @Test func twoThatFitShareALine() {
        let result = PictureStripLayout.layout(aspects: [1.0, 0.75], width: 370, metrics: compact)
        #expect(result.lineCount == 1)
        #expect(result.frames[0].x == 0)
        #expect(result.frames[1].x == 180 + compact.imageStripGap)
        #expect(result.height == 180)
    }

    @Test func aThirdThatWouldPassTheEdgeWrapsUnderTheGutter() {
        let result = PictureStripLayout.layout(aspects: [1.0, 1.0, 1.0], width: 370, metrics: compact)
        #expect(result.lineCount == 2)
        #expect(result.frames[2].x == 0)
        #expect(result.frames[2].y == 180 + compact.imageStripGap)
        #expect(result.height == 180 + compact.imageStripGap + 180)
    }

    @Test func aSmallerShapeMayStillFitAfterALargerOneDidNot() {
        let result = PictureStripLayout.layout(aspects: [1.0, 1.0, 0.55], width: 370, metrics: compact)
        #expect(result.frames[2].y > 0)
        let narrow = PictureStripLayout.layout(aspects: [1.0, 0.55], width: 370, metrics: compact)
        #expect(narrow.lineCount == 1)
    }

    @Test func shapesAreClampedAndUnknownOnesAreAssumed() {
        #expect(PictureStripLayout.shape(of: 10) == 2.4)
        #expect(PictureStripLayout.shape(of: 0.1) == 0.55)
        #expect(PictureStripLayout.shape(of: nil) == PictureStripLayout.placeholderAspect)
        #expect(PictureStripLayout.shape(of: .nan) == PictureStripLayout.placeholderAspect)
        #expect(PictureStripLayout.shape(of: -1) == PictureStripLayout.placeholderAspect)
    }

    @Test func comfortableAllowsTallerThumbnailsAndNeverShorterThanCompact() {
        let aspects: [Double?] = [1.5, 0.8, nil]
        let tight = PictureStripLayout.layout(aspects: aspects, width: 370, metrics: compact)
        let airy = PictureStripLayout.layout(aspects: aspects, width: 370, metrics: comfortable)
        #expect(tight.height <= airy.height)
        #expect(tight.frames.allSatisfy { $0.height <= compact.imageMaxHeight })
    }

    @Test func nothingToPlaceOrNoRoomIsEmpty() {
        #expect(PictureStripLayout.layout(aspects: [], width: 370, metrics: compact).frames.isEmpty)
        #expect(PictureStripLayout.layout(aspects: [1.0], width: 0, metrics: compact).height == 0)
    }

    @Test func everyFrameStaysInsideTheLine() {
        let aspects: [Double?] = (0..<9).map { $0 % 2 == 0 ? 1.7 : 0.6 }
        let result = PictureStripLayout.layout(aspects: aspects, width: 330, metrics: compact)
        for frame in result.frames {
            #expect(frame.x >= 0)
            #expect(frame.x + frame.width <= 330.5)
            #expect(frame.y + frame.height <= result.height + 0.001)
        }
    }
}
