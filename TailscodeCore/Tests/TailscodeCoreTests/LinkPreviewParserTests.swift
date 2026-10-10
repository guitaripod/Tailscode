import Foundation
import Testing

@testable import TailscodeCore

@Suite struct LinkPreviewParserTests {
    private let page = URL(string: "https://example.com/docs/intro")!

    private func parse(_ html: String, at url: URL? = nil) -> LinkPreviewMetadata? {
        LinkPreviewParser.parse(Data(html.utf8), finalURL: url ?? page)
    }

    @Test func openGraphTitleBeatsTheTitleElement() {
        let html = """
            <html><head><title>Plain title</title>
            <meta property="og:title" content="Graph title"></head></html>
            """
        #expect(parse(html)?.title == "Graph title")
    }

    @Test func fallsBackToTheTitleElementThenToAMetaTitle() {
        #expect(parse("<head><title>  A   page \n here </title></head>")?.title == "A page here")
        #expect(
            parse(#"<head><meta name="title" content="Named in meta"></head>"#)?.title
                == "Named in meta")
    }

    @Test func titleIsNilWhenNothingIsDeclared() {
        #expect(parse("<head><meta charset=utf-8></head><body>hi</body>") == nil)
    }

    @Test func decodesEntitiesInOnePass() {
        let html = "<title>Tom &amp; Jerry &#8212; &#x41;&quot;s &lt;b&gt; &amp;lt; &bogus;</title>"
        #expect(parse(html)?.title == "Tom & Jerry — A\"s <b> &lt; &bogus;")
    }

    @Test func stripsTagsInsideATitle() {
        #expect(parse("<title>Hello <b>bold</b> world</title>")?.title == "Hello bold world")
    }

    @Test func tagNamesAndAttributesAreCaseInsensitive() {
        let html = #"<HEAD><META PROPERTY="OG:TITLE" CONTENT="Shouting"><LINK REL="ICON" HREF="/i.png"></HEAD>"#
        let result = parse(html)
        #expect(result?.title == "Shouting")
        #expect(result?.faviconURL?.absoluteString == "https://example.com/i.png")
    }

    @Test func singleQuotedAndBareAttributesParse() {
        let html = "<link rel='icon' href=/bare.png><meta property=og:title content='Quoted'>"
        let result = parse(html)
        #expect(result?.faviconURL?.absoluteString == "https://example.com/bare.png")
        #expect(result?.title == "Quoted")
    }

