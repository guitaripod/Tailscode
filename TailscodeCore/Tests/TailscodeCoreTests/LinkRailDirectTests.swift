import Foundation
import Testing

@testable import TailscodeCore

@Suite struct LinkRailDirectTests {
    @Test func aLoneAddressOpensDirectlyAndTwoOrMoreDoNot() {
        let one = LinkRailReading.placeholder(for: ["https://a.example/x"])
        let two = LinkRailReading.placeholder(for: ["https://a.example/x", "https://b.example/y"])
        let none = LinkRailReading(items: [])
        #expect(one.opensDirectly)
        #expect(!two.opensDirectly)
        #expect(!none.opensDirectly)
    }

    @Test func aLoneAddressIsReadAsALinkWhateverItsState() {
        let waiting = LinkRailReading.placeholder(for: ["https://a.example/x"])
        #expect(waiting.spoken(expanded: false) == "a.example, link")
        #expect(waiting.spoken(expanded: true) == "a.example, link")
        let titled = LinkRailReading.settled(
            for: ["https://a.example/x"],
            metadata: ["https://a.example/x": LinkPreviewMetadata(title: "A page", faviconURL: nil)])
        #expect(titled.spoken(expanded: false) == "A page, link")
    }

    @Test func moreThanOneAddressIsStillADisclosure() {
        let rail = LinkRailReading.placeholder(for: ["https://a.example", "https://b.example"])
        #expect(rail.spoken(expanded: false).hasSuffix("collapsed"))
        #expect(rail.spoken(expanded: true).hasSuffix("expanded"))
    }
}
