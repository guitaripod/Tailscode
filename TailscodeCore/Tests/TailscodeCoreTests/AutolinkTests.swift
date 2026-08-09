import Testing

@testable import TailscodeCore

@Suite struct AutolinkTests {
    private func only(_ text: String) -> Autolink.Span? {
        let spans = Autolink.spans(in: text)
        return spans.count == 1 ? spans[0] : nil
    }

    @Test func findsABareAddress() {
        let span = only("published at https://claude.ai/code/artifact/8c09 for you")
        #expect(span?.text == "https://claude.ai/code/artifact/8c09")
        #expect(span?.url == "https://claude.ai/code/artifact/8c09")
    }

    @Test func fillsInASchemeForABareHost() {
        let span = only("see www.example.com today")
        #expect(span?.text == "www.example.com")
        #expect(span?.url == "https://www.example.com")
    }

    @Test func handsBackSentencePunctuation() {
        #expect(only("go to https://example.com/a.")?.text == "https://example.com/a")
        #expect(only("go to https://example.com/a, then")?.text == "https://example.com/a")
        #expect(only("(see https://example.com/a)")?.text == "https://example.com/a")
    }

    @Test func keepsABracketTheAddressOpened() {
        #expect(
            only("read https://en.wikipedia.org/wiki/Foo_(bar) now")?.text
                == "https://en.wikipedia.org/wiki/Foo_(bar)")
    }

    @Test func keepsAnEscapedEntityWhole() {
        #expect(
            only("open https://example.com/?a=1&amp;b=2 here")?.text
                == "https://example.com/?a=1&amp;b=2")
    }

    @Test func findsEveryAddressInOrder() {
        let spans = Autolink.spans(in: "https://a.dev and https://b.dev and www.c.dev")
        #expect(spans.map(\.text) == ["https://a.dev", "https://b.dev", "www.c.dev"])
    }

    @Test func refusesWhatIsNotAnAddress() {
        #expect(Autolink.spans(in: "a ratio of 3://4 in the log").isEmpty)
        #expect(Autolink.spans(in: "the www. prefix means nothing here").isEmpty)
        #expect(Autolink.spans(in: "plain prose with no address at all").isEmpty)
        #expect(Autolink.spans(in: "https://localhost:8080/health").isEmpty)
    }

    @Test func doesNotStartInsideAnotherAddress() {
        let spans = Autolink.spans(in: "https://proxy.dev/?to=https://inner.dev/x")
        #expect(spans.count == 1)
        #expect(spans[0].text == "https://proxy.dev/?to=https://inner.dev/x")
    }

    @Test func readsAPublishedPage() {
        let link = ArtifactLink.parse("https://claude.ai/code/artifact/8c099629-2bd0-4fda-8144-265a")
        #expect(link?.id == "8c099629-2bd0-4fda-8144-265a")
        #expect(link?.shortID == "8c099629")
        #expect(link?.label == "Artifact · 8c099629")
        #expect(ArtifactLink.parse("https://claude.ai/chat/8c099629") == nil)
        #expect(ArtifactLink.parse("https://example.com/code/artifact/8c099629") == nil)
    }
}
