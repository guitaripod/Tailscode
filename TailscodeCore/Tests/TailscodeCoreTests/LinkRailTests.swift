import Foundation
import Testing

@testable import TailscodeCore

@Suite struct LinkRailTests {
    private func addresses(_ segments: [String], settled: Bool = true) -> [String] {
        LinkRailPolicy.addresses(inRun: segments, enabled: true, settled: settled)
    }

    @Test func gathersAcrossSegmentsInOrderWithoutRepeats() {
        let run = ["see https://a.example/one and https://b.example", "again https://a.example/one then http://c.example/x"]
        #expect(addresses(run) == ["https://a.example/one", "https://b.example", "http://c.example/x"])
    }

    @Test func capsAtTwelveAndOnlyHttp() {
        let many = (1...20).map { "https://h\($0).example" }.joined(separator: " ")
        #expect(addresses([many]).count == 12)
        #expect(addresses([many]).last == "https://h12.example")
        #expect(addresses(["mailto:me@example.com ftp://files.example/x https://ok.example"]) == ["https://ok.example"])
        #expect(LinkRailPolicy.limit == 12)
    }

    @Test func aBareWwwHostCounts() {
        #expect(addresses(["try www.example.com today"]) == ["https://www.example.com"])
    }

    @Test func emptyUntilTheRunHasSettledAndWhenOff() {
        #expect(addresses(["https://a.example"], settled: false).isEmpty)
        #expect(LinkRailPolicy.addresses(inRun: ["https://a.example"], enabled: false, settled: true).isEmpty)
        #expect(addresses([]).isEmpty)
        #expect(addresses(["nothing to see"]).isEmpty)
    }

    @Test func theGrowingAddressRuleSurvivesInTheSegmentExtraction() {
        #expect(LinkEmbedPolicy.candidates(in: "see https://a.example/pa", growing: true).isEmpty)
        #expect(LinkEmbedPolicy.candidates(in: "see https://a.example/pa\n", growing: true) == ["https://a.example/pa"])
        #expect(LinkEmbedPolicy.urls(in: "https://a https://b.example https://c.example https://d.example https://e.example", enabled: true).count == 3)
    }

    @Test func aRunSettlesWhenFurnitureFollowsOrTheTurnEnds() {
        #expect(LinkRailPolicy.isSettled(lastRowIsLive: false, followedByFurniture: true, turnIsOpen: true))
        #expect(LinkRailPolicy.isSettled(lastRowIsLive: false, followedByFurniture: false, turnIsOpen: false))
        #expect(!LinkRailPolicy.isSettled(lastRowIsLive: false, followedByFurniture: false, turnIsOpen: true))
        #expect(!LinkRailPolicy.isSettled(lastRowIsLive: true, followedByFurniture: false, turnIsOpen: true))
        #expect(!LinkRailPolicy.isSettled(lastRowIsLive: true, followedByFurniture: true, turnIsOpen: false))
    }

    private let eight = (1...8).map { "https://h\($0).example/p" }

    @Test func anUnopenedRailPlansThreeAndAnOpenedOnePlansAll() {
        #expect(LinkRailPolicy.fetchPlan(for: eight, opened: false) == Array(eight.prefix(3)))
        #expect(LinkRailPolicy.fetchPlan(for: eight, opened: true) == eight)
        #expect(LinkRailPolicy.fetchPlan(for: Array(eight.prefix(2)), opened: false) == Array(eight.prefix(2)))
    }

    @Test func aReaskPlansNothingNew() {
        var fetches = LinkRailFetches()
        #expect(fetches.claim(for: eight, opened: false) == Array(eight.prefix(3)))
        #expect(fetches.claim(for: eight, opened: false).isEmpty)
        #expect(fetches.claim(for: eight, opened: true) == Array(eight.dropFirst(3)))
        #expect(fetches.claim(for: eight, opened: true).isEmpty)
        #expect(fetches.fetched.count == 8)
    }

    @Test func oneAddressReadsAsItsTitleOnceKnown() {
        let waiting = LinkRailReading.placeholder(for: ["https://docs.example.com/guide"])
        #expect(waiting.singleTitle == "docs.example.com")
        #expect(waiting.hostsLine == "docs.example.com")
        #expect(waiting.moreCount == 0)
        #expect(waiting.moreLabel == nil)
        let titled = LinkRailReading.settled(
            for: ["https://docs.example.com/guide"],
            metadata: ["https://docs.example.com/guide": LinkPreviewMetadata(title: "Getting started", faviconURL: nil)])
        #expect(titled.singleTitle == "Getting started")
        #expect(titled.spoken(expanded: false) == "Link: Getting started, collapsed")
        #expect(titled.spoken(expanded: true) == "Link: Getting started, expanded")
    }

