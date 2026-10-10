import Foundation
import Testing

@testable import TailscodeCore

@Suite struct LinkRailGatheringTests {
    @Test func gatheringHeldCandidatesMatchesGatheringFromText() {
        let run = ["see https://a.example/one and https://b.example", "again https://a.example/one then http://c.example/x"]
        let held = run.map { LinkEmbedPolicy.candidates(in: $0) }
        #expect(
            LinkRailPolicy.addresses(gathering: held, enabled: true, settled: true)
                == LinkRailPolicy.addresses(inRun: run, enabled: true, settled: true))
        #expect(LinkRailPolicy.addresses(gathering: held, enabled: true, settled: false).isEmpty)
        #expect(LinkRailPolicy.addresses(gathering: held, enabled: false, settled: true).isEmpty)
    }

    @Test func gatheringStopsAtTheLimit() {
        let many = [(1...20).map { "https://h\($0).example" }]
        #expect(LinkRailPolicy.addresses(gathering: many, enabled: true, settled: true).count == LinkRailPolicy.limit)
    }
}
