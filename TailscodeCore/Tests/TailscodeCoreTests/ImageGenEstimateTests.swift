import Foundation
import Testing

@testable import TailscodeCore

@Suite struct ImageGenEstimateTests {
    private func picture(
        engine: ImageGenEngine = .quality, size: ImageGenSize = .standard,
        mode: ImageGenMode = .generate, seconds: Double
    ) -> ImageGenPicture {
        ImageGenPicture(
            path: "/tmp/\(UUID().uuidString).png", prompt: "a lighthouse", engine: engine,
            mode: mode, aspect: .landscape, size: size, seconds: seconds, seed: 1)
    }

    @Test func nothingComparableSaysNothing() {
        #expect(
            ImageGenEstimate.seconds(
                engine: .quality, size: .standard, mode: .generate, among: []) == nil)
        let other = [picture(engine: .fast, seconds: 9), picture(size: .large, seconds: 120)]
        #expect(
            ImageGenEstimate.seconds(
                engine: .quality, size: .standard, mode: .generate, among: other) == nil)
        #expect(
            ImageGenEstimate.line(
                machine: "arch", engine: .quality, size: .standard, mode: .generate, among: other)
                == nil)
    }

    @Test func anEditIsNotPricedFromWordsAlone() {
        let made = [picture(seconds: 40), picture(mode: .edit, seconds: 90)]
        #expect(
            ImageGenEstimate.seconds(
                engine: .quality, size: .standard, mode: .generate, among: made) == 40)
        #expect(
            ImageGenEstimate.seconds(
                engine: .quality, size: .standard, mode: .edit, among: made) == 90)
    }

    @Test func onlyTheNewestFewAreAveraged() {
        let made = [20, 20, 20, 20, 400].map { picture(seconds: Double($0)) }
        #expect(
            ImageGenEstimate.seconds(
                engine: .quality, size: .standard, mode: .generate, among: made) == 20)
    }

    @Test func theLineNamesTheMachineAndSaysAbout() {
        let made = [picture(seconds: 81)]
        let line = ImageGenEstimate.line(
            machine: "arch", engine: .quality, size: .standard, mode: .generate, among: made)
        #expect(line == "about 1 min 21 s on arch")
    }
}
