import CodingAgentKit
import Foundation
import Synchronization

/// The chooser's rules, proved headlessly in the Kit rather than in one client — all three run this
public enum ModelChooserCheck {
    /// `run()` flips `ModelFavoritesStore` — real device state, not a copy — so two callers
    /// running at once (Swift Testing runs suites concurrently) steal each other's toggles and
    /// both report stars that did not land. One check at a time.
    private static let gate = Synchronization.Mutex<Bool>(false)

    public static func run() -> [String] {
        gate.withLock { _ in runLocked() }
    }

    private static func runLocked() -> [String] {
        // The star writes to the machine's own store, and half this check reads rankings a star
        // reorders. So the check runs against an empty shelf and puts back exactly what it found
        // — and because it clears at the start rather than only tidying at the end, a run killed
        // part-way (a piped test run losing its reader is enough) is healed by the next one
        // instead of failing every run after it for a reason nobody could see.
        let starredBefore = ModelFavoritesStore.all()
        ModelFavoritesStore.replace([])
        defer { ModelFavoritesStore.replace(starredBefore) }
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let catalog = [
            ModelInfo(
                id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", providerID: "anthropic",
                capabilities: ModelCapabilities(attachment: true, imageInput: true, pdfInput: true),
                variants: ["low", "medium", "high"]),
            ModelInfo(
                id: "anthropic/claude-sonnet-4.5", name: "Claude Sonnet 4.5",
                providerID: "openrouter"),
            ModelInfo(id: "gpt-5.6-luna", name: "GPT-5.6 Luna", providerID: "opencode-go"),
            ModelInfo(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", providerID: "opencode-go"),
            ModelInfo(
                id: "deepseek-v4-flash-direct", name: "DeepSeek V4 Flash", providerID: "deepseek"),
            ModelInfo(id: "qwen3:latest", name: "Qwen3", providerID: "ollama"),
            ModelInfo(id: "qwen3-coder", name: "Qwen3 Coder", providerID: "opencode-go"),
        ]

        let folded = ModelChooser.fold(catalog)
        expect(folded.count == 5, "the same model from two providers folds into one row")
        guard let sonnet = folded.first(where: { $0.name == "Claude Sonnet 4.5" }) else {
            return failures + ["the folded catalog lost Claude Sonnet"]
        }
        expect(sonnet.offers.count == 2, "both doors survive the fold")
        expect(sonnet.family.title == "Claude", "a model is filed under its own house")
        expect(
            sonnet.capabilities?.imageInput == true,
            "the fold keeps the offer that actually described itself first")
        expect(
            folded.first { $0.name == "Qwen3" }?.isLocal == true,
            "a local model stays local")
        expect(
            folded.filter { $0.family.title == "Qwen" }.count == 2,
            "local and hosted namesakes never fold together")
        expect(ModelChooser.bareID("anthropic/claude-sonnet-4-5-20250219") == "claude-sonnet-4-5",
            "a gateway prefix and a release date are not part of a model's name")
        expect(ModelChooser.bareID("qwen3:latest") == "qwen3", "a latest tag is not a revision")

        var chooser = ModelChooser(models: catalog, selected: nil, recents: [])
        expect(chooser.rows.first?.isAuto == true, "the server's own choice leads")
        expect(chooser.rows.first?.isSelected == true, "and is checked when nothing is picked")
        expect(
            chooser.sections.first?.id == "·yours",
            "what the chat runs is a named section rather than an untitled row")
        expect(
            chooser.sections.contains { $0.id == "·local" },
            "what runs on the machine's own hardware is a section of its own")
        expect(
            chooser.sections.first { $0.id == "qwen" }?.rows.allSatisfy { !$0.facts.contains(.local) }
                == true,
            "and never sits in a family beside a hosted namesake")
        expect(chooser.sections.count == 6, "yours, local, then one section per hosted family")
        expect(chooser.summary.contains("5"), "the summary counts the folded catalog")
        expect(
            chooser.rows.first { $0.title == "GPT-5.6 Luna" }?.detail.contains("gpt-5.6-luna")
                == false,
            "an id that only respells the name is not a second line")
        expect(
            chooser.rows.first { $0.title == "Qwen3" }?.detail.contains("qwen3:latest") == true,
            "an id that says more than the name stays")

        chooser.search("sonnet")
        expect(chooser.rows.count == 1, "a query narrows to what it names")
        expect(chooser.rows.first?.highlight.isEmpty == false, "and says which letters it read")
        expect(
            chooser.rows.first?.detail.contains("+1") == true,
            "two doors is counted in the second line rather than worn as a pill")
        expect(
            chooser.rows.first?.facts.allSatisfy(\.isCapability) == true,
            "and effort levels are not a fact about the pick")

        chooser.search("openrouter")
        expect(chooser.rows.count == 1, "a provider nobody's model is named after still finds it")
        expect(chooser.rows.first?.highlight.isEmpty == true, "with nothing in the name to weight")

        chooser.search("qw3")
        expect(chooser.rows.count == 2, "scattered letters still reach a name")

        chooser.search("zzz")
        expect(chooser.rows.isEmpty, "a word the catalog lacks matches nothing")
        expect(chooser.emptyResult?.contains("zzz") == true, "and says so, naming the word")

        chooser.search("")
        expect(chooser.rows.count > 5, "clearing the query restores the catalog")
        let sonnetIndex = chooser.rows.firstIndex { $0.title == "Claude Sonnet 4.5" }
        expect(sonnetIndex != nil, "the folded row is in the list")
        if let sonnetIndex {
            chooser.focus(sonnetIndex)
            expect(chooser.setExpanded(true), "a folded row opens onto its providers")
            expect(chooser.rows.count > 6, "and the alternates take rows of their own")
            expect(chooser.rows[sonnetIndex + 1].isNested, "drawn under the row they belong to")
            let pick = chooser.rows[sonnetIndex + 1].selection
            expect(pick != nil, "an alternate picks a concrete provider")
            expect(chooser.setExpanded(false), "and closes again")
        }

        var picking = ModelChooser(models: catalog, selected: nil, recents: [])
        _ = picking.handle(.down)
        let outcome = picking.handle(.activate)
        expect(outcome.handled, "enter is the chooser's key")
        expect(outcome.pick != nil, "and answers with a pick")

        let auto = ModelChooser(
            models: catalog, selected: nil, allowsServerDefault: false, recents: [])
        expect(auto.rows.first?.isAuto == false, "a backend with no server default offers none")

        let empty = ModelChooser(models: [], selected: nil, recents: [], isReachable: true)
        expect(empty.isEmpty, "an empty catalog is empty")
        expect(empty.summary == Localized.text("This server lists no models"), "and says so, once the server has said it")

        let asking = ModelChooser(models: [], selected: nil, recents: [])
        expect(asking.summary.contains("Asking"), "before an answer arrives the list says it is asking")

        let refused = ModelChooser(models: [], selected: nil, recents: [], isReachable: false)
        expect(refused.summary.contains("not answering"), "a refused ask is a state, never an empty claim")

        let selection = ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-4-5")
        let opened = ModelChooser(models: catalog, selected: selection, recents: [])
        expect(
            opened.focused?.title == "Claude Sonnet 4.5",
            "the chooser opens on the model already chosen")

        var recent = ModelChooser(models: catalog, selected: nil, recents: [selection])
        expect(
            recent.sections.first { $0.id == "·yours" }?.rows.contains { $0.title == "Claude Sonnet 4.5" }
                == true,
            "what you reached for last leads the list")
        expect(
            Set(recent.rows.map(\.id)).count == recent.rows.count,
            "a model listed under Yours and again under its family is two rows, not one id twice")
        if let index = recent.rows.firstIndex(where: {
            $0.sectionID == "claude" && $0.canExpand
        }) {
            expect(recent.setExpanded(true, at: index), "the family copy opens onto its providers")
            expect(
                Set(recent.rows.map(\.id)).count == recent.rows.count,
                "and its alternates stay distinct from the recent copy's")
            expect(
                recent.focused?.sectionID == "claude",
                "expanding a row leaves the cursor on the row that was expanded")
        } else {
            failures.append("the recent catalog lost the expandable Claude row")
        }

        let short = ModelChooser.shortlist(
            catalog, selected: selection, limit: 3, recents: [selection])
        expect(short.count == 1, "a shortlist is what you reached for, not a prefix of the catalog")
        expect(
            ModelChooser.shortlist(catalog, selected: nil, limit: 99, recents: []).count == 5,
            "a catalog that fits is shown whole")

        let studio = ModelSource(
            profileID: "studio", name: "studio", backend: .claudeCode,
            models: [
                ModelInfo(id: "opus", name: "Opus", providerID: "anthropic"),
                ModelInfo(id: "sonnet", name: "Sonnet", providerID: "anthropic"),
            ], isCurrent: true, allowsServerDefault: true, acceptsAnyModelID: true)
        let homelab = ModelSource(
            profileID: "homelab", name: "homelab", backend: .openCode, models: catalog,
            isCurrent: false, allowsServerDefault: true, acceptsAnyModelID: false)

        var fleet = ModelChooser(sources: [homelab, studio], selected: nil, recents: [])
        expect(fleet.candidates.count == 7, "every server's catalog is folded")
        expect(fleet.machines.count == 2 && fleet.showsMachines, "and each machine is a tab")
        expect(fleet.machines.first?.profileID == "studio", "the one the chooser opened from first")
        expect(fleet.machine == "studio", "and it is the tab showing")
        expect(fleet.machines[1].count == 5, "a tab counts what its machine offers")
        expect(fleet.machines[1].localCount == 1, "and how much of it is local")
        expect(fleet.machines[1].consequence != nil, "another machine's tab says a pick starts a chat there")
        expect(fleet.machines[0].consequence == nil, "this one's does not")
        expect(
            fleet.rows.allSatisfy { !$0.isElsewhere },
            "the list under a tab is one machine's catalog and nothing else's")
        expect(
            !fleet.rows.contains { $0.title == "Claude Sonnet 4.5" },
            "the other machine's models are not in it")
        expect(fleet.summary.contains(ModelChooser.modelCount(2)), "the summary counts this machine")
        expect(fleet.handle(.machine(1)).handled, "⌃2 shows the second machine")
        expect(fleet.machine == "homelab", "which is the one it names")
        guard let theirs = fleet.rows.firstIndex(where: { $0.title == "Claude Sonnet 4.5" }) else {
            return failures + ["the other machine's tab lost its models"]
        }
        expect(fleet.rows[theirs].isElsewhere, "a model on the other machine says so")
        expect(
            !fleet.rows[theirs].facts.contains(.server("homelab")),
            "without wearing the machine's name on every row under its own tab")
        expect(
            fleet.rows[theirs].pick.profileID == "homelab",
            "picking it answers with that machine")
        expect(
            fleet.rows[theirs].pick.isElsewhere,
            "and says the work has to move rather than the chat change")
        expect(
            !fleet.rows.contains { $0.isAuto },
            "the server default is this chat's server's answer, not another machine's")
        expect(!fleet.handle(.machine(5)).handled, "a tab nobody offered leaves the key alone")
        expect(fleet.setMachine("studio"), "and the tab goes back")

        var pinned = ModelChooser(sources: [studio, homelab], selected: nil, recents: [], favorites: [
            ModelSelection(providerID: "ollama", modelID: "qwen3:latest"),
        ])
        _ = pinned.setMachine("homelab")
        expect(
            pinned.sections.first { $0.id == "·yours" }?.rows.first?.title == "Qwen3",
            "a starred model leads Yours on the machine that runs it")
        expect(
            pinned.rows.first { $0.sectionID == "·yours" }?.isPinned == true,
            "and the row says it is pinned")
        let probe = ModelSelection(providerID: "anthropic", modelID: "opus")
        pinned.togglePin(probe)
        expect(pinned.isFavorite(probe), "the star is on")
        pinned.togglePin(probe)
        expect(!pinned.isFavorite(probe), "and toggles off")

        let quick = ModelChooser.shortlist(
            sources: [studio, homelab], selected: nil, limit: 4, recents: [],
            favorites: [ModelSelection(providerID: "openrouter", modelID: "anthropic/claude-sonnet-4.5")])
        expect(quick.first?.name != nil && quick.count <= 4, "the quick list keeps its length")
        expect(
            quick.contains { $0.name == "Claude Sonnet 4.5" },
            "a star from another door still makes the quick list")

        let reached = ModelChooser.shortlist(
            sources: [studio, homelab], selected: nil, limit: 8,
            recents: [ModelSelection(providerID: "anthropic", modelID: "opus")], favorites: [])
        expect(
            reached.count == 1 && reached.first?.name == "Opus",
            "a quick menu is what the person reached for, never padded out with models they never picked")

        let mirror = ModelSource(
            profileID: "mirror", name: "mirror", backend: .openCode, models: catalog,
            isCurrent: false, allowsServerDefault: true, acceptsAnyModelID: false)
        let untouched = ModelChooser.shortlist(
            sources: [studio, homelab, mirror], selected: nil, limit: 8, recents: [], favorites: [])
        expect(
            untouched.count == 1 && untouched.first?.name == "Qwen3",
            "a device that has picked nothing opens on what the machines run themselves, once per model")

        let hosted = ModelSource(
            profileID: "bridge", name: "bridge", backend: .claudeCode,
            models: [
                ModelInfo(id: "opus", name: "Opus", providerID: "anthropic"),
                ModelInfo(id: "sonnet", name: "Sonnet", providerID: "anthropic"),
            ],
            isCurrent: true, allowsServerDefault: true, acceptsAnyModelID: true)
        let elsewhere = ModelSource(
            profileID: "other", name: "other", backend: .claudeCode,
            models: [ModelInfo(id: "haiku", name: "Haiku", providerID: "anthropic")],
            isCurrent: false, allowsServerDefault: true, acceptsAnyModelID: true)
        let hostedOnly = ModelChooser.shortlist(
            sources: [hosted, elsewhere], selected: nil, limit: 8, recents: [], favorites: [])
        expect(
            hostedOnly.map(\.name) == ["Opus", "Sonnet"],
            "a fleet that runs nothing itself opens on the aimed machine's own models, not an empty menu")

        fleet.search("claude-opus-4-5-20260101")
        expect(fleet.emptyResult == nil, "a name the catalog lacks is not the end of the list")
        let literals = fleet.rows.filter(\.isLiteral)
        expect(literals.count == 1, "only the server that takes any name offers to take this one")
        expect(literals.first?.profileID == "studio", "and it is the one whose CLI does")
        expect(
            literals.first?.pick.selection?.modelID == "claude-opus-4-5-20260101",
            "typing an id is a way of picking it")

        fleet.search("sonnet")
        expect(
            fleet.rows.contains { !$0.isElsewhere } && fleet.rows.contains { $0.isElsewhere },
            "one query reaches both machines")
        expect(
            fleet.rows.first?.isElsewhere == false,
            "with this machine's answer first")
        expect(
            fleet.sections.last { $0.id == "·elsewhere" }?.rows.allSatisfy {
                $0.facts.contains(.server("homelab"))
            } == true,
            "and the other machine's answers under their own heading, each naming its machine")
        expect(fleet.summary.contains(Localized.text("%@ elsewhere", "1")), "the header counts them")
        expect(
            fleet.rows.contains { $0.isLiteral } == false,
            "a name the catalog already has is not offered as a typed id")
        fleet.search("qwen coder")
        expect(fleet.rows.count == 1 && fleet.rows.first?.isElsewhere == true,
            "a name only the other machine has is still found there")
        expect(fleet.emptyResult == nil, "so the list is not empty")
        fleet.search("zzz nowhere")
        expect(
            fleet.emptyResult?.contains("studio") == true,
            "an empty answer names the machine as well as the word")
        fleet.search("")

        let alone = ModelChooser(models: catalog, selected: nil, recents: [])
        expect(
            alone.rows.allSatisfy { !$0.isElsewhere },
            "one server's list has nowhere else in it")
        expect(
            alone.rows.first?.pick.isElsewhere == false,
            "and every pick stays where it is")

        expect(
            ModelChooser(models: studio.models, selected: nil, recents: []).showsMachines == false,
            "a catalog with one machine draws no strip")
        expect(
            alone.sections.first { $0.id == "·local" }?.title == Localized.text("On this machine"),
            "and its local section is named for the only machine there is")
        var keyed = ModelChooser(models: catalog, selected: nil, recents: [])
        expect(
            !keyed.handle(.machine(0)).handled,
            "a tab key with one machine leaves the key to whoever wants it")

        let described = [
            ModelInfo(
                id: "a-one", name: "A One", providerID: "anthropic",
                capabilities: ModelCapabilities(attachment: true, imageInput: true, pdfInput: true)),
            ModelInfo(
                id: "a-two", name: "A Two", providerID: "anthropic",
                capabilities: ModelCapabilities(attachment: true, imageInput: true, pdfInput: false)),
        ]
        let uniform = ModelChooser(models: described, selected: nil, recents: [])
        expect(
            uniform.rows.allSatisfy { !$0.facts.contains(.vision) },
            "a capability every model in the catalog has is a fact about none of them")
        expect(
            uniform.rows.contains { $0.facts.contains(.pdf) },
            "the one that tells two models apart is still worn")

        var big: [ModelInfo] = []
        for index in 0..<40 {
            big.append(
                ModelInfo(
                    id: "gpt-\(index)", name: "GPT \(index)", providerID: "openai",
                    capabilities: ModelCapabilities(
                        attachment: true, imageInput: true, pdfInput: index.isMultiple(of: 2))))
        }
        big.append(ModelInfo(id: "claude-x", name: "Claude X", providerID: "anthropic"))
        let picked = ModelSelection(providerID: "anthropic", modelID: "claude-x")
        var shelf = ModelChooser(models: big, selected: picked, recents: [])
        expect(
            shelf.sections.first { $0.id == "gpt" }?.isCollapsed == true,
            "a catalog too long to read arrives shelf")
        expect(
            shelf.sections.first { $0.id == "claude" }?.isCollapsed == false,
            "except where the model in use lives")
        expect(shelf.hidden == 40, "and says how much it is holding back")
        expect(
            shelf.sections.first { $0.id == "gpt" }?.count == 40,
            "a shut heading still counts what is under it")
        expect(shelf.rows.count < 10, "so the list is a screen rather than a scroll")
        expect(shelf.foldAction?.collapses == false, "the one press on offer is the opening one")
        expect(shelf.toggleSection("gpt"), "a heading opens")
        expect(shelf.rows.count > 40, "onto everything it held")
        expect(shelf.focused?.sectionID == "gpt", "with the cursor inside what just opened")
        expect(shelf.setAllCollapsed(true), "and every heading shuts at once")
        expect(shelf.rows.allSatisfy { $0.sectionID.hasPrefix("·") }, "leaving only the headings")
        shelf.search("gpt 3")
        expect(
            shelf.sections.allSatisfy { !$0.isCollapsed },
            "a query is never answered from behind a shut heading")
        expect(!shelf.rows.isEmpty, "and finds what folding was hiding")
        shelf.search("")
        expect(shelf.hidden > 0, "clearing the query gives the folding back")

        let tiny = ModelChooser(models: studio.models, selected: nil, recents: [])
        expect(
            tiny.sections.allSatisfy { !$0.isCollapsed },
            "a catalog you can read whole is never shelf")
        expect(tiny.foldAction == nil, "and offers no press for it")

        let ownModel = ModelSelection(providerID: "ollama", modelID: "qwen3:latest")
        let inUse = ModelChooser(
            models: catalog, selected: ownModel, recents: [ownModel, selection])
        expect(inUse.sections.first?.id == "·yours", "the model in use leads the list")
        expect(inUse.rows.first?.isSelected == true, "and is the row the chooser opens on")
        let yours = inUse.sections.first { $0.id == "·yours" }?.rows ?? []
        expect(
            yours.filter { $0.title == "Qwen3" }.count == 1,
            "a model both running and recent is one row, not two")
        expect(yours.contains { $0.title == "Claude Sonnet 4.5" }, "while what else you reached for is still there")
        expect(yours.last?.isAuto == true, "and the server's own default closes the section")

        func window(_ label: String, _ fraction: Double) -> UsageQuota.Gauge {
            UsageQuota.Gauge(
                key: label, label: label, fraction: fraction,
                resetsAt: Date().addingTimeInterval(7_200), trustedReset: true)
        }
        func account(_ gauges: [UsageQuota.Gauge]) -> UsageQuota {
            UsageQuota(
                providerName: "Claude", subtitle: "", source: "selftest", live: true,
                gauges: gauges, details: [])
        }

        let scoped = ModelChooser(
            models: catalog, selected: nil, recents: [],
            quotas: [account([window("Weekly · Opus 4.1", 1), window("5-hour session", 0.3)])])
        expect(
            scoped.rows.allSatisfy { $0.wall == nil },
            "a wall around a model the catalog does not carry marks nothing")

        let walled = ModelChooser(
            models: catalog, selected: nil, recents: [],
            quotas: [account([window("Weekly · Sonnet 4.5", 1), window("5-hour session", 0.3)])])
        let sonnetRow = walled.rows.first { $0.title == "Claude Sonnet 4.5" }
        expect(sonnetRow?.wall != nil, "the model the window names is marked spent")
        expect(sonnetRow?.wall?.isAccountWide == false, "and knows the wall is its own")
        expect(
            walled.rows.filter { $0.title.hasPrefix("GPT") }.allSatisfy { $0.wall == nil },
            "a model the window never mentioned is left alone")
        expect(walled.summary.contains(Localized.text("%@ used up", "1")), "and the count says so")

        let ranked = ModelChooser(
            models: studio.models, selected: nil, recents: [],
            quotas: [account([window("Weekly · Opus 4.1", 1)])])
        let opusAt = ranked.rows.firstIndex { $0.title == "Opus" }
        let sonnetAt = ranked.rows.firstIndex { $0.title == "Sonnet" }
        expect(
            opusAt != nil && sonnetAt != nil && sonnetAt! < opusAt!,
            "a spent model sinks under the ones in its family that can still answer")
        if let wall = sonnetRow?.wall {
            expect(
                QuotaSurface.rowNote(wall).contains(Localized.text("Used up")),
                "the row says what it is")
            expect(QuotaSurface.rowNote(wall).contains("h "), "and when it comes back")
        }

        let stopped = ModelChooser(
            models: catalog, selected: nil, recents: [],
            quotas: [account([window("5-hour session", 1)])])
        expect(
            stopped.rows.filter { $0.title == "Claude Sonnet 4.5" }.allSatisfy { $0.wall != nil },
            "a window metered against the account stops the models its provider bills")
        expect(
            stopped.rows.first { !$0.isAuto && $0.wall != nil }?.wall?.isAccountWide == true,
            "and says it is the account's rather than the model's")
        expect(
            stopped.rows.filter { $0.title != "Claude Sonnet 4.5" && !$0.isAuto }
                .allSatisfy { $0.wall == nil },
            "a Claude wall is not a fact about models billed somewhere else")

        func quota(_ provider: String, _ gauges: [UsageQuota.Gauge]) -> UsageQuota {
            UsageQuota(
                providerName: provider, subtitle: "", source: "selftest", live: true,
                gauges: gauges, details: [])
        }

        let goWall = ModelChooser(
            models: catalog, selected: nil, recents: [],
            quotas: [quota("opencode go", [window("5-hour session", 1)])])
        expect(
            goWall.rows.filter { !$0.isAuto }.allSatisfy { row in
                // Only the door a pick would take. Dual-door DeepSeek prefers deepseek, so Go's
                // wall is not on the parent row; Claude and local never are.
                let goOnly = row.title == "GPT-5.6 Luna" || row.title == "Qwen3 Coder"
                return (row.wall != nil) == goOnly
            },
            "a reseller's wall holds models whose primary door is Go — never a dual-door "
                + "row that would send through another house, and never local")
        var goOpened = goWall
        if let index = goOpened.rows.firstIndex(where: { $0.title == "DeepSeek V4 Flash" }) {
            _ = goOpened.setExpanded(true, at: index)
        }
        expect(
            goOpened.rows.first { $0.isNested && $0.title == "OpenCode Go" }?.wall != nil,
            "the Go alternate under a dual-door row still names Go's spent window")
        expect(
            goOpened.rows.first { $0.isNested && $0.title == "DeepSeek" }?.wall == nil,
            "and the direct alternate does not")

        let deepWall = ModelChooser(
            models: catalog, selected: nil, recents: [],
            quotas: [quota("DeepSeek", [window("Balance", 1)])])
        expect(
            deepWall.rows.filter { $0.title == "DeepSeek V4 Flash" }.allSatisfy { $0.wall != nil },
            "a prepaid balance wall holds the models billed from it")
        expect(
            deepWall.rows.filter { $0.title != "DeepSeek V4 Flash" && !$0.isAuto }
                .allSatisfy { $0.wall == nil },
            "and leaves every other house alone")

        let keys: [(UInt32, UInt32, ModelChooserCommand?)] = [
            (Keymap.down, 0, .down),
            (Keymap.up, 0, .up),
            (Keymap.enter, 0, .activate),
            (Keymap.escape, 0, .dismiss),
            (0xFF53, Keymap.control, .expand),
            (0xFF51, Keymap.control, .collapse),
            (0xFF55, 0, .top),
            (UInt32(UnicodeScalar("1").value), Keymap.control, .machine(0)),
            (UInt32(UnicodeScalar("3").value), Keymap.control, .machine(2)),
            (UInt32(UnicodeScalar("1").value), 0, nil),
            (UInt32(UnicodeScalar("n").value), Keymap.control, .down),
            (UInt32(UnicodeScalar("j").value), 0, nil),
            (0xFF53, 0, nil),
            (UInt32(UnicodeScalar(" ").value), 0, nil),
        ]
        for (keyval, state, expected) in keys {
            guard let chord = KeyChord.canonical(keyval: keyval, state: state) else {
                failures.append("chord \(keyval) does not canonicalize")
                continue
            }
            expect(ModelChooser.command(for: chord) == expected, "key \(keyval)/\(state)")
        }
        return failures
    }
}
