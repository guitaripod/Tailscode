import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Quota binding")
struct QuotaBindingTests {
    private func gauge(_ label: String, _ fraction: Double = 1.0) -> UsageQuota.Gauge {
        UsageQuota.Gauge(
            key: label.lowercased(), label: label, fraction: fraction,
            resetsAt: Date().addingTimeInterval(7_200), trustedReset: true)
    }

    private func quota(_ provider: String, _ gauges: [UsageQuota.Gauge]) -> UsageQuota {
        UsageQuota(
            providerName: provider, subtitle: "", source: "test", live: true, gauges: gauges,
            details: [])
    }

    @Test("A window that names no model is the account's")
    func accountWindows() {
        for label in [
            "5-hour session", "Weekly · all models", "Extra usage credits", "Weekly credits",
            "Monthly spend", "Pay-as-you-go", "5-hour window", "Weekly", "Weekly · scoped",
        ] {
            #expect(QuotaBinding.scope(of: gauge(label)) == .account, "\(label) is the account's")
        }
    }

    @Test("A scoped window is read for the model it names")
    func scopedWindows() {
        #expect(QuotaBinding.scope(of: gauge("Weekly · Opus 4.1")) == .model(["opus"]))
        #expect(QuotaBinding.scope(of: gauge("Weekly · Claude Opus 4.5")) == .model(["opus"]))
        #expect(QuotaBinding.scope(of: gauge("Grok Build")) == .model(["grok", "build"]))
    }

    @Test("A scoped window governs its own family and nothing else")
    func governs() {
        let opus = QuotaBinding.scope(of: gauge("Weekly · Opus 4.1"))
        #expect(QuotaBinding.governs(opus, model: "claude-opus-4-5-20260101"))
        #expect(QuotaBinding.governs(opus, model: "opus"))
        #expect(QuotaBinding.governs(opus, model: "anthropic/claude-opus-4-1"))
        #expect(!QuotaBinding.governs(opus, model: "claude-sonnet-4-5"))
        #expect(!QuotaBinding.governs(opus, model: "claude-fable-5"))
        #expect(!QuotaBinding.governs(opus, model: nil))
        #expect(QuotaBinding.governs(opus, model: "", named: "Claude Opus 4.5"))
    }

    @Test("An account window governs every model, including one nobody named")
    func accountGoverns() {
        let session = QuotaBinding.scope(of: gauge("5-hour session"))
        #expect(QuotaBinding.governs(session, model: "claude-sonnet-4-5"))
        #expect(QuotaBinding.governs(session, model: nil))
    }

    @Test("The chat notice speaks only for the wall in front of its own model")
    func notice() {
        let quotas = [
            quota(
                "Claude",
                [
                    gauge("Weekly · Opus 4.1", 1.0),
                    gauge("5-hour session", 0.4),
                    gauge("Weekly · all models", 0.8),
                ])
        ]
        #expect(QuotaSurface.hottestExhausted(in: quotas, model: "claude-sonnet-4-5") == nil)
        #expect(QuotaSurface.hottestExhausted(in: quotas, model: nil) == nil)
        let onOpus = QuotaSurface.hottestExhausted(in: quotas, model: "claude-opus-4-5")
        #expect(onOpus?.window == "Weekly · Opus 4.1")
        #expect(onOpus?.isAccountWide == false)
    }

    @Test("An account wall still stops a chat on any model")
    func accountNotice() {
        let quotas = [quota("Claude", [gauge("5-hour session", 1.0)])]
        let onSonnet = QuotaSurface.hottestExhausted(in: quotas, model: "claude-sonnet-4-5")
        #expect(onSonnet?.window == "5-hour session")
        #expect(onSonnet?.isAccountWide == true)
        #expect(QuotaSurface.hottestExhausted(in: quotas, model: nil) != nil)
    }

    @Test("A failed turn's own wall is reported whatever the chat is on")
    func failureIgnoresScope() {
        let e = QuotaSurface.resolve(
            failureMessage: "claude usage limit reached", quotas: [], model: "gpt-5.6")
        #expect(e?.provider == "Claude")
        #expect(e?.source == .failure)
    }

    @Test("A row note says what ran out and when it comes back")
    func rowNote() {
        let scoped = QuotaExhaustion(
            provider: "Claude", window: "Weekly · Opus", fraction: 1,
            resetsAt: Date().addingTimeInterval(7_200), trustedReset: true, source: .gauge,
            scope: .model(["opus"]))
        let note = QuotaSurface.rowNote(scoped)
        #expect(note.hasPrefix(Localized.text("Used up")))
        #expect(note.contains("1h "))

        let account = QuotaExhaustion(
            provider: "Claude", window: "5-hour session", fraction: 1, resetsAt: nil,
            trustedReset: false, source: .gauge, scope: .account)
        #expect(QuotaSurface.rowNote(account).contains("5-hour session"))
    }

    @Test("The chooser marks the spent models and leaves the rest alone")
    func chooserWalls() {
        let catalog = [
            ModelInfo(id: "claude-opus-4-5", name: "Claude Opus 4.5", providerID: "anthropic"),
            ModelInfo(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", providerID: "anthropic"),
            ModelInfo(id: "claude-fable-5", name: "Claude Fable 5", providerID: "anthropic"),
        ]
        let chooser = ModelChooser(
            models: catalog, selected: nil, recents: [],
            quotas: [quota("Claude", [gauge("Weekly · Opus 4.1", 1.0)])])
        let byTitle = Dictionary(
            uniqueKeysWithValues: chooser.rows.filter { !$0.isAuto }.map { ($0.title, $0) })
        #expect(byTitle["Claude Opus 4.5"]?.wall != nil)
        #expect(byTitle["Claude Sonnet 4.5"]?.wall == nil)
        #expect(byTitle["Claude Fable 5"]?.wall == nil)
        #expect(chooser.summary.contains(Localized.text("%@ used up", "1")))
        #expect(
            chooser.rows.firstIndex { $0.title == "Claude Opus 4.5" }
                == chooser.rows.count - 1,
            "the spent model sits under the two that can still answer")
    }

    @Test("A model on another machine is never marked from this one's account")
    func elsewhereUnmarked() {
        let here = ModelSource(
            profileID: "studio", name: "studio", backend: .claudeCode,
            models: [ModelInfo(id: "opus", name: "Opus", providerID: "anthropic")],
            isCurrent: true, allowsServerDefault: true, acceptsAnyModelID: false)
        let there = ModelSource(
            profileID: "homelab", name: "homelab", backend: .openCode,
            models: [ModelInfo(id: "claude-opus-4-5", name: "Opus 4.5", providerID: "anthropic")],
            isCurrent: false, allowsServerDefault: true, acceptsAnyModelID: false)
        let chooser = ModelChooser(
            sources: [here, there], selected: nil, recents: [],
            quotas: [quota("Claude", [gauge("Weekly · Opus 4.1", 1.0)])])
        let mine = chooser.rows.first { !$0.isAuto && !$0.isElsewhere }
        let theirs = chooser.rows.first { $0.isElsewhere }
        #expect(mine?.wall != nil)
        #expect(theirs?.wall == nil)
    }

    @Test("The chooser's own selftest passes")
    func selftest() {
        #expect(ModelChooserCheck.run().isEmpty)
    }
}
