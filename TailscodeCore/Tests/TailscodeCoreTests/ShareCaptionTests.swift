import Foundation
import Testing
@testable import TailscodeCore

@Suite("Share caption")
struct ShareCaptionTests {
    private func share(_ analytics: UsageAnalytics) -> AnalyticsShare {
        AnalyticsShare(analytics, now: ShareFixtures.now, calendar: ShareFixtures.calendar)
    }

    @Test("X counts a link as 23, an emoji as 2, and a wide script as 2")
    func xLength() {
        #expect(AnalyticsShare.xLength("hello") == 5)
        #expect(AnalyticsShare.xLength("a https://example.com/a/very/long/path?with=query b") == 2 + 23 + 2)
        #expect(AnalyticsShare.xLength("fire 🔥") == 7)
        #expect(AnalyticsShare.xLength("日本語") == 6)
        #expect(AnalyticsShare.xLength("cafe\u{301}") == 4)
        #expect(AnalyticsShare.xLength("a · b") == 5)
        #expect(AnalyticsShare.xLength("") == 0)
    }

    @Test("A caption fits a post for every account, format and selection, and keeps the headline")
    func fits() {
        for fixture in ShareFixtures.all() {
            let package = share(fixture.analytics)
            for format in ShareFormat.allCases {
                for (name, modules) in ShareTestSupport.allSelections {
                    let selection = ShareSelection(format: format, chosen: [format: modules])
                    let caption = package.caption(selection)
                    #expect(
                        AnalyticsShare.xLength(caption) <= 280,
                        "\(fixture.name)/\(format)/\(name): \(caption)")
                    #expect(caption.hasPrefix(fixture.analytics.headline))
                    #expect(!caption.contains("#"))
                    #expect(!caption.contains("http"))
                }
            }
        }
    }

    @Test("A caption says what the chosen modules say, and not what they do not")
    func followsTheModules() throws {
        let analytics = try #require(ShareFixtures.analytics(named: "rich"))
        let package = share(analytics)
        let some = package.caption(
            ShareSelection(format: .post, chosen: [.post: [.daily, .models]]))
        #expect(some.contains(analytics.windowLabel))
        #expect(some.contains("Peak "))
        #expect(some.contains("Models: "))
        #expect(some.contains(analytics.models[0].label))
        #expect(!some.contains("Tools"))
        #expect(!some.contains("Records"))
        let none = package.caption(ShareSelection(format: .post, chosen: [.post: []]))
        #expect(none.contains(analytics.headline))
        #expect(!none.contains("Models: "))
    }

    @Test("Money in a caption is never left looking like a bill")
    func estimateTravels() throws {
        let priced = try #require(ShareFixtures.analytics(named: "rich"))
        let caption = share(priced).caption(ShareSelection(format: .post))
        #expect(caption.hasSuffix("API-equivalent estimate · not a bill"))
        let local = try #require(ShareFixtures.analytics(named: "localOnly"))
        let free = share(local).caption(ShareSelection(format: .post))
        #expect(!free.contains("not a bill"))
        #expect(free.hasPrefix(local.headline))
    }

    @Test("The picture's description names the headline, the window and every module it shows")
    func altText() throws {
        for fixture in ShareFixtures.all() {
            let package = share(fixture.analytics)
            for format in ShareFormat.allCases {
                let selection = ShareSelection(format: format)
                let alt = package.altText(selection)
                #expect(alt.count <= 1000, "\(fixture.name)/\(format) \(alt.count)")
                #expect(alt.contains(fixture.analytics.headline))
                #expect(alt.contains(fixture.analytics.windowLabel))
                #expect(alt.contains("not a bill"))
                let fit = selection.fit(fixture.analytics)
                if format == .long { continue }
                for module in fit.shown where alt.count < 900 {
                    switch module {
                    case .daily: #expect(alt.contains("Peak "), "\(fixture.name) daily")
                    case .models: #expect(alt.contains("Models: "), "\(fixture.name) models")
                    case .records: #expect(alt.contains("Records: "), "\(fixture.name) records")
                    case .tokens: #expect(alt.contains("Tokens: "), "\(fixture.name) tokens")
                    default: break
                    }
                }
            }
        }
        let rich = try #require(ShareFixtures.analytics(named: "rich"))
        let alt = share(rich).altText(ShareSelection(format: .post))
        #expect(alt.hasPrefix("Tailscode usage card"))
    }
}
