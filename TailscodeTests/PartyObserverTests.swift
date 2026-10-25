import CodingAgentKit
import Foundation
import Testing
import TailscodeCore
import UIKit

@testable import Tailscode

/// The party sheet observes stores that change wherever their caller is. A store that posted from
/// a background task used to run the sheet's main-actor observer there, which traps.
@MainActor
struct PartyObserverTests {
    private func makeParty() -> PartyViewController {
        let party = PartyViewController(
            sources: { [] },
            aim: { PartyAim(model: nil, effort: nil, agentOptions: [], isBusy: false) },
            actions: PartyViewController.Actions(
                take: { _ in }, takeModel: { _ in }, takeElsewhere: { _ in }, browseAll: {},
                fill: { _, _ in }),
            editing: false)
        party.loadViewIfNeeded()
        return party
    }

    private func settled(after post: @escaping @Sendable () -> Void) async {
        let (heard, sink) = AsyncStream.makeStream(of: Void.self)
        let token = NotificationCenter.default.addObserver(
            forName: ModelCatalogStore.didChange, object: nil, queue: .main
        ) { _ in sink.yield() }
        defer { NotificationCenter.default.removeObserver(token) }
        await Task.detached { post() }.value
        for await _ in heard { break }
    }

    @Test func aCatalogStoredInTheBackgroundDoesNotTrapAnOpenParty() async {
        let party = makeParty()
        let profile = "party-observer-" + UUID().uuidString
        defer { ModelCatalogStore.forget(profile) }
        let models = [ModelInfo(id: "m", name: "M", providerID: "p")]
        await settled { ModelCatalogStore.store(models, for: profile) }
        #expect(party.isViewLoaded)
    }

    @Test func aPartyChangedInTheBackgroundDoesNotTrapAnOpenParty() async {
        let party = makeParty()
        let saved = UserDefaults.standard.string(forKey: "tailscode.modelParty")
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: "tailscode.modelParty")
            } else {
                UserDefaults.standard.removeObject(forKey: "tailscode.modelParty")
            }
        }
        let preset = ModelPreset(
            selection: ModelSelection(providerID: "p", modelID: "party-observer-" + UUID().uuidString),
            effort: .server)
        let (heard, sink) = AsyncStream.makeStream(of: Void.self)
        let token = NotificationCenter.default.addObserver(
            forName: ModelParty.didChange, object: nil, queue: .main
        ) { _ in sink.yield() }
        defer { NotificationCenter.default.removeObserver(token) }
        await Task.detached { _ = ModelParty.place(preset) }.value
        for await _ in heard { break }
        #expect(party.isViewLoaded)
    }
}
