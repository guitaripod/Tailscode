import CodingAgentKit
import Foundation
import Testing
@testable import TailscodeCore

@Suite("Ollama Cloud usage")
struct OllamaCloudTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private var reading: OllamaCloud.Reading {
        OllamaCloud.Reading(
            session: OllamaCloud.Bucket(key: "session", label: "Session", usage: 0.32),
            weekly: OllamaCloud.Bucket(key: "weekly", label: "Weekly", usage: 0.87),
            cost: "4.21")
    }

    @Test("The endpoint's shape decodes: nested buckets, absent fields reading as zero")
    func decode() throws {
        let json = """
        {"activity":{"cost":"4.21","period":{"type":"last_4_weeks","starting_at":"2026-07-27T00:00:00Z","ending_at":"2026-08-19T12:43:30Z"},"models":[{"name":"gpt-oss:120b","request_count":12}]},"limits":{"session":{"usage":0.32,"models":[]},"weekly":{"usage":0.87,"models":[{"name":"gpt-oss:120b","request_count":104}]}}}
        """
        let decoded = try OllamaCloud.decode(Data(json.utf8))
        #expect(decoded.session.usage == 0.32)
        #expect(decoded.weekly.usage == 0.87)
        #expect(decoded.cost == "4.21")

        let bare = try OllamaCloud.decode(Data("{}".utf8))
        #expect(bare.session.usage == 0)
        #expect(bare.weekly.usage == 0)
        #expect(bare.cost.isEmpty)
    }

    @Test("The snapshot carries both windows as account-wide gauges with no invented reset")
    func snapshot() {
        let quota = OllamaCloud.snapshot(for: reading)
        #expect(quota.providerName == "Ollama Cloud")
        #expect(quota.live)
        #expect(quota.gauges.map(\.key) == ["session", "weekly"])
        #expect(quota.gauges.map(\.fraction) == [0.32, 0.87])
        #expect(quota.gauges.allSatisfy { $0.resetsAt == nil && !$0.trustedReset })
        #expect(quota.details.map(\.value) == ["$4.21"])
    }

    @Test("A missing cost rides as no detail rather than an empty row")
    func costless() {
        let quota = OllamaCloud.snapshot(
            for: OllamaCloud.Reading(
                session: reading.session, weekly: reading.weekly, cost: ""))
        #expect(quota.details.isEmpty)
    }

    @Test("The brand answers for the name the snapshot writes and nothing else claims it")
    func brand() {
        #expect(ProviderBrand.slug("Ollama Cloud") == "ollama-cloud")
        #expect(ProviderBrand.brand("Ollama Cloud") == "ollama-cloud")
        #expect(ProviderBrand.short("Ollama Cloud") == "Ollama")
        #expect(ProviderIdentity.slug("ollama-cloud") == "ollama-cloud")
 #expect(ProviderIdentity.slug("ollama") == nil)
    }

    @Test("The wall bills only the ollama-cloud door: the local server and every other house stay outside it")
    func billing() {
        let quota = OllamaCloud.snapshot(for: reading)
        let cloud = ModelSelection(providerID: "ollama-cloud", modelID: "gpt-oss:120b")
        let local = ModelSelection(providerID: "ollama", modelID: "qwen3:latest")
        let claude = ModelSelection(providerID: "anthropic", modelID: "claude-opus-4-8")
        #expect(QuotaBinding.bills(quota, selection: cloud, model: cloud.modelID))
        #expect(!QuotaBinding.bills(quota, selection: local, model: local.modelID))
        #expect(!QuotaBinding.bills(quota, selection: claude, model: claude.modelID))
    }

    @Test("The windows are account-wide: every cloud model hears them, and a full window is a wall")
    func scope() {
        let quota = OllamaCloud.snapshot(
            for: OllamaCloud.Reading(
                session: OllamaCloud.Bucket(key: "session", label: "Session", usage: 0.32),
                weekly: OllamaCloud.Bucket(key: "weekly", label: "Weekly", usage: 1.0),
                cost: "4.21"))
        for gauge in quota.gauges {
            #expect(QuotaBinding.scope(of: gauge) == .account)
        }
        let walls = QuotaSurface.walls(in: [quota], model: "gpt-oss:120b", named: "gpt-oss:120b", now: now)
        #expect(walls.count == 1)
        #expect(walls.first?.provider == "Ollama Cloud")
        #expect(walls.first?.isAccountWide == true)
    }

    @Test("A reading under the walls never exhausts anything")
    func fresh() {
        let quota = OllamaCloud.snapshot(
            for: OllamaCloud.Reading(
                session: OllamaCloud.Bucket(key: "session", label: "Session", usage: 0.1),
                weekly: OllamaCloud.Bucket(key: "weekly", label: "Weekly", usage: 0.2),
                cost: "0.00"))
        #expect(QuotaSurface.walls(in: [quota], model: "gpt-oss:120b", now: now).isEmpty)
    }

    @Test("No key means absence: refresh clears what it had and answers nil")
    func keyless() async {
        OllamaCloud.forgetLastFetch()
        let answer = await OllamaCloud.refresh(key: nil)
        #expect(answer == nil)
        #expect(OllamaCloud.cached == nil)
    }
}