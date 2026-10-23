import CodingAgentKit
import Foundation

extension UsageAnalytics {
    /// A model as every row names it: the codename the catalog gives it where a client had one
    /// to hand, which is what the person's own picker shows, and the id cleaned of its packaging
    /// otherwise. The rule for what a catalog name is worth wearing is ``ModelBadge``'s, applied
    /// once by ``modelNames(from:)``; this only looks the result up.
    struct Names: Sendable, Equatable {
        let table: [String: String]

        func callAsFunction(_ model: String) -> String {
            table[model] ?? ModelBadge.shortName(model)
        }
    }

    /// The names a catalog gives its models, keyed the way a ledger keys them — `provider/id`,
    /// and the bare id too where no two providers disagree about it, because a Claude bridge
    /// names its models without a door. A name is whatever ``ModelBadge`` would put on a session
    /// row, so a codename shows here the way it does in the picker.
    public static func modelNames(from catalog: [ModelInfo]) -> [String: String] {
        catalogTable(catalog) {
            ModelBadge.shortName($0.id, catalogName: $0.name, providerID: $0.providerID)
        }
    }

    /// The context windows a catalog states, keyed like ``modelNames(from:)``. A model whose
    /// catalog entry says nothing has no entry, so no row claims a window nobody reported.
    public static func contextWindows(from catalog: [ModelInfo]) -> [String: Int] {
        catalogTable(catalog) { ($0.contextWindow ?? 0) > 0 ? $0.contextWindow : nil }
    }

    /// The same names from what each server last told this device about its models.
    public static func modelNames(profileIDs: [String]) -> [String: String] {
        modelNames(from: profileIDs.flatMap(ModelCatalogStore.cached))
    }

    public static func contextWindows(profileIDs: [String]) -> [String: Int] {
        contextWindows(from: profileIDs.flatMap(ModelCatalogStore.cached))
    }

    /// Makes sure the names exist to be read. A catalog is remembered whenever a chat or a chooser
    /// asked a server for it, so a device that has only ever opened the month has none, and the
    /// models would wear their ids. A server that has just answered the ledger can be asked once
    /// more; one whose catalog is already remembered is left alone.
    public static func rememberModels(profileID: String, backend: any CodingAgentBackend) async {
        guard ModelCatalogStore.cached(profileID).isEmpty else { return }
        await ModelCatalogStore.refresh(profileID: profileID, backend: backend)
    }

    private static func catalogTable<Value: Equatable>(
        _ catalog: [ModelInfo], _ value: (ModelInfo) -> Value?
    ) -> [String: Value] {
        var table: [String: Value] = [:]
        var bare: [String: Value] = [:]
        var contested = Set<String>()
        for model in catalog {
            guard let known = value(model) else { continue }
            table["\(model.providerID)/\(model.id)"] = known
            if let seen = bare[model.id], seen != known { contested.insert(model.id) }
            bare[model.id] = known
        }
        for (id, known) in bare where !contested.contains(id) && table[id] == nil {
            table[id] = known
        }
        return table
    }
}
