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

    @Test("A failed turn's own wall is reported for any model its house bills, and for none it does not")
    func failureFollowsTheHouse() {
        let unplaced = QuotaSurface.resolve(
            failureMessage: "claude usage limit reached", quotas: [], model: nil)
        #expect(unplaced?.provider == "Claude")
        #expect(unplaced?.source == .failure)
        let sonnet = QuotaSurface.resolve(
            failureMessage: "claude usage limit reached", quotas: [], model: "claude-sonnet-4-5")
        #expect(sonnet?.provider == "Claude")
        #expect(
            QuotaSurface.resolve(
                failureMessage: "claude usage limit reached", quotas: [], model: "gpt-5.6") == nil,
            "a chat that has moved to a model Claude never billed is not behind Claude's wall")
    }

    @Test("A row note says what ran out and when it comes back")
    func rowNote() {
        let scoped = QuotaExhaustion(
            provider: "Claude", window: "Weekly · Opus", fraction: 1,
            resetsAt: Date().addingTimeInterval(7_200), trustedReset: true, source: .gauge,
            scope: .model(["opus"]))
        let note = QuotaSurface.rowNote(scoped)
        #expect(note.hasPrefix(Localized.text("Used up")))
        #expect(note.contains("h "))

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

    @Test("The door that runs a model bills it, never the name on the box")
    func doorOverFamily() {
        let catalog = [
            ModelInfo(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", providerID: "opencode-go"),
            ModelInfo(
                id: "deepseek-v4-flash-direct", name: "DeepSeek V4 Flash Direct",
                providerID: "deepseek"),
            ModelInfo(id: "claude-opus-4-5", name: "Claude Opus 4.5", providerID: "anthropic"),
        ]
        let byTitle: (ModelChooser) -> [String: ModelChooserRow] = { chooser in
            Dictionary(
                uniqueKeysWithValues: chooser.rows.filter { !$0.isAuto }.map { ($0.title, $0) })
        }
        let go = ModelChooser(
            models: catalog, selected: nil, recents: [],
            quotas: [quota("opencode go", [gauge("5-hour session", 1.0)])])
        let goRows = byTitle(go)
        #expect(goRows["DeepSeek V4 Flash"]?.wall != nil, "go bills the model it fronts")
        #expect(
            goRows["DeepSeek V4 Flash Direct"]?.wall == nil,
            "go does not bill a model the deepseek door runs")
        #expect(
            goRows["Claude Opus 4.5"]?.wall == nil,
            "go does not bill a model the anthropic door runs")

        let balance = ModelChooser(
            models: catalog, selected: nil, recents: [],
            quotas: [quota("DeepSeek", [gauge("Balance", 1.0)])])
        let balanceRows = byTitle(balance)
        #expect(
            balanceRows["DeepSeek V4 Flash Direct"]?.wall != nil,
            "the prepaid balance bills the model the deepseek door runs")
        #expect(
            balanceRows["DeepSeek V4 Flash"]?.wall == nil,
            "the prepaid balance does not bill a model go fronts")
        #expect(
            balanceRows["Claude Opus 4.5"]?.wall == nil,
            "the prepaid balance does not bill Claude's")
    }

    @Test("A window belongs to the account, so both machines' copies wear it")
    func elsewhereMarkedTheSame() {
        let here = ModelSource(
            profileID: "studio", name: "studio", backend: .claudeCode,
            models: [ModelInfo(id: "opus", name: "Opus", providerID: "anthropic")],
            isCurrent: true, allowsServerDefault: true, acceptsAnyModelID: false)
        let there = ModelSource(
            profileID: "homelab", name: "homelab", backend: .openCode,
            models: [
                ModelInfo(id: "claude-opus-4-5", name: "Opus 4.5", providerID: "anthropic"),
                ModelInfo(id: "qwen3:latest", name: "Qwen3", providerID: "ollama"),
            ],
            isCurrent: false, allowsServerDefault: true, acceptsAnyModelID: false)
        var chooser = ModelChooser(
            sources: [here, there], selected: nil, recents: [],
            quotas: [quota("Claude", [gauge("Weekly · Opus 4.1", 1.0)])])
        let mine = chooser.rows.first { !$0.isAuto && !$0.isElsewhere }
        chooser.setMachine("homelab")
        let theirs = chooser.rows.first { $0.isElsewhere && $0.title.hasPrefix("Opus") }
        let local = chooser.rows.first { $0.title == "Qwen3" }
        #expect(mine?.wall != nil)
        #expect(theirs?.wall != nil, "one plan, two machines, one weekly window")
        #expect(local?.wall == nil, "and a model that plan never bills is left alone")
    }

    @Test("A wall holds only the models its provider bills")
    func billingAwareWalls() {
        let catalog = [
            ModelInfo(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", providerID: "anthropic"),
            ModelInfo(
                id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", providerID: "opencode-go"),
            ModelInfo(
                id: "deepseek-v4-flash-direct", name: "DeepSeek V4 Flash Direct",
                providerID: "deepseek"),
            ModelInfo(id: "gpt-5.6-luna", name: "GPT-5.6 Luna", providerID: "opencode-go"),
            ModelInfo(id: "qwen3:latest", name: "Qwen3", providerID: "ollama"),
        ]
        func accountWall(_ provider: String) -> UsageQuota {
            quota(provider, [gauge("5-hour session", 1.0)])
        }

        let claudeWall = ModelChooser(
            models: catalog, selected: nil, recents: [], quotas: [accountWall("Claude")])
        let byTitle = Dictionary(
            uniqueKeysWithValues: claudeWall.rows.filter { !$0.isAuto }.map { ($0.title, $0) })
        #expect(byTitle["Claude Sonnet 4.5"]?.wall != nil)
        #expect(byTitle["DeepSeek V4 Flash"]?.wall == nil)
        #expect(byTitle["DeepSeek V4 Flash Direct"]?.wall == nil)
        #expect(byTitle["GPT-5.6 Luna"]?.wall == nil)
        #expect(byTitle["Qwen3"]?.wall == nil)

        let goWall = ModelChooser(
            models: catalog, selected: nil, recents: [], quotas: [accountWall("opencode go")])
        let goByTitle = Dictionary(
            uniqueKeysWithValues: goWall.rows.filter { !$0.isAuto }.map { ($0.title, $0) })
        #expect(goByTitle["DeepSeek V4 Flash"]?.wall != nil)
        #expect(goByTitle["GPT-5.6 Luna"]?.wall != nil)
        #expect(goByTitle["DeepSeek V4 Flash Direct"]?.wall == nil, "go does not bill the deepseek door")
        #expect(goByTitle["Qwen3"]?.wall == nil, "the reseller does not bill a local model")

        let deepWall = ModelChooser(
            models: catalog, selected: nil, recents: [], quotas: [accountWall("DeepSeek")])
        let deepByTitle = Dictionary(
            uniqueKeysWithValues: deepWall.rows.filter { !$0.isAuto }.map { ($0.title, $0) })
        #expect(deepByTitle["DeepSeek V4 Flash Direct"]?.wall != nil)
        #expect(deepByTitle["DeepSeek V4 Flash"]?.wall == nil, "the balance does not bill a model go fronts")
        #expect(deepByTitle["Claude Sonnet 4.5"]?.wall == nil)
        #expect(deepByTitle["GPT-5.6 Luna"]?.wall == nil)
    }

    @Test("A chat's chooser admits the quotas its backend spends against")
    func relevantFamilies() {
        let quotas = [
            quota("Claude", [gauge("5-hour session", 1.0)]),
            quota("opencode go", [gauge("5-hour session", 1.0)]),
            quota("DeepSeek", [gauge("Balance", 1.0)]),
            quota("Grok", [gauge("5-hour session", 1.0)]),
        ]
        let claude = QuotaSurface.relevantQuotas(for: .claudeCode, among: quotas)
        #expect(claude.map(\.providerName) == ["Claude"])
        let opencode = QuotaSurface.relevantQuotas(for: .openCode, among: quotas)
        #expect(Set(opencode.map(\.providerName)) == ["opencode go", "DeepSeek", "Grok"])
        #expect(QuotaSurface.relevantQuotas(for: nil, among: quotas).count == 4)
    }

    @Test("A dual-door Grok row wears the wall of the door a pick would take, not Go's")
    func dualDoorGrok() {
        let catalog = [
            ModelInfo(id: "grok-4.5", name: "Grok 4.5", providerID: "xai"),
            ModelInfo(id: "grok-4.5", name: "Grok 4.5", providerID: "opencode-go"),
            ModelInfo(id: "kimi-k3", name: "Kimi K3", providerID: "opencode-go"),
        ]
        let goSpent = [quota("opencode go", [gauge("5-hour session", 1.0)])]
        let chooser = ModelChooser(models: catalog, selected: nil, recents: [], quotas: goSpent)
        let byTitle = Dictionary(
            uniqueKeysWithValues: chooser.rows.filter { !$0.isAuto }.map { ($0.title, $0) })
        #expect(
            byTitle["Grok 4.5"]?.wall == nil,
            "primary is xAI; Go's spent window is not a fact about that pick")
        #expect(byTitle["Kimi K3"]?.wall != nil, "a model only Go fronts still wears Go's wall")

        var opened = chooser
        if let index = opened.rows.firstIndex(where: { $0.title == "Grok 4.5" }) {
            _ = opened.setExpanded(true, at: index)
        }
        let nested = opened.rows.filter(\.isNested)
        let xaiAlt = nested.first { $0.title == "xAI" }
        let goAlt = nested.first { $0.title == "OpenCode Go" }
        #expect(xaiAlt?.wall == nil, "the xAI alternate is free")
        #expect(goAlt?.wall != nil, "the Go alternate names Go's spent window")

        let viaXai = ModelSelection(providerID: "xai", modelID: "grok-4.5")
        #expect(
            QuotaSurface.resolve(failureMessage: nil, quotas: goSpent, selection: viaXai) == nil,
            "a chat on the xAI door does not hear Go's wall")
        let viaGo = ModelSelection(providerID: "opencode-go", modelID: "grok-4.5")
        #expect(
            QuotaSurface.resolve(failureMessage: nil, quotas: goSpent, selection: viaGo)?.provider
                == "opencode go",
            "a chat on the Go door still does")
    }

    @Test("A chat's banner reads the door its model runs through")
    func chatBilling() {
        let quotas = [
            quota("Claude", [gauge("5-hour session", 1.0)]),
            quota("opencode go", [gauge("5-hour session", 1.0)]),
            quota("DeepSeek", [gauge("Balance", 1.0)]),
        ]
        let viaGo = ModelSelection(providerID: "opencode-go", modelID: "deepseek-v4-flash")
        let goBilled = QuotaSurface.billingQuotas(in: quotas, selection: viaGo)
        #expect(goBilled.map(\.providerName) == ["opencode go"])

        let viaDeepseek = ModelSelection(providerID: "deepseek", modelID: "deepseek-v4-flash")
        let deepBilled = QuotaSurface.billingQuotas(in: quotas, selection: viaDeepseek)
        #expect(deepBilled.map(\.providerName) == ["DeepSeek"])

        let viaAnthropic = ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-4-5")
        #expect(QuotaSurface.billingQuotas(in: quotas, selection: viaAnthropic).map(\.providerName) == ["Claude"])

        let onClaude = QuotaSurface.resolve(
            failureMessage: nil, quotas: quotas,
            selection: ModelSelection(providerID: "opencode-go", modelID: "kimi-k3"))
        #expect(onClaude?.provider == "opencode go", "the reseller's wall is in the way, not Claude's")

        #expect(
            QuotaSurface.resolve(
                failureMessage: nil, quotas: quotas,
                selection: ModelSelection(providerID: "deepseek", modelID: "deepseek-v4-flash")
            )?.provider == "DeepSeek",
            "an empty prepaid balance stops its own models and no others")
        #expect(
            QuotaSurface.resolve(
                failureMessage: nil, quotas: quotas,
                selection: ModelSelection(providerID: "anthropic", modelID: "claude-opus-4-5")
            )?.provider == "Claude",
            "a Claude wall is what stands in front of an Anthropic-door model")
    }

    @Test("The composer's own wall is read through the model's door")
    func bandBilling() {
        let quotas = [
            quota("opencode go", [gauge("Weekly", 1.0)]),
            quota("DeepSeek", [gauge("Balance", 0.9)]),
        ]
        let direct = ModelSelection(providerID: "deepseek", modelID: "deepseek/deepseek-v4-pro")
        #expect(
            QuotaSurface.hottestExhausted(
                in: QuotaSurface.billingQuotas(in: quotas, selection: direct, model: direct.modelID),
                model: direct.modelID
            ) == nil,
            "the plan's weekly wall is not news above a chat on the direct key")
        let viaGo = ModelSelection(providerID: "opencode-go", modelID: "deepseek/deepseek-v4-pro")
        #expect(
            QuotaSurface.hottestExhausted(
                in: QuotaSurface.billingQuotas(in: quotas, selection: viaGo, model: viaGo.modelID),
                model: viaGo.modelID
            )?.provider == "opencode go",
            "the plan's weekly wall speaks above a chat the plan bills")
    }

    @Test("A model on the server's own machine wears no reseller's wall")
    func localModelUnderGoWall() {
        let quotas = [quota("opencode go", [gauge("5-hour session", 1.0)])]
        let local = ModelSelection(providerID: "llama-server", modelID: "qwen38-nvfp4")
        #expect(!QuotaBinding.bills(quotas[0], selection: local))
        #expect(QuotaSurface.billingQuotas(in: quotas, selection: local).isEmpty)
        #expect(QuotaSurface.resolve(failureMessage: nil, quotas: quotas, selection: local) == nil)
        let viaGo = ModelSelection(providerID: "opencode-go", modelID: "qwen3-coder")
        #expect(
            QuotaSurface.resolve(failureMessage: nil, quotas: quotas, selection: viaGo)?.provider
                == "opencode go", "the same family through Go's door is Go's to stop")
        let doorless = ModelSelection(providerID: ActiveModel.unknownDoor, modelID: "qwen38-nvfp4")
        #expect(
            QuotaBinding.bills(quotas[0], selection: doorless),
            "a qwen nobody can place is still assumed to be the reseller's, which is why the door must travel")
    }

    @Test("A chat read from its transcript bills through the door the answer came by")
    func transcriptDoorBilling() {
        let quotas = [quota("opencode go", [gauge("Monthly", 1.0)])]
        let now = Date()
        let answered = ChatMessage(
            id: "a", role: .assistant, agentType: .openCode, createdAt: now,
            providerID: "llama-server", modelID: "qwen38-nvfp4")
        let selection = ActiveModel.selection(picked: nil, messages: [answered], session: nil)
        #expect(
            QuotaSurface.resolve(failureMessage: nil, quotas: quotas, selection: selection) == nil,
            "the transcript said llama-server, and Go's month is not that machine's")
        let record = AgentSession(
            id: "s", agentType: .openCode, title: "t", createdAt: now, updatedAt: now,
            model: "qwen38-nvfp4",
            modelProviderID: "llama-server")
        #expect(
            QuotaSurface.resolve(
                failureMessage: nil, quotas: quotas,
                selection: ActiveModel.selection(picked: nil, messages: [], session: record)) == nil)
    }

    @Test("The chooser's own selftest passes")
    func selftest() {
        #expect(ModelChooserCheck.run().isEmpty)
    }
}
