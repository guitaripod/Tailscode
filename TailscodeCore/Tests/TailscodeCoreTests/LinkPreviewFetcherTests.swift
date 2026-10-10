import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import TailscodeCore

/// Serves pages from memory, so the fetcher's whole path — session, delegate, limits, caches — runs
/// without a network. Each test names its own host, so suites running in parallel never see each
/// other's pages.
final class StubPages: URLProtocol, @unchecked Sendable {
    struct Page: Sendable {
        var status = 200
        var type = "text/html; charset=utf-8"
        var body = Data()
        var chunk = 4096
        var failure = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pages: [String: Page] = [:]
    nonisolated(unsafe) private static var hits: [String: Int] = [:]

    static func serve(_ key: String, _ page: Page) {
        lock.lock()
        pages[key] = page
        lock.unlock()
    }

    static func hitCount(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return hits[key, default: 0]
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubPages.self]
        configuration.timeoutIntervalForRequest = 5
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let key = (url.host ?? "") + url.path
        Self.lock.lock()
        let page = Self.pages[key]
        Self.hits[key, default: 0] += 1
        Self.lock.unlock()
        guard let page, !page.failure else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: page.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": page.type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < page.body.count {
            let end = min(page.body.count, offset + page.chunk)
            client?.urlProtocol(self, didLoad: page.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct LinkPreviewFetcherTests {
    private func fetcher(failureMemory: TimeInterval = 600) -> LinkPreviewFetcher {
        LinkPreviewFetcher(
            configuration: StubPages.configuration(), failureMemory: failureMemory,
            reach: { _ in true })
    }

    private func html(_ title: String, icon: String = "/icon.png") -> Data {
        Data(#"<html><head><title>\#(title)</title><link rel="icon" href="\#(icon)"></head></html>"#.utf8)
    }

    @Test func readsTheTitleAndIconAddressOfAPage() async {
        StubPages.serve("read.test/page", .init(body: html("Read me")))
        let metadata = await fetcher().metadata(for: "https://read.test/page")
        #expect(metadata?.title == "Read me")
        #expect(metadata?.faviconURL?.absoluteString == "https://read.test/icon.png")
    }

    @Test func aSettledFaceIsReadableAtOnceWithoutAskingTheActor() async {
        StubPages.serve("face.test/page", .init(body: html("Face value")))
        StubPages.serve("faceless.test/page", .init(failure: true))
        let fetcher = fetcher()
        #expect(fetcher.cachedFace(for: "https://face.test/page") == nil)
        _ = await fetcher.metadata(for: "https://face.test/page")
        #expect(
            fetcher.cachedFace(for: "https://face.test/page")
                == .titled(title: "Face value", host: "face.test"))
        _ = await fetcher.metadata(for: "https://faceless.test/page")
        #expect(
            fetcher.cachedFace(for: "https://faceless.test/page")
                == .hostOnly(host: "faceless.test", path: "faceless.test/page"))
    }

    @Test func aRepeatedAskIsOneRequest() async {
        StubPages.serve("once.test/page", .init(body: html("Once")))
        let fetcher = fetcher()
        for _ in 0..<5 { _ = await fetcher.metadata(for: "https://once.test/page") }
        #expect(StubPages.hitCount("once.test/page") == 1)
        #expect(await fetcher.requestCount == 1)
    }

    @Test func concurrentAsksShareOneRequest() async {
        StubPages.serve("shared.test/page", .init(body: html("Shared")))
        let fetcher = fetcher()
        await withTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask { await fetcher.metadata(for: "https://shared.test/page")?.title }
            }
            for await title in group { #expect(title == "Shared") }
        }
        #expect(StubPages.hitCount("shared.test/page") == 1)
    }

    @Test func aFailedFetchIsRememberedAndNotRetriedSoon() async {
        StubPages.serve("down.test/page", .init(failure: true))
        let fetcher = fetcher()
        #expect(await fetcher.metadata(for: "https://down.test/page") == nil)
        #expect(await fetcher.metadata(for: "https://down.test/page") == nil)
        #expect(StubPages.hitCount("down.test/page") == 1)
    }

