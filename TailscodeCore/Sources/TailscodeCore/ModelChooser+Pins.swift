import CodingAgentKit
import Foundation

extension ModelChooser {
    /// Whether a star is on this model right now.
    public func isFavorite(_ selection: ModelSelection) -> Bool {
        favoriteKeys.contains(selection.rawValue)
    }

    /// Stars or unstars a model and re-renders: the Yours section answers immediately, so the
    /// press feels like moving the list rather than filing a preference away somewhere.
    ///
    /// A star lit by a pair rather than a bare star is put out with every pin of the model, so a
    /// press on a lit star always leaves it dark.
    public mutating func togglePin(_ selection: ModelSelection) {
        if !favoriteKeys.contains(selection.rawValue), pins.contains(where: { $0.selection == selection }) {
            ModelPresetStore.unpinAll(selection)
        } else {
            ModelFavoritesStore.toggle(selection)
        }
        reloadPins()
        rebuild()
        cursor = min(cursor, max(0, rows.count - 1))
    }

    private mutating func reloadPins() {
        favorites = ModelFavoritesStore.all()
        favoriteKeys = Set(favorites.map(\.rawValue))
        pins = ModelPresetStore.explicit()
    }

    /// Pins or unpins what a press on this row's star means, and answers whether the row is pinned
    /// afterwards. The press toggles the row's own pair — the model at the level a pick of it would
    /// run at — through the store's one rule: pinning it absorbs the model's bare star, unpinning it
    /// takes the star too. A row of the Pinned section toggles exactly its pair. A row lit only by
    /// pairs at other levels puts every one of them out, because a press on a lit star must never
    /// leave it lit by a pin the press cannot see.
    @discardableResult
    public mutating func togglePin(row: ModelChooserRow) -> Bool {
        guard let preset = row.pinning.preset else { return false }
        let all = ModelPresetStore.all()
        let starred = all.contains { $0.selection == preset.selection && $0.effort == .keep }
        if row.pair == nil, row.pinning.isPinned, !all.contains(preset), !starred {
            ModelPresetStore.unpinAll(preset.selection)
        } else {
            ModelPresetStore.pin(preset)
        }
        refreshPins()
        return row.pair != nil
            ? pins.contains(preset)
            : pinnedKeys.contains(preset.selection.rawValue)
    }

    /// Reads the stars and pairs again after a pin changed anywhere, and redraws.
    public mutating func refreshPins() {
        reloadPins()
        let anchor = focused?.anchor
        rebuild()
        cursor = rows.firstIndex { $0.anchor == anchor } ?? min(cursor, max(0, rows.count - 1))
    }
}
