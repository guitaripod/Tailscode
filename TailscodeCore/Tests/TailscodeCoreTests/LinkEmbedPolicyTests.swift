import Foundation
import Testing

@testable import TailscodeCore

@Suite struct LinkEmbedPolicyTests {
    @Test func picksHttpAddressesInTheOrderTheyWereWritten() {
        let text = "see https://a.example/one and http://b.example/two then https://c.example"
        #expect(
            LinkEmbedPolicy.urls(in: text, enabled: true)
                == ["https://a.example/one", "http://b.example/two", "https://c.example"])
    }

    @Test func eachAddressOnceAndAtMostThree() {
        let text = """
            https://a.example https://a.example https://b.example https://c.example \
            https://d.example https://e.example
            """
        #expect(
            LinkEmbedPolicy.urls(in: text, enabled: true)
                == ["https://a.example", "https://b.example", "https://c.example"])
    }

    @Test func aBareWwwHostGetsAnHttpsCard() {
        #expect(LinkEmbedPolicy.urls(in: "try www.example.com today", enabled: true) == ["https://www.example.com"])
    }

    @Test func offMeansNoCardsAndProseWithoutAddressesMeansNone() {
        #expect(LinkEmbedPolicy.urls(in: "https://a.example", enabled: false).isEmpty)
        #expect(LinkEmbedPolicy.urls(in: "nothing to see here", enabled: true).isEmpty)
    }

    @Test func aStreamedAddressIsOneCardWhoseContentGrows() {
        let growing = ["see http://exa", "see http://example.com/pa", "see http://example.com/path."]
        let seen = growing.map { LinkEmbedPolicy.urls(in: $0, enabled: true) }
        #expect(seen.allSatisfy { $0.count <= 1 })
        #expect(seen.last == ["http://example.com/path"])
    }

    @Test func anAddressRunningToTheEndOfAGrowingTextEarnsNoCardYet() {
        #expect(LinkEmbedPolicy.urls(in: "see https://a.example/pa", enabled: true, growing: true).isEmpty)
        #expect(
            LinkEmbedPolicy.urls(in: "see https://a.example/pa\n", enabled: true, growing: true)
                == ["https://a.example/pa"])
        #expect(
            LinkEmbedPolicy.urls(in: "https://a.example and https://b.example", enabled: true, growing: true)
                == ["https://a.example"])
        #expect(
            LinkEmbedPolicy.urls(in: "see https://a.example/pa", enabled: true, growing: false)
                == ["https://a.example/pa"])
    }

    @Test func defaultFollowsTheSetting() {
        let key = LinkEmbedsSetting.defaultsKey
        let kept = UserDefaults.standard.object(forKey: key)
        defer {
            if let kept { UserDefaults.standard.set(kept, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(LinkEmbedsSetting.isEnabled)
        #expect(LinkEmbedPolicy.urls(in: "https://a.example").count == 1)
        UserDefaults.standard.set(false, forKey: key)
        #expect(LinkEmbedPolicy.urls(in: "https://a.example").isEmpty)
    }

    @Test func debounceIsSevenHundredMilliseconds() {
        #expect(LinkEmbedPolicy.debounce == .milliseconds(700))
        #expect(LinkEmbedPolicy.limit == 3)
    }

    @Test func settleSaysYesOnlyWhileTheAddressIsStillWanted() async {
        #expect(await LinkEmbedPolicy.settle(debounce: .milliseconds(5)) { true })
        #expect(await LinkEmbedPolicy.settle(debounce: .milliseconds(5)) { false } == false)
    }

    @Test func settleSaysNoWhenCancelledDuringTheWait() async {
        let task = Task { await LinkEmbedPolicy.settle(debounce: .seconds(30)) { true } }
        task.cancel()
        #expect(await task.value == false)
    }

    @Test func faceBeforeAndAfterTheFetch() throws {
        let url = try #require(URL(string: "https://docs.example.com/guide/start/"))
        let waiting = LinkCardFace.placeholder(for: url)
        #expect(waiting.headline == "docs.example.com")
        #expect(waiting.caption == "docs.example.com/guide/start")
        #expect(waiting.headlineIsQuiet)

        let titled = LinkCardFace.settled(
            for: url, metadata: LinkPreviewMetadata(title: "Getting started", faviconURL: nil))
        #expect(titled == .titled(title: "Getting started", host: "docs.example.com"))
        #expect(titled.headline == "Getting started")
        #expect(titled.caption == "docs.example.com")
        #expect(!titled.headlineIsQuiet)
        #expect(titled.spoken == "Getting started · docs.example.com")
    }

    @Test func aFailedOrTitlelessFetchLeavesTheHostAlone() throws {
        let url = try #require(URL(string: "https://example.com"))
        for metadata in [nil, LinkPreviewMetadata(title: nil, faviconURL: nil), LinkPreviewMetadata(title: "  \n ", faviconURL: nil)] {
            let face = LinkCardFace.settled(for: url, metadata: metadata)
            #expect(face == .hostOnly(host: "example.com", path: "example.com"))
            #expect(face.headline == "example.com")
            #expect(!face.caption.isEmpty)
        }
    }
}
