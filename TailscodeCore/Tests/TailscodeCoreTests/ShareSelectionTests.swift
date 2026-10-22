import Foundation
import Testing
@testable import TailscodeCore

@Suite("Share selection")
struct ShareSelectionTests {
    private func rich() throws -> UsageAnalytics {
        try #require(ShareFixtures.analytics(named: "rich"))
    }

    @Test("The hero is not a choice and the rest come in one fixed order")
    func selectableModules() {
        #expect(!ShareModule.hero.isSelectable)
        #expect(!ShareModule.selectable.contains(.hero))
        #expect(ShareModule.selectable.count == ShareModule.allCases.count - 1)
        #expect(Set(ShareModule.priority) == Set(ShareModule.selectable))
        #expect(ShareSelection.canonical([.records, .daily, .models, .daily]) == [.daily, .models, .records])
    }

    @Test("Formats hold what the brief says and open on a curated set that fits")
    func formats() {
        #expect(ShareFormat.post.capacity == 4)
        #expect(ShareFormat.square.capacity == 4)
        #expect(ShareFormat.portrait.capacity == 6)
        #expect(ShareFormat.long.capacity == nil)
        #expect(ShareFormat.fallback == .post)
        for format in ShareFormat.allCases {
            if let capacity = format.capacity { #expect(format.curated.count <= capacity) }
            #expect(ShareSelection.canonical(format.curated) == format.curated)
        }
        #expect(ShareFormat.post.curated == [.daily, .models, .tokens, .records])
    }

    @Test("A module the account cannot fill is disabled with its reason, never silently absent")
    func unavailableModules() throws {
        let local = try #require(ShareFixtures.analytics(named: "localSessions"))
        #expect(!ShareModule.tools.isAvailable(in: local))
        #expect(ShareModule.tools.unavailableReason(in: local) == "No server counted tool calls")
        let fit = ShareSelection(format: .post).fit(local)
        #expect(fit.unavailable[.tools] != nil)
        #expect(fit.state(of: .tools) == .blocked("No server counted tool calls"))
        let noDaily = try #require(ShareFixtures.analytics(named: "noDaily"))
        #expect(ShareModule.daily.unavailableReason(in: noDaily) == "No activity in this window")
        let oneModel = try #require(ShareFixtures.analytics(named: "oneModel"))
        #expect(ShareModule.providers.unavailableReason(in: oneModel) != nil)
        for module in ShareModule.allCases where module.isAvailable(in: local) {
            #expect(module.unavailableReason(in: local) == nil)
        }
    }

    @Test("A curated set that the account cannot fill is topped up to the format's capacity")
    func curatedIsToppedUp() throws {
        let noDaily = try #require(ShareFixtures.analytics(named: "noDaily"))
        let fit = ShareSelection(format: .post).fit(noDaily)
        #expect(fit.shown.count == 4)
        #expect(!fit.shown.contains(.daily))
        #expect(fit.shown.contains(.models))
        let chosen = ShareSelection(format: .post, chosen: [.post: [.daily, .models]])
        let kept = chosen.fit(noDaily)
        #expect(kept.shown == [.models])
    }

    @Test("A chosen set longer than the format holds loses what ranks last, and says so")
    func dropsByPriority() throws {
        let analytics = try rich()
        let all = ShareModule.selectable
        let selection = ShareSelection(format: .post, chosen: [.post: all])
        let fit = selection.fit(analytics)
        #expect(fit.shown.count == 4)
        #expect(fit.shown == ShareSelection.canonical(Array(ShareModule.priority.prefix(4))))
        #expect(Set(fit.shown).union(fit.dropped).isSubset(of: Set(all)))
        #expect(fit.dropped.count == all.filter { $0.isAvailable(in: analytics) }.count - 4)
        let note = try #require(fit.note)
        #expect(note.hasPrefix("Post holds 4 modules. Left out: "))
        #expect(fit.dropped.allSatisfy { note.contains($0.title) })
        #expect(ShareSelection(format: .long, chosen: [.long: all]).fit(analytics).note == nil)
    }

    @Test("Pressing a chip changes one thing, and a full poster refuses a fifth with the reason")
    func toggling() throws {
        let analytics = try rich()
        var selection = ShareSelection(format: .post)
        #expect(!selection.isCustomised)
        #expect(selection.toggle(.models, in: analytics) == .removed)
        #expect(selection.isCustomised)
        #expect(selection.fit(analytics).shown == [.daily, .tokens, .records])
        #expect(selection.toggle(.week, in: analytics) == .added)
        #expect(selection.fit(analytics).shown == [.daily, .week, .tokens, .records])
        let refused = selection.toggle(.tools, in: analytics)
        #expect(refused == .refused("Post holds 4 modules. Turn one off to add another."))
        #expect(selection.fit(analytics).shown == [.daily, .week, .tokens, .records])
        let local = try #require(ShareFixtures.analytics(named: "localSessions"))
        var thin = ShareSelection(format: .portrait)
        #expect(thin.toggle(.tools, in: local) == .refused("No server counted tool calls"))
        #expect(thin.toggle(.hero, in: local) != .added)
        selection.forgetChoices(for: .post)
        #expect(!selection.isCustomised)
    }

    @Test("Each format keeps its own modules")
    func perFormat() throws {
        let analytics = try rich()
        var selection = ShareSelection(format: .post)
        selection.toggle(.tokens, in: analytics)
        selection.format = .long
        #expect(selection.requested == ShareFormat.long.curated)
        selection.toggle(.models, in: analytics)
        selection.format = .post
        #expect(selection.requested == [.daily, .models, .records])
        selection.format = .square
        #expect(selection.requested == ShareFormat.square.curated)
    }

    @Test("The choice survives a restart, and a settings file from the future still opens")
    func persistence() throws {
        let analytics = try rich()
        let suite = try #require(UserDefaults(suiteName: "share-selection-\(UUID().uuidString)"))
        #expect(ShareSelectionStore.load(defaults: suite).format == .post)
        var selection = ShareSelection(format: .portrait)
        selection.toggle(.week, in: analytics)
        selection.toggle(.insights, in: analytics)
        ShareSelectionStore.save(selection, defaults: suite)
        let loaded = ShareSelectionStore.load(defaults: suite)
        #expect(loaded.format == .portrait)
        #expect(loaded.requested == selection.requested)
        #expect(loaded.style.id == "aurora")
        #expect(suite.string(forKey: "tailscode.shareFormat") == "portrait")
        let decoded = ShareSelection.decodeChoices("post=daily,teleport,models;warp=daily;long=;square")
        #expect(decoded[.post] == [.daily, .models])
        #expect(decoded[.long] == [])
        #expect(decoded[.square] == nil)
        #expect(ShareSelection.decodeChoices(nil).isEmpty)
        let untouched = ShareSelection(format: .post)
        ShareSelectionStore.save(untouched, defaults: suite)
        #expect(suite.string(forKey: ShareSelectionStore.modulesKey) == nil)
    }
}
