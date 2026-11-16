import Testing

@testable import TailscodeCore

@Suite struct PictureVerbsTests {
    @Test func aDeskOffersThePathOnlyWhenThePictureHasOne() {
        #expect(PictureVerbs.pointer(hasPath: true) == [.open, .copy, .saveToDownloads, .copyPath])
        #expect(PictureVerbs.pointer(hasPath: false) == [.open, .copy, .saveToDownloads])
    }

    @Test func aPhoneOffersWhatALonePictureAlwaysDid() {
        #expect(PictureVerbs.touch == [.saveToPhotos, .copy, .saveToFiles, .share])
    }

    @Test func noTwoVerbsReadAlike() {
        #expect(Set(PictureVerb.allCases.map(\.title)).count == PictureVerb.allCases.count)
        #expect(Set(PictureVerb.allCases.map(\.symbol)).count == PictureVerb.allCases.count)
    }
}
