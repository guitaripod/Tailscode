import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The quick ask against the scripted fleet the party's demo uses: three machines whose catalogs
/// are the chooser demo's, the quick ask aimed at the first on Opus at high, and the device's own
/// party and aim put aside while it is on screen and put back when it is gone, for the drive
/// verb that photographs it and the self-test that presses it.
enum QuickAskPartyDemo {
    static let ids = ["arch", "macbook", "studio"]
    nonisolated(unsafe) private static var seeded = false

    static var profiles: [ConnectionProfile] {
        ModelChooserDemo.sources().map { source in
            ConnectionProfile(
                id: source.profileID, name: source.name, backend: source.backend,
                baseURL: URL(string: "http://\(source.profileID).invalid")!)
        }
    }

    static func seed(aimedAt id: String = "arch") {
        PartyDemo.seed()
        seeded = true
        for source in ModelChooserDemo.sources() {
            ModelCatalogStore.store(source.models, for: source.profileID)
        }
        QuickAskDefaults.record(profileID: id)
        QuickAskDefaults.recordModel(ModelChooserDemo.selected, forProfileID: "arch")
        QuickAskDefaults.recordEffort("high", forProfileID: "arch")
    }

    static func restore() {
        guard seeded else { return }
        seeded = false
        PartyDemo.restore()
        for id in ids {
            ModelCatalogStore.forget(id)
            QuickAskDefaults.clearOwnAim(forProfileID: id)
        }
        QuickAskDefaults.clear()
    }

    @discardableResult
    static func present(
        aimedAt id: String = "arch", parent: UnsafeMutablePointer<GtkWidget>?
    ) -> QuickAskWindow? {
        seed(aimedAt: id)
        QuickAskWindow.present(
            servers: profiles, agentEfforts: [:], promptTextGrammar: [:], preferredServer: id,
            recents: [], parent: parent,
            onAsk: { _, _, _, done in done(nil) }, onResume: { _ in })
        return QuickAskWindow.open
    }

    /// *Which one makes room?* over the quick ask's pill with six slots held, so the question can
    /// be photographed without a chooser to ask it from.
    static func offerToFullParty() {
        guard let ask = QuickAskWindow.open else { return }
        ModelParty.replace(
            slot: 5, with: ModelPreset(
                selection: ModelSelection(providerID: "anthropic", modelID: "claude-haiku-4-5"),
                effort: .server), name: "Quick")
        ask.addToParty(
            ModelPreset(
                selection: ModelSelection(providerID: "deepseek", modelID: "deepseek-v4-flash"),
                effort: .level("deep")), on: ask.editor.widget)
    }
}