    @Test func aFailureIsRetriedOnceItsMemoryHasRunOut() async {
        StubPages.serve("flaky.test/page", .init(failure: true))
        let fetcher = fetcher(failureMemory: 0)
        #expect(await fetcher.metadata(for: "https://flaky.test/page") == nil)
        StubPages.serve("flaky.test/page", .init(body: html("Back")))
        #expect(await fetcher.metadata(for: "https://flaky.test/page")?.title == "Back")
        #expect(StubPages.hitCount("flaky.test/page") == 2)
    }

    @Test func aPageThatDeclaresNothingIsRememberedForGood() async {
        StubPages.serve("bare.test/page", .init(body: Data("<html><body>hi</body></html>".utf8)))
        let fetcher = fetcher(failureMemory: 0)
        #expect(await fetcher.metadata(for: "https://bare.test/page") == nil)
        #expect(await fetcher.metadata(for: "https://bare.test/page") == nil)
        #expect(StubPages.hitCount("bare.test/page") == 1)
    }

    @Test func nonHtmlAndNon200PagesGiveNothing() async {
        StubPages.serve("pdf.test/doc", .init(type: "application/pdf", body: html("Not a page")))
        StubPages.serve("gone.test/page", .init(status: 404, body: html("Gone")))
        let fetcher = fetcher()
        #expect(await fetcher.metadata(for: "https://pdf.test/doc") == nil)
        #expect(await fetcher.metadata(for: "https://gone.test/page") == nil)
    }

    @Test func onlyWebAddressesAreEverFetched() async {
        let fetcher = fetcher()
        #expect(await fetcher.metadata(for: "ftp://files.test/a") == nil)
        #expect(await fetcher.metadata(for: "file:///etc/passwd") == nil)
        #expect(await fetcher.metadata(for: "not a url") == nil)
        #expect(await fetcher.requestCount == 0)
    }

    @Test func aBodyPastTheLimitIsCutAndStillParsed() async {
        var body = html("Early title")
        body.append(Data(repeating: UInt8(ascii: "x"), count: LinkPreviewFetcher.bodyLimit * 4))
        StubPages.serve("big.test/page", .init(body: body, chunk: 16 * 1024))
        #expect(await fetcher().metadata(for: "https://big.test/page")?.title == "Early title")
    }

    @Test func fetchesAndCachesIconBytes() async {
        let icon = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        StubPages.serve("icons.test/page", .init(body: html("Icons")))
        StubPages.serve("icons.test/icon.png", .init(type: "image/png", body: icon))
        let fetcher = fetcher()
        #expect(await fetcher.faviconData(for: "https://icons.test/page") == icon)
        #expect(await fetcher.faviconData(for: "https://icons.test/page") == icon)
        #expect(StubPages.hitCount("icons.test/icon.png") == 1)
    }

    @Test func aPageWithoutADeclaredIconTriesTheRootFavicon() async {
        let icon = Data([1, 2, 3, 4])
        StubPages.serve("root.test/page", .init(body: Data("<title>No icon link</title>".utf8)))
        StubPages.serve("root.test/favicon.ico", .init(type: "image/x-icon", body: icon))
        #expect(await fetcher().faviconData(for: "https://root.test/page") == icon)
    }

    @Test func anOversizeOrNonImageIconIsRefusedAndRemembered() async {
        StubPages.serve("heavy.test/page", .init(body: html("Heavy")))
        StubPages.serve(
            "heavy.test/icon.png",
            .init(
                type: "image/png", body: Data(repeating: 7, count: LinkPreviewFetcher.imageLimit + 10),
                chunk: 64 * 1024))
        StubPages.serve("wrong.test/page", .init(body: html("Wrong")))
        StubPages.serve("wrong.test/icon.png", .init(type: "text/html", body: Data("<html>".utf8)))
        let fetcher = fetcher()
        #expect(await fetcher.faviconData(for: "https://heavy.test/page") == nil)
        #expect(await fetcher.faviconData(for: "https://heavy.test/page") == nil)
        #expect(await fetcher.faviconData(for: "https://wrong.test/page") == nil)
        #expect(StubPages.hitCount("heavy.test/icon.png") == 1)
    }

    @Test func anIconIsNeverAskedForWhenThePageCannotBeRead() async {
        StubPages.serve("dead.test/page", .init(failure: true))
        let fetcher = fetcher()
        #expect(await fetcher.faviconData(for: "https://dead.test/page") == nil)
        #expect(StubPages.hitCount("dead.test/favicon.ico") == 0)
    }
}