    @Test func twoAddressesNameBothHostsAndHaveNoTitle() {
        let rail = LinkRailReading.placeholder(for: ["https://github.com/a", "https://docs.github.com/b"])
        #expect(rail.count == 2)
        #expect(rail.singleTitle == nil)
        #expect(rail.hostsLine == "github.com · docs.github.com")
        #expect(rail.moreCount == 0)
        #expect(rail.spoken(expanded: false) == "Links (2): github.com, docs.github.com, collapsed")
    }

    @Test func threeAddressesFillTheStackAndDedupTheirHosts() {
        let rail = LinkRailReading.placeholder(for: [
            "https://github.com/a", "https://github.com/b", "https://datatracker.ietf.org/doc/rfc9110",
        ])
        #expect(rail.stack.count == 3)
        #expect(rail.hostsLine == "github.com · datatracker.ietf.org")
        #expect(rail.moreCount == 0)
        #expect(rail.spoken(expanded: true) == "Links (3): github.com and 1 more, expanded")
    }

    @Test func fiveAddressesCountTheRest() {
        let urls = ["https://a.example", "https://b.example", "https://c.example", "https://d.example", "https://e.example"]
        let rail = LinkRailReading.placeholder(for: urls)
        #expect(rail.stack.map(\.url) == Array(urls.prefix(3)))
        #expect(rail.hostsLine == "a.example · b.example · c.example")
        #expect(rail.moreCount == 2)
        #expect(rail.moreLabel == "+2")
        #expect(rail.spoken(expanded: false) == "Links (5): a.example, b.example and 3 more, collapsed")
        #expect(rail.copyAllText == urls.joined(separator: "\n"))
        #expect(rail.rowFaces.count == 5)
    }

    @Test func aLandedFetchChangesOnlyItsOwnRow() throws {
        let urls = ["https://a.example/x", "https://b.example/y"]
        let rail = LinkRailReading.placeholder(for: urls)
        let url = try #require(URL(string: urls[1]))
        let face = LinkCardFace.settled(for: url, metadata: LinkPreviewMetadata(title: "B page", faviconURL: nil))
        let after = rail.replacing(face, for: urls[1])
        #expect(after.items[0] == rail.items[0])
        #expect(after.items[1].face == .titled(title: "B page", host: "b.example"))
        #expect(after.count == rail.count)
    }

    @Test func aFailedFetchLeavesTheHostAndAnUnaskedOneKeepsItsPlaceholder() {
        let urls = ["https://a.example/x", "https://b.example/y"]
        let failed: [String: LinkPreviewMetadata?] = [urls[0]: nil]
        let rail = LinkRailReading.settled(for: urls, metadata: failed)
        #expect(rail.items[0].face == .hostOnly(host: "a.example", path: "a.example/x"))
        #expect(rail.items[1].face == .placeholder(host: "b.example", path: "b.example/y"))
    }

    @Test func plateOpensUpwardWhenThereIsLessRoomBelowThanItIsTall() {
        #expect(LinkRailPlate.opensUpward(roomBelow: 200, plateHeight: 288))
        #expect(!LinkRailPlate.opensUpward(roomBelow: 288, plateHeight: 288))
        #expect(!LinkRailPlate.opensUpward(roomBelow: 600, plateHeight: 288))
    }

    @Test func plateHeightIsRowsUpToTheVisibleMaximum() {
        let pointer = ChatMetrics.metrics(for: .compact, input: .pointer)
        #expect(LinkRailPlate.plateHeight(rows: 3, metrics: pointer) == 108)
        #expect(LinkRailPlate.plateHeight(rows: 8, metrics: pointer) == 288)
        #expect(LinkRailPlate.plateHeight(rows: 12, metrics: pointer) == 288)
        #expect(LinkRailPlate.plateHeight(rows: 0, metrics: pointer) == 0)
        let touch = ChatMetrics.metrics(for: .compact, input: .touch)
        #expect(LinkRailPlate.plateHeight(rows: 2, metrics: touch) == 88)
    }

    @Test func cardFaceKeepsItsBehaviourAndNamesItsHost() throws {
        let url = try #require(URL(string: "https://docs.example.com/guide/start/"))
        let waiting = LinkCardFace.placeholder(for: url)
        #expect(waiting.headline == "docs.example.com")
        #expect(waiting.caption == "docs.example.com/guide/start")
        #expect(waiting.host == "docs.example.com")
        let titled = LinkCardFace.settled(for: url, metadata: LinkPreviewMetadata(title: "Getting started", faviconURL: nil))
        #expect(titled.spoken == "Getting started · docs.example.com")
        #expect(titled.host == "docs.example.com")
    }
}
