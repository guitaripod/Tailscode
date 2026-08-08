import Foundation
import Testing

@testable import TailscodeCore

@Suite("Image preview size")
struct ImagePreviewTests {
    @Test("A picture the agent hands over keeps the whole box")
    func receivedIsUntouched() {
        #expect(ImagePreview.bound(220, mine: false) == 220)
        #expect(ImagePreview.share(0.72, mine: false) == 0.72)
    }

    @Test("A picture you sent is a fraction of it")
    func sentIsSmaller() {
        #expect(ImagePreview.bound(300, mine: true) < 300)
        #expect(ImagePreview.share(0.72, mine: true) < 0.72)
        #expect(ImagePreview.bound(300, mine: true) == 126)
    }

    @Test("A small box never shrinks past being recognisable")
    func floorHolds() {
        #expect(ImagePreview.bound(140, mine: true) == ImagePreview.sentFloor)
        #expect(ImagePreview.bound(60, mine: true) == 60)
    }
}