    @Test func relativeFaviconResolvesAgainstTheFinalURL() {
        let result = parse(#"<link rel="icon" href="../static/fav.png">"#)
        #expect(result?.faviconURL?.absoluteString == "https://example.com/static/fav.png")
        let rooted = parse(#"<link rel="icon" href="/fav.png">"#, at: URL(string: "https://moved.example.org/a/b")!)
        #expect(rooted?.faviconURL?.absoluteString == "https://moved.example.org/fav.png")
    }

    @Test func protocolRelativeFaviconTakesTheFinalURLsScheme() {
        let result = parse(#"<link rel="icon" href="//cdn.example.net/f.ico">"#)
        #expect(result?.faviconURL?.absoluteString == "https://cdn.example.net/f.ico")
        let plain = parse(#"<link rel="icon" href="//cdn.example.net/f.ico">"#, at: URL(string: "http://example.com/")!)
        #expect(plain?.faviconURL?.absoluteString == "http://cdn.example.net/f.ico")
    }

    @Test func touchIconBeatsIconBeatsOtherIconRelations() {
        let html = """
            <link rel="fluid-icon" href="/fluid.png">
            <link rel="shortcut icon" href="/short.ico">
            <link rel="apple-touch-icon" href="/touch.png">
            <link rel="icon" href="/plain.png">
            """
        #expect(parse(html)?.faviconURL?.absoluteString == "https://example.com/touch.png")
        let withoutTouch = """
            <link rel="fluid-icon" href="/fluid.png">
            <link rel="shortcut icon" href="/short.ico">
            """
        #expect(parse(withoutTouch)?.faviconURL?.absoluteString == "https://example.com/short.ico")
        #expect(
            parse(#"<link rel="fluid-icon" href="/fluid.png">"#)?.faviconURL?.absoluteString
                == "https://example.com/fluid.png")
    }

    @Test func firstOfEqualRankWins() {
        let html = #"<link rel="icon" href="/a.png"><link rel="icon" href="/b.png">"#
        #expect(parse(html)?.faviconURL?.absoluteString == "https://example.com/a.png")
    }

    @Test func svgMasksAndDataIconsAreRejected() {
        let html = """
            <link rel="icon" type="image/svg+xml" href="/typed">
            <link rel="icon" href="/vector.svg?v=2">
            <link rel="mask-icon" href="/mask.png">
            <link rel="icon" href="data:image/png;base64,AAAA">
            <link rel="icon" href="ftp://example.com/f.ico">
            """
        #expect(parse(html) == nil)
        let withGood = html + #"<link rel="icon" href="/real.png">"#
        #expect(parse(withGood)?.faviconURL?.absoluteString == "https://example.com/real.png")
    }

    @Test func aTitleInTheBodyIsNotThePagesTitle() {
        let html = "<html><head></head><body><svg><title>Chart</title></svg></body></html>"
        #expect(parse(html) == nil)
    }

    @Test func unclosedTitleAndUnclosedTagsDoNotHang() {
        #expect(parse("<title>never closed") == nil)
        #expect(parse("<meta property=\"og:title\" content=\"cut off") == nil)
        #expect(parse("<link rel=\"icon\" href=\"/x.png\"") == nil)
    }

    @Test func aHugeMalformedHeadIsScannedInBoundedTime() {
        let junk = String(repeating: "<meta ", count: 40_000)
        let html = "<head>" + junk + "<title>Found</title></head>"
        let started = Date()
        let result = parse(html)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(result?.title == "Found")
    }

    @Test func aTitleIsBoundedInLength() {
        let long = String(repeating: "word ", count: 2000)
        let result = parse("<title>\(long)</title>")
        #expect((result?.title?.count ?? 0) <= 2000)
        #expect(result?.title?.hasPrefix("word word") == true)
    }

    @Test func utf8CutInTheMiddleOfACharacterStillReadsAsUTF8() {
        var bytes = Data("<title>Caf\u{00E9} \u{65E5}\u{672C}</title><!-- ".utf8)
        bytes.append(contentsOf: [0xE6, 0x97])
        let result = LinkPreviewParser.parse(bytes, finalURL: page)
        #expect(result?.title == "Caf\u{00E9} \u{65E5}\u{672C}")
    }

    @Test func aDeclaredLatinOneBodyIsReadAsLatinOne() {
        var bytes = Data("<meta charset=\"iso-8859-1\"><title>Caf".utf8)
        bytes.append(0xE9)
        bytes.append(contentsOf: Data("</title>".utf8))
        #expect(LinkPreviewParser.parse(bytes, finalURL: page)?.title == "Caf\u{00E9}")
        var header = Data("<title>Caf".utf8)
        header.append(0xE9)
        header.append(contentsOf: Data("</title>".utf8))
        #expect(
            LinkPreviewParser.parse(header, finalURL: page, charset: "windows-1252")?.title
                == "Caf\u{00E9}")
    }

    @Test func invalidBytesWithNoDeclarationDoNotLoseTheTitle() {
        var bytes = Data("<title>Plain</title>".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE, 0xFD])
        #expect(LinkPreviewParser.parse(bytes, finalURL: page)?.title == "Plain")
    }

    @Test func readsTheCharsetOutOfAContentType() {
        #expect(LinkPreviewParser.charset(ofContentType: "text/html; charset=ISO-8859-1") == "ISO-8859-1")
        #expect(LinkPreviewParser.charset(ofContentType: "text/html; charset=\"utf-8\"; x=y") == "utf-8")
        #expect(LinkPreviewParser.charset(ofContentType: "text/html") == nil)
        #expect(LinkPreviewParser.charset(ofContentType: nil) == nil)
    }

    @Test func anIconWithoutATitleStillMakesAPreview() {
        let result = parse(#"<link rel="icon" href="/only.png">"#)
        #expect(result?.title == nil)
        #expect(result?.faviconURL != nil)
    }
}
