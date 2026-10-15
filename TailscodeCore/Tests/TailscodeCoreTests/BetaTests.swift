import Foundation
import Testing

@testable import TailscodeCore

@Suite("Beta")
struct BetaTests {
    private func version(_ text: String) -> SoftwareVersion { SoftwareVersion(text)! }

    private func card(changes: [BetaChange]) -> BetaCard {
        BetaCard(
            name: "Thing", symbol: "star", glyph: "*", title: "Thing is in beta", lead: "Lead.",
            paragraphs: ["One."], works: ["Works"], rough: ["Rough"], changes: changes, reportName: "its log")
    }

    private func suite() -> UserDefaults {
        let name = "BetaTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Every feature in beta says what it is, why, what is solid and what is rough")
    func everyFeatureIsComplete() {
        for feature in BetaFeature.allCases {
            let card = feature.card
            #expect(!card.name.isEmpty)
            #expect(!card.symbol.isEmpty)
            #expect(!card.glyph.isEmpty)
            #expect(!card.title.isEmpty)
            #expect(!card.lead.isEmpty)
            #expect(!card.paragraphs.isEmpty)
            #expect(!card.works.isEmpty)
            #expect(!card.rough.isEmpty)
            #expect(!card.reportName.isEmpty)
            #expect(card.spoken.hasPrefix(BetaWords.label))
            #expect(card.spoken.contains(card.name))
            #expect(card.paragraphs.allSatisfy { !$0.isEmpty })
        }
    }

    @Test("The catalog holds delegate and the call")
    func catalogCases() {
        #expect(BetaFeature.allCases == [.delegate, .voiceCall])
        #expect(BetaFeature.voiceCall.card.title == "Calls are in beta")
        #expect(BetaFeature.voiceCall.card.paragraphs.count == 3)
        #expect(BetaFeature.voiceCall.card.rough.count == 5)
    }

    @Test("A mark is unseen until the card is opened, changed when something newer was said, settled otherwise")
    func freshnessTransitions() {
        let plain = card(changes: [])
        let changing = card(changes: [
            BetaChange(since: version("1.70"), line: "Newer"),
            BetaChange(since: version("1.65"), line: "Older"),
        ])
        #expect(BetaFreshness.read(seen: nil, current: version("1.70"), card: plain) == .unseen)
        #expect(BetaFreshness.read(seen: nil, current: version("1.70"), card: changing) == .unseen)
        #expect(BetaFreshness.read(seen: version("1.60"), current: version("1.70"), card: plain) == .settled)
        #expect(BetaFreshness.read(seen: version("1.60"), current: version("1.70"), card: changing) == .changed)
        #expect(BetaFreshness.read(seen: version("1.66"), current: version("1.70"), card: changing) == .changed)
        #expect(BetaFreshness.read(seen: version("1.70"), current: version("1.70"), card: changing) == .settled)
        #expect(BetaFreshness.read(seen: version("1.80"), current: version("1.80"), card: changing) == .settled)
        #expect(BetaFreshness.read(seen: version("1.60"), current: version("1.68"), card: changing) == .settled)
        #expect(BetaFreshness.unseen.isFresh && BetaFreshness.changed.isFresh && !BetaFreshness.settled.isFresh)
    }

    @Test("The sheen is nothing under reduced motion and outside its single pass")
    func sheenBounds() {
        #expect(BetaSheen.progress(elapsed: 0.5, reducedMotion: true) == nil)
        #expect(BetaSheen.progress(elapsed: -0.01, reducedMotion: false) == nil)
        #expect(BetaSheen.progress(elapsed: BetaSheen.duration + 0.01, reducedMotion: false) == nil)
        #expect(BetaSheen.progress(elapsed: 0, reducedMotion: false) == 0)
    }

    @Test("The sheen only moves right and ends at the far edge")
    func sheenTravels() throws {
        var last = -1.0
        for step in 0...140 {
            let elapsed = Double(step) / 100
            let value = try #require(BetaSheen.progress(elapsed: elapsed, reducedMotion: false))
            #expect(value >= last)
            #expect((0.0...1.0).contains(value))
            last = value
        }
        let end = try #require(BetaSheen.progress(elapsed: BetaSheen.duration, reducedMotion: false))
        #expect(abs(end - 1) < 1e-9)
        let middle = try #require(BetaSheen.progress(elapsed: BetaSheen.duration / 2, reducedMotion: false))
        #expect(abs(middle - 0.5) < 1e-9)
    }

    @Test("The report is a stable block that leads with what it is and holds no clock of its own")
    func reportText() {
        let report = BetaReport.compose(
            feature: .voiceCall, app: "Tailscode 1.70 (200)", system: "iOS 26.1",
            lines: ["Gateway: arch 0.1.0", "Seen at: 2026-10-16T10:00:00Z"])
        #expect(
            report
                == """
                Tailscode beta report
                Feature: voiceCall
                App: Tailscode 1.70 (200)
                System: iOS 26.1
                Gateway: arch 0.1.0
                Seen at: 2026-10-16T10:00:00Z
                """)
        let bare = BetaReport.compose(feature: .delegate, app: "a", system: "s", lines: [])
        #expect(bare.components(separatedBy: "\n") == ["Tailscode beta report", "Feature: delegate", "App: a", "System: s"])
    }

    @Test("Opening a card is remembered per feature and settles the mark")
    func storeRoundTrip() {
        let defaults = suite()
        #expect(BetaSeenStore.seen(.delegate, defaults: defaults) == nil)
        #expect(BetaSeenStore.freshness(.delegate, current: version("1.70"), defaults: defaults) == .unseen)
        BetaSeenStore.markSeen(.delegate, at: version("1.70"), defaults: defaults)
        #expect(BetaSeenStore.seen(.delegate, defaults: defaults)?.raw == "1.70")
        #expect(BetaSeenStore.seen(.voiceCall, defaults: defaults) == nil)
        #expect(BetaSeenStore.freshness(.delegate, current: version("1.70"), defaults: defaults) == .settled)
        #expect(BetaSeenStore.freshness(.voiceCall, current: version("1.70"), defaults: defaults) == .unseen)
        #expect(BetaSeenStore.key(.voiceCall) == "tailscode.beta.seen.voiceCall")
    }

    @Test("Seen keys are captured by prefix, one per feature")
    func keysShareOnePrefix() {
        for feature in BetaFeature.allCases {
            #expect(BetaSeenStore.key(feature).hasPrefix(BetaSeenStore.keyPrefix))
        }
        #expect(Set(BetaFeature.allCases.map(BetaSeenStore.key)).count == BetaFeature.allCases.count)
    }
}
